import SwiftUI

/// Everything about walking on one scrolling page: your steps and goal,
/// walk ideas on a map, the leaderboard, and rewards.
struct WalkPage: View {
    /// Whether the Walk tab is on screen. Location is only asked for once it is.
    var isVisible = true

    @EnvironmentObject private var steps: StepStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var leaderboard: LeaderboardStore
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var places = PlacesStore()
    @StateObject private var planner = RoutePlanner()
    @StateObject private var location = LocationTracker()

    @AppStorage("walk.dailyGoal") private var dailyGoal = 8_000
    @State private var selectedID: WalkSuggestion.ID?
    @State private var addingKind: SavedPlace.Kind?
    @State private var showingMap = false
    @State private var showingLeaderboard = false
    @State private var showingGoalPicker = false
    @State private var justClaimed: Reward?
    /// Set just after the first step count arrives, so opening the app
    /// doesn't buzz for rewards or goals that were already reached.
    @State private var celebrationsReady = false

    private var stepsNeeded: Int { max(dailyGoal - steps.stepsToday, 0) }
    private var selected: WalkSuggestion? { planner.suggestions.first { $0.id == selectedID } }
    private var myRank: Int? { leaderboard.rank(of: auth.user?.uid) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                GoalHero(onStartWalk: startWalk,
                         onChangeGoal: { showingGoalPicker = true },
                         onClaim: claim)

                if steps.access == .unavailable {
                    Label("Step counting needs Apple Health, which isn't available on this device.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                }

                goalCard
                walkIdeas
                leaderboardPreview
                rewards

                #if DEBUG
                debugTools
                #endif
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Color(.systemBackground))
        .refreshable {
            Haptics.soft()
            await steps.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await steps.refresh() } }
        }
        .task(id: places.places) {
            selectedID = nil
            await planner.plan(home: places.home, destinations: places.destinations)
        }
        .onAppear {
            if steps.hasLoaded { celebrationsReady = true }
        }
        .onChange(of: isVisible, initial: true) { _, visible in
            if visible { location.requestOnce() }
        }
        // Celebrate real progress, not the first load.
        .onChange(of: steps.hasLoaded) { _, loaded in
            if loaded { Task { @MainActor in celebrationsReady = true } }
        }
        .onChange(of: steps.unlockedCount) { old, new in
            if celebrationsReady && new > old { Haptics.success() }
        }
        .onChange(of: stepsNeeded == 0) { wasDone, isDone in
            if celebrationsReady && isDone && !wasDone { Haptics.success() }
        }
        .onChange(of: myRank) { old, new in
            if celebrationsReady, let old, let new, new < old { Haptics.success() }
        }
        .sheet(item: $addingKind) { kind in
            AddPlaceView(initialKind: kind, currentLocation: location.lastLocation) { place in
                places.add(place)
                Haptics.success()
            }
            .presentationDetents([.large])
        }
        .fullScreenCover(isPresented: $showingMap) {
            RoutesView(selectedID: $selectedID, onClose: { showingMap = false })
                .environmentObject(steps)
                .environmentObject(places)
                .environmentObject(planner)
                .environmentObject(location)
                .tint(.brand)
        }
        .sheet(isPresented: $showingLeaderboard) {
            NavigationStack {
                LeaderboardView()
                    .navigationTitle("Leaderboard")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                Haptics.tap()
                                showingLeaderboard = false
                            }
                        }
                    }
            }
            .environmentObject(auth)
            .environmentObject(leaderboard)
            .tint(.brand)
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingGoalPicker) {
            GoalPicker()
                .environmentObject(steps)
                .presentationDetents([.medium, .large])
        }
        .alert(item: $justClaimed) { reward in
            Alert(
                title: Text("You earned it! 🎉"),
                message: Text("\(reward.fullName) is yours. You walked \(reward.steps.formatted()) steps for it."),
                dismissButton: .default(Text("Nice"))
            )
        }
    }

    // MARK: - Daily goal

    private var goalCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color(.systemFill), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: min(Double(steps.stepsToday) / Double(dailyGoal), 1))
                    .stroke(Color.brand, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(duration: 0.5), value: steps.stepsToday)
                Image(systemName: stepsNeeded == 0 ? "checkmark" : "flag.fill")
                    .font(.footnote.bold())
                    .foregroundStyle(Color.brand)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text("Daily goal · \(dailyGoal.formatted())")
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.numericText())
                Text(stepsNeeded == 0 ? "Goal reached today 🎉" : "\(stepsNeeded.formatted()) steps to go")
                    .font(.caption)
                    .foregroundStyle(stepsNeeded == 0 ? Color.brand : .secondary)
            }

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                roundButton("minus", label: "Lower goal") { dailyGoal = max(2_000, dailyGoal - 1_000) }
                roundButton("plus", label: "Raise goal") { dailyGoal = min(30_000, dailyGoal + 1_000) }
            }
        }
        .padding(14)
        .card()
        .animation(.snappy, value: dailyGoal)
    }

    private func roundButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.subheadline.bold())
                .frame(width: 34, height: 34)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Walk ideas (map + suggestions)

    private var walkIdeas: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Walk ideas",
                          actionTitle: places.home == nil ? nil : "Full map") {
                showingMap = true
            }

            if places.home == nil {
                prompt("Set your home to get walk ideas", systemImage: "house.fill") { addingKind = .home }
            } else {
                Button {
                    Haptics.tap()
                    showingMap = true
                } label: {
                    RouteMap(places: places.places, walk: selected, topInset: 0, interactive: false)
                        .frame(height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            Label("Open map", systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.regularMaterial, in: Capsule())
                                .padding(10)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open the full map")

                if places.destinations.isEmpty {
                    prompt("Add places you go often", systemImage: "mappin.and.ellipse") { addingKind = .other }
                } else if planner.isPlanning {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Finding walking routes…").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(planner.ranked(for: stepsNeeded)) { walk in
                                SuggestionCard(walk: walk,
                                               reachesGoal: stepsNeeded > 0 && walk.steps >= stepsNeeded,
                                               isSelected: walk.id == selectedID)
                                    .frame(width: 270)
                                    .onTapGesture {
                                        Haptics.select()
                                        withAnimation(.snappy) {
                                            selectedID = selectedID == walk.id ? nil : walk.id
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 2)
                    }
                    .padding(.horizontal, -16)
                }
            }

            placeChips

            if stepsNeeded > 0 {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                    Text("Taking a rickshaw or bus? Get off 1 km early and walk the rest: about **+1,300 steps**.")
                        .font(.subheadline)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if planner.suggestions.contains(where: \.isEstimate) {
                Text("Dashed lines are straight-line estimates where no walking route was found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = planner.googleError {
                Text("Google Maps: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var placeChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(places.places) { place in
                        Label(place.name, systemImage: place.kind.systemImage)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                            .contextMenu {
                                Button(role: .destructive) {
                                    Haptics.warning()
                                    places.remove(place)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                    Button {
                        Haptics.tap()
                        addingKind = places.home == nil ? .home : .other
                    } label: {
                        Label("Add place", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.brand.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.brand)
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)

            if !places.places.isEmpty {
                Text("Saved only on this phone. Long-press a place to remove it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            #if DEBUG
            if places.places.isEmpty {
                Button("Load sample Dhaka places (debug)") {
                    Haptics.tap()
                    places.addSampleDhakaPlaces()
                }
                .font(.caption)
            }
            #endif
        }
    }

    // MARK: - Leaderboard preview

    private var leaderboardPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Leaderboard",
                          actionTitle: leaderboard.ranked.isEmpty ? nil : "See all") {
                showingLeaderboard = true
            }

            if let notice = LeaderboardNotice.current(auth: auth, leaderboard: leaderboard,
                                                      isEmpty: leaderboard.ranked.isEmpty,
                                                      emptyText: "No walkers yet. Start walking to take #1!") {
                notice
            } else {
                let top = Array(leaderboard.ranked.prefix(3))
                let me = auth.user?.uid
                VStack(spacing: 0) {
                    ForEach(Array(top.enumerated()), id: \.element.id) { index, entry in
                        LeaderRow(rank: index + 1, entry: entry, steps: entry.totalSteps, isMe: entry.id == me)
                        if index < top.count - 1 { Divider().padding(.leading, 64) }
                    }
                    if let myRank, myRank > 3, let mine = leaderboard.ranked.first(where: { $0.id == me }) {
                        HStack {
                            Spacer()
                            Image(systemName: "ellipsis").foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.vertical, 2)
                        LeaderRow(rank: myRank, entry: mine, steps: mine.totalSteps, isMe: true)
                    }
                }
                .padding(.horizontal, -14)
                .onTapGesture {
                    Haptics.tap()
                    showingLeaderboard = true
                }
            }
        }
    }

    // MARK: - Rewards

    private var rewards: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Rewards")

            VStack(spacing: 0) {
                ForEach(Reward.all) { reward in
                    RewardCard(reward: reward) { claim(reward) }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !steps.isClaimed(reward), reward.id != steps.goalReward?.id else { return }
                            Haptics.select()
                            withAnimation(.snappy) { steps.setGoal(reward) }
                        }
                        .hairline(leading: reward.id == Reward.all.last?.id ? 0 : 72)
                }
            }

            Text("Tap a reward to make it your goal.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Steps count from \(steps.joinDate.formatted(date: .abbreviated, time: .omitted)), when you joined.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    /// "Start a walk": open the map, or ask for home first if it isn't set.
    private func startWalk() {
        if places.home == nil {
            addingKind = .home
        } else {
            showingMap = true
        }
    }

    private func claim(_ reward: Reward) {
        steps.claim(reward)
        justClaimed = reward
    }

    private func prompt(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.brand)
    }

    #if DEBUG
    private var debugTools: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Testing (debug builds only)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack {
                Button("+1,000") { Haptics.press(); steps.addTestSteps(1_000) }
                Button("+10,000") { Haptics.press(); steps.addTestSteps(10_000) }
                Spacer()
                Button("Reset", role: .destructive) { Haptics.warning(); steps.resetTestProgress() }
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .card()
    }
    #endif
}
