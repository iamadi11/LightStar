#if os(macOS)
import CoreVideo
import ScreenCaptureKit
import CoreMedia
import AppKit

/// Screen color sampler that wraps a ScreenFrameProvider for color extraction.
/// Protected-frame policy: hold last good HSV; do not write DRM black to the strip.
@MainActor
public final class ScreenColorSampler: NSObject {

    /// Legacy callback for color updates (H, S, V in 0-1 range).
    public var onColor: ((Double, Double, Double) -> Void)?

    public var onAudioBands: ((FrequencyBands) -> Void)? {
        get { provider.onAudioBands }
        set { provider.onAudioBands = newValue }
    }

    public var capturesAudio: Bool {
        get { provider.capturesAudio }
        set { provider.capturesAudio = newValue }
    }

    /// Called when the DRM guide should appear (N consecutive protected frames).
    public var onProtectedContentDetected: (() -> Void)?

    /// Lamp gradient colours for frames that pass the protected-content hold.
    public var onZones: (([WizRGB]) -> Void)?

    /// Called with detailed frame analysis for diagnostics.
    public var onFrameAnalysis: ((FrameAnalysis) -> Void)?

    /// Called when the popover banner should appear, update, or clear.
    public var onDiagnosticsUpdate: ((ProtectedContentBanner?) -> Void)?

    public var responsiveness: Double = 1.0   // unused, kept for API compat

    /// Display selection — set before calling start()
    public var selectedDisplayID: CGDirectDisplayID? = nil {
        didSet { provider.selectedDisplayID = selectedDisplayID }
    }

    public var isRunning: Bool { provider.isRunning }

    public private(set) var protectedContentDetected = false
    public private(set) var protectedContentBanner: ProtectedContentBanner?

    private var tracker = ProtectedContentTracker()

    private let provider: ScreenCaptureKitProvider

    public let diagnostics = CaptureDiagnostics()

    public override init() {
        self.provider = ScreenCaptureKitProvider()
        super.init()
        setupProviderCallback()
    }

    public init(provider: ScreenCaptureKitProvider) {
        self.provider = provider
        super.init()
        setupProviderCallback()
    }

    private var trailingRefresh: Task<Void, Never>?

    /// Re-paint the lightbar from the latest frame. Lightbar settings write
    /// UserDefaults; on a still screen no new frame would show the change.
    /// Sync drops zone frames over 30 fps, so once a slider stops, paint once
    /// more so its final position always lands.
    public func refreshZones() {
        paintLatestZones()
        trailingRefresh?.cancel()
        trailingRefresh = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 60_000_000) } catch { return }
            self?.paintLatestZones()
        }
    }

    public func lampSides() -> [LampGradient.Side: WizRGB] { provider.currentLampSides() }

    private func paintLatestZones() {
        guard isRunning, let onZones else { return }
        let zones = provider.currentLampZones()
        guard LampGradient.shouldPaint(zones, frameWritable: false) else { return }
        onZones(zones)
    }

    private func setupProviderCallback() {
        // ponytail: never removed; the sampler lives as long as the app.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshZones() }
        }
        provider.onFrame = { [weak self] analysis in
            guard let self else { return }
            self.handleFrame(analysis)
        }
    }

    func handleFrame(_ analysis: FrameAnalysis) {
        let write = tracker.ingest(analysis)
        diagnostics.processFrame(analysis, consecutiveProtectedFrames: tracker.consecutiveProtectedFrames)

        let banner = diagnostics.makeBanner(showsGuide: tracker.showsGuide)
        if banner != protectedContentBanner {
            protectedContentBanner = banner
            onDiagnosticsUpdate?(banner)
        }

        if tracker.showsGuide && !protectedContentDetected {
            protectedContentDetected = true
            onProtectedContentDetected?()
        } else if !tracker.showsGuide {
            protectedContentDetected = false
        }

        onFrameAnalysis?(analysis)

        var writable = false
        if case .write(let hsv) = write {
            writable = true
            onColor?(hsv.hue, hsv.saturation, hsv.brightness)
        }
        if !analysis.zones.isEmpty, LampGradient.shouldPaint(analysis.zones, frameWritable: writable) {
            onZones?(analysis.zones)
        }
    }

    @MainActor
    public static func availableDisplays() async -> [(id: CGDirectDisplayID, name: String)] {
        await ScreenCaptureKitProvider.availableDisplays()
    }

    public func start() async throws {
        resetProtectedContentDetection()
        diagnostics.startBrowserMonitoring()
        do {
            try await provider.start()
        } catch {
            diagnostics.stopBrowserMonitoring()
            throw error
        }
    }

    public func stop() async {
        diagnostics.stopBrowserMonitoring()
        resetProtectedContentDetection()
        if protectedContentBanner != nil {
            protectedContentBanner = nil
            onDiagnosticsUpdate?(nil)
        }
        await provider.stop()
    }

    public func getDiagnostics() -> CaptureProviderDiagnostics {
        let base = provider.getDiagnostics()
        return CaptureProviderDiagnostics(
            providerName: base.providerName,
            frameRate: base.frameRate,
            resolution: base.resolution,
            captureLatencyMs: base.captureLatencyMs,
            protectedContentDetected: tracker.showsGuide,
            blackFramePercentage: base.blackFramePercentage
        )
    }

    public func resetProtectedContentDetection() {
        tracker.reset()
        diagnostics.reset()
        protectedContentDetected = false
        protectedContentBanner = nil
    }
}

#endif
