import SwiftUI

/// Profile and settings, like Facebook's Menu tab.
struct MenuView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var steps: StepStore
    @EnvironmentObject private var leaderboard: LeaderboardStore

    @AppStorage(Haptics.enabledKey) private var hapticsOn = true

    private var claimed: [Reward] { Reward.all.filter(steps.isClaimed) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    Avatar(url: auth.user?.photoURL, name: auth.displayName, size: 60)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(auth.displayName).font(.title3.bold())
                        if let email = auth.user?.email {
                            Text(email).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(16)
                .card()

                HStack(spacing: 12) {
                    stat(steps.totalSteps.formatted(), "Total steps")
                    stat(steps.stepsToday.formatted(), "Today")
                    stat("\(claimed.count)", "Rewards")
                }

                if !claimed.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your rewards").font(.headline)
                        ForEach(claimed) { reward in
                            HStack(spacing: 12) {
                                RewardImage(reward: reward)
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                Text(reward.fullName).font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }

                Toggle(isOn: $hapticsOn) {
                    Label("Haptics", systemImage: "iphone.radiowaves.left.and.right")
                        .font(.headline)
                }
                .tint(.brand)
                .padding(16)
                .card(cornerRadius: 16)
                .onChange(of: hapticsOn) { _, on in
                    if on { Haptics.success() }
                }

                Button(role: .destructive) {
                    Haptics.warning()
                    leaderboard.stopListening()
                    auth.signOut()
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .card(cornerRadius: 16)
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .card(cornerRadius: 16)
    }
}
