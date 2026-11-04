import XCTest
import CoreVideo
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

    func testLogoOnBlackComesThroughAtItsBrightest() {
        // Mostly black band; a red stroke whose edge pixels blended with black.
        let band = zones { $0 % 4 == 0 ? [0, 0, 255, 255] : ($0 % 4 == 1 ? [0, 0, 110, 255] : [0, 0, 0, 255]) }
        XCTAssertEqual(band, [WizRGB(r: 255, g: 0, b: 0)], "not the dim mean of stroke and edge")
        let frame = (0..<28).flatMap { $0 % 4 == 0 ? [0, 0, 128, 255] : [0, 0, 0, 255] as [UInt8] }
        let full = frame.withUnsafeBufferPointer {
            LampGradient.screenZones(bgra: $0.baseAddress!, width: 4, height: 7, bytesPerRow: 16, count: 1, followBrightness: false)
        }
        XCTAssertEqual(full, [WizRGB(r: 255, g: 0, b: 0)], "full strength when not following screen brightness")
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

    func testScreenFillsOnlyItsStretchOfTheBar() {
        // 18 segments, 7 colours.
        let full = LampGradient.Placement().widths(zones: 7, segments: 18)
        XCTAssertEqual(full, [0, 3, 2, 3, 2, 3, 2, 3, 0], "whole bar, no dark ends")

        let half = LampGradient.Placement(span: 0.5).widths(zones: 7, segments: 18)
        XCTAssertEqual(half.count, 9, "7 colours + 2 dark steps, inside WiZ's 12")
        XCTAssertEqual(half.reduce(0, +), 18)
        XCTAssertEqual(half[1..<8].reduce(0, +), 9, "screen covers half the bar")
        XCTAssertEqual(abs(half[0] - half[8]), 1, "centred: dark ends match (±1 rounding)")

        let right = LampGradient.Placement(span: 0.5, centre: 0.25).widths(zones: 7, segments: 18)
        XCTAssertEqual(right.first, 9, "screen on the right half: left half dark")
        XCTAssertEqual(right.last, 0)

        let flipped = LampGradient.Placement(span: 0.5, centre: 0.25, flipped: true).widths(zones: 7, segments: 18)
        XCTAssertEqual(flipped.first, 0, "base on the right: the lit half starts at the base")
        XCTAssertEqual(flipped.last, 9)
    }

    func testScreenPushedPastTheEndIsCutOff() {
        // Full-size screen slid half a bar right: left half dark, and the
        // screen's right-hand colours fall off the end.
        let w = LampGradient.Placement(span: 1, centre: 0.5).widths(zones: 7, segments: 18)
        XCTAssertEqual(w.first, 9)
        XCTAssertEqual(w.last, 0)
        XCTAssertEqual(w[5...7].reduce(0, +), 0, "the screen's right zones are off the bar")
        XCTAssertEqual(w.reduce(0, +), 18)
    }

    func testPlacedGradientEncodesDarkEnds() throws {
        let red = WizRGB(r: 255, g: 0, b: 0)
        let widths = LampGradient.Placement(span: 0.5, centre: 0.25).widths(zones: 7, segments: 18)
        let desired = WizPilot(power: true, mode: .gradient([.off] + Array(repeating: red, count: 7) + [.off], widths: widths), dimming: 100)
        let data = try XCTUnwrap(WizFlush.messages(desired: desired, sent: WizPilot(power: true), layout: WizSegmentLayout(), mac: nil).first?.0)
        let params = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["params"] as? [String: Any])
        let steps = try XCTUnwrap((params["elm"] as? [String: Any])?["steps"] as? [[Int]])
        XCTAssertEqual(steps.first?[7], 0, "dark stretch first")
        XCTAssertEqual(steps.first?[12], 9)
        XCTAssertEqual(steps.map { $0[12] }.reduce(0, +), 18, "zero-width dark end dropped, bar fully covered")
    }

    #if os(macOS)
    func testLatestFrameRepaintsWithNewSettingsWithoutANewFrame() {
        let defaults = UserDefaults.standard
        let keys = [LampGradient.orientationDefaultsKey, LampGradient.flippedDefaultsKey, LampGradient.centreDefaultsKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { defaults.set(v, forKey: k) } }

        // 14×4 BGRA: left half red, right half blue.
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 14, 4, kCVPixelFormatType_32BGRA, nil, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<4 { for col in 0..<14 {
            let i = row * bpr + col * 4
            (base[i], base[i + 1], base[i + 2], base[i + 3]) = col < 7 ? (0, 0, 255, 255) : (255, 0, 0, 255)
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let store = LampFrameStore()
        store.store(buffer)
        defaults.set("horizontal", forKey: LampGradient.orientationDefaultsKey)
        defaults.set(false, forKey: LampGradient.flippedDefaultsKey)
        defaults.set(0.0, forKey: LampGradient.centreDefaultsKey)
        let before = store.zones()
        defaults.set(true, forKey: LampGradient.flippedDefaultsKey)
        let after = store.zones()
        XCTAssertEqual(before.first, WizRGB(r: 255, g: 0, b: 0))
        XCTAssertEqual(after.first, WizRGB(r: 0, g: 0, b: 255), "same frame, new setting, new zones")
    }
    #endif

    func testVerticalFlipPutsTheTopOfTheScreenAtTheBase() {
        let frame = splitFrame()
        let zones = frame.withUnsafeBufferPointer {
            LampGradient.screenZones(bgra: $0.baseAddress!, width: 4, height: 14, bytesPerRow: 16, count: 7, flipped: true)
        }
        XCTAssertEqual(zones.first, WizRGB(r: 255, g: 0, b: 0), "top of screen (red) at the base")
    }

    func testLogoOnBlackPaintsEvenWhenTheDRMGuardHoldsTheStrip() {
        let red = WizRGB(r: 255, g: 0, b: 0)
        let logo: [WizRGB] = [.off, .off, .off, red, .off, .off, .off]
        XCTAssertTrue(LampGradient.shouldPaint(logo, frameWritable: false), "Netflix N on black: red centre, rest off")
        XCTAssertFalse(LampGradient.shouldPaint(Array(repeating: .off, count: 7), frameWritable: false),
                       "solid black may be DRM: hold the last frame")
        XCTAssertTrue(LampGradient.shouldPaint(Array(repeating: .off, count: 7), frameWritable: true))
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
