import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case news, walk, friends, discover, menu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .news: "News"
        case .walk: "Walk"
        case .friends: "Messages"
        case .discover: "Discover"
        case .menu: "Menu"
        }
    }

    var icon: String {
        switch self {
        case .news: "house"
        case .walk: "figure.walk"
        case .friends: "person.2"
        case .discover: "ticket"
        case .menu: "line.3.horizontal"
        }
    }

    /// The dock's own drawn icon for this tab.
    var dockIcon: DockIcon.Kind {
        switch self {
        case .news, .menu: .home
        case .walk: .walk
        case .friends: .people
        case .discover: .ticket
        }
    }

    var selectedIcon: String {
        switch self {
        case .news: "house.fill"
        case .walk: "figure.walk"
        case .friends: "person.2.fill"
        case .discover: "ticket.fill"
        case .menu: "line.3.horizontal"
        }
    }
}

/// The shell: a hot-pink bar with the white "cablgram" wordmark on top, the
/// pages side by side (swipe left and right to move between them, like
/// Instagram), and a floating, rounded pink dock at the bottom.
struct MainView: View {
    @State private var tab: AppTab = .news
    @Environment(\.scenePhase) private var scenePhase
    /// The page mostly on screen while you swipe, so the dock follows your
    /// finger instead of waiting for the swipe to settle.
    @State private var showing: AppTab = .news
    /// Held, not watched: when the dock shrinks only the dock redraws, not
    /// every page.
    @State private var dock = DockState()
    /// Friends and the eggs on them, shared by every page (avatars show splats).
    @StateObject private var friends = FriendsStore()
    @State private var eggs = EggStore()
    /// Conversations with friends (the Messages tab).
    @State private var inbox = InboxStore()


    var body: some View {
        // The pages run all the way to the bottom of the screen and the dock
        // floats on top, so the feed scrolls under the glass like Instagram.
        ZStack(alignment: .bottom) {
            TabView(selection: $tab) {
                NewsView(openWalk: {
                    withAnimation(.snappy) { tab = .walk }
                })
                .tracksPage(.news, showing: $showing)
                .tag(AppTab.news)
                WalkPage()
                    .tracksPage(.walk, showing: $showing)
                    .tag(AppTab.walk)
                DiscoverView()
                    .tracksPage(.discover, showing: $showing)
                    .tag(AppTab.discover)
                MenuView()
                    .tracksPage(.menu, showing: $showing)
                    .tag(AppTab.menu)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Room at the end of every page so the last item clears the dock.
            .contentMargins(.bottom, 92, for: .scrollContent)
            .ignoresSafeArea(.all, edges: .bottom)

            Dock(selection: $tab, showing: showing, dock: dock)
        }

        .environment(\.dockState, dock)
        // Ask to allow notifications once you're in, then location; open the tab a tapped
        // notification points to.
        .task {
            await Push.requestPermission()
            LocationTracker.shared.requestPermission()
        }
        // Record the walk route only while the Walk tab is on screen and the app is open.
        .onChange(of: tab == .walk && scenePhase == .active, initial: true) { _, walking in
            LocationTracker.shared.setRecording(walking)
        }
        .onReceive(PushRouter.shared.$openTab) { target in
            guard let target else { return }
            if target == .friends { inbox.open() } else { withAnimation(.snappy) { tab = target } }
            PushRouter.shared.openTab = nil
        }
        .onReceive(PushRouter.shared.$openChat) { uid in
            guard let uid else { return }
            inbox.open(uid)
            PushRouter.shared.openChat = nil
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 1.5) {
                Text("cablgram")
                    .font(.wordmark(28))
                    .tracking(-0.8)
                // A perfectly round dot, like the logo (the font's own
                // full stop is squarish).
                Circle()
                    .frame(width: 6.5, height: 6.5)
                    .alignmentGuide(.lastTextBaseline) { d in d[.bottom] }
                    .accessibilityHidden(true)
                Spacer()
                MessagesButton()
                    .alignmentGuide(.lastTextBaseline) { d in d[VerticalAlignment.center] + 8 }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 10)
            .background(Color.brand.ignoresSafeArea(edges: .top))
        }
        // Messages slides in over the whole screen (the pink bar too) from the right, like
        // Instagram's DMs: its own header shows who you're talking to. Pink stays behind the
        // clock so the white status bar stays readable.
        .overlay {
            if inbox.isOpen {
                MessagesView()
                    .background(Color(.systemBackground).ignoresSafeArea(edges: .bottom))
                    .background(alignment: .top) {
                        Color.brand.frame(height: 0).ignoresSafeArea(edges: .top)
                    }
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .animation(.snappy(duration: 0.32), value: inbox.isOpen)
        .onChange(of: tab) { _, new in
            if showing != new { showing = new }
        }
        .onChange(of: showing) { _, _ in
            Haptics.select()
            dock.setCompact(false)
        }
        // Step and leaderboard syncing lives in its own invisible view, so
        // new step counts don't redraw every page.
        .background(StepSync())
        .background(FriendsSync())
        .environmentObject(friends)
        .environment(eggs)
        .environment(inbox)
    }
}

/// The floating tab dock, like Instagram's: a Liquid Glass bar with
/// a soft grey pill sliding behind the selected tab, dark outline icons
/// (the selected one filled, in pink), and your profile photo last.
private struct Dock: View {
    @Binding var selection: AppTab
    /// The page on screen right now (follows a swipe as it happens).
    var showing: AppTab
    @EnvironmentObject private var auth: AuthStore
    @Environment(InboxStore.self) private var inbox: InboxStore?
    @EnvironmentObject private var friends: FriendsStore
    @ObservedObject var dock: DockState
    @Namespace private var pill

    /// Unread messages plus friend requests waiting for you.
    private var messagesBadge: Int {
        (inbox?.unreadTotal ?? 0) + friends.requests.count
    }

    /// The dock never hides now that Messages opens over it.
    private var hidden: Bool { false }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases.filter { $0 != .friends }) { tab in
                let isSelected = tab == showing
                Button {
                    guard selection != tab || showing != tab else { return }
                    withAnimation(.snappy(duration: 0.3)) { selection = tab }
                } label: {
                    ZStack {
                        if isSelected {
                            Capsule()
                                .fill(Color.black.opacity(0.07))
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                        icon(for: tab, selected: isSelected)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: dock.compact ? 42 : 52)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab == .menu ? "Your profile" : tab.title)
                .accessibilityValue(tab == .friends && messagesBadge > 0 ? "\(messagesBadge) new" : "")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(dock.compact ? 4 : 6)
        .modifier(GlassDock())
        // Smaller and narrower while scrolling, like Instagram's.
        .padding(.horizontal, dock.compact ? 64 : 22)
        // Sits low, close to the bottom edge; slides away inside a chat.
        .offset(y: hidden ? 140 : 16)
        .opacity(hidden ? 0 : 1)
        .allowsHitTesting(!hidden)
        .accessibilityHidden(hidden)
        .animation(.snappy(duration: 0.3), value: showing)
        .animation(.snappy(duration: 0.3), value: hidden)
    }

    @ViewBuilder
    private func icon(for tab: AppTab, selected: Bool) -> some View {
        if tab == .menu {
            Avatar(url: auth.user?.photoURL, name: auth.displayName, size: 28)
                .padding(2)
                .overlay(Circle().stroke(selected ? Color.brand : Color.clear, lineWidth: 1.5))
                .scaleEffect(dock.compact ? 0.84 : 1)
        } else {
            DockIcon(kind: tab.dockIcon, selected: selected,
                     color: selected ? Color.brand : .black, size: 26)
                .overlay(alignment: .topTrailing) {
                    if tab == .friends {
                        UnreadBadge(count: messagesBadge)
                            .offset(x: 9, y: -6)
                            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: messagesBadge)
                    }
                }
                .scaleEffect((selected ? 1.06 : 1) * (dock.compact ? 0.84 : 1))
        }
    }
}

/// The dock's glass, like Instagram's: Apple's Liquid Glass on iOS 26+,
/// and before that a frosted bar with a thin bright edge and soft shadow.
private struct GlassDock: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // Liquid Glass with a light white tint, like Instagram's: what
            // scrolls behind stays visible but softened, so the icons stay
            // readable.
            content
                .glassEffect(.regular.tint(.white.opacity(0.24)).interactive(), in: Capsule())
                .environment(\.colorScheme, .light)
        } else {
            content
                .background {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().fill(.white.opacity(0.22)))
                }
                .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1))
                .overlay(Capsule().strokeBorder(.black.opacity(0.06), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.10), radius: 20, y: 8)
                .environment(\.colorScheme, .light)
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

private extension View {
    /// Marks `page` as showing once more than half of it is on screen.
    func tracksPage(_ page: AppTab, showing: Binding<AppTab>) -> some View {
        onGeometryChange(for: Bool.self) { proxy in
            let frame = proxy.frame(in: .global)
            return abs(frame.minX) < frame.width / 2
        } action: { onScreen in
            if onScreen, showing.wrappedValue != page { showing.wrappedValue = page }
        }
    }
}

/// Keeps steps and the leaderboard in sync: starts step counting, uploads
/// this phone's Health days when they change (the server then recalculates
/// your totals), and adopts steps spent on other devices.
private struct StepSync: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var steps: StepStore
    @EnvironmentObject private var leaderboard: LeaderboardStore

    var body: some View {
        Color.clear
        .task { await steps.start() }
        .task(id: auth.user?.uid) {
            steps.setUser(auth.user?.uid)
            if auth.user != nil {
                leaderboard.startListening()
                sync()
            } else {
                leaderboard.stopListening()
                showYourSteps()
            }
        }
        .onChange(of: steps.stepsSinceJoining) { _, _ in sync() }
        .onChange(of: steps.localWeek) { _, _ in sync() }
        .onChange(of: steps.dailySteps) { _, _ in sync() }
        .onChange(of: steps.spentSteps) { _, _ in sync() }
        .onChange(of: steps.goalReward?.id) { _, _ in sync() }
        .onChange(of: steps.hasLoaded) { _, _ in sync() }
        .onChange(of: steps.totalSteps) { _, _ in showYourSteps() }
        .onChange(of: steps.stepsThisWeek) { _, _ in showYourSteps() }
        .onChange(of: leaderboard.entries) { _, entries in
            if let mine = entries.first(where: { $0.id == auth.user?.uid }) {
                steps.adoptSpentSteps(mine.spentSteps)
            }
        }
    }

    /// Uploads (when anything changed) and refreshes your own leaderboard row.
    private func sync() {
        leaderboard.upload(steps)
        showYourSteps()
    }

    private func showYourSteps() {
        leaderboard.showYourSteps(uid: auth.user?.uid, total: steps.totalSteps, week: steps.stepsThisWeek)
    }
}

/// Top-right of the pink bar: opens Messages (friends and chats), with a badge for unread
/// messages plus friend requests, like Instagram's messages button.
private struct MessagesButton: View {
    @Environment(InboxStore.self) private var inbox
    @EnvironmentObject private var friends: FriendsStore

    var body: some View {
        let count = inbox.unreadTotal + friends.requests.count
        Button {
            Haptics.tap()
            inbox.open()
        } label: {
            DockIcon(kind: .people, selected: false, color: .white, size: 26)
                .frame(width: 40, height: 36)
                .overlay(alignment: .topTrailing) {
                    UnreadBadge(count: count)
                        .overlay(Capsule().stroke(Color.brand, lineWidth: 1.5))
                        .offset(x: 4, y: -2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: count)
        .accessibilityLabel(count > 0 ? "Messages, \(count) new" : "Messages")
    }
}
