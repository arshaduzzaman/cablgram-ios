import Foundation

/// One event from a ticketing site (Tickify or Quicket), in one shape.
struct ListedEvent: Codable, Identifiable, Hashable {
    struct Price: Codable, Hashable {
        let label: String?
        let amount: String?
    }

    let id: String
    let title: String
    let organizer: String?
    /// live, upcoming, ended, postponed or cancelled.
    let status: String?
    /// buyable, not_on_sale, sales_closed or sold_out.
    let sale: String?
    let categories: [String]?
    let starts: String?
    let ends: String?
    let location: String?
    let price: Price?
    let image: String?
    let banner: String?
    let featuredRank: Int?
    /// Path of the event page on tickify.live, e.g. /o/tickify/art-dhaka.
    let href: String
    /// Which site it's from ("Tickify" when missing, for older saved lists).
    var source: String? = nil
    /// Full event page link, when it isn't on tickify.live.
    var link: String? = nil

    var sourceName: String { source ?? "Tickify" }

    var isLive: Bool { status == "live" }
    var startDate: Date? { starts.flatMap(Self.parse) }
    var endDate: Date? { ends.flatMap(Self.parse) }

    var pageURL: URL? { link.flatMap(URL.init(string:)) ?? URL(string: "https://tickify.live" + href) }
    /// The square poster, or the banner when an event has no poster.
    var imageURL: URL? { Self.absolute(image) ?? Self.absolute(banner) }
    var bannerURL: URL? { Self.absolute(banner) ?? Self.absolute(image) }

    /// "From ৳350", "Free", "Sold out"…
    var priceText: String? {
        switch sale {
        case "sold_out": return "Sold out"
        case "sales_closed": return "Sales closed"
        default: break
        }
        guard let amount = price?.amount, !amount.isEmpty else { return nil }
        if amount.lowercased() == "free" { return "Free" }
        return price?.label?.lowercased().hasPrefix("starts") == true ? "From \(amount)" : amount
    }

    var canBuy: Bool { sale == "buyable" }

    /// "Thu 13 Nov · 6:00 PM" in Dhaka time; multi-day events show the range.
    var whenText: String {
        guard let start = startDate else { return "" }
        let day = Date.FormatStyle(timeZone: Self.dhaka).weekday(.abbreviated).day().month(.abbreviated)
        let time = Date.FormatStyle(timeZone: Self.dhaka).hour().minute()
        if let end = endDate, !Self.sameDay(start, end) {
            return "\(start.formatted(day)) – \(end.formatted(day))"
        }
        return "\(start.formatted(day)) · \(start.formatted(time))"
    }

    static let dhaka = TimeZone(identifier: "Asia/Dhaka") ?? .current

    private static func sameDay(_ a: Date, _ b: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = dhaka
        return calendar.isDate(a, inSameDayAs: b)
    }

    static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private static func absolute(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: "https://tickify.live" + (path.hasPrefix("/") ? path : "/" + path))
    }
}

/// Events from Bangladesh's ticketing sites, merged into one list:
///
/// - **Tickify** (tickify.live) has no public API, so its public /events
///   page is read the way a browser does: the page carries the full event
///   list as data for its own event browser, which is pulled out and decoded.
/// - **Quicket** (quicket.me) has a JSON API its website uses
///   (api.quicket.me/v2/events), read newest first.
///
/// Both load at once; if one fails the other still shows. Same-name events
/// listed on both appear once. The last list is saved on the phone so the
/// tab opens instantly. Tickets are bought on the sites; the app only links
/// to each event's page.
@MainActor
final class EventStore: ObservableObject {
    @Published private(set) var events: [ListedEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private static let source = URL(string: "https://tickify.live/events")!
    private static let savedURL: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tickify-events.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.savedURL),
           let saved = try? JSONDecoder().decode([ListedEvent].self, from: data) {
            events = saved
        }
    }

    /// Events you can still go to: happening now first, then soonest first.
    var current: [ListedEvent] {
        let now = Date.now
        return events
            .filter { ($0.status == "live" || $0.status == "upcoming") && ($0.endDate ?? .distantFuture) > now }
            .sorted { a, b in
                if a.isLive != b.isLive { return a.isLive }
                return (a.startDate ?? .distantFuture) < (b.startDate ?? .distantFuture)
            }
    }

    /// The sites' own featured picks (Tickify's featured, Quicket's
    /// highlights), soonest first.
    var featured: [ListedEvent] {
        current.filter { $0.featuredRank != nil }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        async let tickify = try? Self.loadTickify()
        async let quicket = try? QuicketSource.load()
        let fromTickify = await tickify ?? []
        let fromQuicket = await quicket ?? []
        guard !fromTickify.isEmpty || !fromQuicket.isEmpty else {
            if events.isEmpty { errorMessage = "Couldn't load events. Pull down to try again." }
            return
        }
        // Keep what loaded last time from a site that's down right now.
        let tickifyList = fromTickify.isEmpty ? events.filter { $0.sourceName == "Tickify" } : fromTickify
        let quicketList = fromQuicket.isEmpty ? events.filter { $0.sourceName == "Quicket" } : fromQuicket

        let seen = Set(tickifyList.map { Self.key($0.title) })
        let list = tickifyList + quicketList.filter { !seen.contains(Self.key($0.title)) }
        events = list
        errorMessage = nil
        if let saved = try? JSONEncoder().encode(list) {
            try? saved.write(to: Self.savedURL, options: .atomic)
        }
    }

    /// Titles compared without case, spaces or punctuation.
    private static func key(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private nonisolated static func loadTickify() async throws -> [ListedEvent] {
        var request = URLRequest(url: source)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Cablgram", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { throw URLError(.badServerResponse) }
        return try extractEvents(from: html)
    }

    // MARK: - Reading the page

    enum ParseError: Error { case noEventList }

    /// Next.js pages ship their data as `self.__next_f.push([1,"…"])` chunks.
    /// Joined together they hold `{"events":[…]}` for the event browser.
    nonisolated static func extractEvents(from html: String) throws -> [ListedEvent] {
        let pattern = #"self\.__next_f\.push\(\[1,"((?:[^"\\]|\\.)*)"\]\)"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let ns = html as NSString
        var payload = ""
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let literal = "\"" + ns.substring(with: match.range(at: 1)) + "\""
            if let data = literal.data(using: .utf8),
               let chunk = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
                payload += chunk
            }
        }
        guard let start = payload.range(of: #"{"events":["#) else { throw ParseError.noEventList }
        let array = try matchingArray(in: payload, from: payload.index(before: start.upperBound))
        let events = try JSONDecoder().decode([ListedEvent].self, from: Data(array.utf8))
        guard !events.isEmpty else { throw ParseError.noEventList }
        return events
    }

    /// The JSON array starting at `open` (a "["), skipping brackets inside strings.
    private nonisolated static func matchingArray(in text: String, from open: String.Index) throws -> Substring {
        var depth = 0
        var inString = false
        var escaped = false
        var index = open
        while index < text.endIndex {
            let c = text[index]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "[" {
                depth += 1
            } else if c == "]" {
                depth -= 1
                if depth == 0 { return text[open...index] }
            }
            index = text.index(after: index)
        }
        throw ParseError.noEventList
    }
}
