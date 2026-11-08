import SwiftUI

/// Cablgram's posts as a Threads-style feed: flat rows, hairlines between
/// them, and a slap counter on each post.
struct NewsView: View {
    var openWalk: () -> Void = {}

    @EnvironmentObject private var steps: StepStore
    @StateObject private var feed = NewsFeed()
    @StateObject private var slaps = SlapStore()
    @StateObject private var drawings = DrawingStore()
    @State private var drawingOn: NewsPost?

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
                            strokes: drawings.strokes(for: post.id),
                            onSlap: { slaps.slap(post.id) },
                            onDraw: { drawingOn = post })
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
        .background(Color(.systemBackground))
        .refreshable {
            Haptics.soft()
            await feed.refresh()
        }
        .task {
            if feed.posts.isEmpty { await feed.refresh() }
        }
        .fullScreenCover(item: $drawingOn) { post in
            DrawingEditor(imageURL: URL(string: post.imageUrl),
                          strokes: drawings.strokes(for: post.id),
                          onDone: { strokes in
                              drawings.save(strokes, for: post.id)
                              drawingOn = nil
                          },
                          onCancel: { drawingOn = nil })
        }
    }

    /// Today's steps in one slim line, linking to the Walk tab.
    private var stepsRow: some View {
        Button(action: openWalk) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Color(.systemFill), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: steps.goalReward.map { min(Double(steps.totalSteps) / Double($0.steps), 1) } ?? 1)
                        .stroke(Color.brand, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "figure.walk")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.brand)
                }
                .frame(width: 30, height: 30)

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

/// One post: Cablgram's avatar on the left, then name, time, photo and the
/// slap button, like a Threads post.
private struct PostRow: View {
    let post: NewsPost
    let slapCount: Int
    let strokes: [Stroke]
    let onSlap: () -> Void
    let onDraw: () -> Void

    @State private var showBurst = false

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
                        Haptics.tap()
                        onDraw()
                    } label: {
                        Image(systemName: strokes.isEmpty ? "pencil.tip.crop.circle" : "pencil.tip.crop.circle.fill")
                            .font(.system(size: 21))
                            .foregroundStyle(strokes.isEmpty ? Color.primary : Color.brand)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(strokes.isEmpty ? "Draw on this post" : "Edit your drawing")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var photo: some View {
        AsyncImage(url: URL(string: post.imageUrl)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
                    .overlay { DoodleCanvas(strokes: strokes) }
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
                .stroke(Color(.separator).opacity(0.5), lineWidth: 1 / 3)
        )
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
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            slap()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { showBurst = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(650))
                withAnimation(.easeOut(duration: 0.2)) { showBurst = false }
            }
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

#Preview {
    NewsView().environmentObject(StepStore())
}
