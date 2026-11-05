import XCTest
@testable import LightStarCore

final class LightbarExtrasTests: XCTestCase {
    func testBoostMakesColoursMoreVividAndKeepsHueAndPeak() {
        let dull = WizRGB(r: 200, g: 150, b: 150)
        let out = LampGradient.boosted([dull], by: 1)[0]
        XCTAssertEqual(out.r, 200, "peak brightness kept")
        XCTAssertEqual(out.g, out.b, "hue kept: the two lower channels stay equal")
        XCTAssertLessThan(out.g, 150, "more saturated")
        XCTAssertEqual(LampGradient.boosted([dull], by: 0), [dull], "off leaves colours alone")
    }

    func testBoostLeavesGreysAndBlackAlone() {
        let colours = [WizRGB(r: 180, g: 180, b: 175), .off]
        XCTAssertEqual(LampGradient.boosted(colours, by: 1), colours)
    }

    func testBeatFlashRunsUpFromTheBaseAndFades() {
        var flash = BeatFlash()
        let frame = Array(repeating: WizRGB(r: 0, g: 40, b: 0), count: 12)
        XCTAssertEqual(flash.apply(frame, at: 0), frame, "no beat, no flash")
        flash.beat(at: 1)
        let early = flash.apply(frame, at: 1.03)
        XCTAssertGreaterThan(early[0].r, 0, "the base lights first")
        XCTAssertEqual(early[11], frame[11], "the top hasn't been reached yet")
        let late = flash.apply(frame, at: 1.35)
        XCTAssertEqual(late[0], frame[0], "the flash has moved on from the base")
        XCTAssertEqual(flash.apply(frame, at: 2), frame, "gone after it crosses the bar")
    }

    func testBeatsTooCloseTogetherStartOneFlash() {
        var a = BeatFlash(), b = BeatFlash()
        a.beat(at: 1)
        b.beat(at: 1); b.beat(at: 1.05)
        let frame = Array(repeating: WizRGB.off, count: 12)
        XCTAssertEqual(a.apply(frame, at: 1.2), b.apply(frame, at: 1.2))
    }

    func testDayWhiteIsCoolAtMiddayAndWarmAtNight() {
        let cal = Calendar.current
        let noon = cal.date(bySettingHour: 13, minute: 0, second: 0, of: Date())!
        let night = cal.date(bySettingHour: 23, minute: 0, second: 0, of: Date())!
        XCTAssertLessThan(LampGradient.dayWhite(at: noon).saturation, LampGradient.dayWhite(at: night).saturation)
    }

    func testSideColoursReadEachEdge() {
        // 20×8: left quarter red, right quarter blue, top rows green, bottom rows yellow.
        let w = 20, h = 8
        let frame: [UInt8] = (0..<h).flatMap { r in (0..<w).flatMap { c -> [UInt8] in
            if c < 3 { return [0, 0, 255, 255] }
            if c >= w - 3 { return [255, 0, 0, 255] }
            if r < 2 { return [0, 255, 0, 255] }
            if r >= h - 2 { return [0, 255, 255, 255] }
            return [0, 0, 0, 255]
        } }
        let sides = frame.withUnsafeBufferPointer {
            LampGradient.sideColours(bgra: $0.baseAddress!, width: w, height: h, bytesPerRow: w * 4, depth: 0.15)
        }
        XCTAssertEqual(sides[.left], WizRGB(r: 255, g: 0, b: 0))
        XCTAssertEqual(sides[.right], WizRGB(r: 0, g: 0, b: 255))
        XCTAssertEqual(sides[.top], WizRGB(r: 0, g: 255, b: 0))
        XCTAssertEqual(sides[.bottom], WizRGB(r: 255, g: 255, b: 0))
    }

    func testProfileDetection() {
        XCTAssertEqual(LightbarProfile.detect(bundleID: "com.apple.dt.Xcode", category: nil), .work)
        XCTAssertEqual(LightbarProfile.detect(bundleID: "com.jetbrains.intellij", category: nil), .work)
        XCTAssertEqual(LightbarProfile.detect(bundleID: "org.videolan.vlc", category: nil), .video)
        XCTAssertEqual(LightbarProfile.detect(bundleID: "com.example.game", category: "public.app-category.action-games"), .game)
        XCTAssertEqual(LightbarProfile.detect(bundleID: "com.apple.Safari", category: "public.app-category.productivity"), .normal)
        XCTAssertEqual(LightbarProfile.resolve(bundleID: "com.apple.dt.Xcode", category: nil,
                                               overrides: ["com.apple.dt.Xcode": .normal]), .normal, "the user's pick wins")
    }

    func testRecentAppsNewestFirstWithoutRepeats() {
        XCTAssertEqual(LightbarProfile.remember("b", in: ["a", "b", "c"]), ["b", "a", "c"])
        XCTAssertEqual(LightbarProfile.remember("z", in: ["a", "b"], limit: 2), ["z", "a"])
    }

    func testAllLightsChoice() {
        XCTAssertEqual(LightOutputTarget.allLights(from: nil), [.strip, .lamp, .lightbar])
        XCTAssertEqual(LightOutputTarget.allLights(from: []), [.strip, .lamp, .lightbar], "never none")
        XCTAssertEqual(LightOutputTarget.allLights(from: ["lightbar", "both", "nonsense"]), [.lightbar])

        let d = UserDefaults.standard
        let key = LightOutputTarget.allLightsDefaultsKey
        let saved = d.object(forKey: key)
        defer { d.set(saved, forKey: key) }
        d.set(["lamp", "lightbar"], forKey: key)
        XCTAssertFalse(LightOutputTarget.both.sendsToStrip, "strip left out of All")
        XCTAssertTrue(LightOutputTarget.both.sendsToLightbar)
        XCTAssertTrue(LightOutputTarget.strip.sendsToStrip, "choosing the strip alone still drives it")
    }
}
