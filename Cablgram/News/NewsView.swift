import SwiftUI

/// Cablgram's posts as a Threads-style feed: flat rows, hairlines between
/// them, and a slap counter on each post.
struct NewsView: View {
    var openWalk: () -> Void = {}

    @EnvironmentObject private var steps: StepStore
    @StateObject private var feed = NewsFeed()
    @StateObject private var slaps = SlapStore()
    @AppStorage("walk.dailyGoal") private var dailyGoal = 8_000

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
                    PostRow(post: post, slapCount: slaps.count(for: post.id)) {
                        slaps.slap(post.id)
                    }
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
    }

    /// Today's steps in one slim line, linking to the Walk tab.
    private var stepsRow: some View {
        Button(action: openWalk) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Color(.systemFill), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: min(Double(steps.stepsToday) / Double(dailyGoal), 1))
                        .stroke(Color.brand, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "figure.walk")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.brand)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(steps.stepsToday.formatted()) steps today")
                        .font(.subheadline.weight(.semibold))
                    if let next = steps.nextReward {
                        Text("\((next.steps - steps.totalSteps).formatted()) to \(next.fullName)")
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
    let onSlap: () -> Void

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

                SlapButton(count: slapCount, action: slap)
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

/// Pink circle with a white Helvetica "c", Cablgram's avatar in the feed.
struct CablgramAvatar: View {
    var size: CGFloat = 36

    var body: some View {
        CablgramLogo(size: size * 0.27)
            .frame(width: size, height: size)
            .background(Color.brand, in: Circle())
    }
}

#Preview {
    NewsView().environmentObject(StepStore())
}
