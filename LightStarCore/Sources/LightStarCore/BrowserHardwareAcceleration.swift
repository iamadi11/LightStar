import Foundation

/// When the strip is on and Screen/Both is running, Chromium can be switched to
/// software rendering (Widevine L3) so ScreenCaptureKit sees the video.
/// Safari/FairPlay cannot. Chrome must fully quit before Local State is written
/// or its shutdown will overwrite the file.
public enum BrowserHardwareAccelerationPolicy: Sendable {
    /// Keep software rendering for the rest of the Screen session once applied,
    /// even after frames become capturable — otherwise we would relaunch in a loop.
    public static func shouldDisable(
        isOn: Bool,
        isSyncingVideo: Bool,
        alreadyAppliedThisSession: Bool,
        protectedContentDetected: Bool,
        playbackIsNetflixOrPrime: Bool
    ) -> Bool {
        guard isOn, isSyncingVideo else { return false }
        if alreadyAppliedThisSession { return true }
        return protectedContentDetected && playbackIsNetflixOrPrime
    }

    /// Netflix and Prime Video only. Other DRM (Disney+, native apps) and
    /// ordinary black frames must not quit the browser.
    public static func isNetflixOrPrime(url: String?, title: String?) -> Bool {
        if let url, isNetflixOrPrimeURL(url) { return true }
        if let title, isNetflixOrPrimeTitle(title) { return true }
        return false
    }

    public static func isNetflixOrPrimeURL(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw), let host = components.host?.lowercased() else {
            return false
        }
        if host == "netflix.com" || host.hasSuffix(".netflix.com") { return true }
        if host == "primevideo.com" || host.hasSuffix(".primevideo.com") { return true }
        let labels = host.split(separator: ".")
        guard labels.contains("amazon") else { return false }
        let path = components.path.lowercased()
        return path.contains("/gp/video") || path.hasPrefix("/video")
    }

    public static func isNetflixOrPrimeTitle(_ raw: String) -> Bool {
        let title = raw.lowercased()
        if title.contains("netflix") { return true }
        if title.contains("prime video") { return true }
        return false
    }

    /// Quit/relaunch at most once per Screen session. Reconcile is called on
    /// every DRM banner rewrite (frontmost app changes while Chrome is quitting).
    public static func shouldPerformDisableRelaunch(
        wantDisabled: Bool,
        alreadyAppliedThisSession: Bool,
        disableInFlight: Bool
    ) -> Bool {
        wantDisabled && !alreadyAppliedThisSession && !disableInFlight
    }

    public static func applicationSupportSubdirectory(bundleID: String) -> String? {
        switch bundleID {
        case "com.google.Chrome": return "Google/Chrome"
        case "com.google.Chrome.beta": return "Google/Chrome Beta"
        case "com.google.Chrome.canary": return "Google/Chrome Canary"
        case "com.google.Chrome.dev": return "Google/Chrome Dev"
        case "com.microsoft.edgemac": return "Microsoft Edge"
        case "com.brave.Browser": return "BraveSoftware/Brave-Browser"
        case "org.chromium.Chromium": return "Chromium"
        default: return nil
        }
    }

    public static func canAutoToggle(bundleID: String) -> Bool {
        applicationSupportSubdirectory(bundleID: bundleID) != nil
    }

    public static func localStateURL(applicationSupport: URL, bundleID: String) -> URL? {
        guard let sub = applicationSupportSubdirectory(bundleID: bundleID) else { return nil }
        return applicationSupport
            .appendingPathComponent(sub, isDirectory: true)
            .appendingPathComponent("Local State")
    }

    public static func preferredBundleID(
        detectedBundleID: String?,
        runningBundleIDs: [String]
    ) -> String? {
        if let detectedBundleID, canAutoToggle(bundleID: detectedBundleID) {
            return detectedBundleID
        }
        let order = [
            "com.google.Chrome",
            "com.google.Chrome.beta",
            "com.google.Chrome.canary",
            "com.microsoft.edgemac",
            "com.brave.Browser",
            "org.chromium.Chromium"
        ]
        return order.first { runningBundleIDs.contains($0) }
    }

    /// Chromium ignores Apple window-resume; this flag reopens Last Session/Tabs.
    public static let restoreSessionLaunchArguments = [
        "--restore-last-session",
        "--disable-session-crashed-bubble"
    ]
}

public enum ChromiumLocalState: Sendable {
    public static func hardwareAccelerationEnabled(_ json: [String: Any]) -> Bool {
        if let nested = json["hardware_acceleration_mode"] as? [String: Any],
           let enabled = nested["enabled"] as? Bool {
            return enabled
        }
        if let enabled = json["hardware_acceleration_mode_enabled"] as? Bool {
            return enabled
        }
        return true
    }

    public static func settingHardwareAcceleration(_ json: [String: Any], enabled: Bool) -> [String: Any] {
        var out = json
        var nested = out["hardware_acceleration_mode"] as? [String: Any] ?? [:]
        nested["enabled"] = enabled
        out["hardware_acceleration_mode"] = nested
        out["hardware_acceleration_mode_enabled"] = enabled
        return out
    }

    public static func parse(_ data: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let json = obj as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return json
    }

    public static func serialize(_ json: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    /// In-place boolean replace so we do not rewrite the whole Local State blob
    /// (full JSONSerialization round-trip can drop session/profile fields).
    public static func patchingHardwareAcceleration(_ jsonUTF8: String, enabled: Bool) -> String? {
        let replacement = enabled ? "true" : "false"
        let patterns = [
            "(\"hardware_acceleration_mode\"\\s*:\\s*\\{[^\\}]*\"enabled\"\\s*:\\s*)(true|false)",
            "(\"hardware_acceleration_mode_enabled\"\\s*:\\s*)(true|false)"
        ]
        var out = jsonUTF8
        var changed = false
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(out.startIndex..., in: out)
            if re.firstMatch(in: out, options: [], range: range) != nil {
                out = re.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "$1\(replacement)")
                changed = true
            }
        }
        return changed ? out : nil
    }
}
