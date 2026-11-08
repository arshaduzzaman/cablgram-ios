import Foundation

/// One Cablgram post, as served by www.cablgram.com/api/facebook-posts —
/// the same feed the website's home page shows.
struct NewsPost: Decodable, Identifiable, Hashable {
    let id: String
    /// Mirrored image (the platform's own image links expire).
    let imageUrl: String
    /// ISO-8601 publish time.
    let time: String
    /// Link to the original post.
    let permalink: String

    var date: Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: time) ?? ISO8601DateFormatter().date(from: time)
    }
}

private struct NewsPage: Decodable {
    let posts: [NewsPost]
    /// Pass back as `before` for the next page; `nil` when there is none.
    let nextBefore: String?
}

@MainActor
final class NewsFeed: ObservableObject {
    @Published private(set) var posts: [NewsPost] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var nextBefore: String?
    private var reachedEnd = false
    private let endpoint = URL(string: "https://www.cablgram.com/api/facebook-posts")!

    func refresh() async {
        nextBefore = nil
        reachedEnd = false
        await loadPage(replacing: true)
    }

    /// Loads the next page when the last post scrolls into view.
    func loadMoreIfNeeded(after post: NewsPost) async {
        guard post.id == posts.last?.id else { return }
        await loadPage(replacing: false)
    }

    private func loadPage(replacing: Bool) async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        if let nextBefore {
            components.queryItems = [URLQueryItem(name: "before", value: nextBefore)]
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let page = try JSONDecoder().decode(NewsPage.self, from: data)
            posts = replacing ? page.posts : posts + page.posts
            nextBefore = page.nextBefore
            reachedEnd = page.nextBefore == nil
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load the news. Pull down to try again."
        }
    }
}
