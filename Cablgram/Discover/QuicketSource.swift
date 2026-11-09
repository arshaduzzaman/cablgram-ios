import Foundation

/// Reads events from quicket.me through the JSON API its own website uses.
enum QuicketSource {
    private static let api = URL(string: "https://api.quicket.me/v2/events?ordering=-starts&page_size=50")!

    private struct Page: Decodable {
        let events: [Event]
    }

    private struct Event: Decodable {
        let id: Int
        let title: String
        let slug: String
        let starts: String?
        let ends: String?
        let effective_starts: String?
        let effective_ends: String?
        let venue_name: String?
        let thumbnail_url: String?
        let banner_url: String?
        let price_range: String?
        let currency_symbol: String?
        let min_price: String?
        let is_highlight: Bool?
        let event_status: String?
        let can_purchase: Bool?
        let discovery_tags: [String]?
    }

    /// Upcoming and ongoing Quicket events, newest listings first.
    static func load() async throws -> [ListedEvent] {
        var request = URLRequest(url: api)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Cablgram", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let page = try JSONDecoder().decode(Page.self, from: data)
        let now = Date.now
        return page.events
            .filter { $0.event_status == "upcoming" }
            .map { convert($0, now: now) }
    }

    private static func convert(_ e: Event, now: Date) -> ListedEvent {
        let starts = e.effective_starts ?? e.starts
        let ends = e.effective_ends ?? e.ends
        let startDate = starts.flatMap(ListedEvent.parse)
        let endDate = ends.flatMap(ListedEvent.parse)
        let happening = (startDate.map { $0 <= now } ?? false) && (endDate.map { $0 > now } ?? true)
        return ListedEvent(
            id: "quicket-\(e.id)",
            title: e.title.trimmingCharacters(in: .whitespaces),
            organizer: nil,
            status: happening ? "live" : "upcoming",
            sale: e.can_purchase == true ? "buyable" : "not_on_sale",
            categories: categories(for: e.discovery_tags ?? []),
            starts: starts,
            ends: ends,
            location: e.venue_name,
            price: price(e),
            image: e.thumbnail_url,
            banner: e.banner_url,
            featuredRank: e.is_highlight == true ? 1 : nil,
            href: "/events/\(e.slug)",
            source: "Quicket",
            link: "https://quicket.me/events/\(e.slug)"
        )
    }

    /// "Starts from ৳400" for a range, "৳500" for one price, or "Free".
    private static func price(_ e: Event) -> ListedEvent.Price? {
        guard let raw = e.min_price, let minimum = Double(raw) else { return nil }
        if minimum == 0 { return .init(label: "Admission", amount: "Free") }
        let symbol = e.currency_symbol ?? "৳"
        let amount = symbol + minimum.formatted(.number.precision(.fractionLength(0)))
        let isRange = e.price_range?.contains("-") == true
        return .init(label: isRange ? "Starts from" : "Price", amount: amount)
    }

    /// Quicket's tags, mapped onto the same categories Tickify uses so the
    /// chips cover both sites.
    private static func categories(for tags: [String]) -> [String] {
        let map: [String: String] = [
            "concert": "Concert", "live-music": "Concert", "indie-pop": "Concert", "music": "Music",
            "electronic-music": "Party", "beach-party": "Party", "nightlife": "Party", "party": "Party",
            "festival": "Festivals", "christmas": "Festivals", "wellness": "Festivals",
            "fashion-show": "Fashion Shows", "fashion-week": "Fashion Shows",
            "comedy": "Stand-up", "stand-up": "Stand-up", "open-mic": "Stand-up",
            "anime-convention": "Pop Culture", "pop-culture": "Pop Culture", "cosplay": "Pop Culture",
            "mma": "Sports", "mixed-martial-arts": "Sports", "sports": "Sports", "football": "Sports",
            "poetry": "Workshops", "workshop": "Workshops", "conference": "Conferences",
            "exhibition": "Exhibitions", "theatre": "Movie / Drama", "drama": "Movie / Drama",
        ]
        var result: [String] = []
        for tag in tags {
            if let name = map[tag], !result.contains(name) { result.append(name) }
        }
        return result
    }
}
