import Foundation

/// How the lightbar tunes screen sync for the app in front. Every profile
/// keeps the screen gradient; none replaces it with a single colour.
public enum LightbarProfile: String, CaseIterable, Sendable, Identifiable {
    /// The user's own lightbar settings.
    case normal
    /// Films: black bars always skipped.
    case video
    /// Games: whole screen, no easing, so hits and flashes land at once.
    case game

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .normal: return "Normal"
        case .video: return "Video"
        case .game: return "Game"
        }
    }

    public static let enabledDefaultsKey = "lightbarAppProfiles"
    /// `[bundleID: profile]` the user picked; anything else is detected.
    public static let overridesDefaultsKey = "lightbarAppProfileOverrides"
    /// Profile in use now, written while screen sync runs.
    public static let activeDefaultsKey = "lightbarActiveProfile"
    /// Apps seen in front lately, newest first, for the Settings list.
    public static let recentDefaultsKey = "lightbarRecentApps"

    public static var enabled: Bool { UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true }

    public static var active: LightbarProfile {
        guard enabled else { return .normal }
        return UserDefaults.standard.string(forKey: activeDefaultsKey).flatMap(LightbarProfile.init) ?? .normal
    }

    public static var overrides: [String: LightbarProfile] {
        let raw = UserDefaults.standard.dictionary(forKey: overridesDefaultsKey) as? [String: String] ?? [:]
        return raw.compactMapValues(LightbarProfile.init)
    }

    public static func setOverride(_ profile: LightbarProfile?, for bundleID: String) {
        var raw = UserDefaults.standard.dictionary(forKey: overridesDefaultsKey) as? [String: String] ?? [:]
        raw[bundleID] = profile?.rawValue
        UserDefaults.standard.set(raw, forKey: overridesDefaultsKey)
    }

    static let videoApps: Set<String> = [
        "com.apple.TV", "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.colliderli.iina",
        "io.mpv", "com.firecore.infuse", "tv.plex.desktop", "com.netflix.Netflix",
    ]
    /// Built-in guess from the bundle ID and the app's declared category
    /// (`LSApplicationCategoryType`). Browsers stay normal: they play films
    /// and show pages alike.
    public static func detect(bundleID: String, category: String?) -> LightbarProfile {
        let category = category ?? ""
        if videoApps.contains(bundleID) || category == "public.app-category.video" { return .video }
        if category.hasSuffix("games") { return .game }
        return .normal
    }

    public static func resolve(bundleID: String, category: String?, overrides: [String: LightbarProfile]) -> LightbarProfile {
        overrides[bundleID] ?? detect(bundleID: bundleID, category: category)
    }

    /// Newest first, no repeats, at most `limit`.
    public static func remember(_ bundleID: String, in recent: [String], limit: Int = 10) -> [String] {
        Array(([bundleID] + recent.filter { $0 != bundleID }).prefix(limit))
    }
}
