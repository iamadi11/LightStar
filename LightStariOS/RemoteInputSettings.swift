import Foundation
import SwiftUI
import LightStarCore

@MainActor
final class RemoteInputSettings: ObservableObject {
    @Published var pointerSpeed: Double {
        didSet { UserDefaults.standard.set(pointerSpeed, forKey: Keys.pointerSpeed) }
    }
    @Published var accelerationEnabled: Bool {
        didSet { UserDefaults.standard.set(accelerationEnabled, forKey: Keys.acceleration) }
    }
    @Published var naturalScrolling: Bool {
        didSet { UserDefaults.standard.set(naturalScrolling, forKey: Keys.naturalScrolling) }
    }
    @Published var tapToClick: Bool {
        didSet { UserDefaults.standard.set(tapToClick, forKey: Keys.tapToClick) }
    }
    @Published var twoFingerSecondaryClick: Bool {
        didSet { UserDefaults.standard.set(twoFingerSecondaryClick, forKey: Keys.twoFingerClick) }
    }
    @Published var threeFingerDrag: Bool {
        didSet { UserDefaults.standard.set(threeFingerDrag, forKey: Keys.threeFingerDrag) }
    }
    @Published var threeFingerHorizSwipe: Bool {
        didSet { UserDefaults.standard.set(threeFingerHorizSwipe, forKey: Keys.threeFingerHorizSwipe) }
    }
    @Published var threeFingerVertSwipe: Bool {
        didSet { UserDefaults.standard.set(threeFingerVertSwipe, forKey: Keys.threeFingerVertSwipe) }
    }
    @Published var hapticClicks: Bool {
        didSet { UserDefaults.standard.set(hapticClicks, forKey: Keys.hapticClicks) }
    }
    @Published var showScrollWheel: Bool {
        didSet { UserDefaults.standard.set(showScrollWheel, forKey: Keys.showScrollWheel) }
    }
    @Published var doubleClickThreshold: Double {
        didSet { UserDefaults.standard.set(doubleClickThreshold, forKey: Keys.doubleClick) }
    }
    @Published var gyroSensitivity: Double {
        didSet { UserDefaults.standard.set(gyroSensitivity, forKey: Keys.gyroSensitivity) }
    }
    @Published private(set) var mirroredFromMac = false

    init() {
        let d = UserDefaults.standard
        pointerSpeed = d.object(forKey: Keys.pointerSpeed) as? Double ?? 1.0
        accelerationEnabled = d.object(forKey: Keys.acceleration) as? Bool ?? true
        naturalScrolling = d.object(forKey: Keys.naturalScrolling) as? Bool ?? true
        tapToClick = d.object(forKey: Keys.tapToClick) as? Bool ?? true
        twoFingerSecondaryClick = d.object(forKey: Keys.twoFingerClick) as? Bool ?? true
        threeFingerDrag = d.object(forKey: Keys.threeFingerDrag) as? Bool ?? false
        threeFingerHorizSwipe = d.object(forKey: Keys.threeFingerHorizSwipe) as? Bool ?? true
        threeFingerVertSwipe = d.object(forKey: Keys.threeFingerVertSwipe) as? Bool ?? true
        hapticClicks = d.object(forKey: Keys.hapticClicks) as? Bool ?? true
        // The first ship wrote `false` on launch, so a missing migration flag
        // means the user never chose to hide the wheel.
        if d.object(forKey: Keys.scrollWheelDefaultedOn) == nil {
            showScrollWheel = true
            d.set(true, forKey: Keys.scrollWheelDefaultedOn)
        } else {
            showScrollWheel = d.object(forKey: Keys.showScrollWheel) as? Bool ?? true
        }
        doubleClickThreshold = d.object(forKey: Keys.doubleClick) as? Double ?? 0.5
        gyroSensitivity = d.object(forKey: Keys.gyroSensitivity) as? Double ?? 1.0
    }

    func applyMacPrefs(_ prefs: MacTrackpadPrefs) {
        // iPhone has no physical click, so a tap is the click analog even if
        // the Mac requires a press. Everything else follows the MacBook pane.
        tapToClick = true
        twoFingerSecondaryClick = prefs.twoFingerSecondaryClick
        threeFingerDrag = prefs.threeFingerDrag
        threeFingerHorizSwipe = prefs.threeFingerHorizSwipe ?? true
        threeFingerVertSwipe = prefs.threeFingerVertSwipe ?? true
        naturalScrolling = prefs.naturalScrolling
        pointerSpeed = prefs.pointerSpeed
        doubleClickThreshold = prefs.doubleClickThreshold
        mirroredFromMac = true
    }

    private enum Keys {
        static let pointerSpeed = "remotePointerSpeed"
        static let acceleration = "remoteAcceleration"
        static let naturalScrolling = "remoteNaturalScrolling"
        static let tapToClick = "remoteTapToClick"
        static let twoFingerClick = "remoteTwoFingerClick"
        static let threeFingerDrag = "remoteThreeFingerDrag"
        static let threeFingerHorizSwipe = "remoteThreeFingerHorizSwipe"
        static let threeFingerVertSwipe = "remoteThreeFingerVertSwipe"
        static let hapticClicks = "remoteHapticClicks"
        static let showScrollWheel = "remoteShowScrollWheel"
        static let scrollWheelDefaultedOn = "remoteScrollWheelDefaultedOn"
        static let doubleClick = "remoteDoubleClickThreshold"
        static let gyroSensitivity = "remoteGyroSensitivity"
    }
}
