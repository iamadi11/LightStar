import UIKit

@MainActor
enum RemoteHaptics {
    private static let lightImpact: UIImpactFeedbackGenerator = {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        return gen
    }()
    
    private static let softImpact: UIImpactFeedbackGenerator = {
        let gen = UIImpactFeedbackGenerator(style: .soft)
        gen.prepare()
        return gen
    }()
    
    private static let selection: UISelectionFeedbackGenerator = {
        let gen = UISelectionFeedbackGenerator()
        gen.prepare()
        return gen
    }()
    
    private static let notification: UINotificationFeedbackGenerator = {
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        return gen
    }()

    static func click(enabled: Bool = true) {
        guard enabled else { return }
        lightImpact.impactOccurred(intensity: 0.85)
        lightImpact.prepare()
    }

    static func select(enabled: Bool = true) {
        guard enabled else { return }
        selection.selectionChanged()
        selection.prepare()
    }

    static func success(enabled: Bool = true) {
        guard enabled else { return }
        notification.notificationOccurred(.success)
        notification.prepare()
    }

    static func warning(enabled: Bool = true) {
        guard enabled else { return }
        notification.notificationOccurred(.warning)
        notification.prepare()
    }

    static func soft(enabled: Bool = true) {
        guard enabled else { return }
        softImpact.impactOccurred(intensity: 0.7)
        softImpact.prepare()
    }
}
