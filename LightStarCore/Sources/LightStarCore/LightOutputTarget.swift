import Foundation

/// Which lights the power, colour, and brightness controls drive.
public enum LightOutputTarget: String, CaseIterable, Sendable, Identifiable {
    case strip
    /// The Mi bedside lamp (Yeelight / HomeKit).
    case lamp
    /// The WiZ gradient lightbar on Wi-Fi.
    case lightbar
    /// Every light. Raw value kept from when there were two.
    case both

    public var id: String { rawValue }
    public static let defaultsKey = "lightOutputTarget"

    public var sendsToStrip: Bool { self == .strip || self == .both }
    public var sendsToMiLamp: Bool { self == .lamp || self == .both }
    public var sendsToLightbar: Bool { self == .lightbar || self == .both }
    /// Any Wi-Fi lamp: the mirror path runs.
    public var sendsToLamp: Bool { sendsToMiLamp || sendsToLightbar }

    public var title: String {
        switch self {
        case .strip: return "LED strip"
        case .lamp: return "Mi lamp"
        case .lightbar: return "Lightbar"
        case .both: return "All"
        }
    }

    public static var stored: LightOutputTarget {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let value = LightOutputTarget(rawValue: raw) {
            return value
        }
        let mirror = UserDefaults.standard.object(forKey: "yeelightMirrorEnabled") as? Bool ?? false
        return mirror ? .both : .strip
    }
}

/// Phone lights tab: the strip must be connected before it can take power.
/// The lamp can be switched as soon as it is the chosen target.
public enum RemoteLightControls {
    public static func target(from raw: String?) -> LightOutputTarget {
        guard let raw, let value = LightOutputTarget(rawValue: raw) else { return .strip }
        return value
    }

    public static func canPower(target: LightOutputTarget, stripConnected: Bool) -> Bool {
        if target == .strip { return stripConnected }
        return true
    }

    public static func canAdjust(target: LightOutputTarget, stripConnected: Bool, isOn: Bool) -> Bool {
        isOn && canPower(target: target, stripConnected: stripConnected)
    }

    public static func powerDetail(target: LightOutputTarget) -> String {
        switch target {
        case .strip: return "Turns the LED strip on and off."
        case .lamp: return "Turns the Mi lamp on and off."
        case .lightbar: return "Turns the lightbar on and off."
        case .both: return "Turns every light on and off together."
        }
    }

    public static func lampStatus(phase: String?, detail: String?) -> String {
        switch phase {
        case "following":
            return "\(detail ?? "Mi lamp") · Connected"
        case "searching":
            return "Looking for the lamp…"
        case "pairing":
            return "Connecting to the lamp…"
        case "needsCode":
            return "Enter the 8-digit code on the lamp base"
        case "failed":
            return detail ?? "The lamp didn’t connect"
        default:
            return "Lamp"
        }
    }
}
