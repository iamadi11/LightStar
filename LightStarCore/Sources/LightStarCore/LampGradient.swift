import Foundation

/// Per-segment colour for a gradient lamp while sync runs. Zone 0 is the bottom
/// of the lamp. Screen sync maps screen bands onto the lamp top-to-top; audio
/// sync is a VU meter that fills from the floor.
public enum LampGradient {
    public static let zoneCount = WizSegmentLayout.zones

    /// Colours a sync frame can carry: WiZ takes at most 12 steps, each dark
    /// (trimmed) end uses one, and there can't be more colours than lit
    /// segments. The 18-segment lightbar gets 12 untrimmed, 10 with both ends off.
    public static func colourCount(for placement: Placement, segments: Int) -> Int {
        let darkEnds = (placement.start > 0 ? 1 : 0) + (placement.end < 1 ? 1 : 0)
        let lit = Int(((placement.end - placement.start) * Double(segments)).rounded())
        return max(1, min(WizSegmentLayout.maxSteps - darkEnds, lit))
    }

    /// What music sync shows on the lightbar.
    public enum MusicStyle: String, CaseIterable, Sendable, Identifiable {
        /// Loudness fills the bar from the base, green to red.
        case meter
        /// Bass at the base, mids in the middle, treble at the top.
        case spectrum
        public var id: String { rawValue }
        public var title: String { self == .meter ? "Level meter" : "Spectrum" }
    }
    public static let musicStyleDefaultsKey = "lightbarMusicStyle"
    public static var musicStyle: MusicStyle {
        UserDefaults.standard.string(forKey: musicStyleDefaultsKey).flatMap(MusicStyle.init) ?? .meter
    }

    /// Spectrum: each zone lit by the energy of its band (bass at the base,
    /// treble at the top, blended between), coloured red at the base to
    /// violet at the top.
    public static func spectrum(_ bands: FrequencyBands, count: Int) -> [WizRGB] {
        (0..<count).map { i in
            let x = count > 1 ? Double(i) / Double(count - 1) : 0
            let energy = x < 0.5
                ? bands.bass + (bands.mid - bands.bass) * x * 2
                : bands.mid + (bands.high - bands.mid) * (x - 0.5) * 2
            guard energy > 0.03 else { return .off }
            return scaled([WizRGB(hue: x * 0.75, saturation: 1)], by: min(1, energy * 1.2))[0]
        }
    }

    /// Physical segments of the connected lightbar (detected, or saved widths).
    public static var segmentCount: Int { WizSegmentLayout.stored.widths.reduce(0, +) }
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

    /// How much of each end of the lightbar stays off in screen sync, as a
    /// share of the bar: start is the left (or bottom) end, end the right (or
    /// top). A bar longer than the monitor lights only the stretch between.
    public static let trimStartDefaultsKey = "lightbarTrimStart"
    public static let trimEndDefaultsKey = "lightbarTrimEnd"
    /// At least this much of the bar stays lit.
    public static let minLit = 0.2

    /// Where the screen sits on the lightbar during screen sync.
    public struct Placement: Equatable, Sendable {
        /// Lit stretch, as shares of the bar from the left / bottom.
        public var start: Double
        public var end: Double
        public var flipped: Bool

        public init(trimStart: Double = 0, trimEnd: Double = 0, flipped: Bool = false) {
            let maxTrim = 1 - minLit
            let a = min(maxTrim, max(0, trimStart.isFinite ? trimStart : 0))
            let b = min(maxTrim - a, max(0, trimEnd.isFinite ? trimEnd : 0))
            start = a
            end = 1 - b
            self.flipped = flipped
        }

        public static var current: Placement {
            let d = UserDefaults.standard
            return Placement(trimStart: d.double(forKey: trimStartDefaultsKey),
                             trimEnd: d.double(forKey: trimEndDefaultsKey),
                             flipped: d.bool(forKey: flippedDefaultsKey))
        }

        /// Segment widths, base first: the dark stretch before the screen, one
        /// per colour zone, the dark stretch after. Always sums to `segments`.
        public func widths(zones: Int, segments: Int) -> [Int] {
            guard zones > 0, segments > 0 else { return [] }
            let span = end - start
            let base = flipped ? 1 - end : start      // from the base end
            let bounds = (0...zones).map { k in
                min(segments, max(0, Int(((base + Double(k) * span / Double(zones)) * Double(segments)).rounded())))
            }
            return [bounds[0]] + (0..<zones).map { bounds[$0 + 1] - bounds[$0] } + [segments - bounds[zones]]
        }
    }

    /// Which part of the screen the lightbar reads. A lightbar beside the
    /// monitor should follow the edge next to it, not the whole width.
    /// first = left (vertical bar) or top (horizontal bar); second = right or bottom.
    public enum Edge: String, CaseIterable, Sendable, Identifiable {
        case whole, first, second, both
        public var id: String { rawValue }
        public func title(for orientation: Orientation) -> String {
            switch (self, orientation) {
            case (.whole, _): return "Whole screen"
            case (.first, .vertical): return "Left edge"
            case (.second, .vertical): return "Right edge"
            case (.first, .horizontal): return "Top edge"
            case (.second, .horizontal): return "Bottom edge"
            case (.both, _): return "Both edges"
            }
        }
    }
    public static let edgeDefaultsKey = "lightbarEdge"
    public static let edgeDepthDefaultsKey = "lightbarEdgeDepth"
    public static let ignoreBarsDefaultsKey = "lightbarIgnoreBars"
    public static let edgeDepthRange = 0.1...0.5

    public static var edge: Edge {
        if LightbarProfile.active == .game { return .whole }
        return UserDefaults.standard.string(forKey: edgeDefaultsKey).flatMap(Edge.init) ?? .whole
    }
    public static var edgeDepth: Double {
        let d = UserDefaults.standard.object(forKey: edgeDepthDefaultsKey) as? Double ?? 0.25
        return min(edgeDepthRange.upperBound, max(edgeDepthRange.lowerBound, d.isFinite ? d : 0.25))
    }
    public static var ignoreBars: Bool {
        if LightbarProfile.active == .video { return true }
        return UserDefaults.standard.object(forKey: ignoreBarsDefaultsKey) as? Bool ?? true
    }

    /// Black bars around the picture (a film's letterbox or a 4:3 pillarbox), in pixels.
    public struct Bars: Equatable, Sendable {
        public var top = 0, bottom = 0, left = 0, right = 0
        public init(top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0) {
            self.top = top; self.bottom = bottom; self.left = left; self.right = right
        }
        public static let none = Bars()
    }

    /// Rows or columns that are black from edge to edge count as a bar, but
    /// only in matching pairs (a dark sky at the top alone is picture) and at
    /// most 45% of the screen. An all-black frame has no bars.
    public static func blackBars(bgra: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> Bars {
        guard width > 2, height > 2 else { return .none }
        func dark(_ i: Int) -> Bool { max(bgra[i], bgra[i + 1], bgra[i + 2]) < 20 }
        func rowDark(_ r: Int) -> Bool { (0..<width).allSatisfy { dark(r * bytesPerRow + $0 * 4) } }
        func colDark(_ c: Int) -> Bool { (0..<height).allSatisfy { dark($0 * bytesPerRow + c * 4) } }
        func pair(_ length: Int, _ isDark: (Int) -> Bool) -> (Int, Int) {
            var a = 0; while a < length, isDark(a) { a += 1 }
            guard a < length else { return (0, 0) }   // all black: no picture to frame
            var b = 0; while b < length, isDark(length - 1 - b) { b += 1 }
            // ponytail: ±2 px symmetry at 48×27; widen if captures grow.
            guard a > 0, b > 0, abs(a - b) <= 2, Double(a + b) <= Double(length) * 0.45 else { return (0, 0) }
            return (a, b)
        }
        let (t, bo) = pair(height, rowDark)
        let (l, r) = pair(width, colDark)
        return Bars(top: t, bottom: bo, left: l, right: r)
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
        edge: Edge = .whole, depth: Double = 0.25, bars: Bars = .none
    ) -> [WizRGB] {
        guard width > 0, height > 0, count > 0 else { return [] }
        let bins = 36
        // The picture inside any black bars.
        let pictureRows = min(bars.top, height - 1)..<max(min(bars.top, height - 1) + 1, height - bars.bottom)
        let pictureCols = min(bars.left, width - 1)..<max(min(bars.left, width - 1) + 1, width - bars.right)
        let zones = (0..<count).map { zone -> WizRGB in
            // Zone 0 is the lightbar's base: the bottom rows, or the left columns.
            // Across the bar, only the chosen edge of the picture is read.
            var rows = [pictureRows], cols = [pictureCols]
            switch orientation {
            case .vertical:
                rows = [band(zone, of: pictureRows, count: count, fromEnd: true)]
                cols = edgeSlices(pictureCols, edge: edge, depth: depth)
            case .horizontal:
                cols = [band(zone, of: pictureCols, count: count, fromEnd: false)]
                rows = edgeSlices(pictureRows, edge: edge, depth: depth)
            }
            var histogram = [Double](repeating: 0, count: bins)
            var satSum = [Double](repeating: 0, count: bins)
            var valSum = [Double](repeating: 0, count: bins)
            var valMax = [Double](repeating: 0, count: bins)
            var hueSum = [Double](repeating: 0, count: bins)
            var binCount = [Int](repeating: 0, count: bins)
            var pixels = 0, colourful = 0
            var valueTotal = 0.0
            for row in rows.joined() {
                for col in cols.joined() {
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

    /// Slice `zone` of `count` along `span`, never empty.
    private static func band(_ zone: Int, of span: Range<Int>, count: Int, fromEnd: Bool) -> Range<Int> {
        let length = span.count
        let lo = min(length - 1, zone * length / count)
        let hi = min(length, max(lo + 1, (zone + 1) * length / count))
        let local = fromEnd ? (length - hi)..<(length - lo) : lo..<hi
        return (span.lowerBound + local.lowerBound)..<(span.lowerBound + local.upperBound)
    }

    /// The part of `span` an edge reads: all of it, `depth` of it at one end, or both ends.
    static func edgeSlices(_ span: Range<Int>, edge: Edge, depth: Double) -> [Range<Int>] {
        let k = max(1, min(span.count, Int((Double(span.count) * depth).rounded())))
        let first = span.lowerBound..<(span.lowerBound + k), second = (span.upperBound - k)..<span.upperBound
        switch edge {
        case .whole: return [span]
        case .first: return [first]
        case .second: return [second]
        case .both: return first.upperBound >= second.lowerBound ? [span] : [first, second]
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

/// Black bars change only after the same bars show for `frames` frames in a
/// row (half a second at 20 fps), so a dark scene can't make the bar jump.
public struct BarsTracker: Sendable {
    public private(set) var current = LampGradient.Bars.none
    private var candidate = LampGradient.Bars.none
    private var streak = 0
    public var frames = 10

    public init() {}

    public mutating func next(_ seen: LampGradient.Bars) -> LampGradient.Bars {
        if seen == current { streak = 0; return current }
        if seen == candidate { streak += 1 } else { candidate = seen; streak = 1 }
        if streak >= frames { current = seen; streak = 0 }
        return current
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

// MARK: - Bulb sides, colour boost, day white

public extension LampGradient {
    /// Where a plain WiZ bulb stands around the screen. It shows that edge's
    /// colour during screen sync; `whole` keeps the lightbar's average.
    enum Side: String, CaseIterable, Sendable, Identifiable {
        case whole, left, right, top, bottom
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .whole: return "Whole screen"
            case .left: return "Left of screen"
            case .right: return "Right of screen"
            case .top: return "Above screen"
            case .bottom: return "Below screen"
            }
        }
    }
    /// `[mac: Side]` for plain bulbs.
    static let sidesDefaultsKey = "wizLightSides"

    static func side(for mac: String) -> Side {
        let stored = UserDefaults.standard.dictionary(forKey: sidesDefaultsKey) as? [String: String]
        return stored?[mac].flatMap(Side.init) ?? .whole
    }

    static func setSide(_ side: Side, for mac: String) {
        var stored = UserDefaults.standard.dictionary(forKey: sidesDefaultsKey) as? [String: String] ?? [:]
        stored[mac] = side == .whole ? nil : side.rawValue
        UserDefaults.standard.set(stored, forKey: sidesDefaultsKey)
    }

    /// One colour per edge of the picture (left, right, top, bottom), read
    /// the same way as a lightbar zone at that edge.
    static func sideColours(
        bgra: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int,
        depth: Double = 0.25, bars: Bars = .none, followBrightness: Bool = true
    ) -> [Side: WizRGB] {
        let reads: [(Side, Orientation, Edge)] = [
            (.left, .vertical, .first), (.right, .vertical, .second),
            (.top, .horizontal, .first), (.bottom, .horizontal, .second),
        ]
        var out: [Side: WizRGB] = [:]
        for (side, orientation, edge) in reads {
            out[side] = screenZones(bgra: bgra, width: width, height: height, bytesPerRow: bytesPerRow, count: 1,
                                    orientation: orientation, followBrightness: followBrightness,
                                    edge: edge, depth: depth, bars: bars).first ?? .off
        }
        return out
    }

    /// 0 (screen colours as they are) … 1 (much more vivid).
    static let colourBoostDefaultsKey = "lightbarColourBoost"
    static var colourBoost: Double {
        let v = UserDefaults.standard.double(forKey: colourBoostDefaultsKey)
        return v.isFinite ? max(0, min(1, v)) : 0
    }

    /// Pushes saturation toward full and keeps hue and peak brightness. Greys
    /// and near-whites are left alone, so white light doesn't pick up a tint.
    static func boosted(_ zones: [WizRGB], by amount: Double) -> [WizRGB] {
        let a = max(0, min(1, amount.isFinite ? amount : 0))
        guard a > 0 else { return zones }
        return zones.map { c in
            let hi = max(c.r, c.g, c.b), lo = min(c.r, c.g, c.b)
            guard hi > 0 else { return c }
            let s = Double(hi - lo) / Double(hi)
            guard s > 0.1 else { return c }
            let k = (1 - pow(1 - s, 1 + 2 * a)) / s
            func channel(_ v: Int) -> Int { Int((Double(hi) - Double(hi - v) * k).rounded()) }
            return WizRGB(r: channel(c.r), g: channel(c.g), b: channel(c.b))
        }
    }

    /// Lightbar shows day-cycle white instead of the strip's colour.
    static let dayWhiteDefaultsKey = "lightbarDayWhite"
    static var dayWhiteEnabled: Bool { UserDefaults.standard.bool(forKey: dayWhiteDefaultsKey) }

    /// Cool white at midday, warm amber in the evening and at night (2700–6500 K).
    static func dayWhite(at date: Date = .now) -> (hue: Double, saturation: Double) {
        let (h, s) = ColorMath.kelvinToHS(2700 + 3800 * ColorMath.circadianCCTValue(for: date))
        return (h, s)
    }

    /// Lightbar (and other WiZ lights) go dark while the Mac sleeps, locks,
    /// or shows the screensaver, and come back after.
    static let offWhenAwayDefaultsKey = "lightbarOffWhenAway"
    static var offWhenAway: Bool {
        UserDefaults.standard.object(forKey: offWhenAwayDefaultsKey) as? Bool ?? true
    }
}

/// A white flash that runs up the lightbar from the base on each beat, over
/// the music frame. Pure function of time, like the effects.
public struct BeatFlash: Sendable {
    public static let defaultsKey = "lightbarBeatFlash"
    public static var enabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    /// Seconds for a flash to cross the bar.
    public var duration = 0.45
    /// Beats closer than this don't start another flash.
    public var minGap = 0.15
    private var starts: [Double] = []

    public init() {}

    public mutating func beat(at time: Double) {
        if let last = starts.last, time - last < minGap { return }
        starts = Array((starts + [time]).suffix(3))
    }

    public mutating func apply(_ frame: [WizRGB], at time: Double) -> [WizRGB] {
        starts.removeAll { time - $0 > duration }
        guard !starts.isEmpty, !frame.isEmpty else { return frame }
        let n = Double(frame.count)
        let tail = max(1.5, n / 5)
        return frame.enumerated().map { i, c in
            let glow = starts.map { start -> Double in
                let t = (time - start) / duration
                let behind = t * (n + tail) - Double(i)
                guard behind >= 0, behind < tail else { return 0 }
                return (1 - behind / tail) * (1 - t * 0.5)
            }.max() ?? 0
            guard glow > 0 else { return c }
            func mix(_ v: Int) -> Int { Int((Double(v) + (255 - Double(v)) * glow).rounded()) }
            return WizRGB(r: mix(c.r), g: mix(c.g), b: mix(c.b))
        }
    }
}
