import SwiftUI

/// Sends a claim for an unlocked reward. It then waits for an admin on the dashboard,
/// who contacts you on your verified number.
struct ClaimSheet: View {
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss
    let reward: Reward
    let onSent: (Reward) -> Void

    @State private var address = ""
    @State private var note = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !sending && (!reward.needsAddress || !trimmedAddress.isEmpty) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        RewardImage(reward: reward)
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(reward.fullName).font(.title3.weight(.bold))
                            Text("\(reward.steps.formatted()) steps")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    if let details = reward.details {
                        Text(details).font(.subheadline)
                    }

                    Label {
                        Text(auth.phoneNumber.map { "We'll check your claim and contact you on **\($0)**." }
                             ?? "We'll check your claim and contact you.")
                    } icon: {
                        Image(systemName: "phone.fill").foregroundStyle(Color.brand)
                    }
                    .font(.subheadline)

                    if reward.needsAddress {
                        field("Delivery address", text: $address, prompt: "House, road, area, city", lines: 3)
                    }
                    field("Note (optional)", text: $note, prompt: "Anything we should know", lines: 2)

                    if let error {
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }

                    Button(action: send) {
                        Group {
                            if sending { ProgressView().tint(.white) } else { Text("Send claim") }
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.brand.opacity(canSend ? 1 : 0.5), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Claim reward")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            TextField(prompt, text: text, axis: .vertical)
                .lineLimit(lines, reservesSpace: true)
                .focused($focused)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func send() {
        focused = false
        sending = true
        error = nil
        Task {
            do {
                try await RewardStore.shared.claim(reward, address: reward.needsAddress ? trimmedAddress : nil,
                                                   note: note.trimmingCharacters(in: .whitespacesAndNewlines))
                Haptics.celebrate()
                dismiss()
                onSent(reward)
            } catch {
                Haptics.error()
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}
