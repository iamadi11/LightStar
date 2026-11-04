import Foundation

/// WiZ (Philips Smart LED "connected by WiZ") local control: compact JSON over
/// UDP 38899, no pairing. Per-segment colour on RGBIC devices goes through an
/// `elm` block written to an empty custom scene slot (256…265). Firmware never
/// reads segment colours back, so what we sent is the only state there is.
/// Wire findings: github.com/TechAntohere/WizScreenSyncController (verified on
/// an RGBIC strip, ESP25_MHORGB_01 fw 1.38.0, and on the Gradient Floor Lamp
/// with the same module: 18 addressable segments, reported as `swHead`).
public struct WizRGB: Equatable, Hashable, Sendable {
    public var r: Int
    public var g: Int
    public var b: Int

    public init(r: Int, g: Int, b: Int) {
        self.r = max(0, min(255, r))
        self.g = max(0, min(255, g))
        self.b = max(0, min(255, b))
    }

    public static let off = WizRGB(r: 0, g: 0, b: 0)
    public var isOff: Bool { r == 0 && g == 0 && b == 0 }

    /// App hue/saturation (0…1, before the strip LUT) at full scale.
    public init(hue: Double, saturation: Double) {
        let value = YeelightFlush.rgbValue(hue: hue, saturation: saturation)
        self.init(r: (value >> 16) & 0xFF, g: (value >> 8) & 0xFF, b: value & 0xFF)
    }
}

public enum WizMode: Equatable, Sendable {
    case color(WizRGB)
    case scene(Int)
    case segments([WizRGB])
    /// Sync colours placed on part of the bar; each light works out the
    /// widths for its own segment count.
    case gradient([WizRGB], placement: LampGradient.Placement)

    /// One colour for a light that can't show segments (a plain WiZ bulb):
    /// the average of the lit zones, as bright as they are.
    public var flattened: WizMode {
        switch self {
        case .segments(let colors), .gradient(let colors, _):
            let lit = colors.filter { !$0.isOff }
            guard !lit.isEmpty else { return .color(.off) }
            func mean(_ v: (WizRGB) -> Int) -> Int { Int((Double(lit.map(v).reduce(0, +)) / Double(lit.count)).rounded()) }
            return .color(WizRGB(r: mean(\.r), g: mean(\.g), b: mean(\.b)))
        case .color, .scene:
            return self
        }
    }
}

/// What the lamp should show. `nil` fields have not been decided yet.
public struct WizPilot: Equatable, Sendable {
    public var power: Bool?
    public var mode: WizMode?
    /// WiZ dimming, 10…100.
    public var dimming: Int?

    public init(power: Bool? = nil, mode: WizMode? = nil, dimming: Int? = nil) {
        self.power = power
        self.mode = mode
        self.dimming = dimming
    }

    public mutating func apply(_ update: YeelightMirrorUpdate) {
        switch update {
        case .power(let on):
            power = on
        case .color(let hue, let saturation):
            mode = .color(WizRGB(hue: hue, saturation: saturation))
        case .brightness(let value):
            dimming = WizCommand.dimming(value)
        }
    }
}

/// Where the lamp's segments sit on the wire. Width is a count of physical
/// segments per step. Gradient lamps report their count in getModelConfig;
/// saved widths are the calibration knob for anything that doesn't.
public struct WizSegmentLayout: Equatable, Sendable {
    public static let defaultsKey = "wizSegmentWidths"
    public static let slotDefaultsKey = "wizSegmentSlot"
    public static let countDefaultsKey = "wizSegmentCount"
    /// Colours the UI offers. Philips sells the floor lamp as "7 colour segments".
    public static let zones = 7
    public static let maxSteps = 12
    public static let slots = 256...265

    public var widths: [Int]
    public var slot: Int

    public init(widths: [Int] = Array(repeating: 1, count: 7), slot: Int = 258) {
        self.widths = widths
        self.slot = slot
    }

    public static var stored: WizSegmentLayout {
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: countDefaultsKey)
        let detected = count > 0 ? even(segments: count, steps: zones) : WizSegmentLayout().widths
        let widths = (defaults.array(forKey: defaultsKey) as? [Int]).flatMap(parse) ?? detected
        let slot = defaults.object(forKey: slotDefaultsKey) as? Int ?? 258
        return WizSegmentLayout(widths: widths, slot: slots.contains(slot) ? slot : 258)
    }

    public func save() {
        UserDefaults.standard.set(widths, forKey: Self.defaultsKey)
        UserDefaults.standard.set(slot, forKey: Self.slotDefaultsKey)
    }

    /// Widths summing to exactly `segments`, as even as integers allow, so the
    /// whole lamp lights. 18 over 7 → [2, 3, 2, 3, 2, 3, 3].
    public static func even(segments: Int, steps: Int) -> [Int] {
        let n = max(1, segments)
        let k = max(1, min(steps, maxSteps, n))
        return (0..<k).map { (($0 + 1) * n) / k - ($0 * n) / k }
    }

    /// "1,1,2,1" → widths. Rejects empty, negative, or more than 12 steps.
    public static func parse(_ text: String) -> [Int]? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count else { return nil }
        return parse(values)
    }

    static func parse(_ values: [Int]) -> [Int]? {
        guard !values.isEmpty, values.count <= maxSteps, values.allSatisfy({ $0 >= 0 }),
              values.contains(where: { $0 > 0 }) else { return nil }
        return values
    }

    /// One step vector per segment: `[0, R, G, B, warm, cold, 0, dimming, 0, 0, 0, 0, width]`.
    /// An off segment is a black step so it goes dark instead of keeping its old colour.
    /// Missing colours are dark; zero-width steps are dropped.
    public func steps(_ colors: [WizRGB], dimming: Int, whiteTone: Double = 1) -> [[Int]]? {
        guard Self.parse(widths) != nil else { return nil }
        return widths.enumerated().compactMap { index, width in
            guard width > 0 else { return nil }
            let c = WizChannels(index < colors.count ? colors[index] : .off, dimming: dimming, whiteTone: whiteTone)
            // Index 4 is warm white, 5 cool white (verified on WiZ RGBIC).
            return [0, c.r, c.g, c.b, c.warm, c.cold, 0, c.dimming, 0, 0, 0, 0, width]
        }
    }
}

/// One colour as a WiZ light wants it. WiZ renders a dark RGB like
/// (30, 30, 30) badly, and white mixed from red + green + blue looks tinted,
/// so: the neutral part of the colour goes to the cool-white LEDs, what's left
/// goes to RGB, both at full scale, and brightness goes in `dimming`. Below
/// the 10% dimming floor the channels themselves are darkened for the rest.
public struct WizChannels: Equatable, Sendable {
    public var r = 0, g = 0, b = 0, warm = 0, cold = 0, dimming = 0

    /// `whiteTone` splits the white part between the warm (0) and cool (1) LEDs.
    public init(_ color: WizRGB, dimming: Int, whiteTone: Double = 1) {
        let peak = max(color.r, color.g, color.b)
        let level = Double(max(0, min(100, dimming))) * Double(peak) / 255
        guard peak >= 4, level >= 1 else { return }
        let scale = (level < 10 ? level / 10 : 1) * 255 / Double(peak)
        // Strong colours stay on RGB alone: a sliver of white (Netflix red is
        // 229, 9, 20) only washes them out. Pastels and greys use the white LEDs.
        let minimum = min(color.r, color.g, color.b)
        let white = minimum * 4 >= peak ? minimum : 0
        func channel(_ v: Int) -> Int { max(0, min(255, Int((Double(v) * scale).rounded()))) }
        r = channel(color.r - white)
        g = channel(color.g - white)
        b = channel(color.b - white)
        let tone = max(0, min(1, whiteTone.isFinite ? whiteTone : 1))
        cold = channel(Int((Double(white) * tone).rounded()))
        warm = channel(Int((Double(white) * (1 - tone)).rounded()))
        self.dimming = max(10, Int(level.rounded()))
    }

    public var isOff: Bool { dimming == 0 }
}

public enum WizCommand {
    public static let port: UInt16 = 38899

    /// WiZ rejects dimming below 10. Power-off is a separate command.
    public static func dimming(_ brightness: Double) -> Int {
        guard brightness.isFinite else { return 10 }
        return max(10, min(100, Int((brightness * 100).rounded())))
    }

    public static func power(_ on: Bool) -> Data {
        encode("setPilot", ["state": on])
    }

    public static func color(_ rgb: WizRGB, dimming: Int, whiteTone: Double = 1) -> Data {
        let c = WizChannels(rgb, dimming: dimming, whiteTone: whiteTone)
        // Black still means "this colour, dimmest": power-off is a separate command.
        guard !c.isOff else { return encode("setPilot", ["r": 0, "g": 0, "b": 0, "c": 0, "w": 0, "dimming": 10]) }
        return encode("setPilot", ["r": c.r, "g": c.g, "b": c.b, "c": c.cold, "w": c.warm, "dimming": c.dimming])
    }

    public static func scene(_ id: Int, dimming: Int) -> Data {
        encode("setPilot", ["sceneId": id, "dimming": dimming])
    }

    public static func segments(_ colors: [WizRGB], layout: WizSegmentLayout, dimming: Int, mac: String?,
                                whiteTone: Double = 1) -> Data? {
        guard let steps = layout.steps(colors, dimming: dimming, whiteTone: whiteTone) else { return nil }
        var params: [String: Any] = [
            "state": true,
            "sceneId": layout.slot,
            "elm": ["modifier": 100, "support": 17, "steps": steps]
        ]
        if let mac { params["mac"] = mac }
        return encode("setPilot", params)
    }

    public static let systemConfig = encode("getSystemConfig", [:])
    public static let modelConfig = encode("getModelConfig", [:])
    public static let pilot = encode("getPilot", [:])

    static func encode(_ method: String, _ params: [String: Any]) -> Data {
        let object: [String: Any] = ["method": method, "params": params]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

public enum WizFlush {
    /// Wire messages that move the lamp from `sent` to `desired`. Colour, scene,
    /// and segments are not sent while the lamp should be off: setPilot with a
    /// colour turns a WiZ light back on.
    public static func messages(
        desired: WizPilot,
        sent: WizPilot,
        layout: WizSegmentLayout,
        mac: String?,
        gradientCapable: Bool = true,
        whiteTone: Double = 1
    ) -> [(Data, WizPilot)] {
        var out: [(Data, WizPilot)] = []
        var next = sent
        if let power = desired.power, power != sent.power {
            next.power = power
            out.append((WizCommand.power(power), next))
        }
        guard desired.power != false, let mode = desired.mode else { return out }
        let dimming = desired.dimming ?? sent.dimming ?? 100
        guard mode != sent.mode || dimming != sent.dimming else { return out }
        let data: Data?
        switch gradientCapable ? mode : mode.flattened {
        case .color(let rgb): data = WizCommand.color(rgb, dimming: dimming, whiteTone: whiteTone)
        case .scene(let id): data = WizCommand.scene(id, dimming: dimming)
        case .segments(let colors):
            data = WizCommand.segments(colors, layout: layout, dimming: dimming, mac: mac, whiteTone: whiteTone)
        case .gradient(let colors, let placement):
            let widths = placement.widths(zones: colors.count, segments: layout.widths.reduce(0, +))
            // Drop zero-width steps (an untrimmed end) before the 12-step check:
            // 12 colours + 2 empty ends would otherwise be refused and nothing sent.
            let steps = zip([.off] + colors + [.off], widths).filter { $0.1 > 0 }
            data = WizCommand.segments(steps.map(\.0), layout: WizSegmentLayout(widths: steps.map(\.1), slot: layout.slot),
                                       dimming: dimming, mac: mac, whiteTone: whiteTone)
        }
        guard let data else { return out }
        next.mode = mode
        next.dimming = dimming
        out.append((data, next))
        return out
    }
}

public struct WizDevice: Equatable, Sendable {
    public var host: String
    public var mac: String
    public var module: String

    public var displayName: String { "Lightbar" }
}

public enum WizDiscovery {
    /// A `getSystemConfig` reply. Anything else on the port is ignored.
    public static func parse(_ data: Data, host: String) -> WizDevice? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["method"] as? String == "getSystemConfig",
              let result = object["result"] as? [String: Any],
              let mac = result["mac"] as? String, !mac.isEmpty else { return nil }
        return WizDevice(host: host, mac: mac, module: result["moduleName"] as? String ?? "")
    }

    /// Addressable segments from a `getModelConfig` reply; nil for non-gradient lights.
    public static func segmentCount(_ data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["method"] as? String == "getModelConfig",
              let result = object["result"] as? [String: Any],
              result["hasGradient"] as? Int == 1,
              let count = result["swHead"] as? Int, count > 0 else { return nil }
        return count
    }

    /// A `getModelConfig` reply: whether the light does gradients, and its
    /// addressable segments if it does. Nil for anything else.
    public static func modelConfig(_ data: Data) -> (gradient: Bool, segments: Int?)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["method"] as? String == "getModelConfig",
              let result = object["result"] as? [String: Any] else { return nil }
        let gradient = result["hasGradient"] as? Int == 1
        let segments = (result["swHead"] as? Int).flatMap { $0 > 0 && gradient ? $0 : nil }
        return (gradient, segments)
    }

    /// Lights LightStar drives. Until the user picks, only the lightbar it has
    /// always used, or the first one found, so other WiZ lights in the house
    /// don't start following the screen.
    public static func enabledLights(found: [String], stored: [String]?, saved: String?) -> Set<String> {
        if let stored { return Set(stored) }
        if let saved { return [saved] }
        return found.sorted().first.map { [$0] } ?? []
    }

    /// Same lamp as last time, otherwise the first reply.
    public static func choose(_ found: [WizDevice], savedMAC: String?) -> WizDevice? {
        if let savedMAC, let match = found.first(where: { $0.mac == savedMAC }) { return match }
        return found.sorted { $0.mac < $1.mac }.first
    }
}

/// UDP never says whether a command landed; the lightbar's reply is the only
/// proof. Checked on every heartbeat while the lightbar is connected.
public enum WizLink {
    public enum Action: Equatable, Sendable { case none, resend, ping, lost }

    /// A command with no reply this long is sent again.
    public static let resendAfter: TimeInterval = 0.5
    /// Quiet this long, ask the lightbar for its state to prove it's there.
    public static let pingAfter: TimeInterval = 3
    /// No reply at all this long: it's gone (unplugged, new IP). Search again.
    public static let lostAfter: TimeInterval = 8

    public static func action(now: Date, lastCommand: Date, lastReply: Date, lastPing: Date) -> Action {
        let silence = now.timeIntervalSince(lastReply)
        if silence > lostAfter { return .lost }
        if lastCommand > lastReply, now.timeIntervalSince(lastCommand) > resendAfter { return .resend }
        if silence > pingAfter, now.timeIntervalSince(lastPing) > 2 { return .ping }
        return .none
    }
}

/// Built-in WiZ scenes (sceneId 1…32), as numbered by the firmware.
public enum WizScene {
    public static let all: [(id: Int, name: String)] = [
        (1, "Ocean"), (2, "Romance"), (3, "Sunset"), (4, "Party"), (5, "Fireplace"),
        (6, "Cozy"), (7, "Forest"), (8, "Pastel Colors"), (9, "Wake Up"), (10, "Bedtime"),
        (11, "Warm White"), (12, "Daylight"), (13, "Cool White"), (14, "Night Light"),
        (15, "Focus"), (16, "Relax"), (17, "True Colors"), (18, "TV Time"),
        (19, "Plant Growth"), (20, "Spring"), (21, "Summer"), (22, "Fall"),
        (23, "Deep Dive"), (24, "Jungle"), (25, "Mojito"), (26, "Club"),
        (27, "Christmas"), (28, "Halloween"), (29, "Candlelight"), (30, "Golden White"),
        (31, "Pulse"), (32, "Steampunk")
    ]
}
