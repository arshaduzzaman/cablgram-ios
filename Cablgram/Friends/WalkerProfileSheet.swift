import SwiftUI

/// A small profile for someone in the race chat: their picture, how far they are toward
/// the reward, and a button for where you stand with them. Friends get "Message" and
/// "Egg them", which both open your conversation (egging with the egg sheet up).
struct WalkerProfileSheet: View {
    let person: EggTarget
    let reward: Reward

    @EnvironmentObject private var friends: FriendsStore
    @EnvironmentObject private var leaderboard: LeaderboardStore
    @Environment(InboxStore.self) private var inbox: InboxStore?
    @Environment(\.dismiss) private var dismiss

    private var steps: Int {
        min(leaderboard.ranked.first { $0.id == person.uid }?.totalSteps ?? 0, reward.steps)
    }

    var body: some View {
        profile
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .onAppear { friends.actionError = nil }
    }

    private var profile: some View {
        VStack(spacing: 16) {
            Avatar(url: person.photoURL, name: person.name, size: 104)
                .overlay(Circle().stroke(.white, lineWidth: 4))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                .padding(.top, 32)

            VStack(spacing: 10) {
                Text(person.name)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    RewardImage(reward: reward)
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("\(steps.formatted()) of \(reward.steps.formatted()) steps toward \(reward.title)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                GradientProgressBar(fraction: Double(steps) / Double(max(reward.steps, 1)))
                    .frame(width: 220)
            }

            VStack(spacing: 10) {
                statusButton
                if friends.status(of: person.uid) == .friends {
                    HStack(spacing: 10) {
                        bigButton(filled: false, busy: false) {
                            Haptics.tap()
                            openChat(egg: false)
                        } label: {
                            Label("Message", systemImage: "bubble.left.fill")
                        }
                        bigButton(filled: true, busy: false) {
                            Haptics.press()
                            openChat(egg: true)
                        } label: {
                            HStack(spacing: 8) {
                                EggIcon()
                                    .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                    .frame(width: 20, height: 20)
                                Text("Egg them")
                            }
                        }
                    }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .padding(.top, 6)
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: friends.status(of: person.uid))

            if let error = friends.actionError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    /// Closes this sheet, then opens your conversation over the app.
    private func openChat(egg: Bool) {
        let inbox = inbox
        let uid = person.uid
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            inbox?.open(uid, egg: egg)
        }
    }

    @ViewBuilder
    private var statusButton: some View {
        let busy = friends.busy.contains(person.uid)
        switch friends.status(of: person.uid) {
        case nil:
            bigButton(filled: true, busy: busy) {
                Haptics.tap()
                Task { await friends.add(person.uid) }
            } label: { Label("Add friend", systemImage: "person.badge.plus") }
        case .sent:
            bigButton(filled: false, busy: busy) {
                Haptics.tap()
                Task { await friends.remove(person.uid) }
            } label: { Text("Requested") }
            .accessibilityHint("Cancels the request")
        case .received:
            bigButton(filled: true, busy: busy) {
                Haptics.tap()
                Task { await friends.accept(person.uid) }
            } label: { Text("Accept") }
        case .friends:
            Text("Friends ✓")
                .font(.headline)
                .foregroundStyle(Color.brand)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.brand.opacity(0.1), in: Capsule())
        }
    }

    private func bigButton<Label: View>(filled: Bool, busy: Bool, action: @escaping () -> Void,
                                        @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            ZStack {
                if busy { ProgressView().tint(filled ? .white : .primary) } else { label() }
            }
            .font(.headline)
            .foregroundStyle(filled ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(filled ? Color.brand : Color.black.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(SquishPress(scale: 0.95))
        .disabled(busy)
    }
}

/// "Rayed egged Arshad" in the race chat: thrower → egg → splatted target, with the
/// message in quotes. Tapping either picture opens their profile.
struct EggChatCard: View {
    let message: ChatMessage
    let egg: ChatEgg
    let me: String?
    /// Arrived while the chat was open: pops in with a light tap.
    let isNew: Bool
    var onOpen: (EggTarget) -> Void
    var onShown: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Bool

    init(message: ChatMessage, egg: ChatEgg, me: String?, isNew: Bool,
         onOpen: @escaping (EggTarget) -> Void, onShown: @escaping () -> Void = {}) {
        self.message = message
        self.egg = egg
        self.me = me
        self.isNew = isNew
        self.onOpen = onOpen
        self.onShown = onShown
        _shown = State(initialValue: !isNew)
    }

    private var line: String {
        let thrower = message.uid == me ? "You" : shortName(message.name)
        let target = egg.toUid == me ? "you" : shortName(egg.toName)
        return "\(thrower) egged \(target)"
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                person(message.uid, message.name, message.photoURL, splat: nil)
                FlyingEggGlyph()
                    .frame(width: 44, height: 22)
                person(egg.toUid, egg.toName, egg.toPhotoURL, splat: egg.eggId ?? message.id)
            }
            VStack(spacing: 3) {
                Text(line)
                    .font(.footnote.weight(.semibold))
                if !egg.message.isEmpty {
                    Text("“\(egg.message)”")
                        .font(.footnote.italic())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Text(message.at, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 18)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.eggCream)
                .overlay(SplatPattern(seed: message.id))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .scaleEffect(shown ? 1 : 0.7)
        .opacity(shown ? 1 : 0)
        .onAppear {
            guard !shown else { return }
            onShown()
            Haptics.tap()
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.25)) { shown = true }
            } else {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.58)) { shown = true }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func person(_ uid: String, _ name: String, _ photo: URL?, splat: String?) -> some View {
        Button {
            guard uid != me else { return }
            Haptics.tap()
            onOpen(EggTarget(uid: uid, name: name, photoURL: photo))
        } label: {
            Avatar(url: photo, name: name, size: 34)
                .overlay {
                    if let splat {
                        SplatMark(seed: splat)
                            .frame(width: 34, height: 34)
                            .clipShape(Circle())
                    }
                }
                .overlay(Circle().stroke(.white, lineWidth: 2))
        }
        .buttonStyle(SquishPress())
        .disabled(uid == me)
    }
}

/// A small egg on a dotted arc, flying right.
private struct FlyingEggGlyph: View {
    var body: some View {
        Canvas { context, size in
            var arc = Path()
            arc.move(to: CGPoint(x: 2, y: size.height - 3))
            arc.addQuadCurve(to: CGPoint(x: size.width - 14, y: size.height * 0.45),
                             control: CGPoint(x: size.width * 0.4, y: -2))
            context.stroke(arc, with: .color(.black.opacity(0.25)),
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [0.1, 4]))
            let egg = EggArt.egg(center: CGPoint(x: size.width - 8, y: size.height * 0.5), size: 13, angle: .degrees(70))
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.25), radius: 1.5, y: 1))
                layer.fill(egg, with: .color(EggArt.shell))
            }
            context.stroke(egg, with: .color(Color(white: 0.6)), lineWidth: 0.8)
        }
        .accessibilityHidden(true)
    }
}
