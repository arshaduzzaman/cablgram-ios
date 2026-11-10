import SwiftUI

/// A brand paying for a spot on the walking page.
///
/// Two kinds of spot:
/// - **Challenge** (one at a time): a big card under your steps. The brand
///   sets a weekly step target and an offer you unlock by hitting it.
/// - **Offer**: a card in the "Partner offers" row further down.
///
/// Empty spots show an invite for brands to sponsor them instead.
struct Sponsor: Identifiable, Hashable {
    enum Spot: Hashable { case challenge, offer }

    let id: String
    let spot: Spot
    /// Brand name, e.g. "Stride".
    let name: String
    /// The big line, e.g. "20% off running shoes".
    let offer: String
    /// One short line under it.
    let detail: String
    /// For a challenge: steps to walk this week to unlock the offer.
    var weeklySteps: Int? = nil
    /// The card's colours, top-left to bottom-right (hex, e.g. "FF2684").
    let colors: [String]
    /// SF Symbol drawn big in the corner.
    let symbol: String
    /// Where "Get offer" goes.
    let link: URL?
    /// Made-up brands to preview the spots in test builds.
    var sample: Bool = false

    /// Where brands get in touch to sponsor a spot.
    static let contactURL = URL(string: "mailto:sponsors@cablgram.com?subject=Sponsor%20a%20spot%20on%20Cablgram")

    /// Edit this list to sell the spots. Samples only show in test builds.
    static let all: [Sponsor] = [
        Sponsor(id: "sample-stride", spot: .challenge, name: "Stride",
                offer: "20% off running shoes",
                detail: "Walk 20,000 steps this week to unlock it.",
                weeklySteps: 20_000, colors: ["FF2684", "FF7A45"], symbol: "shoe.2.fill",
                link: nil, sample: true),
        Sponsor(id: "sample-fresh", spot: .offer, name: "Fresh Press",
                offer: "Free juice after 5k", detail: "Any outlet in Dhaka",
                colors: ["22C55E", "0EA5A4"], symbol: "cup.and.saucer.fill",
                link: nil, sample: true),
        Sponsor(id: "sample-tide", spot: .offer, name: "Tide Water",
                offer: "Buy 1 get 1 bottle", detail: "Stay cool on your walk",
                colors: ["3B82F6", "6366F1"], symbol: "drop.fill",
                link: nil, sample: true),
    ]

    static var live: [Sponsor] {
        #if DEBUG
        all
        #else
        all.filter { !$0.sample }
        #endif
    }

    static var challenge: Sponsor? { live.first { $0.spot == .challenge } }
    static var offers: [Sponsor] { live.filter { $0.spot == .offer } }

    var gradient: LinearGradient {
        LinearGradient(colors: colors.map(Color.init(hex:)), startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

// MARK: - "Sponsored" tag

/// Small frosted "Sponsored" label for a card's corner.
private struct SponsoredTag: View {
    var body: some View {
        Text("SPONSORED")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.22), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
    }
}

/// Soft glossy circles and the brand's symbol, drawn behind a card's text.
private struct CardDecoration: View {
    let symbol: String
    var symbolSize: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.14))
                .frame(width: symbolSize * 2.4)
                .offset(x: symbolSize * 1.1, y: -symbolSize * 0.9)
            Circle()
                .fill(.white.opacity(0.08))
                .frame(width: symbolSize * 1.6)
                .offset(x: symbolSize * 1.5, y: symbolSize * 0.7)
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .bold))
                .foregroundStyle(.white.opacity(0.28))
                .rotationEffect(.degrees(-14))
                .offset(x: symbolSize * 0.55, y: -symbolSize * 0.3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .allowsHitTesting(false)
    }
}

// MARK: - Challenge spot

/// The big sponsored challenge card: brand, offer, your progress this week
/// towards it, and a button that unlocks when you get there.
struct SponsorChallengeCard: View {
    let sponsor: Sponsor
    let weekSteps: Int
    var onOpen: () -> Void = {}

    private var target: Int { sponsor.weeklySteps ?? 0 }
    private var fraction: Double { target > 0 ? min(Double(weekSteps) / Double(target), 1) : 1 }
    private var unlocked: Bool { fraction >= 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(sponsor.name.uppercased())
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(1.2)
                Spacer()
                SponsoredTag()
            }

            Text("WEEKLY CHALLENGE")
                .padding(.top, 28)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .opacity(0.8)
            Text(sponsor.offer)
                .font(.system(size: 26, weight: .heavy))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.top, 2)
            Text(sponsor.detail)
                .font(.subheadline.weight(.medium))
                .opacity(0.9)
                .padding(.top, 4)

            if target > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.25))
                            Capsule().fill(.white)
                                .frame(width: max(8, geo.size.width * fraction))
                        }
                    }
                    .frame(height: 8)
                    HStack {
                        Text("\(weekSteps.formatted()) / \(target.formatted()) steps")
                            .font(.footnote.weight(.semibold).monospacedDigit())
                        Spacer()
                        Text(unlocked ? "Unlocked" : "\(Int(fraction * 100))%")
                            .font(.footnote.weight(.bold).monospacedDigit())
                    }
                }
                .padding(.top, 16)
            }

            Button {
                Haptics.tap()
                onOpen()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: unlocked ? "gift.fill" : "lock.fill")
                        .font(.footnote.weight(.bold))
                    Text(unlocked ? "Get offer" : "Keep walking to unlock")
                        .font(.subheadline.weight(.bold))
                }
                .foregroundStyle(unlocked ? Color(hex: sponsor.colors[0]) : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(unlocked ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.2)), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!unlocked)
            .padding(.top, 16)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                sponsor.gradient
                CardDecoration(symbol: sponsor.symbol, symbolSize: 92)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color(hex: sponsor.colors[0]).opacity(0.35), radius: 16, y: 8)
    }
}

// MARK: - Offer spots

/// A partner offer in the horizontal row.
struct SponsorOfferCard: View {
    let sponsor: Sponsor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: sponsor.symbol)
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Spacer()
                SponsoredTag()
            }
            Spacer(minLength: 12)
            Text(sponsor.name)
                .font(.caption.weight(.heavy))
                .tracking(0.6)
                .textCase(.uppercase)
                .opacity(0.85)
            Text(sponsor.offer)
                .font(.system(size: 18, weight: .heavy))
                .lineLimit(2)
                .padding(.top, 2)
            Text(sponsor.detail)
                .font(.footnote.weight(.medium))
                .opacity(0.85)
                .lineLimit(1)
                .padding(.top, 2)
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: 230, height: 168, alignment: .topLeading)
        .background {
            ZStack {
                sponsor.gradient
                CardDecoration(symbol: sponsor.symbol, symbolSize: 56)
                    .opacity(0.6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// An empty spot: invites brands to sponsor it.
struct SponsorInviteCard: View {
    var wide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.brand)
                .frame(width: 38, height: 38)
                .background(Color.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            Spacer(minLength: 12)
            Text("Your brand here")
                .font(.system(size: 18, weight: .heavy))
            Text(wide ? "Put your offer in front of people walking across Dhaka every day."
                      : "Reach walkers across Dhaka.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.top, 2)
            HStack(spacing: 4) {
                Text("Sponsor this spot")
                Image(systemName: "arrow.right")
            }
            .font(.footnote.weight(.bold))
            .foregroundStyle(Color.brand)
            .padding(.top, 8)
        }
        .padding(14)
        .frame(width: wide ? nil : 230, height: wide ? 170 : 168, alignment: .topLeading)
        .frame(maxWidth: wide ? .infinity : nil, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: wide ? 24 : 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: wide ? 24 : 20, style: .continuous)
                .strokeBorder(Color.brand.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        }
    }
}

/// The "Partner offers" section: a swipeable row of offers, ending with an
/// invite to sponsor one.
struct SponsorOffersRow: View {
    let offers: [Sponsor]
    var onOpen: (Sponsor) -> Void = { _ in }
    var onInvite: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Partner offers")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(offers) { sponsor in
                        Button {
                            Haptics.tap()
                            onOpen(sponsor)
                        } label: {
                            SponsorOfferCard(sponsor: sponsor)
                        }
                        .buttonStyle(CardPress())
                    }
                    Button {
                        Haptics.tap()
                        onInvite()
                    } label: {
                        SponsorInviteCard()
                    }
                    .buttonStyle(CardPress())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .padding(.horizontal, -16)
            .scrollClipDisabled()
        }
    }
}

/// Cards sink a little under your finger.
private struct CardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
