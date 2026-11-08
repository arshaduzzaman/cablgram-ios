import SwiftUI

/// A live race to your goal reward: a track with you and the walkers
/// around you on it, the reward at the finish, and who's closest to it.
struct RaceTrack: View {
    let goal: Reward
    var onOpenLeaderboard: () -> Void = {}

    @EnvironmentObject private var steps: StepStore
    @EnvironmentObject private var leaderboard: LeaderboardStore
    @EnvironmentObject private var auth: AuthStore

    private var racers: [Racer] {
        leaderboard.race(for: goal, yourSteps: steps.totalSteps, uid: auth.user?.uid,
                         name: auth.user?.displayName ?? "You", photoURL: auth.user?.photoURL)
    }

    var body: some View {
        let all = racers
        let youIndex = all.firstIndex { $0.isYou } ?? 0
        let you = all[youIndex]
        let leader = all.first { !$0.isYou && !$0.finished }
        let shown = Self.nearby(all, youIndex: youIndex)

        VStack(alignment: .leading, spacing: 10) {
            track(shown: shown, you: you)
                .frame(height: 58)

            HStack {
                Text("\(steps.totalSteps.formatted()) of \(goal.steps.formatted()) steps")
                    .contentTransition(.numericText(value: Double(steps.totalSteps)))
                Spacer()
                Text("\(Int(min(Double(steps.totalSteps) / Double(goal.steps), 1) * 100))%")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.brand)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            Button(action: {
                Haptics.tap()
                onOpenLeaderboard()
            }) {
                leaderLine(leader: leader, you: you, rank: youIndex + 1, total: all.count)
            }
            .buttonStyle(.plain)
        }
        .animation(.smooth(duration: 0.9), value: all.map(\.steps))
        .onAppear { leaderboard.prepareRace(for: goal, yourSteps: steps.totalSteps) }
        .onChange(of: goal.id) { _, _ in leaderboard.prepareRace(for: goal, yourSteps: steps.totalSteps) }
    }

    // MARK: - Track

    private func track(shown: [Racer], you: Racer) -> some View {
        GeometryReader { geo in
            let width = geo.size.width - 30 // room for the finish
            let x: (Racer) -> CGFloat = { racer in
                14 + width * CGFloat(min(Double(racer.steps) / Double(goal.steps), 1)) - 14
            }

            ZStack(alignment: .topLeading) {
                // Track and your progress
                Capsule().fill(Color(.systemFill))
                    .frame(width: width + 6, height: 8)
                    .offset(y: 44)
                Capsule().fill(Color.brand)
                    .frame(width: max(8, x(you) + 14), height: 8)
                    .offset(y: 44)

                // Finish: the reward itself
                RewardImage(reward: goal)
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    .offset(x: geo.size.width - 30, y: 33)

                // Rivals above the track, alternating heights so they don't overlap
                ForEach(Array(shown.filter { !$0.isYou }.enumerated()), id: \.element.id) { index, racer in
                    VStack(spacing: 2) {
                        ZStack(alignment: .bottomTrailing) {
                            Avatar(url: racer.photoURL, name: racer.name, size: 24)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                            if racer.finished {
                                Text("🏆").font(.system(size: 10)).offset(x: 4, y: 3)
                            }
                        }
                        Rectangle().fill(Color(.separator)).frame(width: 1, height: index.isMultiple(of: 2) ? 8 : 0)
                    }
                    .offset(x: x(racer) + 2, y: index.isMultiple(of: 2) ? 2 : 12)
                }

                // You, on the track
                Avatar(url: you.photoURL, name: you.name, size: 28)
                    .overlay(Circle().stroke(Color.brand, lineWidth: 3))
                    .background(Circle().fill(.white).padding(-3))
                    .offset(x: x(you), y: 34)
            }
        }
    }

    // MARK: - Leader line

    @ViewBuilder
    private func leaderLine(leader: Racer?, you: Racer, rank: Int, total: Int) -> some View {
        HStack(spacing: 4) {
            if let leader, leader.steps > you.steps {
                let left = max(goal.steps - leader.steps, 0)
                Text("🔥").padding(.trailing, 2)
                (Text(leader.firstName).fontWeight(.semibold) + Text(" is "))
                    .lineLimit(1)
                Text(left.formatted())
                    .fontWeight(.bold)
                    .foregroundStyle(Color.brand)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(left)))
                Text("steps away")
                    .lineLimit(1)
            } else {
                Text("🔥 You're leading the race")
                    .fontWeight(.semibold)
            }
            Spacer(minLength: 4)
            Text("You're #\(rank)")
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(rank)))
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The leader, the two closest rivals ahead of you, you, and the closest
    /// one behind (skipping anyone level with you so avatars don't pile up).
    static func nearby(_ all: [Racer], youIndex: Int) -> [Racer] {
        let you = all[youIndex]
        let ahead = all.filter { !$0.isYou && $0.steps > you.steps }
        let behind = all.filter { !$0.isYou && $0.steps < you.steps }
        var picked: [Racer] = []
        if let leader = ahead.first { picked.append(leader) }
        for racer in ahead.suffix(2) where !picked.contains(racer) { picked.append(racer) }
        picked.append(you)
        if let next = behind.first { picked.append(next) }
        return picked
    }
}
