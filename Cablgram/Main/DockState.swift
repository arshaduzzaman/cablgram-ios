import SwiftUI

/// Whether the dock is shrunk. Scrolling down any page shrinks it (more
/// room for the content, like Instagram); scrolling back up, reaching the
/// top, or changing tab brings it back to full size.
@MainActor
final class DockState: ObservableObject {
    @Published var compact = false

    func setCompact(_ value: Bool) {
        guard value != compact else { return }
        withAnimation(.smooth(duration: 0.35)) { compact = value }
    }
}

/// Hands pages the dock without making them redraw when it changes (only
/// the dock itself watches it).
private struct DockStateKey: EnvironmentKey {
    @MainActor static let defaultValue = DockState()
}

extension EnvironmentValues {
    var dockState: DockState {
        get { self[DockStateKey.self] }
        set { self[DockStateKey.self] = newValue }
    }
}

/// Watches a page's scrolling and shrinks or grows the dock to match.
private struct CollapsesDock: ViewModifier {
    @Environment(\.dockState) private var dock

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { old, new in
                // Near the top the dock is always full size; otherwise follow
                // the direction, ignoring tiny jitters.
                if new < 30 {
                    dock.setCompact(false)
                } else if new - old > 3 {
                    dock.setCompact(true)
                } else if old - new > 3 {
                    dock.setCompact(false)
                }
            }
        } else {
            content
        }
    }
}

extension View {
    /// Shrinks the floating dock while this scroll view scrolls down.
    func collapsesDock() -> some View { modifier(CollapsesDock()) }
}
