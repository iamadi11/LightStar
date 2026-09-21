#if os(iOS)
import CoreGraphics
import Foundation

public typealias CGDirectDisplayID = UInt32

/// Analysis result for a captured frame (iOS stub).
public struct FrameAnalysis: Sendable {
    public let dominantHue: Double
    public let dominantSaturation: Double
    public let dominantBrightness: Double
    public let blackPixelPercentage: Double
    public let hasRectangularBlackRegion: Bool
    
    public var suspectedProtectedContent: Bool { false }
    
    public init(
        dominantHue: Double = 0,
        dominantSaturation: Double = 0,
        dominantBrightness: Double = 0,
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

/// Diagnostics stub for iOS.
public struct CaptureProviderDiagnostics: Sendable {
    public let providerName: String
    public let frameRate: Double
    public let resolution: (width: Int, height: Int)
    public let captureLatencyMs: Double
    public let protectedContentDetected: Bool
    public let blackFramePercentage: Double
    
    public init(
        providerName: String = "None",
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

@MainActor
public final class ScreenColorSampler: NSObject {
    public var onColor: ((Double, Double, Double) -> Void)?
    public var onAudioBands: ((FrequencyBands) -> Void)?
    public var capturesAudio = false
    public var onProtectedContentDetected: (() -> Void)?
    public var onFrameAnalysis: ((FrameAnalysis) -> Void)?
    public var selectedDisplayID: CGDirectDisplayID?
    public var responsiveness: Double = 1.0
    public var protectedContentDetected: Bool { false }
    
    public func start() async throws {
        throw NSError(domain: "ScreenCapture", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Screen sync is macOS only"])
    }
    public func stop() async {}
    public static func availableDisplays() async -> [(id: CGDirectDisplayID, name: String)] { [] }
    public func getDiagnostics() -> CaptureProviderDiagnostics { CaptureProviderDiagnostics() }
    public func resetProtectedContentDetection() {}
}

@MainActor
public final class SystemAudioSampler: NSObject {
    public var onBands: ((FrequencyBands) -> Void)?
    public func start() async throws {
        throw NSError(domain: "SystemAudio", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "System audio capture is macOS only"])
    }
    public func stop() async {}
}
#endif
