import Foundation

/// One event listed on tickify.live.
struct TickifyEvent: Codable, Identifiable, Hashable {
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

    var isLive: Bool { status == "live" }
    var startDate: Date? { starts.flatMap(Self.parse) }
    var endDate: Date? { ends.flatMap(Self.parse) }

    var pageURL: URL? { URL(string: "https://tickify.live" + href) }
    var imageURL: URL? { Self.absolute(image) }
    var bannerURL: URL? { Self.absolute(banner) ?? imageURL }

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

    private static func parse(_ text: String) -> Date? {
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

/// Events from tickify.live, Bangladesh's ticketing site.
///
/// Tickify has no public API, so this reads its public /events page the way
/// a browser does: the page carries the full event list as data for its own
/// event browser, which is pulled out and decoded. The last list is saved on
/// the phone so the tab opens instantly. Tickets are bought on Tickify; the
/// app only links to each event's page.
@MainActor
final class EventStore: ObservableObject {
    @Published private(set) var events: [TickifyEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private static let source = URL(string: "https://tickify.live/events")!
    private static let savedURL: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tickify-events.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.savedURL),
           let saved = try? JSONDecoder().decode([TickifyEvent].self, from: data) {
            events = saved
        }
    }

    /// Events you can still go to: happening now first, then soonest first.
    var current: [TickifyEvent] {
        let now = Date.now
        return events
            .filter { ($0.status == "live" || $0.status == "upcoming") && ($0.endDate ?? .distantFuture) > now }
            .sorted { a, b in
                if a.isLive != b.isLive { return a.isLive }
                return (a.startDate ?? .distantFuture) < (b.startDate ?? .distantFuture)
            }
    }

    /// Tickify's own featured picks, in their order.
    var featured: [TickifyEvent] {
        current.filter { $0.featuredRank != nil }.sorted { ($0.featuredRank ?? 0) < ($1.featuredRank ?? 0) }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var request = URLRequest(url: Self.source)
            request.timeoutInterval = 30
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Cablgram", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { throw URLError(.badServerResponse) }
            let list = try await Task.detached { try Self.extractEvents(from: html) }.value
            events = list
            errorMessage = nil
            if let saved = try? JSONEncoder().encode(list) {
                try? saved.write(to: Self.savedURL, options: .atomic)
            }
        } catch {
            if events.isEmpty { errorMessage = "Couldn't load events from Tickify. Pull down to try again." }
        }
    }

    // MARK: - Reading the page

    enum ParseError: Error { case noEventList }

    /// Next.js pages ship their data as `self.__next_f.push([1,"…"])` chunks.
    /// Joined together they hold `{"events":[…]}` for the event browser.
    nonisolated static func extractEvents(from html: String) throws -> [TickifyEvent] {
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
        let events = try JSONDecoder().decode([TickifyEvent].self, from: Data(array.utf8))
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
