import SwiftUI

extension Color {
    /// Cablgram hot pink (#FF2684), from the asset catalog. The one accent
    /// colour in the app; everything else is black, white and greys.
    static let brand = Color("Brand")
}

extension Font {
    /// Helvetica Bold, used for the "cablgram" wordmark.
    static func wordmark(_ size: CGFloat) -> Font {
        .custom("Helvetica-Bold", size: size)
    }
}

extension View {
    /// Flat grouped block: light grey fill, no border or shadow.
    func card(cornerRadius: CGFloat = 16) -> some View {
        background(Color(.secondarySystemBackground),
                   in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Hairline under a row, like Threads and Instagram.
    func hairline(leading: CGFloat = 0) -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(.separator).opacity(0.6))
                .frame(height: 1 / 3)
                .padding(.leading, leading)
        }
    }
}

/// Thin pink progress bar.
struct GradientProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.systemFill))
                Capsule()
                    .fill(Color.brand)
                    .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}

/// Section title in plain bold text with an optional pink link.
struct SectionTitle: View {
    let title: String
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            if let actionTitle {
                Button {
                    Haptics.tap()
                    action()
                } label: {
                    Text(actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.brand)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The Cablgram logo: "cabl." stacked over "gram" in tight Helvetica Bold.
struct CablgramLogo: View {
    /// Font size of each line.
    var size: CGFloat
    var color: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: -size * 0.52) {
            Text("cabl.")
            Text("gram")
        }
        .font(.custom("HelveticaNeue-Bold", size: size))
        .tracking(-size * 0.035)
        .foregroundStyle(color)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("cablgram")
    }
}
