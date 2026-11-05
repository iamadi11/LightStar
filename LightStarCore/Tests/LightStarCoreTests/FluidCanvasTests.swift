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

#if canImport(Metal)
/// Runs the real shaders on this Mac's GPU: they compile, a splat shows up
/// where it was put, the flow carries it, and nothing turns into NaN.
final class FluidSimulationGPUTests: XCTestCase {
    private func render(_ sim: FluidSimulation, size: Int = 48) throws -> [UInt8] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .shared
        let target = try XCTUnwrap(sim.device.makeTexture(descriptor: d))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let queue = try XCTUnwrap(sim.device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        sim.draw(cb, to: pass, format: .bgra8Unorm)
        cb.commit(); cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        target.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        return bytes
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
}
#endif
