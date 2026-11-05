import Foundation

/// How the lightbar treats screen sync for the app in front.
public enum LightbarProfile: String, CaseIterable, Sendable, Identifiable {
    /// The user's own lightbar settings.
    case normal
    /// Films: black bars always skipped.
    case video
    /// Games: whole screen, no easing, so hits and flashes land at once.
    case game
    /// Coding and terminals: steady day-cycle white instead of dark editor colours.
    case work

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .normal: return "Normal"
        case .video: return "Video"
        case .game: return "Game"
        case .work: return "Work light"
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
    static let workApps: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.Terminal",
        "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.zed.Zed", "com.sublimetext.4",
        "com.mitchellh.ghostty",
    ]

    /// Built-in guess from the bundle ID and the app's declared category
    /// (`LSApplicationCategoryType`). Browsers stay normal: they play films
    /// and show pages alike.
    public static func detect(bundleID: String, category: String?) -> LightbarProfile {
        let category = category ?? ""
        if videoApps.contains(bundleID) || category == "public.app-category.video" { return .video }
        if category.hasSuffix("games") { return .game }
        if workApps.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.")
            || category == "public.app-category.developer-tools" { return .work }
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
