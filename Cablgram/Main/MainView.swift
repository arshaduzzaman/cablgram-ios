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

/// Facebook-style shell: a hot-pink bar with the white "cablgram" wordmark
/// and the tab icons, and the selected page below.
struct MainView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var steps: StepStore
    @EnvironmentObject private var leaderboard: LeaderboardStore
    @State private var tab: AppTab = .news

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                TopBar(onProfile: {
                    Haptics.tap()
                    tab = .menu
                })
                TabStrip(selection: $tab)
            }
            .background(Color.brand.ignoresSafeArea(edges: .top))
            .environment(\.colorScheme, .dark)

            // All pages stay alive so switching tabs keeps scroll position and map state.
            ZStack {
                NewsView(openWalk: {
                    Haptics.select()
                    tab = .walk
                })
                    .opacity(tab == .news ? 1 : 0)
                    .allowsHitTesting(tab == .news)
                WalkPage(isVisible: tab == .walk)
                    .opacity(tab == .walk ? 1 : 0)
                    .allowsHitTesting(tab == .walk)
                MenuView()
                    .opacity(tab == .menu ? 1 : 0)
                    .allowsHitTesting(tab == .menu)
            }
        }
        .background(Color(.systemBackground))
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

/// "cablgram" in white Helvetica on the left, profile photo on the right.
private struct TopBar: View {
    @EnvironmentObject private var auth: AuthStore
    let onProfile: () -> Void

    var body: some View {
        HStack {
            Text("cablgram")
                .font(.wordmark(28))
                .tracking(-0.8)
                .foregroundStyle(.white)
            Spacer()
            Button(action: onProfile) {
                Avatar(url: auth.user?.photoURL, name: auth.displayName, size: 32)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
            }
            .accessibilityLabel("Your profile")
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }
}

/// Tab icons in white with a thin sliding underline, like Facebook's.
private struct TabStrip: View {
    @Binding var selection: AppTab
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                let isSelected = tab == selection
                Button {
                    if selection != tab { Haptics.select() }
                    withAnimation(.snappy(duration: 0.25)) { selection = tab }
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: isSelected ? tab.selectedIcon : tab.icon)
                            .font(.system(size: 20, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(isSelected ? 1 : 0.65))
                            .frame(height: 24)
                        ZStack {
                            Rectangle().fill(.clear).frame(height: 2)
                            if isSelected {
                                Rectangle()
                                    .fill(.white)
                                    .frame(height: 2)
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
    }
}

/// Round profile photo, or the first letter of the name on pink.
struct Avatar: View {
    let url: URL?
    let name: String
    var size: CGFloat = 40

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text(String(name.prefix(1)).uppercased())
                .font(.custom("Helvetica-Bold", size: size * 0.45))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.brand)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
