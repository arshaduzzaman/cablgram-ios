import SwiftUI

/// Cablgram's posts as a messy pile of photos on a table. Flick the top one
/// away to see the next, double-tap to leave a pink handprint where your
/// finger lands, hold to draw on it, and shake the phone to throw them all
/// back. Slaps and drawings are shared, so the photos carry everyone's marks.
struct NewsView: View {
    var openWalk: () -> Void = {}

    @EnvironmentObject private var steps: StepStore
    @EnvironmentObject private var auth: AuthStore
    @StateObject private var feed = NewsFeed()
    @StateObject private var social = NewsSocial()
    @Environment(\.openURL) private var openURL

    /// Posts flicked away, most recent last, so Back can return them.
    @State private var tossed: [String] = []
    /// The post being drawn on, if any.
    @State private var drawingPostID: String?
    @State private var slapPulse = 0

    private var pile: [NewsPost] {
        let gone = Set(tossed)
        return feed.posts.filter { !gone.contains($0.id) }
    }

    private var top: NewsPost? { pile.first }

    var body: some View {
        VStack(spacing: 0) {
            stepsRow

            GeometryReader { geo in
                table(in: geo.size)
                    .frame(width: geo.size.width, height: geo.size.height)
            }

            controls
        }
        .background(Color(.secondarySystemBackground))
        .task {
            if feed.posts.isEmpty { await feed.refresh() }
        }
        .onChange(of: pile.prefix(2).map(\.id), initial: true) { _, ids in
            social.watch(ids)
            PhotoCache.shared.prefetch(pile.prefix(5).map(\.imageUrl))
        }
        .onChange(of: pile.count) { _, remaining in
            if remaining < 6, !feed.posts.isEmpty { Task { await feed.loadMore() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
            guard drawingPostID == nil else { return }
            shuffleBack()
        }
    }

    // MARK: - The table

    @ViewBuilder
    private func table(in size: CGSize) -> some View {
        if feed.posts.isEmpty {
            if let message = feed.errorMessage {
                ContentUnavailableView {
                    Label("No news right now", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") {
                        Haptics.tap()
                        Task { await feed.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView()
            }
        } else if pile.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.brand)
                Text("You've been through all the news")
                    .font(.headline)
                Text("Shake your phone to throw it all back on the table.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    shuffleBack()
                } label: {
                    Label("Throw them back", systemImage: "arrow.uturn.backward")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(height: 48)
                        .background(Color.brand, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(32)
        } else {
            let photoBox = CGSize(width: min(size.width - 64, 460),
                                  height: max(size.height - 42 - 10 - 64, 120))
            ZStack {
                // Deepest first, so the top photo is drawn last.
                ForEach(Array(pile.prefix(4)).reversed()) { post in
                    PileCard(post: post,
                             isTop: post.id == top?.id,
                             maxPhotoSize: photoBox,
                             marks: social.marks(post.id),
                             drawings: social.drawings(post.id),
                             isDrawing: drawingPostID == post.id,
                             myID: auth.user?.uid,
                             slapPulse: post.id == top?.id ? slapPulse : 0,
                             onDrawingChange: { drawing in
                                 drawingPostID = drawing ? post.id : nil
                             },
                             onSlap: { spot in slap(post, at: spot) },
                             onPost: { strokes in
                                 social.postDrawing(strokes, by: auth.displayName, on: post.id)
                             },
                             onDelete: { id in social.deleteDrawing(id, on: post.id) },
                             onTossed: { toss(post) })
                        .transition(.asymmetric(
                            insertion: .offset(y: -size.height).combined(with: .scale(scale: 1.15)),
                            removal: .identity))
                }
            }
        }
    }

    // MARK: - Controls under the pile

    private var controls: some View {
        VStack(spacing: 10) {
            Text(drawingPostID != nil
                 ? "Draw on the photo, then tap Post"
                 : "Flick to toss · Double-tap to slap · Hold to draw")
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.snappy, value: drawingPostID)

            HStack(spacing: 0) {
                roundButton("arrow.uturn.backward", label: "Bring back the last photo",
                            disabled: tossed.isEmpty, action: bringBack)

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        guard let top else { return }
                        slap(top, at: CGPoint(x: .random(in: 0.2...0.8), y: .random(in: 0.2...0.8)))
                    } label: {
                        let count = top.map { social.slapCount($0.id) } ?? 0
                        HStack(spacing: 6) {
                            Image(systemName: "hand.raised.fill")
                                .rotationEffect(.degrees(-20))
                                .symbolEffect(.bounce, value: slapPulse)
                            Text(count.formatted())
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(count)))
                                .animation(.smooth, value: count)
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 46)
                        .background(Color.brand, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Slap this post")

                    Button {
                        guard let top else { return }
                        drawingPostID = top.id
                    } label: {
                        Image(systemName: "pencil.tip")
                            .font(.headline)
                            .foregroundStyle(Color.brand)
                            .frame(width: 46, height: 46)
                            .background(Color.brand.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Draw on this post")
                }

                Spacer()

                roundButton("arrow.up.right", label: "Open on Facebook", disabled: top == nil) {
                    guard let top, let url = URL(string: top.permalink) else { return }
                    openURL(url)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .disabled(drawingPostID != nil || feed.posts.isEmpty)
        .opacity(drawingPostID != nil ? 0.45 : 1)
        .animation(.snappy, value: drawingPostID)
    }

    private func roundButton(_ systemImage: String, label: String, disabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(width: 46, height: 46)
                .background(Color(.systemBackground), in: Circle())
                .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(label)
    }

    // MARK: - Actions

    private func slap(_ post: NewsPost, at spot: CGPoint) {
        Haptics.slap()
        slapPulse += 1
        social.slap(post.id, at: spot)
    }

    private func toss(_ post: NewsPost) {
        tossed.append(post.id)
    }

    private func bringBack() {
        guard !tossed.isEmpty else { return }
        Haptics.soft()
        _ = withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
            tossed.removeLast()
        }
    }

    /// Shake (or the button on an empty table): every photo lands back on
    /// the pile, newest on top, and the feed checks for new posts.
    private func shuffleBack() {
        guard !tossed.isEmpty || pile.isEmpty else { return }
        Haptics.celebrate()
        withAnimation(.spring(response: 0.55, dampingFraction: 0.75)) {
            tossed = []
        }
        Task { await feed.refresh() }
    }

    // MARK: - Steps

    /// This week's steps in one slim line, linking to the Walk tab.
    private var stepsRow: some View {
        Button(action: openWalk) {
            HStack(spacing: 12) {
                if let goal = steps.goalReward {
                    RewardImage(reward: goal)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                } else {
                    Image(systemName: "figure.walk")
                        .font(.headline)
                        .foregroundStyle(Color.brand)
                        .frame(width: 40, height: 40)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(steps.stepsThisWeek.formatted()) steps this week")
                        .font(.subheadline.weight(.semibold))
                    if let goal = steps.goalReward {
                        Text(steps.stepsToGoal == 0 ? "\(goal.fullName) is ready to claim" : "\(steps.stepsToGoal.formatted()) steps to \(goal.fullName)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hairline()
    }
}

/// Cablgram's profile picture (Assets: CablgramAvatar).
struct CablgramAvatar: View {
    var size: CGFloat = 36

    var body: some View {
        Image("CablgramAvatar")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color(.separator).opacity(0.5), lineWidth: 1 / 3))
    }
}
