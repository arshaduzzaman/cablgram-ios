import SwiftUI

/// Cablgram's posts as a Threads-style feed: flat rows, hairlines between
/// them, a slap counter, and drawings people leave on each post.
struct NewsView: View {
    var openWalk: () -> Void = {}

    @EnvironmentObject private var steps: StepStore
    @EnvironmentObject private var auth: AuthStore
    @StateObject private var feed = NewsFeed()
    @StateObject private var slaps = SlapStore()
    @StateObject private var drawings = DrawingStore()
    /// The post whose photo is being drawn on, if any. Scrolling pauses meanwhile.
    @State private var drawingPostID: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                stepsRow

                if let message = feed.errorMessage, feed.posts.isEmpty {
                    ContentUnavailableView("No news right now",
                                           systemImage: "wifi.exclamationmark",
                                           description: Text(message))
                        .padding(.top, 60)
                }

                ForEach(feed.posts) { post in
                    PostRow(post: post,
                            slapCount: slaps.count(for: post.id),
                            comments: drawings.comments(for: post.id),
                            isDrawing: drawingPostID == post.id,
                            onSlap: { slaps.slap(post.id) },
                            onDrawingChange: { drawing in
                                drawingPostID = drawing ? post.id : (drawingPostID == post.id ? nil : drawingPostID)
                            },
                            onPost: { strokes in
                                drawings.post(strokes, by: auth.displayName, on: post.id)
                            },
                            onDelete: { id in drawings.delete(id, on: post.id) })
                    .hairline()
                    .task { await feed.loadMoreIfNeeded(after: post) }
                }

                if feed.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(24)
                }
            }
        }
        .scrollDisabled(drawingPostID != nil)
        .background(Color(.systemBackground))
        .refreshable {
            Haptics.soft()
            await feed.refresh()
        }
        .task {
            if feed.posts.isEmpty { await feed.refresh() }
        }
    }

    /// This week's steps in one slim line, linking to the Walk tab.
    private var stepsRow: some View {
        Button(action: openWalk) {
            HStack(spacing: 12) {
                if let goal = steps.goalReward {
                    RewardImage(reward: goal)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: "figure.walk")
                        .font(.headline)
                        .foregroundStyle(Color.brand)
                        .frame(width: 44, height: 44)
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
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hairline()
    }
}

/// One post: Cablgram's avatar on the left, then name, time, photo, slap and
/// draw buttons, and the drawings people left, like a Threads post.
///
/// Press and hold the photo to draw on it right there; the same touch keeps
/// drawing, and scrolling is never blocked unless you're holding still.
/// Post adds the drawing under the post.
private struct PostRow: View {
    let post: NewsPost
    let slapCount: Int
    let comments: [DoodleComment]
    let isDrawing: Bool
    let onSlap: () -> Void
    let onDrawingChange: (Bool) -> Void
    let onPost: ([Stroke]) -> Void
    let onDelete: (UUID) -> Void

    @State private var showBurst = false
    @State private var shownCommentID: UUID?

    // Drawing in progress
    @State private var draft: [Stroke] = []
    @State private var current: Stroke?
    @State private var ink: InkColor = .pink
    @State private var haptics = DrawHaptics()
    @State private var lastPoint: CGPoint?
    @State private var lastTime: Date?
    @State private var lastAngle: CGFloat?

    private let brush = BrushSize.medium

    /// The drawing shown on the photo when not drawing: the one picked below, or the newest.
    private var shownComment: DoodleComment? {
        comments.first { $0.id == shownCommentID } ?? comments.last
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CablgramAvatar(size: 36)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    Text("cablgram")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.brand)
                    if let date = post.date {
                        Text(Self.shortAge(date))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                photo

                HStack(spacing: 14) {
                    SlapButton(count: slapCount, action: slap)
                    Button {
                        guard !isDrawing else { return }
                        beginDrawing()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: comments.isEmpty ? "pencil.tip.crop.circle" : "pencil.tip.crop.circle.fill")
                                .font(.system(size: 21))
                                .foregroundStyle(comments.isEmpty ? Color.primary : Color.brand)
                            if !comments.isEmpty {
                                Text(comments.count.formatted())
                                    .font(.subheadline.weight(.medium).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Draw on this post")

                    Spacer()

                    if comments.isEmpty && !isDrawing {
                        Text("Hold the photo to draw")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if !comments.isEmpty {
                    drawingsSection
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .onChange(of: isDrawing) { _, drawing in
            if !drawing { resetDraft() }
        }
    }

    // MARK: - Photo

    private var photo: some View {
        AsyncImage(url: URL(string: post.imageUrl)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
                    .overlay {
                        ZStack {
                            DoodleCanvas(strokes: isDrawing ? draft : (shownComment?.strokes ?? []),
                                         current: current)
                            DrawTouchLayer(isDrawing: isDrawing,
                                           onHoldBegan: { if !isDrawing { beginDrawing() } },
                                           onStroke: { point, size, time in continueStroke(at: point, time: time, in: size) },
                                           onStrokeEnded: endStroke,
                                           onDoubleTap: doubleTapSlap)
                        }
                    }
                    .overlay {
                        if isDrawing { drawControls }
                    }
            case .failure:
                placeholder(systemImage: "photo")
            default:
                placeholder(systemImage: nil)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isDrawing ? Color.brand : Color(.separator).opacity(0.5),
                        lineWidth: isDrawing ? 3 : 1 / 3)
        )
        .scaleEffect(isDrawing ? 1.01 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDrawing)
        .overlay {
            // Big hand that pops up on a double-tap, like Instagram's heart.
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 84))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(-20))
                .shadow(color: .black.opacity(0.25), radius: 8)
                .scaleEffect(showBurst ? 1 : 0.4)
                .opacity(showBurst ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    /// Colours, undo, cancel and Post, sitting on the photo while drawing.
    private var drawControls: some View {
        VStack {
            HStack {
                Button {
                    if !draft.isEmpty { haptics.wipe() } else { Haptics.tap() }
                    onDrawingChange(false)
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(0.55), in: Circle())
                }
                Spacer()
                Button {
                    guard !draft.isEmpty else { return }
                    Haptics.celebrate()
                    onPost(draft)
                    shownCommentID = nil
                    onDrawingChange(false)
                } label: {
                    Text("Post")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(draft.isEmpty ? Color.brand.opacity(0.5) : Color.brand, in: Capsule())
                }
                .disabled(draft.isEmpty)
            }

            Spacer()

            HStack(spacing: 10) {
                ForEach(InkColor.allCases) { option in
                    Button {
                        guard ink != option else { return }
                        haptics.pick()
                        ink = option
                    } label: {
                        Circle()
                            .fill(option.color)
                            .frame(width: 22, height: 22)
                            .overlay(Circle().stroke(.white, lineWidth: ink == option ? 2.5 : 1))
                            .scaleEffect(ink == option ? 1.18 : 1)
                            .animation(.snappy, value: ink)
                    }
                }
                Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 20)
                Button {
                    guard !draft.isEmpty else { return }
                    haptics.undo()
                    withAnimation(.snappy) { _ = draft.removeLast() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white.opacity(draft.isEmpty ? 0.4 : 1))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
        }
        .padding(10)
        .transition(.opacity)
    }

    // MARK: - Drawings section

    private var drawingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(comments.count == 1 ? "1 drawing" : "\(comments.count) drawings")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(comments.reversed()) { comment in
                        let isShown = comment.id == shownComment?.id
                        Button {
                            Haptics.select()
                            withAnimation(.snappy) { shownCommentID = comment.id }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                AsyncImage(url: URL(string: post.imageUrl)) { phase in
                                    if let image = phase.image {
                                        image.resizable().scaledToFit()
                                            .overlay { DoodleCanvas(strokes: comment.strokes) }
                                    } else {
                                        Color(.secondarySystemBackground).aspectRatio(1, contentMode: .fit)
                                    }
                                }
                                .frame(height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(isShown ? Color.brand : Color(.separator).opacity(0.5),
                                                lineWidth: isShown ? 2 : 1 / 3)
                                )
                                HStack(spacing: 4) {
                                    Text(comment.author.components(separatedBy: " ").first ?? comment.author)
                                        .font(.caption2.weight(.semibold))
                                    Text(Self.shortAge(comment.date))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                Haptics.warning()
                                onDelete(comment.id)
                            } label: {
                                Label("Delete drawing", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Drawing

    private func beginDrawing() {
        haptics.pickUp()
        draft = []
        onDrawingChange(true)
    }

    private func continueStroke(at point: CGPoint, time: Date, in size: CGSize) {
        let normalized = CGPoint(x: min(max(point.x / size.width, 0), 1),
                                 y: min(max(point.y / size.height, 0), 1))
        guard current != nil, let last = lastPoint, let lastTime else {
            current = Stroke(points: [normalized], color: ink, width: brush.rawValue)
            lastPoint = point
            self.lastTime = time
            lastAngle = nil
            haptics.strokeBegan(brush: brush)
            return
        }
        let dx = point.x - last.x, dy = point.y - last.y
        let distance = hypot(dx, dy)
        guard distance >= 1.5 else { return }
        let seconds = max(time.timeIntervalSince(lastTime), 0.004)
        let angle = atan2(dy, dx)
        var turn: CGFloat = 0
        if let lastAngle {
            turn = abs(angle - lastAngle)
            if turn > .pi { turn = 2 * .pi - turn }
        }
        current?.points.append(normalized)
        haptics.strokeMoved(distance: distance, speed: distance / seconds, turn: turn, brush: brush)
        lastPoint = point
        self.lastTime = time
        lastAngle = angle
    }

    private func endStroke() {
        if let current { draft.append(current) }
        current = nil
        lastPoint = nil
        lastTime = nil
        lastAngle = nil
        haptics.strokeEnded()
    }

    private func resetDraft() {
        draft = []
        current = nil
        haptics.stop()
    }

    // MARK: - Slaps

    private func doubleTapSlap() {
        guard !isDrawing else { return }
        slap()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { showBurst = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.easeOut(duration: 0.2)) { showBurst = false }
        }
    }

    private func slap() {
        Haptics.slap()
        onSlap()
    }

    private func placeholder(systemImage: String?) -> some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// "now", "5m", "3h", "2d", or a date for older posts.
    static func shortAge(_ date: Date) -> String {
        let seconds = max(0, Int(-date.timeIntervalSinceNow))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        case ..<604_800: return "\(seconds / 86_400)d"
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}

/// Hand icon and count. Every tap adds a slap.
private struct SlapButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: count > 0 ? "hand.raised.fill" : "hand.raised")
                    .font(.system(size: 19))
                    .rotationEffect(.degrees(-20))
                    .foregroundStyle(count > 0 ? Color.brand : .primary)
                    .symbolEffect(.bounce, value: count)
                if count > 0 {
                    Text(count.formatted())
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            .padding(.vertical, 6)
            .padding(.trailing, 10)
            .contentShape(Rectangle())
            .animation(.snappy, value: count)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count == 1 ? "1 slap" : "\(count) slaps")
        .accessibilityHint("Slap this post")
    }
}

/// Cablgram's profile picture in the feed (Assets: CablgramAvatar).
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
