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

    private func zones(_ pixel: (Int) -> [UInt8], height: Int = 7) -> [WizRGB] {
        let frame = (0..<(4 * height)).flatMap { pixel($0) }
        return frame.withUnsafeBufferPointer {
            LampGradient.screenZones(bgra: $0.baseAddress!, width: 4, height: height, bytesPerRow: 16, count: 1)
        }
    }

    func testMixedBandTakesTheDominantColourNotAMuddyAverage() {
        // 3 of 4 columns red, 1 green: an average would be olive/brown.
        let band = zones { $0 % 4 == 3 ? [0, 255, 0, 255] : [0, 0, 255, 255] }
        XCTAssertEqual(band, [WizRGB(r: 255, g: 0, b: 0)])
    }

    func testBlackBandIsOffNotDimGrey() {
        XCTAssertEqual(zones { _ in [12, 12, 12, 255] }, [.off])
    }

    func testGreyBandIsNeutralAtItsBrightness() {
        let band = zones { _ in [128, 128, 128, 255] }
        XCTAssertEqual(band, [WizRGB(r: 128, g: 128, b: 128)])
    }

    /// 14×4 frame: left half red, right half blue.
    private func sideBySide(_ orientation: LampGradient.Orientation, flipped: Bool = false) -> [WizRGB] {
        let frame = (0..<4).flatMap { _ in (0..<14).flatMap { col in col < 7 ? [0, 0, 255, 255] : [255, 0, 0, 255] as [UInt8] } }
        return frame.withUnsafeBufferPointer {
            LampGradient.screenZones(bgra: $0.baseAddress!, width: 14, height: 4, bytesPerRow: 56, count: 7,
                                     orientation: orientation, flipped: flipped)
        }
    }

    func testHorizontalReadsTheScreenLeftToRightFromTheBase() {
        let zones = sideBySide(.horizontal)
        XCTAssertEqual(zones.first, WizRGB(r: 255, g: 0, b: 0), "base end = left of screen")
        XCTAssertEqual(zones.last, WizRGB(r: 0, g: 0, b: 255))
        XCTAssertEqual(sideBySide(.horizontal, flipped: true).first, WizRGB(r: 0, g: 0, b: 255), "base on the right")
    }

    func testVerticalFlipPutsTheTopOfTheScreenAtTheBase() {
        let frame = splitFrame()
        let zones = frame.withUnsafeBufferPointer {
            LampGradient.screenZones(bgra: $0.baseAddress!, width: 4, height: 14, bytesPerRow: 16, count: 7, flipped: true)
        }
        XCTAssertEqual(zones.first, WizRGB(r: 255, g: 0, b: 0), "top of screen (red) at the base")
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
