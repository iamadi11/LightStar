import Foundation
import CoreGraphics

/// Screen sync can follow the display the user is working on: the one that
/// holds most of the frontmost app's window. Not the mouse pointer, which
/// drifts to the other screen while a film plays.
public enum FocusedDisplay {
    public static let followDefaultsKey = "syncFollowsFocusedDisplay"
    /// On unless the user switched it off: with two screens, sync should follow the one in use.
    public static var follows: Bool { UserDefaults.standard.object(forKey: followDefaultsKey) as? Bool ?? true }

    /// The display covering most of `window`; nil when it's on none of them.
    public static func display(for window: CGRect, displays: [(id: CGDirectDisplayID, frame: CGRect)]) -> CGDirectDisplayID? {
        var best: CGDirectDisplayID?
        var bestArea: CGFloat = 0
        for display in displays {
            let overlap = display.frame.intersection(window)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea { best = display.id; bestArea = area }
        }
        return best
    }
}

/// Switches only after the same display has held focus for `hold` seconds,
/// so a quick click on the other screen doesn't restart capture.
public struct FocusDebouncer: Sendable {
    public var hold: TimeInterval
    private var candidate: CGDirectDisplayID?
    private var since: TimeInterval = 0

    public init(hold: TimeInterval = 1.5) { self.hold = hold }

    /// The display to switch to now, if any.
    public mutating func next(_ seen: CGDirectDisplayID?, current: CGDirectDisplayID?, now: TimeInterval) -> CGDirectDisplayID? {
        guard let seen, seen != current else { candidate = nil; return nil }
        if seen != candidate { candidate = seen; since = now; return nil }
        guard now - since >= hold else { return nil }
        candidate = nil
        return seen
    }
}
