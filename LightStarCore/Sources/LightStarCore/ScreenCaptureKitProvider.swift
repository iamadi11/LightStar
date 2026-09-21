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
    public var selectedDisplayID: CGDirectDisplayID?
    
    /// Whether to use GPU-accelerated analysis (Metal). Defaults to true when available.
    public nonisolated(unsafe) var useMetalAnalysis: Bool = true
    
    public private(set) var isRunning = false
    
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "screen.capture.kit", qos: .userInteractive)
    private var generation = 0
    
    // Metal analyzer for GPU acceleration
    private let metalAnalyzer = MetalColorAnalyzer.shared
    
    // Diagnostics
    private var frameCount = 0
    private var lastFrameTime: Double = 0
    private var recentBlackPercentages: [Double] = []
    private let blackPercentageWindowSize = 30
    private var usingMetal = false
    
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
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.capturesAudio = false
        cfg.showsCursor = false
        
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        
        guard !CaptureSessionPolicy.isSuperseded(startGeneration: gen, currentGeneration: generation) else {
            try? await s.stopCapture()
            throw CancellationError()
        }
        
        stream = s
        isRunning = true
        frameCount = 0
        recentBlackPercentages = []
    }
    
    public func stop() async {
        generation &+= 1  // invalidate any concurrent start(), even if idle
        guard isRunning else { return }
        try? await stream?.stopCapture()
        stream = nil
        isRunning = false
    }
    
    /// Get current diagnostics for the capture session.
    public func getDiagnostics() -> CaptureProviderDiagnostics {
        let avgBlackPercentage = recentBlackPercentages.isEmpty ? 0 : recentBlackPercentages.reduce(0, +) / Double(recentBlackPercentages.count)
        return CaptureProviderDiagnostics(
            providerName: usingMetal ? "ScreenCaptureKit (Metal GPU)" : "ScreenCaptureKit (CPU)",
            frameRate: frameCount > 1 ? Double(frameCount - 1) / max(0.001, CACurrentMediaTime() - lastFrameTime) : 0,
            resolution: (48, 27),
            captureLatencyMs: 0,
            protectedContentDetected: avgBlackPercentage > 0.6,
            blackFramePercentage: avgBlackPercentage
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
        guard type == .screen else { return }
        guard let pb = sb.imageBuffer else { return }
        
        // Capture useMetalAnalysis before async dispatch to avoid data race
        let wantMetal = useMetalAnalysis
        // Use Metal GPU analysis when available and enabled
        let analysis: FrameAnalysis
        let usedMetal: Bool
        if wantMetal, let metal = MetalColorAnalyzer.shared {
            analysis = metal.analyze(pb)
            usedMetal = true
        } else {
            analysis = analyzePixelBuffer(pb)
            usedMetal = false
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameCount += 1
            self.usingMetal = usedMetal
            if self.frameCount == 1 { self.lastFrameTime = CACurrentMediaTime() }
            
            self.recentBlackPercentages.append(analysis.blackPixelPercentage)
            if self.recentBlackPercentages.count > self.blackPercentageWindowSize {
                self.recentBlackPercentages.removeFirst()
            }
            
            self.onFrame?(analysis)
        }
    }
}

// MARK: - Pixel Analysis

private func analyzePixelBuffer(_ pb: CVPixelBuffer) -> FrameAnalysis {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else {
        return FrameAnalysis(dominantHue: 0, dominantSaturation: 0, dominantBrightness: 0)
    }
    
    let w = CVPixelBufferGetWidth(pb)
    let h = CVPixelBufferGetHeight(pb)
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    let ptr = base.assumingMemoryBound(to: UInt8.self)
    
    let bins = 36
    var histogram = [Double](repeating: 0, count: bins)
    var binSat = [Double](repeating: 0, count: bins)
    var binVal = [Double](repeating: 0, count: bins)
    var binCount = [Int](repeating: 0, count: bins)
    var totalV = 0.0
    var pixCount = 0
    var blackCount = 0
    var darkRows = 0
    var darkCols = 0
    
    for row in 0..<h {
        var rowBlackCount = 0
        for col in 0..<w {
            let isEdge = row == 0 || row == h - 1 || col == 0 || col == w - 1
            let wt: Double = isEdge ? 3.0 : 1.0
            let i = row * bpr + col * 4
            let r = Double(ptr[i + 2]) / 255
            let g = Double(ptr[i + 1]) / 255
            let b = Double(ptr[i]) / 255
            let (hh, ss, vv) = rgbToHSV(r, g, b)
            totalV += vv * wt
            pixCount += 1
            
            if vv < 0.05 {
                blackCount += 1
                rowBlackCount += 1
            }
            
            guard vv > 0.12, ss > 0.15 else { continue }
            
            let bin = min(bins - 1, Int(hh * Double(bins)))
            histogram[bin] += wt * ss * vv
            binSat[bin] += ss
            binVal[bin] += vv
            binCount[bin] += 1
        }
        if rowBlackCount > w * 8 / 10 { darkRows += 1 }
    }
    
    for col in 0..<w {
        var colBlackCount = 0
        for row in 0..<h {
            let i = row * bpr + col * 4
            let r = Double(ptr[i + 2]) / 255
            let g = Double(ptr[i + 1]) / 255
            let b = Double(ptr[i]) / 255
            let (_, _, vv) = rgbToHSV(r, g, b)
            if vv < 0.05 { colBlackCount += 1 }
        }
        if colBlackCount > h * 8 / 10 { darkCols += 1 }
    }
    
    let blackPercentage = pixCount > 0 ? Double(blackCount) / Double(pixCount) : 0
    let hasRectangularBlackRegion = darkRows > h / 3 || darkCols > w / 3
    
    if let maxBin = histogram.indices.max(by: { histogram[$0] < histogram[$1] }),
       histogram[maxBin] > 0, binCount[maxBin] > 0 {
        let hue = (Double(maxBin) + 0.5) / Double(bins)
        let n = Double(binCount[maxBin])
        let sat = binSat[maxBin] / n
        let val = binVal[maxBin] / n
        return FrameAnalysis(
            dominantHue: hue,
            dominantSaturation: min(1, sat),
            dominantBrightness: min(1, val),
            blackPixelPercentage: blackPercentage,
            hasRectangularBlackRegion: hasRectangularBlackRegion
        )
    }
    
    let avgV = pixCount > 0 ? totalV / Double(pixCount) : 0
    return FrameAnalysis(
        dominantHue: 0,
        dominantSaturation: 0,
        dominantBrightness: avgV,
        blackPixelPercentage: blackPercentage,
        hasRectangularBlackRegion: hasRectangularBlackRegion
    )
}

private func rgbToHSV(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    let s = mx < 1e-6 ? 0.0 : d / mx
    var h = 0.0
    if d > 1e-6 {
        if mx == r { h = (g - b) / d }
        else if mx == g { h = 2 + (b - r) / d }
        else { h = 4 + (r - g) / d }
        h = (h / 6).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
    }
    return (h, s, mx)
}

#endif
