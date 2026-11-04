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

    /// Dominant colour of each horizontal band of a BGRA frame, picked the way
    /// the strip picks its single colour (hue histogram weighted by
    /// saturation × brightness), so the lightbar and the bar agree. The hue is
    /// the mean of the winning bin's pixels, not the bin centre, so pure
    /// colours land exactly. A band with
    /// almost nothing colourful in it shows neutral white at its brightness;
    /// averaging instead would mix colours into grey.
    public static func screenZones(
        bgra: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, count: Int = zoneCount
    ) -> [WizRGB] {
        guard width > 0, height > 0, count > 0 else { return [] }
        let bins = 36
        return (0..<count).map { zone in
            // Bottom zone comes from the bottom rows of the screen.
            let top = height - (zone + 1) * height / count
            let bottom = height - zone * height / count
            var histogram = [Double](repeating: 0, count: bins)
            var satSum = [Double](repeating: 0, count: bins)
            var valSum = [Double](repeating: 0, count: bins)
            var hueSum = [Double](repeating: 0, count: bins)
            var binCount = [Int](repeating: 0, count: bins)
            var pixels = 0, colourful = 0
            var valueTotal = 0.0
            for row in max(0, top)..<max(top + 1, bottom) where row < height {
                for col in 0..<width {
                    let i = row * bytesPerRow + col * 4
                    let (h, s, v) = hsv(r: bgra[i + 2], g: bgra[i + 1], b: bgra[i])
                    pixels += 1
                    valueTotal += v
                    // Same floor as the strip's analyser: ignore near-black and greys.
                    guard v > 0.12, s > 0.15 else { continue }
                    colourful += 1
                    let bin = min(bins - 1, Int(h * Double(bins)))
                    histogram[bin] += s * v
                    satSum[bin] += s
                    valSum[bin] += v
                    hueSum[bin] += h
                    binCount[bin] += 1
                }
            }
            guard pixels > 0 else { return .off }
            // ponytail: 2% colourful pixels claims the band; a lone icon shouldn't.
            if colourful * 50 >= pixels,
               let peak = histogram.indices.max(by: { histogram[$0] < histogram[$1] }), binCount[peak] > 0 {
                let n = Double(binCount[peak])
                let hue = hueSum[peak] / n
                let saturation = min(1, satSum[peak] / n * 1.15)
                return scaled([WizRGB(hue: hue, saturation: saturation)], by: valSum[peak] / n)[0]
            }
            let grey = Int((valueTotal / Double(pixels) * 255).rounded())
            return WizRGB(r: grey, g: grey, b: grey)
        }
    }

    private static func hsv(r: UInt8, g: UInt8, b: UInt8) -> (Double, Double, Double) {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let hi = max(rf, gf, bf), lo = min(rf, gf, bf), d = hi - lo
        guard d > 0 else { return (0, 0, hi) }
        var h: Double
        if hi == rf { h = (gf - bf) / d } else if hi == gf { h = (bf - rf) / d + 2 } else { h = (rf - gf) / d + 4 }
        h /= 6
        if h < 0 { h += 1 }
        return (h, d / hi, hi)
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
