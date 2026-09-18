#if os(macOS)
import CoreVideo
import CoreGraphics
import Foundation

/// Analysis result for a captured frame, including protected content detection.
public struct FrameAnalysis: Sendable {
    public let dominantHue: Double
    public let dominantSaturation: Double
    public let dominantBrightness: Double
    public let blackPixelPercentage: Double
    public let hasRectangularBlackRegion: Bool
    
    public var suspectedProtectedContent: Bool {
        blackPixelPercentage > 0.6 && hasRectangularBlackRegion
    }
    
    public init(
        dominantHue: Double,
        dominantSaturation: Double,
        dominantBrightness: Double,
        blackPixelPercentage: Double = 0,
        hasRectangularBlackRegion: Bool = false
    ) {
        self.dominantHue = dominantHue
        self.dominantSaturation = dominantSaturation
        self.dominantBrightness = dominantBrightness
        self.blackPixelPercentage = blackPixelPercentage
        self.hasRectangularBlackRegion = hasRectangularBlackRegion
    }
}

/// Protocol for screen capture providers. Allows swapping capture implementations
/// without changing the color analysis or lighting engine.
@MainActor
public protocol ScreenFrameProvider: AnyObject {
    /// Called when a new frame is analyzed. Provides HSV color and analysis metadata.
    var onFrame: ((FrameAnalysis) -> Void)? { get set }
    
    /// The display to capture. Set before calling start().
    var selectedDisplayID: CGDirectDisplayID? { get set }
    
    /// Whether the provider is currently capturing.
    var isRunning: Bool { get }
    
    /// Start capturing frames from the selected display.
    func start() async throws
    
    /// Stop capturing frames.
    func stop() async
    
    /// Get list of available displays.
    static func availableDisplays() async -> [(id: CGDirectDisplayID, name: String)]
}

/// Diagnostics information for capture troubleshooting.
public struct CaptureProviderDiagnostics: Sendable {
    public let providerName: String
    public let frameRate: Double
    public let resolution: (width: Int, height: Int)
    public let captureLatencyMs: Double
    public let protectedContentDetected: Bool
    public let blackFramePercentage: Double
    
    public init(
        providerName: String,
        frameRate: Double = 0,
        resolution: (width: Int, height: Int) = (0, 0),
        captureLatencyMs: Double = 0,
        protectedContentDetected: Bool = false,
        blackFramePercentage: Double = 0
    ) {
        self.providerName = providerName
        self.frameRate = frameRate
        self.resolution = resolution
        self.captureLatencyMs = captureLatencyMs
        self.protectedContentDetected = protectedContentDetected
        self.blackFramePercentage = blackFramePercentage
    }
}

#endif
