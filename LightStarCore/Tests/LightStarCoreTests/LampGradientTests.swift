import XCTest
@testable import LightStarCore

final class LampGradientTests: XCTestCase {
    /// 4×14 BGRA frame: top half red, bottom half blue.
    private func splitFrame() -> [UInt8] {
        (0..<14).flatMap { row in
            (0..<4).flatMap { _ in row < 7 ? [0, 0, 255, 255] : [255, 0, 0, 255] as [UInt8] }
        }
    }

    func testScreenBottomLightsLampBottom() {
        let frame = splitFrame()
        let zones = frame.withUnsafeBufferPointer {
            LampGradient.screenZones(bgra: $0.baseAddress!, width: 4, height: 14, bytesPerRow: 16, count: 7)
        }
        XCTAssertEqual(zones.count, 7)
        XCTAssertEqual(zones.first, WizRGB(r: 0, g: 0, b: 255), "bottom of lamp = bottom of screen")
        XCTAssertEqual(zones.last, WizRGB(r: 255, g: 0, b: 0))
    }

    func testVUFillsFromTheFloorGreenToRed() {
        XCTAssertTrue(LampGradient.vu(level: 0).allSatisfy(\.isOff))
        let full = LampGradient.vu(level: 1)
        XCTAssertEqual(full.first, WizRGB(r: 0, g: 255, b: 0))
        XCTAssertEqual(full.last, WizRGB(r: 255, g: 0, b: 0))
        let half = LampGradient.vu(level: 0.5)
        XCTAssertFalse(half[2].isOff)
        XCTAssertLessThan(half[3].g, 255, "boundary zone is partly lit")
        XCTAssertTrue(half[4...].allSatisfy(\.isOff))
    }

    func testMeterRisesAtOnceAndFallsSlowly() {
        var meter = VUMeter()
        XCTAssertEqual(meter.next(FrequencyBands(bass: 0.9, mid: 0, high: 0, rms: 0, flux: 0)), 0.9)
        let fell = meter.next(FrequencyBands(bass: 0, mid: 0, high: 0, rms: 0, flux: 0))
        XCTAssertEqual(fell, 0.9 * 0.85, accuracy: 1e-9)
    }

    func testSmootherEasesSmallMovesAndJumpsOnCuts() {
        var smoother = LampZoneSmoother()
        _ = smoother.next([WizRGB(r: 100, g: 0, b: 0)], alpha: 0.5)
        XCTAssertEqual(smoother.next([WizRGB(r: 140, g: 0, b: 0)], alpha: 0.5), [WizRGB(r: 120, g: 0, b: 0)])
        XCTAssertEqual(smoother.next([WizRGB(r: 0, g: 0, b: 255)], alpha: 0.5), [WizRGB(r: 0, g: 0, b: 255)])
    }
}
