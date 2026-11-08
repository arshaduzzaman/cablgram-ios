import SwiftUI

struct NewsView: View {
    @StateObject private var feed = NewsFeed()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if let message = feed.errorMessage, feed.posts.isEmpty {
                        ContentUnavailableView(
                            "No news right now",
                            systemImage: "wifi.exclamationmark",
                            description: Text(message)
                        )
                        .padding(.top, 80)
                    }

                    ForEach(feed.posts) { post in
                        NewsCard(post: post)
                            .task { await feed.loadMoreIfNeeded(after: post) }
                    }

                    if feed.isLoading {
                        ProgressView().padding()
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Cablgram")
            .refreshable { await feed.refresh() }
            .task {
                if feed.posts.isEmpty { await feed.refresh() }
            }
        }
    }
}

private struct NewsCard: View {
    let post: NewsPost
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: post.permalink) { openURL(url) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
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

                HStack {
                    if let date = post.date {
                        Text(date, format: .relative(presentation: .named))
                    }
                    Spacer()
                    Label("Open", systemImage: "arrow.up.right")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(Color.brand)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(12)
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
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
    NewsView()
}
