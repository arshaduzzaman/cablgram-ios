import SwiftUI

/// Things the app reads from the server instead of having them built in, so they can change
/// without an app update: the newest build (for "Update available"), prices and limits,
/// wording, what's switched on, and the sponsors on the Walk page. Edited on the dashboard
/// (cablgram-admin → App and Sponsors; see lib/app-config.ts there).
///
/// Every value has a built-in default, used until the first answer arrives and for any field
/// the server doesn't send. To move something else to the server: add it here with its
/// default, read it in `init(json:)`, and add it to the dashboard.
struct AppSettings: Equatable {
    struct Update: Equatable {
        /// The newest build out, and the oldest still allowed in (0 for no limit).
        var latest = 0
        var minimum = 0
        var url = "itms-beta://beta.itunes.apple.com/v1/app/6837301681"
        var message = "A newer Cablgram is out, with fixes and new things to walk for."
    }

    var update = Update()
    var headlineMinimumSteps = 500
    var headlineOutbidBy = 100
    var headlineMaxLength = 80
    var eggChips = ["Get moving 😤", "Couch potato 🥔", "I'm catching up 👀", "Walk with me?"]
    var signInSubtitle = "Steps turn into food, games and a PS5."
    var raceNote = "Faded walkers haven't sent steps for a while and may be further ahead. Steps count only if they reach Cablgram by midday the next day."
    var timedRaceNote = "Only steps walked in this period count, minus any you spend. Faded walkers haven't sent steps for a while."
    var raceCatchUpSteps = 1_000
    var raceStaleMinutes = 60
    var showDiscover = true
    var showSponsors = true
    var sponsorContact = "mailto:sponsors@cablgram.com?subject=Sponsor%20a%20spot%20on%20Cablgram"
    var sponsors: [Sponsor] = []

    init() {}

    /// The server's answer; anything missing or of the wrong kind keeps its default.
    init(json: [String: Any]) {
        func map(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
        func int(_ value: Any?, _ fallback: Int) -> Int { (value as? NSNumber)?.intValue ?? fallback }
        func text(_ value: Any?, _ fallback: String) -> String {
            guard let text = value as? String, !text.isEmpty else { return fallback }
            return text
        }
        func flag(_ value: Any?, _ fallback: Bool) -> Bool { value as? Bool ?? fallback }

        let update = map(json["update"]), ios = map(update["ios"])
        self.update.latest = int(ios["latest"], 0)
        self.update.minimum = int(ios["minimum"], 0)
        self.update.url = text(ios["url"], self.update.url)
        self.update.message = text(update["message"], self.update.message)

        let headline = map(json["headline"])
        headlineMinimumSteps = int(headline["minimumSteps"], headlineMinimumSteps)
        headlineOutbidBy = max(int(headline["outbidBy"], headlineOutbidBy), 1)
        headlineMaxLength = max(int(headline["maxLength"], headlineMaxLength), 10)

        if let chips = json["eggChips"] as? [String], !chips.isEmpty { eggChips = chips }

        let words = map(json["text"])
        signInSubtitle = text(words["signInSubtitle"], signInSubtitle)
        raceNote = text(words["raceNote"], raceNote)
        timedRaceNote = text(words["timedRaceNote"], timedRaceNote)

        let race = map(json["race"])
        raceCatchUpSteps = max(int(race["catchUpSteps"], raceCatchUpSteps), 100)
        raceStaleMinutes = max(int(race["staleMinutes"], raceStaleMinutes), 5)

        let show = map(json["show"])
        showDiscover = flag(show["discover"], true)
        showSponsors = flag(show["sponsors"], true)

        sponsorContact = text(json["sponsorContact"], sponsorContact)
        sponsors = (json["sponsors"] as? [[String: Any]] ?? []).compactMap(Sponsor.init(json:))
    }
}

/// Loads `AppSettings` from `GET /api/app/config` when the app opens and each time it comes
/// back to the front (at most every few minutes), and keeps the last answer on the phone so
/// the next launch starts with it.
@MainActor
final class AppConfig: ObservableObject {
    static let shared = AppConfig()

    @Published private(set) var settings: AppSettings

    /// The settings right now, for code that isn't a view. Views that should redraw when
    /// they change watch `AppConfig.shared` instead.
    nonisolated static var current: AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var snapshot = AppSettings()

    private static let url = Backend.url("/api/app/config")
    private static let savedURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("app-config.json")
    private static let minGap: TimeInterval = 3 * 60
    private var lastLoad: Date?
    private var loading = false

    /// This build's number (CFBundleVersion).
    static let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0

    private init() {
        let saved = (try? Data(contentsOf: Self.savedURL)).flatMap(Self.parse) ?? AppSettings()
        settings = saved
        Self.publish(saved)
    }

    /// This build is older than the oldest one allowed: nothing works until it's updated.
    var mustUpdate: Bool { Self.build > 0 && Self.build < settings.update.minimum }
    /// A newer build is out.
    var updateAvailable: Bool { Self.build > 0 && Self.build < settings.update.latest }

    func refresh(force: Bool = false) async {
        if loading { return }
        if !force, let lastLoad, Date().timeIntervalSince(lastLoad) < Self.minGap { return }
        loading = true
        defer { loading = false }
        var request = URLRequest(url: Self.url, timeoutInterval: 15)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let fresh = Self.parse(data) else { return }
        lastLoad = Date()
        try? data.write(to: Self.savedURL, options: .atomic)
        guard fresh != settings else { return }
        settings = fresh
        Self.publish(fresh)
    }

    /// Opens where this build is updated (TestFlight or the App Store).
    func openUpdate() {
        let fallback = URL(string: "https://testflight.apple.com")!
        guard let url = URL(string: settings.update.url) else {
            UIApplication.shared.open(fallback)
            return
        }
        UIApplication.shared.open(url) { opened in
            if !opened { UIApplication.shared.open(fallback) }
        }
    }

    nonisolated private static func parse(_ data: Data) -> AppSettings? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).map(AppSettings.init(json:))
    }

    nonisolated private static func publish(_ settings: AppSettings) {
        lock.lock()
        snapshot = settings
        lock.unlock()
    }
}

// MARK: - Update prompt

/// Shown instead of the app when this build is older than the oldest one allowed.
struct UpdateRequiredView: View {
    @ObservedObject private var config = AppConfig.shared

    var body: some View {
        ZStack {
            Color.brand.ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                CablgramLogo(size: 56)
                Text("Time to update")
                    .font(.title2.weight(.bold))
                Text(config.settings.update.message)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .opacity(0.9)
                Text("This version of Cablgram no longer works.")
                    .font(.footnote)
                    .opacity(0.75)
                Spacer()
                Button {
                    Haptics.tap()
                    config.openUpdate()
                } label: {
                    Text("Update")
                        .font(.headline)
                        .foregroundStyle(Color.brand)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(28)
        }
    }
}

/// "Update available", once per new build: shown again only when a newer one comes out.
struct UpdatePrompt: ViewModifier {
    @ObservedObject private var config = AppConfig.shared
    @AppStorage("update.dismissedBuild") private var dismissed = 0
    @State private var showing = false

    private var due: Bool {
        config.updateAvailable && !config.mustUpdate && dismissed < config.settings.update.latest
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: due, initial: true) { _, due in showing = due }
            .alert("Update available", isPresented: $showing) {
                Button("Update") {
                    dismissed = config.settings.update.latest
                    config.openUpdate()
                }
                Button("Not now", role: .cancel) { dismissed = config.settings.update.latest }
            } message: {
                Text(config.settings.update.message)
            }
    }
}
