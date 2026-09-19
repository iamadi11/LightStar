import UIKit

enum RemoteHaptics {
    static func click(enabled: Bool = true) {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.85)
    }

    static func select(enabled: Bool = true) {
        guard enabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success(enabled: Bool = true) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning(enabled: Bool = true) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func soft(enabled: Bool = true) {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
    }
}
