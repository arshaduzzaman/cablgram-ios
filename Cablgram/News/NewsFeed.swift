import Foundation

/// One Cablgram post: the same mirrored Facebook posts the website shows.
struct NewsPost: Codable, Identifiable, Hashable {
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

private struct NewsPage: Codable {
    let posts: [NewsPost]
    /// Pass back as `before` for the next page; `nil` when there is none.
    let nextBefore: String?
}

/// The Nutshell API wraps pages as `{ success, data: { posts, nextBefore } }`.
private struct NutshellResponse: Decodable {
    let data: NewsPage
}

/// Loads Cablgram's posts.
///
/// Reads straight from the Nutshell API that mirrors the Facebook Page
/// (the website's own source, answers in well under a second), and falls
/// back to www.cablgram.com/api/facebook-posts if that fails. The first page
/// is saved on the phone, so the feed shows instantly on the next launch
/// while fresh posts load.
@MainActor
final class NewsFeed: ObservableObject {
    @Published private(set) var posts: [NewsPost] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var nextBefore: String?
    private var reachedEnd = false

    private let nutshell = URL(string: "https://nutshell-server.onrender.com/cablgram/facebook-posts")!
    private let website = URL(string: "https://www.cablgram.com/api/facebook-posts")!
    private static let pageSize = 24

    private static let savedURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("news-first-page.json")
    }()

    init() {
        // Last time's first page, so there's something to read right away.
        if let data = try? Data(contentsOf: Self.savedURL),
           let page = try? JSONDecoder().decode(NewsPage.self, from: data) {
            posts = page.posts
            nextBefore = page.nextBefore
            reachedEnd = page.nextBefore == nil
        }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await fetch(before: nil)
            posts = page.posts
            nextBefore = page.nextBefore
            reachedEnd = page.nextBefore == nil
            errorMessage = nil
            if let data = try? JSONEncoder().encode(page) {
                try? data.write(to: Self.savedURL, options: .atomic)
            }
        } catch {
            if posts.isEmpty { errorMessage = "Couldn't load the news. Pull down to try again." }
        }
    }

    /// Loads the next page, if there is one.
    func loadMore() async {
        guard !isLoading, !reachedEnd, let before = nextBefore else { return }
        isLoading = true
        defer { isLoading = false }
        guard let page = try? await fetch(before: before) else { return }
        let known = Set(posts.map(\.id))
        posts += page.posts.filter { !known.contains($0.id) }
        nextBefore = page.nextBefore
        reachedEnd = page.nextBefore == nil
    }

    /// Nutshell first; the website if Nutshell is down.
    private func fetch(before: String?) async throws -> NewsPage {
        do {
            var direct = URLComponents(url: nutshell, resolvingAgainstBaseURL: false)!
            direct.queryItems = [URLQueryItem(name: "limit", value: String(Self.pageSize))]
                + (before.map { [URLQueryItem(name: "before", value: $0)] } ?? [])
            let data = try await get(direct.url!, timeout: 10)
            return try JSONDecoder().decode(NutshellResponse.self, from: data).data
        } catch {
            var site = URLComponents(url: website, resolvingAgainstBaseURL: false)!
            site.queryItems = before.map { [URLQueryItem(name: "before", value: $0)] }
            let data = try await get(site.url!, timeout: 45)
            return try JSONDecoder().decode(NewsPage.self, from: data)
        }
    }

    private func get(_ url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
