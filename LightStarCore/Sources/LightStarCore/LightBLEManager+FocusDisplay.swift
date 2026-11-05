#if os(macOS)
import AppKit
import CoreGraphics

extension LightBLEManager {
    /// Checks twice a second; does nothing unless screen sync runs, the
    /// setting is on, and there is more than one display.
    public func startFollowingFocus() {
        focusTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.focusTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        focusTimer = t
    }

    func focusTick() {
        guard FocusedDisplay.follows, isSyncingVideo, availableDisplays.count > 1,
              let window = Self.frontWindowFrame() else { return }
        let displays = availableDisplays.map { (id: $0.id, frame: CGDisplayBounds($0.id)) }
        let seen = FocusedDisplay.display(for: window, displays: displays)
        let current = selectedDisplayID ?? CGMainDisplayID()
        if let next = focusDebouncer.next(seen, current: current, now: CACurrentMediaTime()) {
            selectedDisplayID = next
        }
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
