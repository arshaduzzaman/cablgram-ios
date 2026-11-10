import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case news, walk, discover, menu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .news: "News"
        case .walk: "Walk"
        case .discover: "Discover"
        case .menu: "Menu"
        }
    }

    var icon: String {
        switch self {
        case .news: "house"
        case .walk: "figure.walk"
        case .discover: "ticket"
        case .menu: "line.3.horizontal"
        }
    }

    var selectedIcon: String {
        switch self {
        case .news: "house.fill"
        case .walk: "figure.walk"
        case .discover: "ticket.fill"
        case .menu: "line.3.horizontal"
        }
    }
}

/// The shell: a hot-pink bar with the white "cablgram" wordmark on top, the
/// pages side by side (swipe left and right to move between them, like
/// Instagram), and a floating, rounded pink dock at the bottom.
struct MainView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var steps: StepStore
    @EnvironmentObject private var leaderboard: LeaderboardStore
    @State private var tab: AppTab = .news

    var body: some View {
        TabView(selection: $tab) {
            NewsView(openWalk: {
                withAnimation(.snappy) { tab = .walk }
            })
            .tag(AppTab.news)
            WalkPage()
                .tag(AppTab.walk)
            DiscoverView()
                .tag(AppTab.discover)
            MenuView()
                .tag(AppTab.menu)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text("cablgram")
                    .font(.wordmark(28))
                    .tracking(-0.8)
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 10)
            .background(Color.brand.ignoresSafeArea(edges: .top))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Dock(selection: $tab)
        }
        .onChange(of: tab) { _, _ in Haptics.select() }
        .task { await steps.start() }
        .task(id: auth.user?.uid) {
            if auth.user != nil {
                leaderboard.startListening()
                leaderboard.upload(totalSteps: steps.totalSteps, weekSteps: steps.stepsThisWeek, spentSteps: steps.spentSteps)
            } else {
                leaderboard.stopListening()
            }
        }
        .onChange(of: steps.totalSteps) { _, _ in
            leaderboard.upload(totalSteps: steps.totalSteps, weekSteps: steps.stepsThisWeek, spentSteps: steps.spentSteps)
        }
        .onChange(of: steps.stepsThisWeek) { _, _ in
            leaderboard.upload(totalSteps: steps.totalSteps, weekSteps: steps.stepsThisWeek, spentSteps: steps.spentSteps)
        }
        .onChange(of: steps.spentSteps) { _, _ in
            leaderboard.upload(totalSteps: steps.totalSteps, weekSteps: steps.stepsThisWeek, spentSteps: steps.spentSteps)
        }
        .onChange(of: leaderboard.entries) { _, entries in
            if let mine = entries.first(where: { $0.id == auth.user?.uid }) {
                steps.adoptSpentSteps(mine.spentSteps)
            }
        }
    }
}

/// The floating tab dock: a rounded bar of glass (Liquid Glass on iOS 26+,
/// frosted blur before that) with a solid pink pill sliding behind the
/// selected tab, and your profile photo as the last tab.
private struct Dock: View {
    @Binding var selection: AppTab
    @EnvironmentObject private var auth: AuthStore
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                let isSelected = tab == selection
                Button {
                    guard selection != tab else { return }
                    withAnimation(.snappy(duration: 0.3)) { selection = tab }
                } label: {
                    ZStack {
                        if isSelected {
                            Capsule()
                                .fill(Color.brand)
                                .shadow(color: Color.brand.opacity(0.4), radius: 8, y: 3)
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                        icon(for: tab, selected: isSelected)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab == .menu ? "Your profile" : tab.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(6)
        .modifier(GlassDock())
        .padding(.horizontal, 28)
        .padding(.bottom, 2)
        .animation(.snappy(duration: 0.3), value: selection)
    }

    @ViewBuilder
    private func icon(for tab: AppTab, selected: Bool) -> some View {
        if tab == .menu {
            Avatar(url: auth.user?.photoURL, name: auth.displayName, size: 28)
                .overlay(Circle().stroke(selected ? .white : Color.clear, lineWidth: 2))
                .padding(2)
        } else {
            Image(systemName: selected ? tab.selectedIcon : tab.icon)
                .font(.system(size: 21, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.75))
                .symbolEffect(.bounce, value: selected)
        }
    }
}

/// The dock's glass: Apple's Liquid Glass where available, otherwise a
/// frosted material with a thin light edge and a soft shadow.
private struct GlassDock: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.6), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
        }
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
