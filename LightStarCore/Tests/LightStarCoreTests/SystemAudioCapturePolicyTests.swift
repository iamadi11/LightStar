import XCTest
@testable import LightStarCore

final class SystemAudioCapturePolicyTests: XCTestCase {
    func testMusicPulseUsesProcessTapOnMacOS14_2AndLater() {
        XCTAssertFalse(SystemAudioCapturePolicy.usesProcessTap(majorVersion: 14, minorVersion: 0))
        XCTAssertFalse(SystemAudioCapturePolicy.usesProcessTap(majorVersion: 14, minorVersion: 1))
        XCTAssertTrue(SystemAudioCapturePolicy.usesProcessTap(majorVersion: 14, minorVersion: 2))
        XCTAssertTrue(SystemAudioCapturePolicy.usesProcessTap(majorVersion: 15, minorVersion: 0))
        XCTAssertTrue(SystemAudioCapturePolicy.usesProcessTap(majorVersion: 26, minorVersion: 0))
    }

    func testMusicPulseMustNotCaptureADisplayWhenProcessTapIsAvailable() {
        XCTAssertTrue(SystemAudioCapturePolicy.usesDisplayStream(majorVersion: 14, minorVersion: 1))
        XCTAssertFalse(SystemAudioCapturePolicy.usesDisplayStream(majorVersion: 14, minorVersion: 2))
        XCTAssertFalse(SystemAudioCapturePolicy.usesDisplayStream(majorVersion: 15, minorVersion: 6))
    }
}
