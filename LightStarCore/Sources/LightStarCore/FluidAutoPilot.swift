import Foundation

/// The Canvas animations, each after a kind of calming ambient video: its own
/// drawing (the display shader's look), palette, motion and physics. All slow,
/// on dark backgrounds (bar Ink), with no flicker.
public enum CanvasStyle: String, CaseIterable, Identifiable, Sendable {
    /// Paint in water. Aura: a soft drifting gradient, like a mood-light loop.
    /// Lava: a lava lamp's merging blobs. Aurora: northern-lights curtains.
    /// Ocean: bioluminescent wave edges. Nebula: clouds over stars. Ink: ink on paper.
    case liquid, aura, lava, aurora, ocean, nebula, ink
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .lava: return "Lava lamp"
        case .ocean: return "Ocean glow"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
    public static let defaultsKey = "canvasStyle"
    public static var stored: CanvasStyle {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(CanvasStyle.init) ?? .liquid
    }

    public enum Pattern: Sendable { case wander, rise, sweep, orbit }

    /// Everything an animation sets. Colour amounts are per 1/60 s.
    public struct Look: Sendable {
        public var hues: [Double]
        public var emitters: Int
        public var speed: Double
        public var pattern: Pattern
        public var radius: Double
        /// Push along the path, scaled by path speed.
        public var force: Double
        public var amount: Double
        public var curl: Float
        public var dyeDissipation: Float
        public var velocityDissipation: Float
    }

    public var look: Look {
        switch self {
        case .liquid:
            return Look(hues: FluidAutoPilot.pop, emitters: 3, speed: 0.6, pattern: .wander, radius: 0.0022,
                        force: 1.1, amount: 0.08, curl: 25, dyeDissipation: 0.45, velocityDissipation: 0.25)
        case .aura:
            return Look(hues: [0.92, 0.78, 0.62, 0.5, 0.07], emitters: 4, speed: 0.35, pattern: .wander, radius: 0.012,
                        force: 0.6, amount: 0.05, curl: 5, dyeDissipation: 0.3, velocityDissipation: 0.6)
        case .lava:
            return Look(hues: [0.0, 0.06, 0.95, 0.1, 0.88], emitters: 2, speed: 0.4, pattern: .rise, radius: 0.006,
                        force: 0.7, amount: 0.03, curl: 8, dyeDissipation: 0.5, velocityDissipation: 0.6)
        case .aurora:
            return Look(hues: [0.36, 0.42, 0.5, 0.78, 0.33], emitters: 3, speed: 0.35, pattern: .sweep, radius: 0.004,
                        force: 0.8, amount: 0.05, curl: 15, dyeDissipation: 0.5, velocityDissipation: 0.35)
        case .ocean:
            return Look(hues: [0.52, 0.55, 0.6, 0.48, 0.65], emitters: 3, speed: 0.5, pattern: .sweep, radius: 0.003,
                        force: 1.4, amount: 0.09, curl: 35, dyeDissipation: 0.55, velocityDissipation: 0.25)
        case .nebula:
            return Look(hues: [0.62, 0.72, 0.8, 0.88, 0.55], emitters: 4, speed: 0.4, pattern: .orbit, radius: 0.004,
                        force: 1.0, amount: 0.05, curl: 30, dyeDissipation: 0.3, velocityDissipation: 0.15)
        case .ink:
            return Look(hues: [0.6, 0.95, 0.12, 0.5], emitters: 2, speed: 0.3, pattern: .wander, radius: 0.0012,
                        force: 0.8, amount: 0.06, curl: 50, dyeDissipation: 0.2, velocityDissipation: 0.1)
        }
    }
}

/// Auto mode for the Canvas: a few emitters move over the canvas on slow,
/// never-repeating paths (the style's pattern), trailing colour and pushing
/// the liquid along their direction. A pure function of time (plus a seed),
/// like the lightbar effects, so it can be tested.
public struct FluidAutoPilot: Sendable {
    /// 1 is the style's own pace; Reduce Motion uses less.
    public var speed: Double
    /// Hues the emitters cycle through, 0…1.
    public var hues: [Double]
    public var pattern: CanvasStyle.Pattern
    public var radius: Double
    public var force: Double
    public var amount: Double
    /// Moves every emitter along the palette (Music: treble cools, bass warms).
    public var hueShift = 0.0
    private let phases: [(x: Double, y: Double, hue: Double)]

    /// Lissajous frequencies with irrational ratios, so paths don't close.
    private static let rates: [(Double, Double)] = [(0.31, 0.47), (0.23, 0.37), (0.41, 0.29), (0.19, 0.53)]

    /// Pop palette: hot pink, electric blue, cyan, lime, orange, violet. Spread
    /// around the wheel so neighbours blend into bright colours, not brown.
    public static let pop: [Double] = [0.92, 0.62, 0.5, 0.25, 0.07, 0.78]

    public init(emitters: Int = 3, seed: UInt64 = 1, speed: Double = 1, hues: [Double] = FluidAutoPilot.pop,
                pattern: CanvasStyle.Pattern = .wander, radius: Double = 0.0018, force: Double = 1.4,
                amount: Double = 0.09) {
        var rng = SeededRandom(seed: seed)
        phases = (0..<max(1, min(emitters, Self.rates.count))).map { _ in
            (rng.next() * 2 * .pi, rng.next() * 2 * .pi, rng.next())
        }
        self.speed = speed
        self.hues = hues.isEmpty ? [0] : hues
        self.pattern = pattern
        self.radius = radius
        self.force = force
        self.amount = amount
    }

    public init(style: CanvasStyle, speedScale: Double = 1, seed: UInt64 = 1) {
        let look = style.look
        self.init(emitters: look.emitters, seed: seed, speed: look.speed * speedScale, hues: look.hues,
                  pattern: look.pattern, radius: look.radius, force: look.force, amount: look.amount)
    }

    /// Where emitter `i` is at time `t`, 0…1 with y down, kept off the edges.
    func position(_ i: Int, at t: Double) -> (x: Double, y: Double) {
        let (a, b) = Self.rates[i]
        let s = t * speed
        let ph = phases[i]
        switch pattern {
        case .wander, .rise:
            return (0.5 + 0.36 * sin(a * s + ph.x), 0.5 + 0.36 * sin(b * s + ph.y))
        case .sweep:
            // Wide, slow sweeps across the canvas in bands at different heights.
            let band = 0.3 + 0.4 * Double(i) / Double(max(1, phases.count - 1))
            return (0.5 + 0.38 * sin(a * 0.7 * s + ph.x), band + 0.08 * sin(b * 1.3 * s + ph.y))
        case .orbit:
            // Round the centre, each on its own ring, breathing in and out.
            let angle = (0.35 + 0.1 * Double(i)) * s + ph.x
            let ring = 0.18 + 0.05 * Double(i) + 0.04 * sin(b * s + ph.y)
            return (0.5 + ring * cos(angle), 0.5 + ring * sin(angle))
        }
    }

    /// Splats for the frame at `t` lasting `dt` seconds. Colour and push per
    /// frame scale with `dt`, so the canvas looks the same at any frame rate.
    public func splats(at t: Double, dt: Double, simCells: Double = 256) -> [FluidSplat] {
        let dt = max(0, min(0.1, dt))
        return phases.indices.map { i in
            let p = position(i, at: t)
            let q = position(i, at: t + 0.05)
            // Cells per second, so any grid looks the same.
            let push = force * simCells * dt * 60
            var dx = (q.x - p.x) / 0.05 * push
            var dy = (q.y - p.y) / 0.05 * push   // y down, like the texture rows
            // Lava rises: a steady upward push on top of the drift.
            if pattern == .rise { dy -= 0.25 * push }
            if pattern == .sweep { dy *= 0.3; dx *= 1.2 }
            let rgb = Self.rgb(hue: colourHue(i, at: t))
            return FluidSplat(x: p.x, y: p.y, dx: dx, dy: dy, color: rgb * Float(dt * 60 * amount), radius: radius)
        }
    }

    /// Each emitter walks the hue list slowly, blending between neighbours.
    func colourHue(_ i: Int, at t: Double) -> Double {
        paletteHue(t * speed * 0.035 + phases[i].hue + hueShift)
    }

    /// The palette as a loop: 0…1 walks once through every hue, blending.
    public func paletteHue(_ position: Double) -> Double {
        let walk = (position.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * Double(hues.count)
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
