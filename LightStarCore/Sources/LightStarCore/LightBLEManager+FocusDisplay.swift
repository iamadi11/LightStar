#if os(macOS)
import AppKit
import CoreGraphics
import os

private let focusLog = Logger(subsystem: "com.adityaraj.LightStar", category: "focus")

extension LightBLEManager {
    /// Checks twice a second while screen sync runs: the lightbar profile for
    /// the app in front, and (with 2+ displays) which screen to capture.
    public func startFollowingFocus() {
        focusTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.focusTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        focusTimer = t
    }

    func focusTick() {
        followLightbarProfile()
        guard FocusedDisplay.follows, isSyncingVideo, availableDisplays.count > 1,
              let window = Self.frontWindowFrame() else { return }
        let displays = availableDisplays.map { (id: $0.id, frame: CGDisplayBounds($0.id)) }
        let seen = FocusedDisplay.display(for: window, displays: displays)
        let current = selectedDisplayID ?? CGMainDisplayID()
        if let next = focusDebouncer.next(seen, current: current, now: CACurrentMediaTime()) {
            focusLog.notice("Following the active screen: display \(next, privacy: .public)")
            selectedDisplayID = next
        }
    }

    /// The app in front picks the lightbar profile while screen sync runs.
    /// Worked out every tick so a changed override applies at once; written
    /// only when it changes, since each write repaints the lightbar.
    func followLightbarProfile() {
        guard isSyncingVideo, LightbarProfile.enabled,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let id = app.bundleIdentifier else { return }
        let d = UserDefaults.standard
        if profileFrontApp?.id != id {
            let category = app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["LSApplicationCategoryType"] as? String }
            profileFrontApp = (id, category)
            let recent = d.stringArray(forKey: LightbarProfile.recentDefaultsKey) ?? []
            if recent.first != id {
                d.set(LightbarProfile.remember(id, in: recent), forKey: LightbarProfile.recentDefaultsKey)
            }
        }
        let profile = LightbarProfile.resolve(bundleID: id, category: profileFrontApp?.category,
                                              overrides: LightbarProfile.overrides)
        guard d.string(forKey: LightbarProfile.activeDefaultsKey) != profile.rawValue else { return }
        focusLog.notice("Lightbar profile \(profile.rawValue, privacy: .public) for \(id, privacy: .public)")
        d.set(profile.rawValue, forKey: LightbarProfile.activeDefaultsKey)
    }

    /// The frontmost app's front window, in global display coordinates.
    /// LightStar's own popover and windowless apps don't count.
    static func frontWindowFrame() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        // Front-to-back order: the first normal window of the app is its front one.
        for w in windows where (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
            && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dict),
                  frame.width > 80, frame.height > 80 else { continue }
            return frame
        }
        return nil
    }
}
#endif
