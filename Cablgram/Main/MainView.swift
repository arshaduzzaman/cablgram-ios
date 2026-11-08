import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case news, walk, menu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .news: "News"
        case .walk: "Walk"
        case .menu: "Menu"
        }
    }

    var icon: String {
        switch self {
        case .news: "house"
        case .walk: "figure.walk"
        case .menu: "line.3.horizontal"
        }
    }

    var selectedIcon: String {
        switch self {
        case .news: "house.fill"
        case .walk: "figure.walk"
        case .menu: "line.3.horizontal"
        }
    }
}

/// Facebook-style shell: "cablgram" bar at the top, an icon tab strip
/// under it, and the selected page below.
struct MainView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var steps: StepStore
    @EnvironmentObject private var leaderboard: LeaderboardStore
    @State private var tab: AppTab = .news

    var body: some View {
        VStack(spacing: 0) {
            TopBar(onProfile: { tab = .menu })
            TabStrip(selection: $tab)
            Divider()

            // All pages stay alive so switching tabs keeps scroll position and map state.
            ZStack {
                NewsView(openWalk: { tab = .walk })
                    .opacity(tab == .news ? 1 : 0)
                    .allowsHitTesting(tab == .news)
                WalkHub()
                    .opacity(tab == .walk ? 1 : 0)
                    .allowsHitTesting(tab == .walk)
                MenuView()
                    .opacity(tab == .menu ? 1 : 0)
                    .allowsHitTesting(tab == .menu)
            }
        }
        .background(Color(.systemGroupedBackground))
        .task { await steps.start() }
        .task(id: auth.user?.uid) {
            if auth.user != nil {
                leaderboard.startListening()
                leaderboard.upload(totalSteps: steps.totalSteps, todaySteps: steps.stepsToday)
            } else {
                leaderboard.stopListening()
            }
        }
        .onChange(of: steps.totalSteps) { _, _ in
            leaderboard.upload(totalSteps: steps.totalSteps, todaySteps: steps.stepsToday)
        }
        .onChange(of: steps.stepsToday) { _, _ in
            leaderboard.upload(totalSteps: steps.totalSteps, todaySteps: steps.stepsToday)
        }
    }
}

/// "cablgram" wordmark on the left, profile photo on the right.
private struct TopBar: View {
    @EnvironmentObject private var auth: AuthStore
    let onProfile: () -> Void

    var body: some View {
        HStack {
            Text("cablgram")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(.brandGradient)
            Spacer()
            Button(action: onProfile) {
                Avatar(url: auth.user?.photoURL, name: auth.displayName, size: 36)
            }
            .accessibilityLabel("Your profile")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(Color(.systemBackground))
    }
}

/// Row of tab icons with a sliding underline, like Facebook's tab bar.
private struct TabStrip: View {
    @Binding var selection: AppTab
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                let isSelected = tab == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = tab }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: isSelected ? tab.selectedIcon : tab.icon)
                            .font(.system(size: 21, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.brand : .secondary)
                            .frame(height: 26)
                        ZStack {
                            Capsule().fill(.clear).frame(height: 3)
                            if isSelected {
                                Capsule()
                                    .fill(.brandGradient)
                                    .frame(height: 3)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.top, 4)
        .background(Color(.systemBackground))
    }
}

/// Round profile photo, or the first letter of the name.
struct Avatar: View {
    let url: URL?
    let name: String
    var size: CGFloat = 40

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.brandGradient)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
