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
    public func steps(_ colors: [WizRGB], dimming: Int) -> [[Int]]? {
        guard Self.parse(widths) != nil else { return nil }
        let level = max(10, min(100, dimming))
        return widths.enumerated().compactMap { index, width in
            guard width > 0 else { return nil }
            let color = index < colors.count ? colors[index] : .off
            return [0, color.r, color.g, color.b, 0, 0, 0, color.isOff ? 0 : level, 0, 0, 0, 0, width]
        }
    }
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

    public static func color(_ rgb: WizRGB, dimming: Int) -> Data {
        encode("setPilot", ["r": rgb.r, "g": rgb.g, "b": rgb.b, "dimming": dimming])
    }

    public static func scene(_ id: Int, dimming: Int) -> Data {
        encode("setPilot", ["sceneId": id, "dimming": dimming])
    }

    public static func segments(_ colors: [WizRGB], layout: WizSegmentLayout, dimming: Int, mac: String?) -> Data? {
        guard let steps = layout.steps(colors, dimming: dimming) else { return nil }
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
        mac: String?
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
        switch mode {
        case .color(let rgb): data = WizCommand.color(rgb, dimming: dimming)
        case .scene(let id): data = WizCommand.scene(id, dimming: dimming)
        case .segments(let colors): data = WizCommand.segments(colors, layout: layout, dimming: dimming, mac: mac)
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

    public var displayName: String { "WiZ lamp" }
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

    /// Same lamp as last time, otherwise the first reply.
    public static func choose(_ found: [WizDevice], savedMAC: String?) -> WizDevice? {
        if let savedMAC, let match = found.first(where: { $0.mac == savedMAC }) { return match }
        return found.sorted { $0.mac < $1.mac }.first
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
