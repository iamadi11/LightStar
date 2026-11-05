#if os(macOS)
import CoreVideo
import ScreenCaptureKit
import CoreMedia
import AppKit

/// ScreenCaptureKit-based frame provider. Primary capture method for macOS 12.3+.
/// Uses Metal GPU acceleration when available for efficient color analysis.
@MainActor
public final class ScreenCaptureKitProvider: NSObject, ScreenFrameProvider {
    
    public var onFrame: ((FrameAnalysis) -> Void)?
    public var onAudioBands: ((FrequencyBands) -> Void)?
    /// Combined must not set this. Both uses a video-only screen stream plus
    /// standalone SystemAudioSampler (see CombinedCapturePolicy).
    public var capturesAudio = false
    public var selectedDisplayID: CGDirectDisplayID?
    
    /// Whether to use GPU-accelerated analysis (Metal). Defaults to true when available.
    public nonisolated(unsafe) var useMetalAnalysis: Bool = true
    
    public private(set) var isRunning = false
    
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "screen.capture.kit", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "screen.capture.audio", qos: .userInteractive)
    private let audioEngine = AudioFFTEngine()
    private var generation = 0
    
    // Metal analyzer for GPU acceleration
    private let metalAnalyzer = MetalColorAnalyzer.shared
    
    // Diagnostics
    private var frameCount = 0
    private var lastFrameTime: Double = 0
    private var lastBlackPercentage: Double = 0
    private var usingMetal = false
    nonisolated let lampFrame = LampFrameStore()

    /// Lightbar zones of the latest frame under the current settings.
    public func currentLampZones() -> [WizRGB] { lampFrame.zones() }
    
    @MainActor
    public static func availableDisplays() async -> [(id: CGDirectDisplayID, name: String)] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [] }
        let nameByID = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return (id, screen.localizedName)
        })
        return content.displays.map { ($0.displayID, nameByID[$0.displayID] ?? "Display \($0.displayID)") }
    }
    
    public func start() async throws {
        guard !isRunning else { return }
        generation &+= 1
        let gen = generation
        
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display: SCDisplay
        if let id = selectedDisplayID,
           let match = content.displays.first(where: { $0.displayID == id }) {
            display = match
        } else {
            guard let first = content.displays.first else {
                throw NSError(domain: "ScreenCapture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "No display found"])
            }
            display = first
        }
        
        let cfg = SCStreamConfiguration()
        cfg.width = 48
        cfg.height = 27
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        // 30 Hz: the lightbar takes 30 fps; the strip's BLE writes stay gated at 20 Hz
        // in the sync loop. EE-011 had 20 here when only the strip existed.
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.capturesAudio = capturesAudio
        cfg.showsCursor = false
        if capturesAudio {
            cfg.sampleRate = 44100
            cfg.channelCount = 2
        }
        
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if capturesAudio {
            audioEngine.prepare()
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await s.startCapture()
        
        guard !CaptureSessionPolicy.isSuperseded(startGeneration: gen, currentGeneration: generation) else {
            try? await s.stopCapture()
            throw CancellationError()
        }
        
        stream = s
        isRunning = true
        frameCount = 0
        lastBlackPercentage = 0
    }
    
    public func stop() async {
        generation &+= 1  // invalidate any concurrent start(), even if idle
        lampFrame.clear()
        guard isRunning else { return }
        try? await stream?.stopCapture()
        stream = nil
        isRunning = false
        onAudioBands = nil
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            audioQueue.async {
                self.audioEngine.reset()
                cont.resume()
            }
        }
    }
    
    /// Get current diagnostics for the capture session.
    public func getDiagnostics() -> CaptureProviderDiagnostics {
        CaptureProviderDiagnostics(
            providerName: usingMetal ? "ScreenCaptureKit (Metal GPU)" : "ScreenCaptureKit (CPU)",
            frameRate: frameCount > 1 ? Double(frameCount - 1) / max(0.001, CACurrentMediaTime() - lastFrameTime) : 0,
            resolution: (48, 27),
            captureLatencyMs: 0,
            protectedContentDetected: false,
            blackFramePercentage: lastBlackPercentage
        )
    }
    
    /// Check if Metal GPU acceleration is available.
    public static var isMetalAvailable: Bool {
        MetalColorAnalyzer.shared != nil
    }
}

extension ScreenCaptureKitProvider: SCStreamOutput {
    public nonisolated func stream(_ stream: SCStream,
                                   didOutputSampleBuffer sb: CMSampleBuffer,
                                   of type: SCStreamOutputType) {
        if type == .audio {
            audioEngine.ingest(sb) { bands in
                DispatchQueue.main.async { [weak self] in self?.onAudioBands?(bands) }
            }
            return
        }
        guard type == .screen else { return }
        guard let pb = sb.imageBuffer else { return }
        
        // Capture useMetalAnalysis before async dispatch to avoid data race
        let wantMetal = useMetalAnalysis
        // Use Metal GPU analysis when available and enabled
        var analysis: FrameAnalysis
        let usedMetal: Bool
        if wantMetal, let metal = MetalColorAnalyzer.shared {
            analysis = metal.analyze(pb)
            usedMetal = true
        } else {
            analysis = MetalColorAnalyzer.cpuAnalysis(pb)
            usedMetal = false
        }
        lampFrame.store(pb)
        analysis.zones = lampFrame.zones()
        
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameCount += 1
            self.usingMetal = usedMetal
            if self.frameCount == 1 { self.lastFrameTime = CACurrentMediaTime() }
            self.lastBlackPercentage = analysis.blackPixelPercentage
            self.onFrame?(analysis)
        }
    }
}

// MARK: - Pixel Analysis

/// The latest captured frame (48×27, ~5 KB), kept so lightbar settings —
/// position, width, swap, orientation — apply at once. On a still screen (a paused
/// video, while lining the lightbar up) ScreenCaptureKit sends no new frames.
final class LampFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var width = 0, height = 0, bytesPerRow = 0
    private var bars = BarsTracker()

    func store(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let copy = Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: bpr * h))
        lock.lock()
        bytes = copy; width = w; height = h; bytesPerRow = bpr
        lock.unlock()
    }

    func clear() {
        lock.lock(); bytes = []; lock.unlock()
    }

    /// Zones of the latest frame under the current lightbar settings.
    func zones() -> [WizRGB] {
        lock.lock()
        let (b, w, h, bpr) = (bytes, width, height, bytesPerRow)
        lock.unlock()
        guard !b.isEmpty else { return [] }
        return b.withUnsafeBufferPointer {
            let seen = LampGradient.ignoreBars
                ? LampGradient.blackBars(bgra: $0.baseAddress!, width: w, height: h, bytesPerRow: bpr) : .none
            lock.lock(); let frameBars = bars.next(seen); lock.unlock()
            return LampGradient.screenZones(
                bgra: $0.baseAddress!, width: w, height: h, bytesPerRow: bpr,
                count: LampGradient.colourCount(for: .current, segments: LampGradient.segmentCount),
                orientation: LampGradient.orientation,
                flipped: LampGradient.flipped,
                followBrightness: UserDefaults.standard.bool(forKey: "videoSyncBrightness"),
                edge: LampGradient.edge, depth: LampGradient.edgeDepth, bars: frameBars
            )
        }
    }
}

#endif
