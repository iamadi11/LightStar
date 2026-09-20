#if os(macOS)
import Foundation
import CoreGraphics
@testable import LightStarCore

/// Mock screen frame provider for testing color analysis.
/// Delivers deterministic frames without requiring screen capture.
@MainActor
public final class MockScreenFrameProvider: ScreenFrameProvider {
    
    public var onFrame: ((FrameAnalysis) -> Void)?
    public var selectedDisplayID: CGDirectDisplayID?
    public private(set) var isRunning = false
    
    // MARK: - Test Configuration
    
    /// Frames to deliver when running.
    public var framesToDeliver: [FrameAnalysis] = []
    
    /// Delay between frames in seconds.
    public var frameDelay: TimeInterval = 0.033 // ~30fps
    
    /// Whether to loop frames continuously.
    public var loopFrames = false
    
    /// Error to throw on start, if any.
    public var startError: Error?
    
    /// Simulated available displays.
    public static var mockDisplays: [(id: CGDirectDisplayID, name: String)] = [
        (id: 1, name: "Built-in Display"),
        (id: 2, name: "External Display")
    ]
    
    // MARK: - Internal State
    
    private var frameIndex = 0
    private var deliveryTask: Task<Void, Never>?
    private var deliveredFrameCount = 0
    
    public init() {}
    
    // MARK: - ScreenFrameProvider
    
    public func start() async throws {
        if let error = startError {
            throw error
        }
        
        guard !isRunning else { return }
        isRunning = true
        frameIndex = 0
        deliveredFrameCount = 0
        
        deliveryTask = Task { @MainActor in
            while !Task.isCancelled && isRunning {
                if frameIndex < framesToDeliver.count {
                    let frame = framesToDeliver[frameIndex]
                    onFrame?(frame)
                    deliveredFrameCount += 1
                    frameIndex += 1
                    
                    if loopFrames && frameIndex >= framesToDeliver.count {
                        frameIndex = 0
                    }
                }
                
                try? await Task.sleep(nanoseconds: UInt64(frameDelay * 1_000_000_000))
            }
        }
    }
    
    public func stop() async {
        isRunning = false
        deliveryTask?.cancel()
        deliveryTask = nil
    }
    
    public static func availableDisplays() async -> [(id: CGDirectDisplayID, name: String)] {
        return mockDisplays
    }
    
    // MARK: - Test Helpers
    
    /// Deliver a single frame immediately.
    public func deliverFrame(_ frame: FrameAnalysis) {
        guard isRunning else { return }
        onFrame?(frame)
        deliveredFrameCount += 1
    }
    
    /// Get the number of frames delivered.
    public var framesDelivered: Int {
        deliveredFrameCount
    }
    
    /// Reset the provider state.
    public func reset() {
        framesToDeliver = []
        frameIndex = 0
        deliveredFrameCount = 0
        startError = nil
        loopFrames = false
    }

    /// Wait until at least `count` frames have been delivered, or timeout.
    public func waitUntilFramesDelivered(_ count: Int, timeoutNanoseconds: UInt64 = 2_000_000_000) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while framesDelivered < count {
            if DispatchTime.now().uptimeNanoseconds >= deadline { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

// MARK: - Test Frame Fixtures

public extension FrameAnalysis {
    
    /// Pure red frame.
    static let pureRed = FrameAnalysis(
        dominantHue: 0.0,
        dominantSaturation: 1.0,
        dominantBrightness: 1.0,
        blackPixelPercentage: 0,
        hasRectangularBlackRegion: false
    )
    
    /// Pure green frame.
    static let pureGreen = FrameAnalysis(
        dominantHue: 0.333,
        dominantSaturation: 1.0,
        dominantBrightness: 1.0,
        blackPixelPercentage: 0,
        hasRectangularBlackRegion: false
    )
    
    /// Pure blue frame.
    static let pureBlue = FrameAnalysis(
        dominantHue: 0.667,
        dominantSaturation: 1.0,
        dominantBrightness: 1.0,
        blackPixelPercentage: 0,
        hasRectangularBlackRegion: false
    )
    
    /// Pure white frame (low saturation).
    static let pureWhite = FrameAnalysis(
        dominantHue: 0.0,
        dominantSaturation: 0.0,
        dominantBrightness: 1.0,
        blackPixelPercentage: 0,
        hasRectangularBlackRegion: false
    )
    
    /// All black frame (suspected protected content).
    static let allBlack = FrameAnalysis(
        dominantHue: 0.0,
        dominantSaturation: 0.0,
        dominantBrightness: 0.0,
        blackPixelPercentage: 1.0,
        hasRectangularBlackRegion: true
    )
    
    /// Frame with rectangular black region (DRM-like).
    static let protectedContent = FrameAnalysis(
        dominantHue: 0.5,
        dominantSaturation: 0.3,
        dominantBrightness: 0.2,
        blackPixelPercentage: 0.75,
        hasRectangularBlackRegion: true
    )
    
    /// Normal desktop frame.
    static let normalDesktop = FrameAnalysis(
        dominantHue: 0.6,
        dominantSaturation: 0.4,
        dominantBrightness: 0.7,
        blackPixelPercentage: 0.1,
        hasRectangularBlackRegion: false
    )
    
    /// Create a custom frame.
    static func custom(hue: Double, saturation: Double, brightness: Double, blackPercent: Double = 0, hasBlackRegion: Bool = false) -> FrameAnalysis {
        FrameAnalysis(
            dominantHue: hue,
            dominantSaturation: saturation,
            dominantBrightness: brightness,
            blackPixelPercentage: blackPercent,
            hasRectangularBlackRegion: hasBlackRegion
        )
    }
}

#endif
