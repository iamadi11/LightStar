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

    func testEachEndTrimsOnItsOwn() {
        // 18 segments, 7 colours.
        XCTAssertEqual(LampGradient.Placement().widths(zones: 7, segments: 18), [0, 3, 2, 3, 2, 3, 2, 3, 0],
                       "no trim: whole bar")
        let left = LampGradient.Placement(trimStart: 0.5).widths(zones: 7, segments: 18)
        XCTAssertEqual(left.first, 9, "left half off")
        XCTAssertEqual(left.last, 0, "right end untouched")
        XCTAssertEqual(left[1..<8].reduce(0, +), 9, "screen fills the right half")

        let both = LampGradient.Placement(trimStart: 2.0 / 18, trimEnd: 4.0 / 18).widths(zones: 7, segments: 18)
        XCTAssertEqual(both.first, 2)
        XCTAssertEqual(both.last, 4)
        XCTAssertEqual(both.count, 9, "7 colours + 2 dark steps, inside WiZ's 12")
        XCTAssertEqual(both.reduce(0, +), 18)
    }

    func testUsesAsManyColoursAsWiZAllows() {
        XCTAssertEqual(LampGradient.colourCount(for: .init(), segments: 18), 12, "whole bar: WiZ's 12-step limit")
        XCTAssertEqual(LampGradient.colourCount(for: .init(trimStart: 0.1), segments: 18), 11, "one dark end")
        XCTAssertEqual(LampGradient.colourCount(for: .init(trimStart: 0.1, trimEnd: 0.1), segments: 18), 10)
        XCTAssertEqual(LampGradient.colourCount(for: .init(trimStart: 0.4, trimEnd: 0.4), segments: 18), 4,
                       "never more colours than lit segments")
        let w = LampGradient.Placement().widths(zones: 12, segments: 18)
        XCTAssertEqual(w.filter { $0 > 0 }.count, 12)
        XCTAssertTrue(w[1...12].allSatisfy { $0 == 1 || $0 == 2 }, "12 colours over 18 segments")
    }

    func testTrimsNeverSwallowTheWholeBar() {
        let p = LampGradient.Placement(trimStart: 0.7, trimEnd: 0.7)
        XCTAssertEqual(p.end - p.start, LampGradient.minLit, accuracy: 1e-9, "a fifth stays lit")
    }

    func testFlipMirrorsTheTrims() {
        // Base on the right: the right-hand trim is at the base end.
        let w = LampGradient.Placement(trimStart: 0, trimEnd: 0.5, flipped: true).widths(zones: 7, segments: 18)
        XCTAssertEqual(w.first, 9)
        XCTAssertEqual(w.last, 0)
    }

    func testTwelveColoursAcrossTheWholeBarAreActuallySent() throws {
        // Regression: 12 colours + 2 zero-width ends were 14 entries, refused
        // by the 12-step check, so nothing went out.
        let zones = (0..<12).map { WizRGB(hue: Double($0) / 12, saturation: 1) }
        let desired = WizPilot(power: true, mode: .gradient(zones, placement: .init()), dimming: 100)
        let layout = WizSegmentLayout(widths: WizSegmentLayout.even(segments: 18, steps: 7))
        let data = try XCTUnwrap(WizFlush.messages(desired: desired, sent: WizPilot(power: true), layout: layout, mac: nil).first?.0)
        let params = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["params"] as? [String: Any])
        let steps = try XCTUnwrap((params["elm"] as? [String: Any])?["steps"] as? [[Int]])
        XCTAssertEqual(steps.count, 12)
        XCTAssertEqual(steps.map { $0[12] }.reduce(0, +), 18)
    }

    func testPlacedGradientEncodesDarkEnds() throws {
        let red = WizRGB(r: 255, g: 0, b: 0)
        let desired = WizPilot(power: true, mode: .gradient(Array(repeating: red, count: 7), placement: .init(trimStart: 0.5)), dimming: 100)
        let layout = WizSegmentLayout(widths: WizSegmentLayout.even(segments: 18, steps: 7))
        let data = try XCTUnwrap(WizFlush.messages(desired: desired, sent: WizPilot(power: true), layout: layout, mac: nil).first?.0)
        let params = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["params"] as? [String: Any])
        let steps = try XCTUnwrap((params["elm"] as? [String: Any])?["steps"] as? [[Int]])
        XCTAssertEqual(steps.first?[7], 0, "dark stretch first")
        XCTAssertEqual(steps.first?[12], 9)
        XCTAssertEqual(steps.map { $0[12] }.reduce(0, +), 18, "zero-width dark end dropped, bar fully covered")
    }

    #if os(macOS)
    func testLatestFrameRepaintsWithNewSettingsWithoutANewFrame() {
        let defaults = UserDefaults.standard
        let keys = [LampGradient.orientationDefaultsKey, LampGradient.flippedDefaultsKey]
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

    // MARK: Lightbar effects

    func testEffectsFillEverySegmentAndMove() {
        for effect in LampEffect.builtIn {
            let a = effect.frame(time: 0.3, speed: 0.5, count: 12)
            let b = effect.frame(time: 1.1, speed: 0.5, count: 12)
            XCTAssertEqual(a.count, 12, effect.name)
            XCTAssertNotEqual(a, b, "\(effect.name) animates")
        }
    }

    func testChaseRunsFromTheBase() {
        let chase = LampEffect(name: "t", motion: .chase, palette: [WizRGB(r: 255, g: 0, b: 0)])
        let early = chase.frame(time: 0.05, speed: 0.5, count: 12)
        XCTAssertFalse(early[0].isOff, "head starts at the base")
        XCTAssertTrue(early[6...].allSatisfy(\.isOff), "far end still dark")
    }

    func testOpenCloseOpensFromTheCentre() {
        let e = LampEffect(name: "t", motion: .openClose, palette: [WizRGB(r: 0, g: 0, b: 255)])
        // A quarter of the way open: centre lit, ends dark.
        let t = 0.25 / LampEffect.rate(0.5)
        let f = e.frame(time: t, speed: 0.5, count: 12)
        XCTAssertFalse(f[5].isOff); XCTAssertFalse(f[6].isOff)
        XCTAssertTrue(f[0].isOff); XCTAssertTrue(f[11].isOff)
    }

    func testReverseRunsFlowsAndChasesFromTheFarEnd() {
        let chase = LampEffect(name: "t", motion: .chase, palette: [WizRGB(r: 255, g: 0, b: 0)])
        let back = chase.frame(time: 0.05, speed: 0.5, count: 12, reversed: true)
        XCTAssertFalse(back[11].isOff, "head starts at the far end")
        XCTAssertTrue(back[...5].allSatisfy(\.isOff))
        let fire = LampEffect.named("Fire")!
        XCTAssertEqual(fire.frame(time: 0.7, speed: 0.5, count: 12, reversed: true),
                       fire.frame(time: 0.7, speed: 0.5, count: 12), "fire stays hottest at the base")
    }

    func testCustomColoursAreKeptInPresets() throws {
        let custom = [WizRGB(r: 10, g: 200, b: 30), WizRGB(r: 250, g: 0, b: 250)]
        let effect = LampEffect.named("Rainbow Flow", palette: custom)!
        let look = LightbarLook(effect: effect)
        XCTAssertEqual(look.palette, [[10, 200, 30], [250, 0, 250]])
        let decoded = try JSONDecoder().decode(LightbarLook.self, from: JSONEncoder().encode(look))
        XCTAssertEqual(decoded.lampEffect, effect)
        XCTAssertNil(LightbarLook(effect: LampEffect.named("Ocean")!).palette, "own colours aren't stored")
        // Presets saved before palettes existed still load.
        let old = try JSONDecoder().decode(LightbarLook.self, from: Data(#"{"effect":"Fire"}"#.utf8))
        XCTAssertEqual(old.lampEffect, LampEffect.named("Fire"))
    }

    func testStripEffectsMapToMatchingColoursAndMotion() {
        func find(_ id: UInt8) -> LampEffect {
            for (group, effects) in knownEffects { if let e = effects.first(where: { $0.id == id }) { return .matching(e, in: group) } }
            fatalError()
        }
        let tail = find(0x4D) // Tailing · Red
        XCTAssertEqual(tail.motion, .chase)
        XCTAssertEqual(tail.palette, [WizRGB(r: 255, g: 0, b: 0)])
        let water = find(0x3E) // Flowing Water · Blue-Purple
        XCTAssertEqual(water.motion, .flow)
        XCTAssertEqual(water.palette.count, 2)
        XCTAssertEqual(find(0x23).motion, .openClose) // Opening / Closing · 7 Colors
        XCTAssertEqual(find(0x23).palette, LampEffect.rainbow)
        XCTAssertEqual(find(0x36).palette, LampEffect.white) // Transition · White
    }

    // MARK: Music styles

    func testSpectrumPutsBassAtTheBaseAndTrebleAtTheTop() {
        let bassOnly = LampGradient.spectrum(FrequencyBands(bass: 1, mid: 0, high: 0, rms: 0.5, flux: 0), count: 12)
        XCTAssertFalse(bassOnly[0].isOff, "bass lights the base")
        XCTAssertTrue(bassOnly[11].isOff, "treble end dark")
        let trebleOnly = LampGradient.spectrum(FrequencyBands(bass: 0, mid: 0, high: 1, rms: 0.5, flux: 0), count: 12)
        XCTAssertTrue(trebleOnly[0].isOff)
        XCTAssertFalse(trebleOnly[11].isOff, "treble lights the top")
        XCTAssertGreaterThan(bassOnly[0].r, bassOnly[0].b, "base is red")
        XCTAssertGreaterThan(trebleOnly[11].b, trebleOnly[11].g, "top is violet")
    }
}

final class AudioLoudnessTests: XCTestCase {
    /// Steady loudness after the peak has settled, for a 220 Hz tone.
    private func settledRMS(amplitude: Float) -> Double {
        let engine = AudioFFTEngine()
        engine.prepare()
        let tone = (0..<44_100).map { amplitude * sinf(2 * .pi * 220 * Float($0) / 44_100) }
        var last = 0.0
        engine.ingest(mono: tone, sampleRate: 44_100) { last = $0.rms }
        return last
    }

    func testSameMusicReadsTheSameFromMicAndSystemAudio() {
        // System audio arrives near full scale; a mic hears the room 4× quieter.
        let system = settledRMS(amplitude: 0.5)
        let mic = settledRMS(amplitude: 0.125)
        XCTAssertEqual(system, mic, accuracy: 0.05, "one loudness scale whatever the input gain (EE-013)")
        XCTAssertGreaterThan(system, 0.9)
    }

    func testSilenceAndRoomNoiseStayDark() {
        XCTAssertEqual(settledRMS(amplitude: 0), 0, accuracy: 1e-9)
        XCTAssertLessThan(settledRMS(amplitude: 0.004), 0.15, "a quiet room is not amplified into light")
    }
}

#if os(macOS)
/// EE-015: the CPU analysis must decide what the GPU shader decides.
final class FrameAnalysisParityTests: XCTestCase {
    private func frame(_ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(nil, 48, 27, kCVPixelFormatType_32BGRA, attrs, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<27 { for x in 0..<48 {
            let (r, g, b) = pixel(x, y)
            let i = y * bpr + x * 4
            (base[i], base[i + 1], base[i + 2], base[i + 3]) = (b, g, r, 255)
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func assertParity(_ pb: CVPixelBuffer, _ label: String) throws {
        let metal = try XCTUnwrap(MetalColorAnalyzer.shared, "no Metal here")
        let gpu = metal.analyze(pb)
        let cpu = MetalColorAnalyzer.cpuAnalysis(pb)
        XCTAssertEqual(gpu.dominantHue, cpu.dominantHue, accuracy: 0.01, label)
        XCTAssertEqual(gpu.dominantSaturation, cpu.dominantSaturation, accuracy: 0.01, label)
        XCTAssertEqual(gpu.dominantBrightness, cpu.dominantBrightness, accuracy: 0.01, label)
        XCTAssertEqual(gpu.blackPixelPercentage, cpu.blackPixelPercentage, accuracy: 0.001, label)
        XCTAssertEqual(gpu.hasRectangularBlackRegion, cpu.hasRectangularBlackRegion, label)
    }

    func testCPUAndGPUAgree() throws {
        try XCTSkipIf(MetalColorAnalyzer.shared == nil, "Metal unavailable")
        try assertParity(frame { x, _ in x < 30 ? (230, 20, 30) : (20, 60, 220) }, "two colours")
        try assertParity(frame { _, y in y < 9 || y > 17 ? (0, 0, 0) : (240, 160, 20) }, "letterboxed")
        // A grey desktop: nothing colourful. Both must report brightness 0, so
        // the strip holds its colour instead of turning white on the CPU path.
        try assertParity(frame { _, _ in (128, 128, 128) }, "grey")
        XCTAssertEqual(MetalColorAnalyzer.cpuAnalysis(frame { _, _ in (128, 128, 128) }).dominantBrightness, 0)
    }
}
#endif
