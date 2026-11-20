import SwiftUI
import UIKit

/// A compact top row for the Messages screens, in place of the system navigation bar (whose
/// big floating buttons looked out of place under the app's pink header): an optional back
/// chevron, then the content, left-aligned like Instagram.
struct InboxHeader<Content: View, Trailing: View>: View {
    var back: (() -> Void)?
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            if let back {
                Button {
                    Haptics.tap()
                    back()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            content
            Spacer(minLength: 8)
            trailing
        }
        .padding(.leading, back == nil ? 16 : 6)
        .padding(.trailing, 12)
        .frame(minHeight: 52)
        .background(Color(.systemBackground))
    }
}

extension InboxHeader where Trailing == EmptyView {
    init(back: (() -> Void)?, @ViewBuilder content: () -> Content) {
        self.back = back
        self.content = content()
        self.trailing = EmptyView()
    }
}

/// Keeps the swipe-from-the-edge back gesture working on screens that hide the system bar.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
