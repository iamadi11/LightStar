import Foundation

/// An animated effect LightStar runs across the lightbar's segments itself
/// (the strip's 58 effects run in its own firmware; WiZ has only fixed scenes).
/// Frames are pure functions of time, so they can be tested and paused freely.
public struct LampEffect: Equatable, Sendable, Identifiable {
    public enum Motion: String, Sendable {
        /// The palette scrolls along the bar.
        case flow
        /// A comet with a fading tail runs from the base to the far end.
        case chase
        /// The whole bar breathes through the palette, one colour per breath.
        case fade
        /// Light opens out from the centre and closes back.
        case openClose
        /// Segments twinkle on and off at random.
        case sparkle
        /// Flickering embers, hottest at the base.
        case fire
    }

    public var name: String
    public var motion: Motion
    public var palette: [WizRGB]
    public var id: String { name }

    public init(name: String, motion: Motion, palette: [WizRGB]) {
        self.name = name
        self.motion = motion
        self.palette = palette.isEmpty ? [WizRGB(r: 255, g: 255, b: 255)] : palette
    }

    // MARK: Palettes

    public static func hues(_ hues: [Double]) -> [WizRGB] {
        hues.map { WizRGB(hue: $0, saturation: 1) }
    }

    public static let rainbow = hues([0, 1.0 / 12, 1.0 / 6, 1.0 / 3, 1.0 / 2, 2.0 / 3, 5.0 / 6])
    public static let white = [WizRGB(r: 255, g: 255, b: 255)]
    static let fireColours = [WizRGB(r: 255, g: 40, b: 0), WizRGB(r: 255, g: 110, b: 0), WizRGB(r: 255, g: 170, b: 20)]

    /// Effects offered in Settings → Lightbar.
    public static let builtIn: [LampEffect] = [
        LampEffect(name: "Rainbow Flow", motion: .flow, palette: rainbow),
        LampEffect(name: "Ocean", motion: .flow, palette: hues([0.5, 0.58, 0.66, 0.55])),
        LampEffect(name: "Rainbow Chase", motion: .chase, palette: rainbow),
        LampEffect(name: "Breathe", motion: .fade, palette: rainbow),
        LampEffect(name: "Open / Close", motion: .openClose, palette: rainbow),
        LampEffect(name: "Sparkle", motion: .sparkle, palette: rainbow),
        LampEffect(name: "Fire", motion: .fire, palette: fireColours),
    ]

    /// The lightbar's version of one of the strip's firmware effects: the
    /// group decides the motion, the name the colours.
    public static func matching(_ effect: Effect, in group: EffectGroup) -> LampEffect {
        let motion: Motion
        switch group {
        case .loop: motion = effect.name.contains("Strobe") ? .sparkle : .flow
        case .flutter: motion = .sparkle
        case .brush, .water: motion = .flow
        case .openClose: motion = .openClose
        case .transition: motion = .fade
        case .tailing, .running: motion = .chase
        }
        return LampEffect(name: "\(group.rawValue) · \(effect.name)", motion: motion, palette: palette(named: effect.name))
    }

    /// Colours named in a strip effect ("Blue-Green-Red", "Purple", "7 Colors").
    static func palette(named name: String) -> [WizRGB] {
        let named: [(String, Double?)] = [
            ("Red", 0), ("Yellow", 1.0 / 6), ("Green", 1.0 / 3), ("Cyan", 1.0 / 2),
            ("Blue", 2.0 / 3), ("Purple", 0.78), ("Violet", 0.75), ("White", nil),
        ]
        let words = name.split(whereSeparator: { $0 == "-" || $0 == " " }).map(String.init)
        let found: [WizRGB] = words.compactMap { word in
            named.first { $0.0 == word }.map { _, hue in hue.map { WizRGB(hue: $0, saturation: 1) } ?? white[0] }
        }
        return found.isEmpty ? rainbow : found
    }

    // MARK: Frames

    /// Cycles per second at the strip's speed setting (0…1).
    static func rate(_ speed: Double) -> Double { 0.1 + max(0, min(1, speed)) * 1.4 }

    /// One frame: `count` colours, zone 0 at the base.
    public func frame(time: Double, speed: Double, count: Int) -> [WizRGB] {
        guard count > 0 else { return [] }
        let phase = time * Self.rate(speed)
        let n = Double(count)
        switch motion {
        case .flow:
            return (0..<count).map { i in colour(at: Double(i) / n + phase) }
        case .chase:
            let tail = max(2, n / 3)
            let lap = phase.truncatingRemainder(dividingBy: 1) * (n + tail)
            let c = palette[Int(phase) % palette.count]
            return (0..<count).map { i in
                let behind = lap - Double(i)
                guard behind >= 0, behind < tail else { return .off }
                return LampGradient.scaled([c], by: 1 - behind / tail)[0]
            }
        case .fade:
            let breath = (1 - cos(phase.truncatingRemainder(dividingBy: 1) * 2 * .pi)) / 2
            let c = palette[Int(phase) % palette.count]
            return Array(repeating: LampGradient.scaled([c], by: 0.08 + 0.92 * breath)[0], count: count)
        case .openClose:
            let p = phase.truncatingRemainder(dividingBy: 2)
            let open = p < 1 ? p : 2 - p
            let c = palette[Int(phase / 2) % palette.count]
            return (0..<count).map { i in
                let fromCentre = abs((Double(i) + 0.5) / n - 0.5) * 2
                return fromCentre <= open ? c : .off
            }
        case .sparkle:
            let tick = Int(phase * 4)
            let within = (phase * 4).truncatingRemainder(dividingBy: 1)
            return (0..<count).map { i in
                let h = Self.hash(i, tick)
                guard h % 3 == 0 else { return .off }
                return LampGradient.scaled([palette[h % palette.count]], by: 1 - within)[0]
            }
        case .fire:
            return (0..<count).map { i in
                let height = Double(i) / n
                let flicker = 0.5 + 0.25 * sin(phase * 9 + Double(i) * 1.7) + 0.25 * sin(phase * 23 + Double(i) * 0.9)
                let heat = max(0, min(1, flicker * (1.1 - height * 0.8)))
                let c = palette[min(palette.count - 1, Int(heat * Double(palette.count)))]
                return LampGradient.scaled([c], by: 0.15 + 0.85 * heat)[0]
            }
        }
    }

    /// Palette colour at a position that wraps every 1.0, blended between neighbours.
    private func colour(at position: Double) -> WizRGB {
        let x = (position.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * Double(palette.count)
        let a = palette[Int(x) % palette.count], b = palette[(Int(x) + 1) % palette.count]
        let t = x - x.rounded(.down)
        func mix(_ u: Int, _ v: Int) -> Int { Int((Double(u) + (Double(v) - Double(u)) * t).rounded()) }
        return WizRGB(r: mix(a.r, b.r), g: mix(a.g, b.g), b: mix(a.b, b.b))
    }

    /// Stable pseudo-random number per segment and tick.
    static func hash(_ a: Int, _ b: Int) -> Int {
        var x = UInt64(truncatingIfNeeded: a &* 73_856_093 ^ b &* 19_349_663)
        x ^= x >> 13; x &*= 0x5bd1e995; x ^= x >> 15
        return Int(x % 1_000_003)
    }
}
