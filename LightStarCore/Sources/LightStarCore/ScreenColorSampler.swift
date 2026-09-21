#if os(macOS)
import CoreVideo
import ScreenCaptureKit
import CoreMedia
import AppKit

/// Screen color sampler that wraps a ScreenFrameProvider for color extraction.
/// Provides both legacy HSV callback API and new protected content detection.
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
    
    /// Called when protected content is detected (persistent black regions).
    public var onProtectedContentDetected: (() -> Void)?
    
    /// Called with detailed frame analysis for diagnostics.
    public var onFrameAnalysis: ((FrameAnalysis) -> Void)?
    
    /// Called when diagnostics status changes (for UI updates).
    public var onDiagnosticsUpdate: ((CaptureDiagnostics) -> Void)?
    
    public var responsiveness: Double = 1.0   // unused, kept for API compat

    /// Display selection — set before calling start()
    public var selectedDisplayID: CGDirectDisplayID? = nil {
        didSet { provider.selectedDisplayID = selectedDisplayID }
    }

    public var isRunning: Bool { provider.isRunning }
    
    /// Whether protected content has been detected in recent frames.
    public private(set) var protectedContentDetected = false
    
    /// Consecutive frames with suspected protected content.
    private var consecutiveProtectedFrames = 0
    private let protectedContentThreshold = 20
    
    /// The underlying frame provider (defaults to ScreenCaptureKit).
    private let provider: ScreenCaptureKitProvider
    
    /// Capture diagnostics for DRM detection and browser guidance.
    public let diagnostics = CaptureDiagnostics()
    
    public override init() {
        self.provider = ScreenCaptureKitProvider()
        super.init()
        setupProviderCallback()
    }
    
    /// Initialize with a specific provider (for testing or alternative implementations).
    public init(provider: ScreenCaptureKitProvider) {
        self.provider = provider
        super.init()
        setupProviderCallback()
    }
    
    private func setupProviderCallback() {
        provider.onFrame = { [weak self] analysis in
            guard let self else { return }
            
            // Update diagnostics with frame data
            self.diagnostics.processFrame(analysis)
            
            // Track protected content detection
            if analysis.suspectedProtectedContent {
                self.consecutiveProtectedFrames += 1
                if self.consecutiveProtectedFrames >= self.protectedContentThreshold && !self.protectedContentDetected {
                    self.protectedContentDetected = true
                    self.onProtectedContentDetected?()
                }
            } else {
                self.consecutiveProtectedFrames = 0
                self.protectedContentDetected = false
            }
            
            // Fire detailed analysis callback
            self.onFrameAnalysis?(analysis)
            
            // Fire diagnostics update callback
            self.onDiagnosticsUpdate?(self.diagnostics)
            
            // Fire legacy HSV callback
            self.onColor?(analysis.dominantHue, analysis.dominantSaturation, analysis.dominantBrightness)
        }
    }

    @MainActor
    public static func availableDisplays() async -> [(id: CGDirectDisplayID, name: String)] {
        await ScreenCaptureKitProvider.availableDisplays()
    }

    public func start() async throws {
        consecutiveProtectedFrames = 0
        protectedContentDetected = false
        try await provider.start()
    }

    public func stop() async {
        await provider.stop()
    }
    
    /// Get diagnostics about the current capture session.
    public func getDiagnostics() -> CaptureProviderDiagnostics {
        provider.getDiagnostics()
    }
    
    /// Reset protected content detection state.
    public func resetProtectedContentDetection() {
        consecutiveProtectedFrames = 0
        protectedContentDetected = false
    }
}

#endif
