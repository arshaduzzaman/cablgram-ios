import SwiftUI

/// Everything about walking on one scrolling page: your steps and goal,
/// the leaderboard, and rewards.
struct WalkPage: View {
    @EnvironmentObject private var steps: StepStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var leaderboard: LeaderboardStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var walking = false
    @State private var finishedSteps: Int?
    @State private var showingLeaderboard = false
    @State private var showingGoalPicker = false
    @State private var justClaimed: Reward?
    /// Set just after the first step count arrives, so opening the app
    /// doesn't buzz for rewards or goals that were already reached.
    @State private var celebrationsReady = false

    private var myRank: Int? { leaderboard.rank(of: auth.user?.uid) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                GoalHero(onStartWalk: { walking = true },
                         onChangeGoal: { showingGoalPicker = true },
                         onClaim: claim,
                         onOpenLeaderboard: { showingLeaderboard = true })

                if steps.access == .unavailable {
                    Label("Step counting needs Apple Health, which isn't available on this device.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                }

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
        .onAppear {
            if steps.hasLoaded { celebrationsReady = true }
        }
        // Celebrate real progress, not the first load.
        .onChange(of: steps.hasLoaded) { _, loaded in
            if loaded { Task { @MainActor in celebrationsReady = true } }
        }
        .onChange(of: steps.unlockedCount) { old, new in
            if celebrationsReady && new > old { Haptics.success() }
        }
        .onChange(of: myRank) { old, new in
            if celebrationsReady, let old, let new, new < old { Haptics.success() }
        }
        .fullScreenCover(isPresented: $walking) {
            WalkNavigationView { walked in
                walking = false
                finishedSteps = walked
                Task { await steps.refresh() }
            }
            .environmentObject(steps)
            .tint(.brand)
        }
        .alert("Nice walk! 🎉", isPresented: Binding(
            get: { finishedSteps != nil },
            set: { if !$0 { finishedSteps = nil } }
        )) {
            Button("Done") { finishedSteps = nil }
        } message: {
            let walked = finishedSteps ?? 0
            if let goal = steps.goalReward {
                Text("You walked \(walked.formatted()) steps. \(steps.stepsToGoal == 0 ? "\(goal.fullName) is ready to claim!" : "\(steps.stepsToGoal.formatted()) more to \(goal.fullName).")")
            } else {
                Text("You walked \(walked.formatted()) steps.")
            }
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
                .animation(.smooth(duration: 0.6), value: leaderboard.ranked.prefix(3).map(\.id))
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

    private func claim(_ reward: Reward) {
        steps.claim(reward)
        justClaimed = reward
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
