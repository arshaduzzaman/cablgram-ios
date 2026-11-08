import SwiftUI

extension Color {
    /// Cablgram pink (#FF2684), from the asset catalog.
    static let brand = Color("Brand")
    /// Warm orange the brand gradient fades into.
    static let brandOrange = Color(red: 1.0, green: 0.45, blue: 0.27)
}

extension ShapeStyle where Self == LinearGradient {
    /// Pink-to-orange gradient used for highlights.
    static var brandGradient: LinearGradient {
        LinearGradient(colors: [.brand, .brandOrange], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension View {
    /// Rounded card on the grouped background.
    func card(cornerRadius: CGFloat = 22) -> some View {
        background(Color(.secondarySystemGroupedBackground),
                   in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }
}

/// Thin rounded progress bar filled with the brand gradient.
struct GradientProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(.brandGradient)
                    .frame(width: max(6, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

/// Big screen title with a small line above it.
struct ScreenHeader: View {
    let eyebrow: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(eyebrow)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(title)
                .font(.system(size: 32, weight: .heavy, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}
