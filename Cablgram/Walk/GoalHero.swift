import SwiftUI

/// Top of the Walk page: the prize you're walking for, how far away it is,
/// and how long that takes.
struct GoalHero: View {
    @EnvironmentObject private var steps: StepStore

    let onChangeGoal: () -> Void
    let onClaim: (Reward) -> Void
    var onOpenLeaderboard: () -> Void = {}

    /// Average walking cadence, used for the time estimate.
    private let stepsPerMinute = 100.0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let goal = steps.goalReward {
                header(goal)
                if steps.isUnlocked(goal) {
                    ready(goal)
                } else {
                    progress(goal)
                }
            } else {
                Text("You've claimed every reward 🎉")
                    .font(.title2.weight(.bold))
                Text("Keep walking. New rewards are on the way.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("This week **\(steps.stepsThisWeek.formatted())** steps")
                Spacer()
                Text(steps.spentSteps > 0
                     ? "Walked **\(steps.totalSteps.formatted())** · spent \(steps.spentSteps.formatted())"
                     : "Total **\(steps.totalSteps.formatted())**")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.top, 16)
    }

    // MARK: - Pieces

    private func header(_ goal: Reward) -> some View {
        HStack(spacing: 14) {
            RewardImage(reward: goal)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("YOUR GOAL")
                    .font(.caption.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(Color.brand)
                Text(goal.fullName)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                Button {
                    Haptics.tap()
                    onChangeGoal()
                } label: {
                    HStack(spacing: 3) {
                        Text("Change")
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func progress(_ goal: Reward) -> some View {
        let remaining = max(goal.steps - steps.availableSteps, 0)
        let pace = steps.dailyPace
        let days = pace >= 500 ? Int((Double(remaining) / Double(pace)).rounded(.up)) : nil
        let minutes = Int((Double(remaining) / stepsPerMinute).rounded())

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(remaining.formatted())
                        .font(.system(size: 46, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(remaining)))
                        .animation(.smooth(duration: 0.8), value: remaining)
                    Text("steps to go")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                RaceTrack(goal: goal, onOpenLeaderboard: onOpenLeaderboard)
            }

            Label {
                Text(days.map { $0 <= 1 ? "Roughly **\(Self.duration(minutes))** of walking. You could get it **today**"
                                         : "Roughly **\(Self.duration(minutes))** of walking, about **\($0) days** at your pace" }
                     ?? "Roughly **\(Self.duration(minutes))** of walking to get it")
            } icon: {
                Image(systemName: "clock").foregroundStyle(Color.brand)
            }
            .font(.subheadline)
        }
    }

    private func ready(_ goal: Reward) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You walked enough for it! 🎉")
                .font(.title2.weight(.bold))
            Button {
                Haptics.celebrate()
                onClaim(goal)
            } label: {
                Text("Claim \(goal.title)")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.brand, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    /// "45 min", "3 hr", "3 hr 20 min".
    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 || hours >= 10 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }
}

/// Sheet for choosing which reward to walk for.
struct GoalPicker: View {
    @EnvironmentObject private var steps: StepStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Reward.all.filter { !steps.isClaimed($0) }) { reward in
                    let remaining = max(reward.steps - steps.availableSteps, 0)
                    let isGoal = reward.id == steps.goalReward?.id
                    Button {
                        Haptics.select()
                        steps.setGoal(reward)
                        dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            RewardImage(reward: reward)
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(reward.fullName)
                                    .font(.subheadline.weight(.semibold))
                                Text(remaining == 0 ? "Ready to claim" : "\(remaining.formatted()) steps to go")
                                    .font(.footnote)
                                    .foregroundStyle(remaining == 0 ? Color.brand : .secondary)
                                    .monospacedDigit()
                            }
                            Spacer()
                            if isGoal {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(Color.brand)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Pick your goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Haptics.tap()
                        dismiss()
                    }
                }
            }
        }
        .tint(.brand)
    }
}
