import Foundation

/// Per-segment colour for a gradient lamp while sync runs. Zone 0 is the bottom
/// of the lamp. Screen sync maps screen bands onto the lamp top-to-top; audio
/// sync is a VU meter that fills from the floor.
public enum LampGradient {
    public static let zoneCount = WizSegmentLayout.zones
    public static let enabledDefaultsKey = "lampGradientSync"
    /// Mean brightness below this is black on screen: the zone goes dark.
    public static let blackLevel = 0.1

    /// Whether a frame's zones go to the lightbar. A frame the DRM guard holds
    /// (mostly black with a black band) can still be real content, like the
    /// Netflix logo on black: paint it, with its black zones off. Only a frame
    /// with nothing visible at all is held, since DRM-protected video captures
    /// as solid black and must not blank the lightbar.
    public static func shouldPaint(_ zones: [WizRGB], frameWritable: Bool) -> Bool {
        frameWritable || zones.contains { !$0.isOff }
    }

    /// How the lightbar stands next to the screen. Vertical slices the screen
    /// into rows (bottom row → base), horizontal into columns (left → base).
    public enum Orientation: String, CaseIterable, Sendable, Identifiable {
        case vertical, horizontal
        public var id: String { rawValue }
        public var title: String { self == .vertical ? "Vertical" : "Horizontal" }
        /// Label for the flip switch in this orientation.
        public var flipTitle: String { self == .vertical ? "Swap top and bottom" : "Swap left and right" }
    }
    public static let orientationDefaultsKey = "lightbarOrientation"
    /// Base at the top (vertical) or on the right (horizontal).
    public static let flippedDefaultsKey = "lightbarFlipped"

    public static var orientation: Orientation {
        UserDefaults.standard.string(forKey: orientationDefaultsKey).flatMap(Orientation.init) ?? .vertical
    }
    public static var flipped: Bool { UserDefaults.standard.bool(forKey: flippedDefaultsKey) }

    /// Where the lightbar's middle sits along the screen, as a share of the
    /// screen: 0 is the screen's centre, +0.25 a quarter further right (or up).
    public static let centreDefaultsKey = "lightbarCentre"
    public static let centreRange = -0.5...0.5
    public static var centre: Double {
        let v = UserDefaults.standard.double(forKey: centreDefaultsKey)
        return min(centreRange.upperBound, max(centreRange.lowerBound, v.isFinite ? v : 0))
    }

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
        bgra: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, count: Int = zoneCount,
        orientation: Orientation = .vertical, flipped: Bool = false, followBrightness: Bool = true,
        centre: Double = 0
    ) -> [WizRGB] {
        guard width > 0, height > 0, count > 0 else { return [] }
        let bins = 36
        let zones = (0..<count).map { zone -> WizRGB in
            // Zone 0 is the lightbar's base: the bottom rows, or the left columns.
            var rows = 0..<height, cols = 0..<width
            switch orientation {
            case .vertical:
                rows = band(zone, of: height, count: count, shift: centre, fromEnd: true)
            case .horizontal:
                cols = band(zone, of: width, count: count, shift: centre, fromEnd: false)
            }
            var histogram = [Double](repeating: 0, count: bins)
            var satSum = [Double](repeating: 0, count: bins)
            var valSum = [Double](repeating: 0, count: bins)
            var valMax = [Double](repeating: 0, count: bins)
            var hueSum = [Double](repeating: 0, count: bins)
            var binCount = [Int](repeating: 0, count: bins)
            var pixels = 0, colourful = 0
            var valueTotal = 0.0
            for row in rows {
                for col in cols {
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
                    valMax[bin] = max(valMax[bin], v)
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
                // Brightest pixels of the winning colour, not their mean: at 48×27 thin
                // bright strokes (a logo on black) blend into the dark around them.
                // Without "Follow screen brightness" colour runs at full, like the strip.
                let value = followBrightness ? valMax[peak] : 1
                return scaled([WizRGB(hue: hue, saturation: saturation)], by: value)[0]
            }
            // A black band is off, not the dimmest grey the lamp can make.
            let mean = valueTotal / Double(pixels)
            guard mean >= blackLevel else { return .off }
            let grey = Int((mean * 255).rounded())
            return WizRGB(r: grey, g: grey, b: grey)
        }
        return flipped ? zones.reversed() : zones
    }

    /// Slice `zone` of `count` along a side `length` long, moved by `shift`
    /// (share of the side), never empty. A slice pushed past the screen's edge
    /// reads the edge row/column rather than going dark.
    private static func band(_ zone: Int, of length: Int, count: Int, shift: Double, fromEnd: Bool) -> Range<Int> {
        let start = (Double(zone) / Double(count) + shift) * Double(length)
        let end = (Double(zone + 1) / Double(count) + shift) * Double(length)
        let lo = min(length - 1, max(0, Int(start.rounded(.down))))
        let hi = min(length, max(lo + 1, Int(end.rounded(.down))))
        let range = lo..<hi
        return fromEnd ? (length - range.upperBound)..<(length - range.lowerBound) : range
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
