import SwiftUI

/// A live race to your goal reward: a track with you and the walkers
/// around you on it, the reward at the finish, and who's closest to it.
struct RaceTrack: View {
    let goal: Reward
    var onOpenLeaderboard: () -> Void = {}

    @EnvironmentObject private var steps: StepStore
    @EnvironmentObject private var leaderboard: LeaderboardStore
    @EnvironmentObject private var auth: AuthStore
    /// Each rival's steps at the last update, to spot a big catch-up.
    @State private var lastSteps: [String: Int] = [:]
    /// "Fariz caught up +3,200", shown for a few seconds.
    @State private var catchUp: (name: String, gain: Int)?

    /// A jump this big in one update gets announced.
    private static let catchUpSteps = 1_000
    /// Rivals whose phone hasn't sent steps for this long are shown faded.
    private static let staleAfter: TimeInterval = 60 * 60

    private var racers: [Racer] {
        leaderboard.race(for: goal, yourSteps: steps.availableSteps, uid: auth.user?.uid,
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
                Text("\(steps.availableSteps.formatted()) of \(goal.steps.formatted()) steps")
                    .contentTransition(.numericText(value: Double(steps.availableSteps)))
                Spacer()
                Text("\(Int(min(Double(steps.availableSteps) / Double(goal.steps), 1) * 100))%")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.brand)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            if let catchUp {
                Text("🚀 **\(catchUp.name)** caught up +\(catchUp.gain.formatted()) steps")
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Button(action: {
                Haptics.tap()
                onOpenLeaderboard()
            }) {
                leaderLine(leader: leader, you: you, rank: youIndex + 1, total: all.count)
            }
            .buttonStyle(.plain)

            Text("Faded walkers haven't sent steps for a while and may be further ahead. Steps count only if they reach Cablgram by midday the next day.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .animation(.smooth(duration: 0.9), value: all.map(\.steps))
        .animation(.snappy, value: catchUp?.name)
        .onChange(of: all.filter { !$0.isYou }.map { "\($0.id):\($0.steps)" }, initial: true) { _, _ in
            noticeCatchUps(all.filter { !$0.isYou })
        }
        .task(id: catchUp?.name) {
            guard catchUp != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            catchUp = nil
        }
    }

    /// Announces the biggest jump since the last update (not on the first load).
    private func noticeCatchUps(_ rivals: [Racer]) {
        let first = lastSteps.isEmpty
        var best: (name: String, gain: Int)?
        for racer in rivals {
            if let before = lastSteps[racer.id], racer.steps - before >= Self.catchUpSteps,
               racer.steps - before > (best?.gain ?? 0) {
                best = (racer.firstName, racer.steps - before)
            }
        }
        lastSteps = Dictionary(rivals.map { ($0.id, $0.steps) }) { a, _ in a }
        if !first, let best { catchUp = best }
    }

    /// Hasn't sent steps for over an hour (or never said when).
    static func isStale(_ racer: Racer, now: Date = .now) -> Bool {
        guard !racer.isYou else { return false }
        guard let date = racer.updatedAt else { return true }
        return now.timeIntervalSince(date) > staleAfter
    }

    /// "2h", "3d" for the badge on a faded walker.
    static func shortAgo(_ date: Date?, now: Date = .now) -> String? {
        guard let date else { return nil }
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        switch minutes {
        case ..<60: return "\(minutes)m"
        case ..<(24 * 60): return "\(minutes / 60)h"
        default: return "\(minutes / (24 * 60))d"
        }
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
                        let stale = Self.isStale(racer)
                        ZStack(alignment: .bottomTrailing) {
                            Avatar(url: racer.photoURL, name: racer.name, size: 24)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                                .saturation(stale ? 0 : 1)
                                .opacity(stale ? 0.45 : 1)
                            if racer.finished {
                                Text("🏆").font(.system(size: 10)).offset(x: 4, y: 3)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            // How old their steps are.
                            if stale, let ago = Self.shortAgo(racer.updatedAt) {
                                Text(ago)
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3)
                                    .background(Color.gray, in: Capsule())
                                    .offset(x: 8, y: -4)
                            }
                        }
                        .accessibilityLabel(stale ? "\(racer.firstName), steps from \(Self.updatedAgo(racer.updatedAt) ?? "a while ago")" : racer.firstName)
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
    /// "12m ago" for when someone's phone last sent steps.
    static func updatedAgo(_ date: Date?, now: Date = .now) -> String? {
        guard let date else { return nil }
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        switch minutes {
        case ..<2: return "just now"
        case ..<60: return "\(minutes)m ago"
        case ..<(24 * 60): return "\(minutes / 60)h ago"
        default: return "\(minutes / (24 * 60))d ago"
        }
    }

    private func leaderLine(leader: Racer?, you: Racer, rank: Int, total: Int) -> some View {
        HStack(spacing: 4) {
            if let leader, leader.steps > you.steps {
                let left = max(goal.steps - leader.steps, 0)
                Text("🔥").padding(.trailing, 2)
                VStack(alignment: .leading, spacing: 1) {
                    // One line: a long name gives way (then the text shrinks a little), never the number.
                    HStack(spacing: 4) {
                        Text(leader.firstName)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Group {
                            Text("is")
                            Text(left.formatted())
                                .fontWeight(.bold)
                                .foregroundStyle(Color.brand)
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(left)))
                            Text("steps away")
                        }
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(1)
                    }
                    .minimumScaleFactor(0.85)
                    // Others' totals are live while their app is open, hourly-ish when closed: show how fresh the leader's is.
                    if let ago = Self.updatedAgo(leader.updatedAt) {
                        Text(ago)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                Text("🔥 You're leading the race")
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 4)
            Text("You're #\(rank)")
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(rank)))
                .lineLimit(1)
                .fixedSize()
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
