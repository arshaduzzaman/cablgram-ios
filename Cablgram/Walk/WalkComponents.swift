import SwiftUI

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
                    GradientProgressBar(fraction: Double(steps.availableSteps) / Double(reward.steps))
                        .padding(.vertical, 3)
                }
                Text(unlocked
                     ? "\(reward.steps.formatted()) steps"
                     : "\(steps.availableSteps.formatted()) of \(reward.steps.formatted()) steps")
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
