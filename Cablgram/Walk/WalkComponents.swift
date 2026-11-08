import SwiftUI

/// Gradient card with the step ring and today's numbers.
struct StepsHero: View {
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
                Label("Next: \(next.fullName)", systemImage: next.systemImage)
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

struct RewardCard: View {
    @EnvironmentObject private var steps: StepStore
    let reward: Reward
    let onClaim: () -> Void

    var body: some View {
        let unlocked = steps.isUnlocked(reward)
        let claimed = steps.isClaimed(reward)

        HStack(spacing: 14) {
            RewardImage(reward: reward)
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if claimed {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title3)
                            .foregroundStyle(.white, .green)
                            .offset(x: 6, y: -6)
                    }
                }

            VStack(alignment: .leading, spacing: 5) {
                if let partner = reward.partner {
                    Text(partner)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(reward.title)
                    .font(.headline)
                    .lineLimit(2)
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

            Spacer(minLength: 4)

            if claimed {
                Text("Claimed")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
            } else if unlocked {
                Button {
                    Haptics.celebrate()
                    onClaim()
                } label: {
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
        .padding(12)
        .card()
    }
}
