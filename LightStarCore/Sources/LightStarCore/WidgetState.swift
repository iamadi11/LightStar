import Foundation

public struct WidgetState: Codable, Equatable, Sendable {
    public var connected: Bool
    public var isOn: Bool
    public var hue: Double
    public var saturation: Double
    /// Lightbar status line, when the lightbar is one of the chosen lights.
    /// Optional so state written by older builds still decodes.
    public var lightbar: String?

    public init(connected: Bool = false, isOn: Bool = false, hue: Double = 0.6, saturation: Double = 1.0,
                lightbar: String? = nil) {
        self.connected = connected
        self.isOn = isOn
        self.hue = hue
        self.saturation = saturation
        self.lightbar = lightbar
    }

    public static let appGroupID = "group.com.adityaraj.LightStar"

    public static var storeURL: URL {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("widget-state.json")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("LightStar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("widget-state.json")
    }

    public static func load() -> WidgetState {
        guard let data = try? Data(contentsOf: storeURL),
              let state = try? JSONDecoder().decode(WidgetState.self, from: data)
        else { return WidgetState() }
        return state
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}
