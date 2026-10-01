import Foundation

/// Which lights the power, colour, and brightness controls drive.
public enum LightOutputTarget: String, CaseIterable, Sendable, Identifiable {
    case strip
    case lamp
    case both

    public var id: String { rawValue }
    public static let defaultsKey = "lightOutputTarget"

    public var sendsToStrip: Bool { self != .lamp }
    public var sendsToLamp: Bool { self != .strip }

    public var title: String {
        switch self {
        case .strip: return "LED strip"
        case .lamp: return "Mi lamp"
        case .both: return "Both"
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
