#if os(macOS)
import Foundation

enum MacTrackpadPreferences {
    static func current() -> MacTrackpadPrefs {
        let domain = "com.apple.AppleMultitouchTrackpad" as CFString
        let clicking = intPref("Clicking", domain) == 1
        let rightClick = intPref("TrackpadRightClick", domain) == 1
        let threeFinger = intPref("TrackpadThreeFingerDrag", domain) == 1
        let horizSwipe = intPref("TrackpadThreeFingerHorizSwipeGesture", domain)
        let vertSwipe = intPref("TrackpadThreeFingerVertSwipeGesture", domain)

        let natural = globalFlag("com.apple.swipescrolldirection", default: true)
        let scaling = globalNumber("com.apple.trackpad.scaling", default: 1.0)
        let doubleClick = globalNumber("com.apple.mouse.doubleClickThreshold", default: 0.5)

        return MacTrackpadPrefs(
            tapToClick: clicking,
            twoFingerSecondaryClick: rightClick,
            threeFingerDrag: threeFinger,
            naturalScrolling: natural,
            pointerSpeed: min(3.0, max(0.0, scaling)),
            doubleClickThreshold: min(0.9, max(0.2, doubleClick)),
            threeFingerHorizSwipe: horizSwipe != 0,
            threeFingerVertSwipe: vertSwipe != 0
        )
    }

    private static func intPref(_ key: String, _ domain: CFString) -> Int {
        guard let value = CFPreferencesCopyAppValue(key as CFString, domain) else { return 0 }
        return (value as? NSNumber)?.intValue ?? 0
    }

    private static func globalFlag(_ key: String, default fallback: Bool) -> Bool {
        guard let value = globalValue(key) else { return fallback }
        if let number = value as? NSNumber { return number.intValue != 0 }
        if let flag = value as? Bool { return flag }
        return fallback
    }

    private static func globalNumber(_ key: String, default fallback: Double) -> Double {
        guard let value = globalValue(key) as? NSNumber else { return fallback }
        return value.doubleValue
    }

    private static func globalValue(_ key: String) -> Any? {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key]
    }
}
#endif
