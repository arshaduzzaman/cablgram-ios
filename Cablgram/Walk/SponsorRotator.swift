import SwiftUI

/// The big "steps to go" number, taking turns with a sponsor message:
/// steps for 20 seconds, then "Sponsored by bKash" for 7, and so on.
struct StepsOrSponsor: View {
    let remaining: Int

    /// How long each side stays up.
    private let stepsSeconds: Double = 20
    private let sponsorSeconds: Double = 7

    @State private var showSponsor = false

    var body: some View {
        ZStack(alignment: .leading) {
            if showSponsor {
                sponsor
                    .transition(slide)
            } else {
                steps
                    .transition(slide)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .clipped()
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(showSponsor ? sponsorSeconds : stepsSeconds))
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.6)) { showSponsor.toggle() }
            }
        }
    }

    private var steps: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(remaining.formatted())
                .font(.system(size: 46, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(remaining)))
                .animation(.smooth(duration: 0.8), value: remaining)
            Text("steps to go")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var sponsor: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Sponsored by")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            BkashLogo(height: 42)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sponsored by bKash")
    }

    /// Slides up into place and out the top, fading as it goes.
    private var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity))
    }
}

/// bKash's logo from Cablgram/Sponsors/bkash-logo.png (or .jpg/.pdf-free
/// image formats). Until that file is added, a "bKash" wordmark in their pink.
struct BkashLogo: View {
    var height: CGFloat

    private static let image: UIImage? = {
        for ext in ["png", "jpg", "jpeg", "webp", "heic"] {
            let url = Bundle.main.url(forResource: "bkash-logo", withExtension: ext)
                ?? Bundle.main.url(forResource: "bkash-logo", withExtension: ext, subdirectory: "Sponsors")
            if let url, let image = UIImage(contentsOfFile: url.path) { return image }
        }
        return nil
    }()

    var body: some View {
        if let image = Self.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(height: height)
        } else {
            Text("bKash")
                .font(.system(size: height * 0.9, weight: .heavy))
                .tracking(-0.5)
                .foregroundStyle(Color(red: 0.886, green: 0.075, blue: 0.431)) // bKash pink #E2136E
        }
    }
}
