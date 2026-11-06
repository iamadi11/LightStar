import Foundation

// The Canvas's ways to play, and the pure rules behind them: symmetry, gravity
// wells, the breathing pacer, the flash limit, hidden discoveries, moods,
// players and saved canvases. No Metal here, so all of it is unit-tested.

/// How the Canvas is played. Raw values `auto` / `interactive` are the
/// original two modes, kept so stored settings and older phones still match.
public enum CanvasMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case auto, interactive, music, tilt, wells, breathe
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .auto: return "Flow"
        case .interactive: return "Stir"
        case .music: return "Music"
        case .tilt: return "Tilt"
        case .wells: return "Wells"
        case .breathe: return "Breathe"
        }
    }
    public var symbol: String {
        switch self {
        case .auto: return "wind"
        case .interactive: return "hand.draw"
        case .music: return "music.note"
        case .tilt: return "iphone.gen3.radiowaves.left.and.right"
        case .wells: return "tornado"
        case .breathe: return "lungs"
        }
    }
    public var summary: String {
        switch self {
        case .auto: return "Flows by itself; stir to join in."
        case .interactive: return "Moves when you stir. Left alone, it slowly carries on in your colours."
        case .music: return "The Mac's sound drives it: bass pushes, beats bloom, pitch picks the colour."
        case .tilt: return "Tilt your iPhone (or press the arrow keys) and the colour pours to the low side. Shake to splash."
        case .wells: return "Click to plant a gravity well, Option-click for a repeller. The liquid orbits them."
        case .breathe: return "Breathe with the room: it swells as you breathe in and settles as you breathe out."
        }
    }
    public static let defaultsKey = "canvasMode"
    public static var stored: CanvasMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(CanvasMode.init) ?? .auto
    }
    /// Emitters move by themselves.
    var runsPilot: Bool { self == .auto || self == .music }
}

// MARK: - Symmetry

/// Kaleidoscope: every stir, tap and well is repeated around the centre.
public enum CanvasSymmetry {
    public static let defaultsKey = "canvasSymmetry"
    public static let choices = [1, 2, 3, 4, 6, 8, 12]
    public static var stored: Int {
        let v = UserDefaults.standard.integer(forKey: defaultsKey)
        return choices.contains(v) ? v : 1
    }
    public static func title(_ folds: Int) -> String { folds <= 1 ? "Off" : "\(folds)×" }

    /// `folds` rotated copies around the centre plus their mirror images
    /// (a real kaleidoscope's mirrors), worked out in square screen space so
    /// a wide canvas doesn't squash them. 2 is a plain left–right mirror.
    public static func expand(_ s: FluidSplat, folds: Int, aspect: Double) -> [FluidSplat] {
        guard folds > 1 else { return [s] }
        let px = (s.x - 0.5) * aspect, py = s.y - 0.5
        if folds == 2 {
            return [s, FluidSplat(x: 1 - s.x, y: s.y, dx: -s.dx, dy: s.dy, color: s.color, radius: s.radius)]
        }
        var out: [FluidSplat] = []
        out.reserveCapacity(folds * 2)
        for k in 0..<folds {
            let a = Double(k) * 2 * .pi / Double(folds)
            for mirror in [false, true] {
                // Mirror across the x axis first, then rotate.
                let (mx, my, mdx, mdy) = mirror ? (px, -py, s.dx, -s.dy) : (px, py, s.dx, s.dy)
                let rx = mx * cos(a) - my * sin(a), ry = mx * sin(a) + my * cos(a)
                let rdx = mdx * cos(a) - mdy * sin(a), rdy = mdx * sin(a) + mdy * cos(a)
                out.append(FluidSplat(x: rx / aspect + 0.5, y: ry + 0.5, dx: rdx, dy: rdy, color: s.color, radius: s.radius))
            }
        }
        return out
    }
}

// MARK: - Gravity wells

/// A point the liquid orbits (attractor) or flees (repeller). Wells drift on
/// small loops and pour a little of their own colour, so a planted well keeps
/// living after you let go.
public struct CanvasWell: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    /// +1 pulls in, -1 pushes away; merged wells grow.
    public var strength: Double
    public var hue: Double
    public var phase: Double
    public init(x: Double, y: Double, strength: Double, hue: Double, phase: Double = 0) {
        self.x = x; self.y = y; self.strength = strength; self.hue = hue; self.phase = phase
    }
}

public struct CanvasWells: Equatable, Sendable {
    public static let maxCount = 6
    public static let mergeDistance = 0.05
    public private(set) var wells: [CanvasWell] = []
    public init(_ wells: [CanvasWell] = []) { self.wells = Array(wells.suffix(Self.maxCount)) }

    /// Oldest goes when full.
    public mutating func plant(_ well: CanvasWell) {
        wells.append(well)
        if wells.count > Self.maxCount { wells.removeFirst(wells.count - Self.maxCount) }
    }

    public mutating func removeNearest(x: Double, y: Double, within r: Double = 0.08) {
        guard let i = wells.indices.min(by: { hypot(wells[$0].x - x, wells[$0].y - y) < hypot(wells[$1].x - x, wells[$1].y - y) }),
              hypot(wells[i].x - x, wells[i].y - y) < r else { return }
        wells.remove(at: i)
    }

    public mutating func clear() { wells.removeAll() }

    /// Slow drift; same-sign wells that meet merge into one stronger well.
    /// Returns where a merge happened (a hidden discovery).
    public mutating func drift(dt: Double, aspect: Double) -> (x: Double, y: Double)? {
        for i in wells.indices {
            wells[i].phase += dt * 0.15
            // Small loops around where it was planted, plus a gentle pull
            // toward other attractors so they find each other over time.
            wells[i].x += cos(wells[i].phase * 1.3) * 0.004 * dt
            wells[i].y += sin(wells[i].phase) * 0.004 * dt
            for j in wells.indices where j != i && wells[j].strength > 0 && wells[i].strength > 0 {
                let dx = (wells[j].x - wells[i].x) * aspect, dy = wells[j].y - wells[i].y
                let d = max(0.02, hypot(dx, dy))
                wells[i].x += dx / d * 0.006 * dt / aspect
                wells[i].y += dy / d * 0.006 * dt
            }
            wells[i].x = min(0.95, max(0.05, wells[i].x))
            wells[i].y = min(0.95, max(0.05, wells[i].y))
        }
        for i in wells.indices {
            for j in wells.indices where j > i && (wells[i].strength > 0) == (wells[j].strength > 0) {
                let dx = (wells[j].x - wells[i].x) * aspect, dy = wells[j].y - wells[i].y
                guard hypot(dx, dy) < Self.mergeDistance else { continue }
                let total = wells[i].strength + wells[j].strength
                let merged = CanvasWell(x: (wells[i].x + wells[j].x) / 2, y: (wells[i].y + wells[j].y) / 2,
                                        strength: total.sign == .minus ? max(-3, total) : min(3, total),
                                        hue: wells[i].hue, phase: wells[i].phase)
                wells.remove(at: j)
                wells[i] = merged
                return (merged.x, merged.y)
            }
        }
        return nil
    }
}

// MARK: - Breathing

/// A slow breathing rhythm: breathe in for 40% of the cycle, out for the rest
/// (longer out-breaths calm). 6 breaths a minute by default.
public struct BreathPacer: Equatable, Sendable {
    public static let defaultsKey = "canvasBreathsPerMinute"
    public var breathsPerMinute: Double
    public init(breathsPerMinute: Double = 6) { self.breathsPerMinute = min(10, max(4, breathsPerMinute)) }
    public var cycle: Double { 60 / breathsPerMinute }
    public var inhaleShare: Double { 0.4 }

    /// 0 (empty) … 1 (full), eased so the turn at the top and bottom is soft.
    public func fullness(at t: Double) -> Double {
        let p = phase(at: t)
        let x = p < inhaleShare ? p / inhaleShare : 1 - (p - inhaleShare) / (1 - inhaleShare)
        return 0.5 - 0.5 * cos(x * .pi)
    }
    public func phase(at t: Double) -> Double {
        let c = (t / cycle).truncatingRemainder(dividingBy: 1)
        return c < 0 ? c + 1 : c
    }
    public func isInhaling(at t: Double) -> Bool { phase(at: t) < inhaleShare }
}

// MARK: - Flash safety

/// The room multiplies any strobe, so big brightness jumps are capped at
/// three a second (WCAG 2.3.1), and saturated red ones at one a second.
public struct FlashLimiter: Sendable {
    public static let minInterval = 1.0 / 3
    public static let redMinInterval = 1.0
    private var last = -Double.infinity
    private var lastRed = -Double.infinity
    public init() {}

    public mutating func allow(at t: Double, hue: Double) -> Bool {
        let red = hue < 0.05 || hue > 0.95
        guard t - last >= Self.minInterval, !red || t - lastRed >= Self.redMinInterval else { return false }
        last = t
        if red { lastRed = t }
        return true
    }
}

// MARK: - Hidden discoveries

/// Things to find by playing, never by waiting or grinding. Each one has an
/// effect every time; the first time it's also collected.
public enum CanvasDiscovery: String, CaseIterable, Identifiable, Sendable, Codable {
    case whirlpool, supernova, twinStars, sparkStorm, rainbowBridge, chorus
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .whirlpool: return "Whirlpool"
        case .supernova: return "Supernova"
        case .twinStars: return "Twin Stars"
        case .sparkStorm: return "Spark Storm"
        case .rainbowBridge: return "Rainbow Bridge"
        case .chorus: return "Chorus"
        }
    }
    /// A nudge shown for ones not yet found; never the full answer.
    public var hint: String {
        switch self {
        case .whirlpool: return "Round and round…"
        case .supernova: return "Press harder and hold."
        case .twinStars: return "Some wells are drawn to each other."
        case .sparkStorm: return "Quick, back and forth."
        case .rainbowBridge: return "All the way across, in one go."
        case .chorus: return "Better with friends."
        }
    }
    public static let defaultsKey = "canvasDiscoveries"
    public static var found: Set<CanvasDiscovery> {
        Set((UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).compactMap(CanvasDiscovery.init))
    }
    /// True the first time.
    @discardableResult
    public static func record(_ d: CanvasDiscovery) -> Bool {
        var f = found
        guard f.insert(d).inserted else { return false }
        UserDefaults.standard.set(f.map(\.rawValue).sorted(), forKey: defaultsKey)
        return true
    }
}

/// Spots the drawn-gesture discoveries in one pointer's path (0…1, y down).
public struct CanvasGestureDetector: Sendable {
    struct Point { var x, y, t: Double }
    private var path: [Point] = []
    private var strokeStart: Point?
    private var strokeMinX = 1.0, strokeMaxX = 0.0
    public init() {}

    /// A new stroke (pointer down / finger lifted).
    public mutating func reset() {
        path.removeAll()
        strokeStart = nil
        strokeMinX = 1; strokeMaxX = 0
    }

    public mutating func add(x: Double, y: Double, t: Double, aspect: Double = 16.0 / 9) -> CanvasDiscovery? {
        let p = Point(x: x, y: y, t: t)
        if strokeStart == nil { strokeStart = p }
        strokeMinX = min(strokeMinX, x); strokeMaxX = max(strokeMaxX, x)
        if let last = path.last, hypot((x - last.x) * aspect, y - last.y) < 0.004 { return nil }
        path.append(p)
        path.removeAll { t - $0.t > 2.0 }

        if let start = strokeStart, strokeMaxX - strokeMinX >= 0.85, t - start.t <= 1.5 {
            strokeMinX = 1; strokeMaxX = 0; strokeStart = p
            return .rainbowBridge
        }
        if reversals(within: 1.2, now: t) >= 6 {
            path.removeAll()
            return .sparkStorm
        }
        if circled(aspect: aspect) {
            path.removeAll()
            return .whirlpool
        }
        return nil
    }

    /// Sideways or up-down direction flips (each leg ≥ 2% of the canvas).
    private func reversals(within window: Double, now: Double) -> Int {
        let pts = path.filter { now - $0.t <= window }
        guard pts.count > 3 else { return 0 }
        var count = 0, lastSign = 0
        var anchor = pts[0]
        for p in pts.dropFirst() {
            let dx = p.x - anchor.x
            guard abs(dx) >= 0.02 else { continue }
            let sign = dx > 0 ? 1 : -1
            if lastSign != 0, sign != lastSign { count += 1 }
            lastSign = sign
            anchor = p
        }
        return count
    }

    /// The path's direction has turned a full circle, and the loop isn't tiny.
    private func circled(aspect: Double) -> Bool {
        guard path.count >= 8 else { return false }
        var turn = 0.0
        var prev: (Double, Double)?
        var minX = 1.0, maxX = 0.0, minY = 1.0, maxY = 0.0
        for i in 1..<path.count {
            let v = ((path[i].x - path[i - 1].x) * aspect, path[i].y - path[i - 1].y)
            if let pv = prev {
                var a = atan2(v.1, v.0) - atan2(pv.1, pv.0)
                if a > .pi { a -= 2 * .pi } else if a < -.pi { a += 2 * .pi }
                turn += a
            }
            prev = v
            minX = min(minX, path[i].x); maxX = max(maxX, path[i].x)
            minY = min(minY, path[i].y); maxY = max(maxY, path[i].y)
        }
        return abs(turn) >= 2 * .pi * 0.92 && (maxX - minX) * aspect >= 0.08 && maxY - minY >= 0.08
    }

    /// Where the last loop was centred.
    public var centre: (x: Double, y: Double)? {
        guard !path.isEmpty else { return nil }
        return (path.map(\.x).reduce(0, +) / Double(path.count), path.map(\.y).reduce(0, +) / Double(path.count))
    }
}

// MARK: - Players (several phones on one canvas)

public enum CanvasPlayer {
    /// The same colour for the same phone on the Mac and on the phone itself.
    public static func hue(for id: String) -> Double {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return Double(h % 3600) / 3600
    }
}

// MARK: - Moods

/// One tap sets the Canvas and the lights up for a moment of the day.
public enum CanvasMood: String, CaseIterable, Identifiable, Sendable, Codable {
    case none, focus, windDown, play, party, listen, ambient
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "None"
        case .focus: return "Focus"
        case .windDown: return "Wind-down"
        case .play: return "Play"
        case .party: return "Party"
        case .listen: return "Listen"
        case .ambient: return "Ambient"
        }
    }
    public var summary: String {
        switch self {
        case .none: return "Your own settings."
        case .focus: return "Slow, soft colour; the room stays a calm white with a hint of the Canvas."
        case .windDown: return "Warm and slow; the room dims over the session, then the lights turn off."
        case .play: return "Everything responds: stir, tap, find what's hidden."
        case .party: return "Follows the music in a kaleidoscope; friends can join from their phones."
        case .listen: return "A slow nebula that moves with your music."
        case .ambient: return "Living décor: northern lights, low and slow."
        }
    }
    public static let defaultsKey = "canvasMood"
    public static let sessionDefaultsKey = "canvasSessionMinutes"
    public static var stored: CanvasMood {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(CanvasMood.init) ?? .none
    }

    public struct Preset: Equatable, Sendable {
        public var mode: CanvasMode
        public var style: CanvasStyle
        public var symmetry: Int
        /// Pace of Auto emitters (×).
        public var pace: Double
        /// Minutes; 0 = no end.
        public var sessionMinutes: Int
    }

    public var preset: Preset? {
        switch self {
        case .none: return nil
        case .focus: return Preset(mode: .auto, style: .aura, symmetry: 1, pace: 0.5, sessionMinutes: 25)
        case .windDown: return Preset(mode: .auto, style: .lava, symmetry: 1, pace: 0.45, sessionMinutes: 30)
        case .play: return Preset(mode: .interactive, style: .liquid, symmetry: 1, pace: 1, sessionMinutes: 0)
        case .party: return Preset(mode: .music, style: .liquid, symmetry: 6, pace: 1, sessionMinutes: 0)
        case .listen: return Preset(mode: .music, style: .nebula, symmetry: 1, pace: 0.8, sessionMinutes: 0)
        case .ambient: return Preset(mode: .auto, style: .aurora, symmetry: 1, pace: 0.5, sessionMinutes: 0)
        }
    }

    public var pace: Double { preset?.pace ?? 1 }
    /// Session length choices for moods that end.
    public var endsByItself: Bool { self == .focus || self == .windDown }

    /// What the lights do at `elapsed` seconds into a session of `minutes`
    /// (0 = no end): brightness (×), share of white, and the white's colour.
    public func lights(elapsed: Double, minutes: Int) -> (gain: Double, white: Double, warm: Bool) {
        let progress = minutes > 0 ? min(1, max(0, elapsed / (Double(minutes) * 60))) : 0
        switch self {
        case .focus: return (0.85, 0.7, false)
        case .windDown:
            // Eases from full to 8% over the session, warming as it goes.
            let eased = progress * progress * (3 - 2 * progress)
            return (1 - 0.92 * eased, 0.25 + 0.35 * eased, true)
        case .ambient: return (0.6, 0, false)
        case .listen: return (0.9, 0, false)
        default: return (1, 0, false)
        }
    }
}

// MARK: - Saved canvases

/// A canvas you kept: its look, how it was played, and its wells. The
/// thumbnail sits beside the list as `<id>.png`.
public struct CanvasScene: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var created: Date
    public var style: CanvasStyle
    public var mode: CanvasMode
    public var symmetry: Int
    public var mood: CanvasMood?
    public var wells: [CanvasWell]
    public init(id: UUID = UUID(), name: String, created: Date = .now, style: CanvasStyle, mode: CanvasMode,
                symmetry: Int, mood: CanvasMood?, wells: [CanvasWell]) {
        self.id = id; self.name = name; self.created = created; self.style = style; self.mode = mode
        self.symmetry = symmetry; self.mood = mood; self.wells = wells
    }
}

extension CanvasStyle: Codable {}

/// Saved canvases on disk: Application Support/LightStar/Canvases.
public enum CanvasSceneStore {
    public static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LightStar/Canvases", isDirectory: true)
    }
    public static var listURL: URL { folder.appendingPathComponent("canvases.json") }

    public static func load(from url: URL = listURL) -> [CanvasScene] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CanvasScene].self, from: data)) ?? []
    }

    public static func save(_ scenes: [CanvasScene], to url: URL = listURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(scenes).write(to: url, options: .atomic)
    }

    public static func thumbnailURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).png") }

    /// "Canvas 3" after "Canvas 1" and "Canvas 2".
    public static func nextName(after scenes: [CanvasScene]) -> String {
        let used = Set(scenes.compactMap { Int($0.name.replacingOccurrences(of: "Canvas ", with: "")) })
        var n = 1
        while used.contains(n) { n += 1 }
        return "Canvas \(n)"
    }
}
