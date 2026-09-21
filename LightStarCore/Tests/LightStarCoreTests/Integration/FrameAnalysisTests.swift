#if os(macOS)
import XCTest
@testable import LightStarCore

/// Tests for frame analysis and protected content detection.
/// Uses mock frame provider with deterministic test fixtures.
///
/// EXECUTION_CATEGORY: MAC_REQUIRED (needs macOS for FrameAnalysis)
@MainActor
final class FrameAnalysisTests: XCTestCase {
    
    var mockProvider: MockScreenFrameProvider!
    
    override func setUp() async throws {
        mockProvider = MockScreenFrameProvider()
    }
    
    override func tearDown() async throws {
        await mockProvider.stop()
        mockProvider = nil
    }
    
    // MARK: - Protected Content Detection Tests
    
    /// TEST_ID: F001
    /// Tests that all-black frames are flagged as suspected protected content.
    func testAllBlackFrameDetection() {
        let frame = FrameAnalysis.allBlack
        XCTAssertTrue(frame.suspectedProtectedContent)
    }
    
    /// TEST_ID: F002
    /// Tests that frames with rectangular black regions are detected.
    func testRectangularBlackRegionDetection() {
        let frame = FrameAnalysis.protectedContent
        XCTAssertTrue(frame.suspectedProtectedContent)
        XCTAssertGreaterThan(frame.blackPixelPercentage, 0.6)
        XCTAssertTrue(frame.hasRectangularBlackRegion)
    }
    
    /// TEST_ID: F003
    /// Tests that normal frames are NOT flagged as protected.
    func testNormalFrameNotFlagged() {
        let frame = FrameAnalysis.normalDesktop
        XCTAssertFalse(frame.suspectedProtectedContent)
    }

    func testDarkCodeEditorDoesNotLookLikeDRM() {
        let frame = FrameAnalysis.darkCodeEditor
        XCTAssertFalse(frame.suspectedProtectedContent)
        XCTAssertFalse(frame.hasRectangularBlackRegion)
        XCTAssertLessThan(frame.blackPixelPercentage, ProtectedContentPolicy.blackPixelThreshold)
    }
    
    /// TEST_ID: F004
    /// Tests pure color frames (high saturation, no black).
    func testPureColorFrames() {
        let red = FrameAnalysis.pureRed
        let green = FrameAnalysis.pureGreen
        let blue = FrameAnalysis.pureBlue
        
        XCTAssertFalse(red.suspectedProtectedContent)
        XCTAssertFalse(green.suspectedProtectedContent)
        XCTAssertFalse(blue.suspectedProtectedContent)
        
        XCTAssertEqual(red.dominantHue, 0.0, accuracy: 0.01)
        XCTAssertEqual(green.dominantHue, 0.333, accuracy: 0.01)
        XCTAssertEqual(blue.dominantHue, 0.667, accuracy: 0.01)
    }
    
    /// TEST_ID: F005
    /// Tests white frame (zero saturation).
    func testWhiteFrame() {
        let white = FrameAnalysis.pureWhite
        XCTAssertFalse(white.suspectedProtectedContent)
        XCTAssertEqual(white.dominantSaturation, 0.0)
        XCTAssertEqual(white.dominantBrightness, 1.0)
    }
    
    /// TEST_ID: F006
    /// Tests custom frame creation.
    func testCustomFrameCreation() {
        let custom = FrameAnalysis.custom(
            hue: 0.25,
            saturation: 0.75,
            brightness: 0.5,
            blackPercent: 0.1,
            hasBlackRegion: false
        )
        
        XCTAssertEqual(custom.dominantHue, 0.25)
        XCTAssertEqual(custom.dominantSaturation, 0.75)
        XCTAssertEqual(custom.dominantBrightness, 0.5)
        XCTAssertEqual(custom.blackPixelPercentage, 0.1)
        XCTAssertFalse(custom.hasRectangularBlackRegion)
        XCTAssertFalse(custom.suspectedProtectedContent)
    }
    
    // MARK: - Mock Provider Tests
    
    /// TEST_ID: F007
    /// Tests that mock provider delivers configured frames.
    func testMockProviderDeliversFrames() async throws {
        mockProvider.framesToDeliver = [.pureRed, .pureGreen, .pureBlue]
        mockProvider.frameDelay = 0.01
        
        var receivedFrames: [FrameAnalysis] = []
        mockProvider.onFrame = { frame in
            receivedFrames.append(frame)
        }
        
        try await mockProvider.start()
        await mockProvider.waitUntilFramesDelivered(3)
        await mockProvider.stop()
        
        XCTAssertGreaterThanOrEqual(receivedFrames.count, 3)
    }
    
    /// TEST_ID: F008
    /// Tests mock provider with loop enabled.
    func testMockProviderLooping() async throws {
        mockProvider.framesToDeliver = [.pureRed]
        mockProvider.frameDelay = 0.01
        mockProvider.loopFrames = true
        
        var frameCount = 0
        mockProvider.onFrame = { _ in
            frameCount += 1
        }
        
        try await mockProvider.start()
        await mockProvider.waitUntilFramesDelivered(6)
        await mockProvider.stop()
        
        XCTAssertGreaterThan(frameCount, 5, "Should deliver multiple frames when looping")
    }
    
    /// TEST_ID: F009
    /// Tests mock provider start error.
    func testMockProviderStartError() async {
        mockProvider.startError = NSError(domain: "Test", code: 1)
        
        do {
            try await mockProvider.start()
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertFalse(mockProvider.isRunning)
        }
    }
    
    /// TEST_ID: F010
    /// Tests mock provider available displays.
    func testMockAvailableDisplays() async {
        MockScreenFrameProvider.mockDisplays = [
            (id: 1, name: "Main"),
            (id: 2, name: "External"),
            (id: 3, name: "Third Display")
        ]
        
        let displays = await MockScreenFrameProvider.availableDisplays()
        XCTAssertEqual(displays.count, 3)
        XCTAssertEqual(displays[0].name, "Main")
        XCTAssertEqual(displays[1].id, 2)
    }
    
    /// TEST_ID: F011
    /// Tests provider immediate frame delivery.
    func testImmediateFrameDelivery() async throws {
        var receivedFrame: FrameAnalysis?
        mockProvider.onFrame = { frame in
            receivedFrame = frame
        }
        
        try await mockProvider.start()
        mockProvider.deliverFrame(.pureRed)
        
        XCTAssertNotNil(receivedFrame)
        XCTAssertEqual(receivedFrame?.dominantHue, 0.0)
        
        await mockProvider.stop()
    }
    
    /// TEST_ID: F012
    /// Tests provider frame count tracking.
    func testFrameCountTracking() async throws {
        mockProvider.framesToDeliver = [.pureRed, .pureGreen, .pureBlue]
        mockProvider.frameDelay = 0.01
        mockProvider.onFrame = { _ in }
        
        XCTAssertEqual(mockProvider.framesDelivered, 0)
        
        try await mockProvider.start()
        await mockProvider.waitUntilFramesDelivered(3)
        await mockProvider.stop()
        
        XCTAssertGreaterThanOrEqual(mockProvider.framesDelivered, 3)
    }
    
    /// TEST_ID: F013
    /// Tests provider reset.
    func testProviderReset() async throws {
        mockProvider.framesToDeliver = [.pureRed]
        mockProvider.startError = NSError(domain: "Test", code: 1)
        mockProvider.loopFrames = true
        
        mockProvider.reset()
        
        XCTAssertTrue(mockProvider.framesToDeliver.isEmpty)
        XCTAssertNil(mockProvider.startError)
        XCTAssertFalse(mockProvider.loopFrames)
        XCTAssertEqual(mockProvider.framesDelivered, 0)
    }
    
    // MARK: - Edge Cases
    
    /// TEST_ID: F014
    /// Tests boundary between protected and normal detection.
    func testProtectionThresholdBoundary() {
        // Just below threshold (60% black)
        let almostProtected = FrameAnalysis.custom(
            hue: 0.0,
            saturation: 0.0,
            brightness: 0.1,
            blackPercent: 0.59,
            hasBlackRegion: true
        )
        XCTAssertFalse(almostProtected.suspectedProtectedContent)
        
        // Just above threshold
        let barelyProtected = FrameAnalysis.custom(
            hue: 0.0,
            saturation: 0.0,
            brightness: 0.1,
            blackPercent: 0.61,
            hasBlackRegion: true
        )
        XCTAssertTrue(barelyProtected.suspectedProtectedContent)
    }
    
    /// TEST_ID: F015
    /// Tests that black region flag must be true for protection detection.
    func testBlackRegionFlagRequired() {
        let highBlackNoRegion = FrameAnalysis.custom(
            hue: 0.0,
            saturation: 0.0,
            brightness: 0.0,
            blackPercent: 0.9,
            hasBlackRegion: false  // No rectangular region
        )
        XCTAssertFalse(highBlackNoRegion.suspectedProtectedContent)
    }
}

#endif
