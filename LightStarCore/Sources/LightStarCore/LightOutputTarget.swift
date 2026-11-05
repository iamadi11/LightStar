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

    public var sendsToStrip: Bool { includes(.strip) }
    public var sendsToMiLamp: Bool { includes(.lamp) }
    public var sendsToLightbar: Bool { includes(.lightbar) }
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

    /// The lights "All" drives. The user can leave some out; never none.
    public static let allLightsDefaultsKey = "allOutputLights"
    public static let allChoices: [LightOutputTarget] = [.strip, .lamp, .lightbar]

    public static var allLights: Set<LightOutputTarget> {
        allLights(from: UserDefaults.standard.stringArray(forKey: allLightsDefaultsKey))
    }

    public static func allLights(from raw: [String]?) -> Set<LightOutputTarget> {
        let chosen = Set((raw ?? []).compactMap(LightOutputTarget.init).filter { $0 != .both })
        return chosen.isEmpty ? Set(allChoices) : chosen
    }

    private func includes(_ light: LightOutputTarget) -> Bool {
        self == light || (self == .both && Self.allLights.contains(light))
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

    /// Lightbar link as the phone shows it while it isn't following.
    public static func lightbarStatus(_ phase: String) -> String {
        switch phase {
        case "searching": return "Looking for the lightbar…"
        case "notFound": return "No lightbar on this network"
        case "blocked": return "Allow Local Network for LightStar on the Mac"
        case "stopped": return "Lightbar is off in LightStar on the Mac"
        default: return "Lightbar"
        }
    }
}
