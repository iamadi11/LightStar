import Foundation

/// Auto mode for the Canvas: a few emitters drift over the canvas on slow,
/// never-repeating paths, trailing colour and pushing the liquid along their
/// direction, so it keeps flowing with nobody touching it. A pure function of
/// time (plus a seed), like the lightbar effects, so it can be tested.
public struct FluidAutoPilot: Sendable {
    /// 1 is the default pace; Reduce Motion uses less.
    public var speed: Double
    /// Hues the emitters cycle through, 0…1.
    public var hues: [Double]
    private let phases: [(x: Double, y: Double, hue: Double)]

    /// Lissajous frequencies with irrational ratios, so paths don't close.
    private static let rates: [(Double, Double)] = [(0.31, 0.47), (0.23, 0.37), (0.41, 0.29), (0.19, 0.53)]

    public init(emitters: Int = 3, seed: UInt64 = 1, speed: Double = 1,
                hues: [Double] = [0.0, 0.08, 0.55, 0.62, 0.78, 0.9]) {
        var rng = SeededRandom(seed: seed)
        phases = (0..<max(1, min(emitters, Self.rates.count))).map { _ in
            (rng.next() * 2 * .pi, rng.next() * 2 * .pi, rng.next())
        }
        self.speed = speed
        self.hues = hues.isEmpty ? [0] : hues
    }

    /// Where emitter `i` is at time `t`, 0…1 with y down, kept off the edges.
    func position(_ i: Int, at t: Double) -> (x: Double, y: Double) {
        let (a, b) = Self.rates[i]
        let s = t * speed
        return (0.5 + 0.36 * sin(a * s + phases[i].x), 0.5 + 0.36 * sin(b * s + phases[i].y))
    }

    /// Splats for the frame at `t` lasting `dt` seconds. Colour per frame
    /// scales with `dt`, so the canvas looks the same at 30, 60 or 120 fps.
    public func splats(at t: Double, dt: Double, simCells: Double = 256) -> [FluidSplat] {
        let dt = max(0, min(0.1, dt))
        return phases.indices.map { i in
            let p = position(i, at: t)
            let q = position(i, at: t + 0.05)
            // Push along the path, in cells per second so any grid looks the
            // same; added every frame, so scaled by the frame's length too.
            let force = 1.4 * simCells * dt * 60
            let dx = (q.x - p.x) / 0.05 * force
            let dy = (q.y - p.y) / 0.05 * force   // y down, like the texture rows
            let hue = colourHue(i, at: t)
            let rgb = Self.rgb(hue: hue)
            let amount = Float(dt * 60 * 0.06)
            return FluidSplat(x: p.x, y: p.y, dx: dx, dy: dy, color: rgb * amount, radius: 0.0018)
        }
    }

    /// Each emitter walks the hue list slowly, blending between neighbours.
    func colourHue(_ i: Int, at t: Double) -> Double {
        let walk = (t * speed * 0.035 + phases[i].hue).truncatingRemainder(dividingBy: 1) * Double(hues.count)
        let a = hues[Int(walk) % hues.count], b = hues[(Int(walk) + 1) % hues.count]
        var d = b - a
        if d > 0.5 { d -= 1 } else if d < -0.5 { d += 1 }
        let h = a + d * (walk - walk.rounded(.down))
        return h < 0 ? h + 1 : h.truncatingRemainder(dividingBy: 1)
    }

    static func rgb(hue: Double) -> SIMD3<Float> {
        let c = WizRGB(hue: hue, saturation: 1)
        return SIMD3(Float(c.r), Float(c.g), Float(c.b)) / 255
    }
}

/// SplitMix64: a fixed sequence per seed, so Auto mode is reproducible in tests.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
