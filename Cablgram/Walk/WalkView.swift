import SwiftUI

struct WalkView: View {
    @EnvironmentObject private var steps: StepStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var justClaimed: Reward?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ProgressRing()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }

                if steps.access == .unavailable {
                    Section {
                        Label("Step counting needs Apple Health, which isn't available on this device.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout)
                    }
                }

                Section {
                    ForEach(Reward.all) { reward in
                        RewardRow(reward: reward) {
                            steps.claim(reward)
                            justClaimed = reward
                        }
                    }
                } header: {
                    Text("Rewards")
                } footer: {
                    Text("Steps count from \(steps.joinDate.formatted(date: .abbreviated, time: .omitted)), when you joined.")
                }

                #if DEBUG
                Section("Testing (debug builds only)") {
                    Button("Add 1,000 test steps") { steps.addTestSteps(1_000) }
                    Button("Add 10,000 test steps") { steps.addTestSteps(10_000) }
                    Button("Reset test steps and claims", role: .destructive) { steps.resetTestProgress() }
                }
                #endif
            }
            .navigationTitle("Walk")
            .task { await steps.start() }
            .refreshable { await steps.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await steps.refresh() } }
            }
            .alert(item: $justClaimed) { reward in
                Alert(
                    title: Text("You earned it! 🎉"),
                    message: Text("\(reward.title) is yours. You walked \(reward.steps.formatted()) steps to get it."),
                    dismissButton: .default(Text("Nice"))
                )
            }
        }
    }
}

private struct ProgressRing: View {
    @EnvironmentObject private var steps: StepStore

    private var progress: Double {
        guard let next = steps.nextReward else { return 1 }
        let previous = Reward.all.last { $0.steps <= steps.totalSteps }?.steps ?? 0
        return Double(steps.totalSteps - previous) / Double(next.steps - previous)
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.brand.opacity(0.15), lineWidth: 18)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.brand, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(duration: 0.6), value: progress)
                VStack(spacing: 2) {
                    Image(systemName: "figure.walk")
                        .font(.title2)
                        .foregroundStyle(Color.brand)
                    Text(steps.totalSteps.formatted())
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                        .monospacedDigit()
                    Text("total steps")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 220, height: 220)
            .padding(.top, 8)

            Text("Today: \(steps.stepsToday.formatted()) steps")
                .font(.headline)

            if let next = steps.nextReward {
                Text("\((next.steps - steps.totalSteps).formatted()) steps to \(next.title)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("You've unlocked every reward!")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.brand)
            }
        }
    }
}

private struct RewardRow: View {
    @EnvironmentObject private var steps: StepStore
    let reward: Reward
    let onClaim: () -> Void

    var body: some View {
        let unlocked = steps.isUnlocked(reward)
        let claimed = steps.isClaimed(reward)

        HStack(spacing: 14) {
            Image(systemName: reward.systemImage)
                .font(.title2)
                .frame(width: 44, height: 44)
                .foregroundStyle(unlocked ? .white : Color.brand)
                .background(unlocked ? Color.brand : Color.brand.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(reward.title).font(.headline)
                if unlocked {
                    Text("\(reward.steps.formatted()) steps").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView(value: Double(steps.totalSteps), total: Double(reward.steps))
                    Text("\(steps.totalSteps.formatted()) / \(reward.steps.formatted())")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            Spacer(minLength: 8)

            if claimed {
                Label("Claimed", systemImage: "checkmark.seal.fill")
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .foregroundStyle(.green)
            } else if unlocked {
                Button("Claim", action: onClaim)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            } else {
                Image(systemName: "lock.fill").foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    WalkView().environmentObject(StepStore())
}
