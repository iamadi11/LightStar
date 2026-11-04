import Foundation

/// Per-segment colour for a gradient lamp while sync runs. Zone 0 is the bottom
/// of the lamp. Screen sync maps screen bands onto the lamp top-to-top; audio
/// sync is a VU meter that fills from the floor.
public enum LampGradient {
    public static let zoneCount = WizSegmentLayout.zones
    public static let enabledDefaultsKey = "lampGradientSync"

    public static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// Average horizontal bands of a BGRA frame. Saturated, bright pixels weigh
    /// more so a coloured window on a grey desktop still tints its band.
    public static func screenZones(
        bgra: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, count: Int = zoneCount
    ) -> [WizRGB] {
        guard width > 0, height > 0, count > 0 else { return [] }
        return (0..<count).map { zone in
            // Bottom zone comes from the bottom rows of the screen.
            let top = height - (zone + 1) * height / count
            let bottom = height - zone * height / count
            var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
            for row in max(0, top)..<max(top + 1, bottom) where row < height {
                for col in 0..<width {
                    let i = row * bytesPerRow + col * 4
                    let pb = Double(bgra[i]), pg = Double(bgra[i + 1]), pr = Double(bgra[i + 2])
                    let hi = max(pr, pg, pb), lo = min(pr, pg, pb)
                    let sat = hi > 0 ? (hi - lo) / hi : 0
                    let w = 0.05 + sat * hi / 255
                    r += pr * w; g += pg * w; b += pb * w; weight += w
                }
            }
            guard weight > 0 else { return .off }
            return WizRGB(r: Int((r / weight).rounded()), g: Int((g / weight).rounded()), b: Int((b / weight).rounded()))
        }
    }

    /// Level bar: green at the floor, yellow, red at the top. The zone the level
    /// lands in is lit partially so the bar moves smoothly.
    public static func vu(level: Double, count: Int = zoneCount) -> [WizRGB] {
        let filled = max(0, min(1, level.isFinite ? level : 0)) * Double(count)
        return (0..<count).map { zone in
            let amount = max(0, min(1, filled - Double(zone)))
            guard amount > 0.02 else { return .off }
            let position = count > 1 ? Double(zone) / Double(count - 1) : 0
            // 120° green → 0° red.
            let base = WizRGB(hue: (1 - position) / 3, saturation: 1)
            return scaled([base], by: amount)[0]
        }
    }

    public static func scaled(_ zones: [WizRGB], by factor: Double) -> [WizRGB] {
        let f = max(0, min(1, factor.isFinite ? factor : 0))
        return zones.map {
            WizRGB(r: Int((Double($0.r) * f).rounded()), g: Int((Double($0.g) * f).rounded()), b: Int((Double($0.b) * f).rounded()))
        }
    }
}

/// Eases each zone toward the next frame. A big jump (scene cut) lands at once.
public struct LampZoneSmoother: Sendable {
    private var current: [Double] = []

    public init() {}

    public mutating func next(_ target: [WizRGB], alpha: Double) -> [WizRGB] {
        let flat = target.flatMap { [Double($0.r), Double($0.g), Double($0.b)] }
        let jump = zip(flat, current).map { abs($0 - $1) }.max() ?? .infinity
        if current.count != flat.count || jump > 120 {
            current = flat
        } else {
            let a = max(0.05, min(1, alpha))
            current = zip(current, flat).map { $0 + ($1 - $0) * a }
        }
        return stride(from: 0, to: current.count, by: 3).map {
            WizRGB(r: Int(current[$0].rounded()), g: Int(current[$0 + 1].rounded()), b: Int(current[$0 + 2].rounded()))
        }
    }
}

/// Rises with the music at once and falls back slowly, like a real meter.
public struct VUMeter: Sendable {
    public private(set) var level = 0.0
    public var release = 0.85

    public init() {}

    public mutating func next(_ bands: FrequencyBands) -> Double {
        let input = max(0, min(1, max(bands.bass, bands.rms * 1.5)))
        level = input >= level ? input : max(input, level * release)
        return level
    }
}
