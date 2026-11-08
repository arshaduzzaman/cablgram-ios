import SwiftUI

/// Everything about walking in one tab: steps and rewards, routes, leaderboard.
struct WalkHub: View {
    enum Section: String, CaseIterable, Identifiable {
        case steps = "Rewards"
        case routes = "Routes"
        case leaderboard = "Leaderboard"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .steps: "figure.walk"
            case .routes: "map.fill"
            case .leaderboard: "trophy.fill"
            }
        }
    }

    @State private var section: Section = .steps

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Section.allCases) { item in
                        let isOn = item == section
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { section = item }
                        } label: {
                            Label(item.rawValue, systemImage: item.icon)
                                .font(.subheadline.weight(.semibold))
                                .labelStyle(TightLabelStyle())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .foregroundStyle(isOn ? .white : .primary)
                                .background(isOn ? AnyShapeStyle(.brandGradient) : AnyShapeStyle(Color(.secondarySystemBackground)),
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Color(.systemBackground))

            ZStack {
                WalkView()
                    .opacity(section == .steps ? 1 : 0)
                    .allowsHitTesting(section == .steps)
                RoutesView()
                    .opacity(section == .routes ? 1 : 0)
                    .allowsHitTesting(section == .routes)
                LeaderboardView()
                    .opacity(section == .leaderboard ? 1 : 0)
                    .allowsHitTesting(section == .leaderboard)
            }
        }
    }
}

/// Icon and title with less space between them than the default label.
private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}
