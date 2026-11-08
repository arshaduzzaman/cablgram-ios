import UIKit

/// Haptic feedback used across the app. Respects the "Haptics" switch in Menu.
@MainActor
enum Haptics {
    static let enabledKey = "haptics.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private static let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private static let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private static let softImpact = UIImpactFeedbackGenerator(style: .soft)
    private static let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    /// Ordinary button tap.
    static func tap() {
        guard isEnabled else { return }
        lightImpact.impactOccurred()
    }

    /// A firmer tap, for adding steps or starting something.
    static func press() {
        guard isEnabled else { return }
        mediumImpact.impactOccurred()
    }

    /// Gentle bump, for panels opening, closing or refreshing.
    static func soft() {
        guard isEnabled else { return }
        softImpact.impactOccurred()
    }

    /// Picking between options: tabs, chips, steppers, cards.
    static func select() {
        guard isEnabled else { return }
        selection.selectionChanged()
    }

    static func success() {
        guard isEnabled else { return }
        notification.notificationOccurred(.success)
    }

    static func warning() {
        guard isEnabled else { return }
        notification.notificationOccurred(.warning)
    }

    static func error() {
        guard isEnabled else { return }
        notification.notificationOccurred(.error)
    }

    /// A success buzz followed by two quick taps, for claiming a reward.
    static func celebrate() {
        guard isEnabled else { return }
        notification.notificationOccurred(.success)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            rigidImpact.impactOccurred(intensity: 1.0)
            try? await Task.sleep(for: .milliseconds(110))
            rigidImpact.impactOccurred(intensity: 0.7)
        }
    }
}
