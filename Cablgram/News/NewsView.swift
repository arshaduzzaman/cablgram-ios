import SwiftUI

struct NewsView: View {
    var openWalk: () -> Void = {}

    @EnvironmentObject private var steps: StepStore
    @StateObject private var feed = NewsFeed()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header
                stepsShortcut

                if let message = feed.errorMessage, feed.posts.isEmpty {
                    ContentUnavailableView("No news right now",
                                           systemImage: "wifi.exclamationmark",
                                           description: Text(message))
                        .padding(.top, 60)
                }

                ForEach(feed.posts) { post in
                    NewsCard(post: post)
                        .task { await feed.loadMoreIfNeeded(after: post) }
                }

                if feed.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { await feed.refresh() }
        .task {
            if feed.posts.isEmpty { await feed.refresh() }
        }
    }

    private var header: some View {
        Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 12)
    }

    /// Today's steps, linking to the Walk tab.
    private var stepsShortcut: some View {
        Button(action: openWalk) {
            HStack(spacing: 12) {
                Image(systemName: "figure.walk")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.brandGradient, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(steps.stepsToday.formatted()) steps today")
                        .font(.subheadline.weight(.semibold))
                    if let next = steps.nextReward {
                        Text("\((next.steps - steps.totalSteps).formatted()) to go for \(next.fullName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .card(cornerRadius: 20)
        }
        .buttonStyle(.plain)
    }
}

private struct NewsCard: View {
    let post: NewsPost
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if let url = URL(string: post.permalink) { openURL(url) }
            } label: {
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
            }
            .buttonStyle(.plain)

            HStack(spacing: 14) {
                if let date = post.date {
                    Text(date, format: .relative(presentation: .named))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let url = URL(string: post.permalink) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Button { openURL(url) } label: {
                        Image(systemName: "arrow.up.right")
                    }
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.brand)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .card()
    }

    private func placeholder(systemImage: String?) -> some View {
        ZStack {
            Color(.tertiarySystemFill)
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

#Preview {
    NewsView().environmentObject(StepStore())
}
