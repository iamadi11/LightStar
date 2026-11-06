import XCTest
#if canImport(Metal)
import Metal
#endif
@testable import LightStarCore

final class FluidAutoPilotTests: XCTestCase {
    func testSameSeedSameFlow() {
        let a = FluidAutoPilot(seed: 7), b = FluidAutoPilot(seed: 7), c = FluidAutoPilot(seed: 8)
        XCTAssertEqual(a.splats(at: 12.3, dt: 1 / 60), b.splats(at: 12.3, dt: 1 / 60))
        XCTAssertNotEqual(a.splats(at: 12.3, dt: 1 / 60), c.splats(at: 12.3, dt: 1 / 60))
    }

    func testEmittersStayOffTheEdges() {
        let pilot = FluidAutoPilot(emitters: 4)
        for t in stride(from: 0.0, to: 600, by: 0.7) {
            for s in pilot.splats(at: t, dt: 1 / 60) {
                XCTAssert((0.1...0.9).contains(s.x) && (0.1...0.9).contains(s.y), "\(s.x), \(s.y) at \(t)")
            }
        }
    }

    func testSameLookAtAnyFrameRate() {
        // Two 1/120 s frames add what one 1/60 s frame adds.
        let pilot = FluidAutoPilot()
        let one = pilot.splats(at: 5, dt: 1 / 60)[0], half = pilot.splats(at: 5, dt: 1 / 120)[0]
        XCTAssertEqual(Double(one.color.x), Double(half.color.x) * 2, accuracy: 1e-5)
        XCTAssertEqual(one.dx, half.dx * 2, accuracy: 1e-6)
    }

    func testColourKeepsChanging() {
        let pilot = FluidAutoPilot(emitters: 1)
        let hues = stride(from: 0.0, to: 60, by: 5).map { pilot.colourHue(0, at: $0) }
        XCTAssertGreaterThan(Set(hues.map { Int($0 * 100) }).count, 6)
        XCTAssert(hues.allSatisfy { (0..<1).contains($0) })
    }

    func testReduceMotionSlowsTheFlow() {
        var calm = FluidAutoPilot(); calm.speed = 0.4
        let normal = FluidAutoPilot()
        // Average push over ten minutes: one instant can sit anywhere on the path.
        func meanPush(_ p: FluidAutoPilot) -> Double {
            let all = stride(from: 0.0, to: 600, by: 0.5).flatMap { p.splats(at: $0, dt: 1 / 60) }
            return all.map { hypot($0.dx, $0.dy) }.reduce(0, +) / Double(all.count)
        }
        XCTAssertLessThan(meanPush(calm), meanPush(normal) * 0.6)
    }
}

final class CanvasStyleTests: XCTestCase {
    func testEveryAnimationStaysOnTheCanvas() {
        for style in CanvasStyle.allCases {
            let pilot = FluidAutoPilot(style: style)
            for t in stride(from: 0.0, to: 400, by: 0.9) {
                for s in pilot.splats(at: t, dt: 1 / 60) {
                    XCTAssert((0.05...0.95).contains(s.x) && (0.05...0.95).contains(s.y), "\(style) at \(t): \(s.x), \(s.y)")
                    XCTAssert(s.dx.isFinite && s.dy.isFinite)
                }
            }
        }
    }

    func testAnimationsMoveDifferently() {
        // Nebula circles the centre; Lava pushes upward; Aurora mostly sideways.
        let galaxy = FluidAutoPilot(style: .nebula)
        let distances = stride(from: 0.0, to: 200, by: 1.3).flatMap { galaxy.splats(at: $0, dt: 1 / 60) }
            .map { hypot($0.x - 0.5, $0.y - 0.5) }
        XCTAssert(distances.allSatisfy { (0.1...0.4).contains($0) }, "galaxy keeps to its rings")

        let lava = stride(from: 0.0, to: 200, by: 0.7).flatMap { FluidAutoPilot(style: .lava).splats(at: $0, dt: 1 / 60) }
        XCTAssertLessThan(lava.map(\.dy).reduce(0, +), 0, "lava rises (y down)")

        let aurora = stride(from: 0.0, to: 200, by: 0.7).flatMap { FluidAutoPilot(style: .aurora).splats(at: $0, dt: 1 / 60) }
        XCTAssertGreaterThan(aurora.map { abs($0.dx) }.reduce(0, +), aurora.map { abs($0.dy) }.reduce(0, +) * 2)
    }

    func testStoredSettingsFallBackToDefaults() {
        XCTAssertEqual(CanvasStyle(rawValue: "nonsense"), nil)
        XCTAssertEqual(CanvasStyle.allCases.count, 7)
        XCTAssertEqual(CanvasMode.allCases.map(\.title), ["Flow", "Stir", "Music", "Tilt", "Wells", "Breathe"])
        XCTAssertEqual(CanvasMode(rawValue: "auto"), .auto, "stored values from before the new modes still load")
        XCTAssertEqual(CanvasMode(rawValue: "interactive"), .interactive)
    }
}

#if canImport(Metal)
@MainActor
final class CanvasEngineSettingsTests: XCTestCase {
    /// Stir mode is still while you play, shows a newly picked animation for
    /// a moment, and carries on gently by itself once left alone.
    func testStirModeStillWhilePlayingThenCarriesOn() {
        let d = UserDefaults.standard
        let saved = (d.object(forKey: CanvasMode.defaultsKey), d.object(forKey: CanvasStyle.defaultsKey))
        defer { d.set(saved.0, forKey: CanvasMode.defaultsKey); d.set(saved.1, forKey: CanvasStyle.defaultsKey) }
        d.set(CanvasMode.interactive.rawValue, forKey: CanvasMode.defaultsKey)
        d.set(CanvasStyle.liquid.rawValue, forKey: CanvasStyle.defaultsKey)
        let engine = CanvasEngine()
        engine.stir(from: CGPoint(x: 0.4, y: 0.5), to: CGPoint(x: 0.42, y: 0.5))
        let now = CACurrentMediaTime()
        XCTAssertFalse(engine.runsPilot(at: now), "still right after a stir")
        engine.applySettings()
        XCTAssertFalse(engine.runsPilot(at: now), "same animation: no replay")
        d.set(CanvasStyle.lava.rawValue, forKey: CanvasStyle.defaultsKey)
        engine.applySettings()
        XCTAssertTrue(engine.runsPilot(at: CACurrentMediaTime()), "a new pick plays")
        let afterPreview = CACurrentMediaTime() + CanvasEngine.previewSeconds + 0.1
        XCTAssertFalse(engine.runsPilot(at: afterPreview))
        let idle = engine.emitterStrength(now: now + CanvasEngine.idleAfter + 7)
        XCTAssertGreaterThan(idle.amount, 0, "left alone, it carries on")
        XCTAssertLessThan(idle.amount, 0.5, "gently")
    }
}

/// Runs the real shaders on this Mac's GPU: they compile, a splat shows up
/// where it was put, the flow carries it, and nothing turns into NaN.
final class FluidSimulationGPUTests: XCTestCase {
    override func setUpWithError() throws {
        // CI's macOS VMs have a paravirtual GPU: the shaders compile, but it
        // renders nothing back. Pixel checks run on real Macs only; the
        // shaders still compile in FluidShaderCompileTests everywhere.
        if let device = MTLCreateSystemDefaultDevice(), device.name.localizedCaseInsensitiveContains("paravirtual") {
            throw XCTSkip("\(device.name) renders nothing back")
        }
    }

    /// The lights' copy of the scene (no glow or grain), size×size.
    private func render(_ sim: FluidSimulation, look: DisplayLook = DisplayLook(), size: Int = 48) throws -> [UInt8] {
        let renderer = try XCTUnwrap(CanvasRenderer(device: sim.device), "canvas shaders didn't compile")
        let dye = try XCTUnwrap(sim.dyeTexture)
        renderer.prepare(dyeWidth: dye.width, dyeHeight: dye.height, particles: 0)
        let target = try texture(sim.device, size, size)
        let queue = try XCTUnwrap(sim.device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        var p = CanvasRenderer.Params()
        p.look = look
        renderer.renderScene(cb, sim: sim, params: p)
        renderer.renderLights(cb, into: target, light: .init())
        cb.commit(); cb.waitUntilCompleted()
        XCTAssertNil(cb.error)
        return bytes(target)
    }

    private func texture(_ device: MTLDevice, _ w: Int, _ h: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: d))
    }

    private func bytes(_ t: MTLTexture) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: t.width * t.height * 4)
        t.getBytes(&b, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        return b
    }

    /// Where the colour's weight sits along x, 0…1.
    private func centroidX(_ px: [UInt8], size: Int = 48) -> Double {
        var sum = 0.0, weight = 0.0
        for y in 0..<size { for x in 0..<size {
            let i = (y * size + x) * 4
            let w = Double(px[i]) + Double(px[i + 1]) + Double(px[i + 2])
            sum += w * (Double(x) + 0.5) / Double(size); weight += w
        } }
        return weight > 0 ? sum / weight : 0.5
    }

    private func step(_ sim: FluidSimulation, frames: Int) throws {
        let queue = try XCTUnwrap(sim.device.makeCommandQueue())
        for _ in 0..<frames {
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            sim.step(cb, dt: 1 / 60)
            cb.commit(); cb.waitUntilCompleted()
            XCTAssertNil(cb.error)
        }
    }

    func testSplatAppearsAndFlowCarriesIt() throws {
        var settings = FluidSimulation.Settings()
        settings.simResolution = 64; settings.dyeResolution = 128
        let sim = try XCTUnwrap(FluidSimulation(settings: settings), "Metal or the fluid shaders unavailable")
        sim.resize(width: 400, height: 400)
        try step(sim, frames: 1)
        let blank = try render(sim).enumerated().filter { $0.offset % 4 != 3 }.map(\.element)   // skip alpha
        XCTAssertEqual(blank.max(), 0, "starts black")

        // A red drop in the left half, pushed right.
        sim.add(FluidSplat(x: 0.25, y: 0.5, dx: 600, dy: 0, color: SIMD3(1, 0, 0), radius: 0.002))
        try step(sim, frames: 1)
        let first = try render(sim)
        func red(_ px: [UInt8], x: Int, y: Int) -> Int { Int(px[(y * 48 + x) * 4 + 2]) }   // BGRA
        XCTAssertGreaterThan(red(first, x: 12, y: 24), 100, "the drop is where it was put")
        XCTAssertEqual(red(first, x: 40, y: 24), 0, "nothing on the far right yet")

        try step(sim, frames: 40)
        let later = try render(sim)
        let rightOfStart = (14..<48).map { red(later, x: $0, y: 24) }.reduce(0, +)
        let atStart = red(later, x: 12, y: 24)
        XCTAssertGreaterThan(rightOfStart, 0, "carried to the right")
        XCTAssertLessThan(atStart, red(first, x: 12, y: 24), "moved on from where it started")
        XCTAssertFalse(later.isEmpty)
    }

    /// Each animation draws the same liquid its own way, not just in other colours.
    func testEveryAnimationLooksDifferent() throws {
        var settings = FluidSimulation.Settings()
        settings.simResolution = 64; settings.dyeResolution = 128
        let sim = try XCTUnwrap(FluidSimulation(settings: settings), "Metal or the fluid shaders unavailable")
        sim.resize(width: 400, height: 400)
        try step(sim, frames: 1)
        sim.add(FluidSplat(x: 0.35, y: 0.5, dx: 300, dy: 100, color: SIMD3(0.8, 0.1, 0.5), radius: 0.004))
        sim.add(FluidSplat(x: 0.65, y: 0.4, dx: -200, dy: 0, color: SIMD3(0.1, 0.4, 0.9), radius: 0.003))
        try step(sim, frames: 10)
        let frames = try CanvasStyle.allCases.indices.map { i -> [UInt8] in
            return try render(sim, look: DisplayLook(style: CanvasStyle.allCases[i], time: 30))
        }
        for i in frames.indices { for j in frames.indices where j > i {
            // Share of lit pixels that clearly differ (black background ignored).
            var lit = 0, differ = 0
            for p in stride(from: 0, to: frames[i].count, by: 4) {
                let a = frames[i][p..<p + 3], b = frames[j][p..<p + 3]
                guard a.contains(where: { $0 > 20 }) || b.contains(where: { $0 > 20 }) else { continue }
                lit += 1
                if zip(a, b).contains(where: { abs(Int($0) - Int($1)) > 40 }) { differ += 1 }
            }
            XCTAssertGreaterThan(Double(differ), Double(lit) * 0.1, "\(CanvasStyle.allCases[i]) and \(CanvasStyle.allCases[j]) look alike")
        } }
    }

    /// Tilting pours the colour toward the low side; a well draws it in.
    func testTiltAndWellsMoveTheColour() throws {
        for force in ["tilt", "well"] {
            var settings = FluidSimulation.Settings()
            settings.simResolution = 64; settings.dyeResolution = 128
            let sim = try XCTUnwrap(FluidSimulation(settings: settings))
            sim.resize(width: 400, height: 400)
            try step(sim, frames: 1)
            sim.add(FluidSplat(x: 0.5, y: 0.5, dx: 0, dy: 0, color: SIMD3(0.9, 0.2, 0.6), radius: 0.004))
            try step(sim, frames: 1)
            let before = centroidX(try render(sim))
            if force == "tilt" { sim.gravity = SIMD2(700, 0) } else { sim.wells = [SIMD4(0.85, 0.5, 1, 0)] }
            try step(sim, frames: 40)
            let after = centroidX(try render(sim))
            XCTAssertGreaterThan(after, before + 0.03, "\(force) should move colour right: \(before) → \(after)")
        }
    }

    /// The full picture: particles, trails, glow, roll-off and grain all run,
    /// and the glow spreads light beyond a bright spot.
    func testParticlesTrailsAndGlowRun() throws {
        var settings = FluidSimulation.Settings()
        settings.simResolution = 64; settings.dyeResolution = 256
        let sim = try XCTUnwrap(FluidSimulation(settings: settings))
        sim.resize(width: 400, height: 400)
        try step(sim, frames: 1)
        sim.add(FluidSplat(x: 0.5, y: 0.5, dx: 300, dy: 0, color: SIMD3(2, 1.6, 1.2), radius: 0.0015))
        try step(sim, frames: 3)
        let renderer = try XCTUnwrap(CanvasRenderer(device: sim.device))
        let dye = try XCTUnwrap(sim.dyeTexture)
        renderer.prepare(dyeWidth: dye.width, dyeHeight: dye.height, particles: 20_000)
        let queue = try XCTUnwrap(sim.device.makeCommandQueue())
        func final(bloom: Float) throws -> [UInt8] {
            let target = try texture(sim.device, 64, 64)
            var p = CanvasRenderer.Params()
            p.look = DisplayLook(style: .liquid, time: 1)
            p.finish = CanvasStyle.liquid.finish
            p.finish.bloom = bloom
            p.finish.grain = 0
            for _ in 0..<5 {
                let cb = try XCTUnwrap(queue.makeCommandBuffer())
                renderer.renderScene(cb, sim: sim, params: p)
                cb.commit(); cb.waitUntilCompleted()
                XCTAssertNil(cb.error)
            }
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            renderer.renderFinal(cb, to: pass, format: .bgra8Unorm, params: p)
            cb.commit(); cb.waitUntilCompleted()
            XCTAssertNil(cb.error)
            return bytes(target)
        }
        let glow = try final(bloom: 1.2), plain = try final(bloom: 0)
        func level(_ px: [UInt8], _ x: Int, _ y: Int) -> Int { let i = (y * 64 + x) * 4; return Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) }
        XCTAssertGreaterThan(level(plain, 32, 32), 200, "the bright spot shows")
        let ring = [(32, 24), (32, 40), (24, 32), (40, 32)]
        XCTAssertGreaterThan(ring.map { level(glow, $0.0, $0.1) }.reduce(0, +), ring.map { level(plain, $0.0, $0.1) }.reduce(0, +) + 20,
                             "glow spreads light around a bright spot")
    }
}
/// Runs everywhere, CI's virtual GPU included: the Metal source compiles.
final class FluidShaderCompileTests: XCTestCase {
    func testShadersCompile() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let sim = try XCTUnwrap(FluidSimulation(), "fluid shaders failed to compile")
        XCTAssertNotNil(CanvasRenderer(device: sim.device), "canvas shaders failed to compile")
    }
}
#endif
