import XCTest
@testable import LightStarCore

final class CanvasSymmetryTests: XCTestCase {
    private let s = FluidSplat(x: 0.7, y: 0.4, dx: 100, dy: -50, color: SIMD3(1, 0, 0))

    func testOffIsTheSplatItself() {
        XCTAssertEqual(CanvasSymmetry.expand(s, folds: 1, aspect: 16.0 / 9), [s])
    }

    func testTwoIsALeftRightMirror() {
        let out = CanvasSymmetry.expand(s, folds: 2, aspect: 16.0 / 9)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[1].x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(out[1].y, s.y)
        XCTAssertEqual(out[1].dx, -s.dx)
    }

    func testKaleidoscopeIsRotationsAndMirrorsAroundTheCentre() {
        let aspect = 16.0 / 9
        for folds in [3, 4, 6, 8, 12] {
            let out = CanvasSymmetry.expand(s, folds: folds, aspect: aspect)
            XCTAssertEqual(out.count, folds * 2)
            // Every copy is the same distance from the centre in square screen space.
            let r = hypot((s.x - 0.5) * aspect, s.y - 0.5)
            for c in out {
                XCTAssertEqual(hypot((c.x - 0.5) * aspect, c.y - 0.5), r, accuracy: 1e-9)
                XCTAssertEqual(hypot(c.dx, c.dy), hypot(s.dx, s.dy), accuracy: 1e-6, "speed kept")
            }
            XCTAssertTrue(out.contains { abs($0.x - s.x) < 1e-9 && abs($0.y - s.y) < 1e-9 }, "the original is one of them")
        }
    }
}

final class CanvasWellsTests: XCTestCase {
    func testPlantKeepsTheNewestSix() {
        var w = CanvasWells()
        for i in 0..<8 { w.plant(CanvasWell(x: Double(i) / 10, y: 0.5, strength: 1, hue: 0)) }
        XCTAssertEqual(w.wells.count, CanvasWells.maxCount)
        XCTAssertEqual(w.wells.first?.x ?? -1, 0.2, accuracy: 1e-9)
    }

    func testRemoveNearestOnlyWhenClose() {
        var w = CanvasWells([CanvasWell(x: 0.3, y: 0.3, strength: 1, hue: 0)])
        w.removeNearest(x: 0.8, y: 0.8)
        XCTAssertEqual(w.wells.count, 1)
        w.removeNearest(x: 0.32, y: 0.31)
        XCTAssertTrue(w.wells.isEmpty)
    }

    func testAttractorsFindEachOtherAndMerge() {
        var w = CanvasWells([CanvasWell(x: 0.4, y: 0.5, strength: 1, hue: 0), CanvasWell(x: 0.6, y: 0.5, strength: 1, hue: 0.5)])
        var merged: (x: Double, y: Double)?
        for _ in 0..<20_000 where merged == nil { merged = w.drift(dt: 1.0 / 60, aspect: 16.0 / 9) }
        XCTAssertNotNil(merged, "two attractors drift together and merge")
        XCTAssertEqual(w.wells.count, 1)
        XCTAssertEqual(w.wells[0].strength, 2, accuracy: 1e-9, "the merged well is stronger")
    }

    func testRepellerAndAttractorNeverMerge() {
        var w = CanvasWells([CanvasWell(x: 0.5, y: 0.5, strength: 1, hue: 0), CanvasWell(x: 0.51, y: 0.5, strength: -1, hue: 0)])
        for _ in 0..<600 { XCTAssertNil(w.drift(dt: 1.0 / 60, aspect: 1)) }
        XCTAssertEqual(w.wells.count, 2)
    }
}

final class BreathPacerTests: XCTestCase {
    func testSixBreathsAMinuteBreatheInFourSecondsOutSix() {
        let p = BreathPacer(breathsPerMinute: 6)
        XCTAssertEqual(p.cycle, 10)
        XCTAssertTrue(p.isInhaling(at: 3.9))
        XCTAssertFalse(p.isInhaling(at: 4.1))
        XCTAssertEqual(p.fullness(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(p.fullness(at: 4), 1, accuracy: 1e-9)
        XCTAssertEqual(p.fullness(at: 10), 0, accuracy: 1e-9)
        XCTAssertTrue(p.isInhaling(at: 12), "repeats")
    }

    func testRateIsClampedToCalmRange() {
        XCTAssertEqual(BreathPacer(breathsPerMinute: 30).breathsPerMinute, 10)
        XCTAssertEqual(BreathPacer(breathsPerMinute: 1).breathsPerMinute, 4)
    }
}

final class FlashLimiterTests: XCTestCase {
    func testAtMostThreeFlashesASecond() {
        var f = FlashLimiter()
        var allowed = 0
        for i in 0..<100 where f.allow(at: Double(i) * 0.01, hue: 0.5) { allowed += 1 }
        XCTAssertLessThanOrEqual(allowed, 3)
        XCTAssertGreaterThanOrEqual(allowed, 2)
    }

    func testSaturatedRedAtMostOnceASecond() {
        var f = FlashLimiter()
        XCTAssertTrue(f.allow(at: 0, hue: 0.01))
        XCTAssertFalse(f.allow(at: 0.5, hue: 0.98), "red again too soon")
        XCTAssertTrue(f.allow(at: 0.5, hue: 0.5), "another colour may flash")
        XCTAssertTrue(f.allow(at: 1.1, hue: 0.0))
    }
}

final class CanvasGestureTests: XCTestCase {
    func testACircleIsAWhirlpool() {
        var g = CanvasGestureDetector()
        var found: CanvasDiscovery?
        for i in 0...40 where found == nil {
            let a = Double(i) / 40 * 2 * .pi
            found = g.add(x: 0.5 + cos(a) * 0.1 / (16.0 / 9), y: 0.5 + sin(a) * 0.1, t: Double(i) * 0.03)
        }
        XCTAssertEqual(found, .whirlpool)
    }

    func testQuickBackAndForthIsASparkStorm() {
        var g = CanvasGestureDetector()
        var found: CanvasDiscovery?
        for i in 0..<40 where found == nil {
            found = g.add(x: 0.5 + (i % 2 == 0 ? 0.03 : -0.03), y: 0.5 + Double(i) * 0.001, t: Double(i) * 0.05)
        }
        XCTAssertEqual(found, .sparkStorm)
    }

    func testAllTheWayAcrossInOneGoIsARainbowBridge() {
        var g = CanvasGestureDetector()
        var found: CanvasDiscovery?
        for i in 0...30 where found == nil { found = g.add(x: 0.04 + Double(i) * 0.031, y: 0.5, t: Double(i) * 0.03) }
        XCTAssertEqual(found, .rainbowBridge)
    }

    func testAnOrdinaryStrokeFindsNothing() {
        var g = CanvasGestureDetector()
        for i in 0..<60 { XCTAssertNil(g.add(x: 0.3 + Double(i) * 0.004, y: 0.4 + Double(i) * 0.002, t: Double(i) * 0.03)) }
    }

    func testASlowSweepIsNotABridge() {
        var g = CanvasGestureDetector()
        for i in 0...30 { XCTAssertNil(g.add(x: 0.04 + Double(i) * 0.031, y: 0.5, t: Double(i) * 0.2)) }
    }
}

final class CanvasMoodTests: XCTestCase {
    func testWindDownDimsAndWarmsOverTheSession() {
        let early = CanvasMood.windDown.lights(elapsed: 0, minutes: 30)
        let late = CanvasMood.windDown.lights(elapsed: 29 * 60, minutes: 30)
        XCTAssertEqual(early.gain, 1, accuracy: 1e-9)
        XCTAssertLessThan(late.gain, 0.15)
        XCTAssertGreaterThan(late.white, early.white)
        XCTAssertTrue(late.warm)
        var previous = 2.0
        for m in stride(from: 0.0, through: 30, by: 1) {
            let g = CanvasMood.windDown.lights(elapsed: m * 60, minutes: 30).gain
            XCTAssertLessThanOrEqual(g, previous, "never brightens")
            previous = g
        }
    }

    func testFocusKeepsTheRoomMostlyWhite() {
        XCTAssertGreaterThanOrEqual(CanvasMood.focus.lights(elapsed: 100, minutes: 25).white, 0.6)
    }

    func testEveryMoodButNoneHasAPreset() {
        for mood in CanvasMood.allCases {
            XCTAssertEqual(mood.preset == nil, mood == .none, mood.rawValue)
        }
        XCTAssertTrue(CanvasMood.windDown.endsByItself)
        XCTAssertFalse(CanvasMood.party.endsByItself)
        XCTAssertEqual(CanvasMood.party.preset?.mode, .music)
    }
}

final class CanvasPlayerAndSceneTests: XCTestCase {
    func testAPhoneAlwaysGetsTheSameColour() {
        XCTAssertEqual(CanvasPlayer.hue(for: "phone-A"), CanvasPlayer.hue(for: "phone-A"))
        XCTAssertNotEqual(CanvasPlayer.hue(for: "phone-A"), CanvasPlayer.hue(for: "phone-B"))
        for id in ["", "x", "a much longer device identifier"] {
            XCTAssert((0..<1).contains(CanvasPlayer.hue(for: id)))
        }
    }

    func testSavedCanvasesRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-\(UUID().uuidString)/canvases.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let scene = CanvasScene(name: "Canvas 1", style: .aurora, mode: .wells, symmetry: 6, mood: .ambient,
                                wells: [CanvasWell(x: 0.3, y: 0.4, strength: -1, hue: 0.2)])
        try CanvasSceneStore.save([scene], to: url)
        XCTAssertEqual(CanvasSceneStore.load(from: url), [scene])
        XCTAssertEqual(CanvasSceneStore.load(from: url.appendingPathExtension("missing")), [])
        XCTAssertEqual(CanvasSceneStore.nextName(after: [scene]), "Canvas 2")
        XCTAssertEqual(CanvasSceneStore.nextName(after: []), "Canvas 1")
    }

    func testCanvasMessagesRoundTripAndOldStateStillDecodes() throws {
        let change = SetCanvasMessage(stir: [0.1, 0.2, 0.3, 0.4], player: "p", finger: 2, tilt: [0.2, -0.4])
        XCTAssertEqual(try JSONDecoder().decode(SetCanvasMessage.self, from: JSONEncoder().encode(change)), change)
        XCTAssertTrue(change.isPlayOnly)
        XCTAssertFalse(SetCanvasMessage(symmetry: 6).isPlayOnly)
        XCTAssertFalse(SetCanvasMessage(well: [0.5, 0.5, 1]).isPlayOnly, "the phone shows the well count")
        let old = #"{"mode":"auto","style":"liquid","quality":"uhd"}"#.data(using: .utf8)!
        let state = try JSONDecoder().decode(CanvasState.self, from: old)
        XCTAssertNil(state.symmetry)
        XCTAssertEqual(state.mode, "auto")
    }
}
