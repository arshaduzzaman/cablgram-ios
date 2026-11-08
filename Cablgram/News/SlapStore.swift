import Foundation

/// Slap counts per post. Kept on this phone only for now; a backend can
/// replace this later without changing the views.
@MainActor
final class SlapStore: ObservableObject {
    @Published private(set) var counts: [String: Int]

    private let key = "news.slaps"

    init() {
        counts = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    func count(for postID: String) -> Int { counts[postID, default: 0] }

    func slap(_ postID: String) {
        counts[postID, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: key)
    }
}
