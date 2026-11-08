import SwiftUI

/// Step ring with your total, plus today's steps and what's next.
struct StepsHero: View {
    @EnvironmentObject private var steps: StepStore

    private var progress: Double {
        guard let next = steps.nextReward else { return 1 }
        let previous = Reward.all.last { $0.steps <= steps.totalSteps }?.steps ?? 0
        return Double(steps.totalSteps - previous) / Double(next.steps - previous)
    }

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .stroke(Color(.systemFill), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.brand, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(duration: 0.6), value: progress)
                VStack(spacing: 2) {
                    Text(steps.totalSteps.formatted())
                        .font(.system(size: 46, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("total steps")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 184, height: 184)

            HStack(spacing: 0) {
                Stat(value: steps.stepsToday.formatted(), label: "Today")
                Rectangle().fill(Color(.separator)).frame(width: 1 / 3, height: 34)
                if let next = steps.nextReward {
                    Stat(value: (next.steps - steps.totalSteps).formatted(), label: "To next reward")
                } else {
                    Stat(value: "All", label: "Rewards unlocked")
                }
            }

            if let next = steps.nextReward {
                Text("Next up: **\(next.fullName)**")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One reward as a flat row: photo, name, progress, and Claim when unlocked.
struct RewardCard: View {
    @EnvironmentObject private var steps: StepStore
    let reward: Reward
    let onClaim: () -> Void

    var body: some View {
        let unlocked = steps.isUnlocked(reward)
        let claimed = steps.isClaimed(reward)

        HStack(spacing: 14) {
            RewardImage(reward: reward)
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .opacity(unlocked || claimed ? 1 : 0.9)

            VStack(alignment: .leading, spacing: 4) {
                Text(reward.fullName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if reward.id == steps.goalReward?.id && !claimed {
                    Text("YOUR GOAL")
                        .font(.caption2.weight(.bold))
                        .tracking(0.5)
                        .foregroundStyle(Color.brand)
                }
                if !unlocked {
                    GradientProgressBar(fraction: Double(steps.totalSteps) / Double(reward.steps))
                        .padding(.vertical, 3)
                }
                Text(unlocked
                     ? "\(reward.steps.formatted()) steps"
                     : "\(steps.totalSteps.formatted()) of \(reward.steps.formatted()) steps")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 4)

            if claimed {
                Text("Claimed")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else if unlocked {
                Button {
                    Haptics.celebrate()
                    onClaim()
                } label: {
                    Text("Claim")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Color.brand, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "lock")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 12)
    }
}
