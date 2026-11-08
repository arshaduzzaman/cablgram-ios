import SwiftUI

struct WalkView: View {
    @EnvironmentObject private var steps: StepStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var justClaimed: Reward?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader(eyebrow: "Every step counts", title: "Walk")

                StepsHero()

                if steps.access == .unavailable {
                    Label("Step counting needs Apple Health, which isn't available on this device.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                }

                Text("Rewards")
                    .font(.title3.bold())
                    .padding(.top, 4)

                VStack(spacing: 12) {
                    ForEach(Reward.all) { reward in
                        RewardCard(reward: reward) {
                            steps.claim(reward)
                            justClaimed = reward
                        }
                    }
                }

                Text("Steps count from \(steps.joinDate.formatted(date: .abbreviated, time: .omitted)), when you joined.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                #if DEBUG
                debugTools
                #endif
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { await steps.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await steps.refresh() } }
        }
        .alert(item: $justClaimed) { reward in
            Alert(
                title: Text("You earned it! 🎉"),
                message: Text("\(reward.partner) \(reward.title) is yours. You walked \(reward.steps.formatted()) steps for it."),
                dismissButton: .default(Text("Nice"))
            )
        }
    }

    #if DEBUG
    private var debugTools: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Testing (debug builds only)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack {
                Button("+1,000") { steps.addTestSteps(1_000) }
                Button("+10,000") { steps.addTestSteps(10_000) }
                Spacer()
                Button("Reset", role: .destructive) { steps.resetTestProgress() }
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .card()
    }
    #endif
}

/// Gradient card with the step ring and today's numbers.
private struct StepsHero: View {
    @EnvironmentObject private var steps: StepStore

    private var progress: Double {
        guard let next = steps.nextReward else { return 1 }
        let previous = Reward.all.last { $0.steps <= steps.totalSteps }?.steps ?? 0
        return Double(steps.totalSteps - previous) / Double(next.steps - previous)
    }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.25), lineWidth: 16)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(duration: 0.6), value: progress)
                VStack(spacing: 0) {
                    Text(steps.totalSteps.formatted())
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("total steps")
                        .font(.subheadline.weight(.medium))
                        .opacity(0.85)
                }
            }
            .frame(width: 190, height: 190)

            HStack(spacing: 10) {
                StatPill(value: steps.stepsToday.formatted(), label: "Today")
                if let next = steps.nextReward {
                    StatPill(value: (next.steps - steps.totalSteps).formatted(), label: "To next reward")
                } else {
                    StatPill(value: "All", label: "Rewards unlocked")
                }
            }

            if let next = steps.nextReward {
                Label("Next: \(next.partner) \(next.title)", systemImage: next.systemImage)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(.brandGradient, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.brand.opacity(0.3), radius: 18, y: 8)
    }
}

private struct StatPill: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .opacity(0.85)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct RewardCard: View {
    @EnvironmentObject private var steps: StepStore
    let reward: Reward
    let onClaim: () -> Void

    var body: some View {
        let unlocked = steps.isUnlocked(reward)
        let claimed = steps.isClaimed(reward)

        HStack(spacing: 14) {
            Image(systemName: reward.systemImage)
                .font(.title3)
                .foregroundStyle(unlocked ? .white : Color.brand)
                .frame(width: 48, height: 48)
                .background(unlocked ? AnyShapeStyle(.brandGradient) : AnyShapeStyle(Color.brand.opacity(0.12)),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(reward.partner)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(reward.title)
                    .font(.headline)
                if !unlocked {
                    GradientProgressBar(fraction: Double(steps.totalSteps) / Double(reward.steps))
                        .padding(.top, 2)
                }
                Text(unlocked
                     ? "\(reward.steps.formatted()) steps"
                     : "\(steps.totalSteps.formatted()) / \(reward.steps.formatted()) steps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            if claimed {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Claimed")
            } else if unlocked {
                Button(action: onClaim) {
                    Text("Claim")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.brandGradient, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .card()
    }
}

#Preview {
    WalkView().environmentObject(StepStore())
}
