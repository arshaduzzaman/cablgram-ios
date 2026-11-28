import Foundation
import FirebaseAuth
import FirebaseFirestore

struct LeaderboardEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let photoURL: URL?
    var totalSteps: Int
    var weekSteps: Int
    /// Week (e.g. 2026-W45) that `weekSteps` belongs to.
    var week: String
    /// Steps spent on eggs and headlines (kept so it follows you between phones).
    var spentSteps: Int = 0
    /// Sent from a Simulator or emulator (Google Play's review bots, our own
    /// testing): hidden from everyone else.
    var test: Bool = false
    /// When their phone last sent steps.
    var updatedAt: Date? = nil
    /// Steps their claims have used (the server's count).
    var rewardSpent: Int = 0
    /// Steps they have to use, as the server last worked it out (nil until it has).
    var available: Int? = nil
    /// How far they are toward each reward, by `Reward.claimKey`, worked out by the server.
    var progress: [String: RewardProgress] = [:]

    /// Steps they have to use: walked minus spent.
    var availableSteps: Int { available ?? max(totalSteps - spentSteps - rewardSpent, 0) }
}

/// How far someone is toward one reward (one period of it, for a limited-time reward), as the
/// server worked it out and saved it on their `walkers` record (cablgram-admin lib/progress.ts).
/// The app only shows and sorts these, so how steps count can change without an app update.
struct RewardProgress: Equatable {
    /// Steps, or days when `countsDays` (a reward that needs its steps every day).
    let done: Int
    let need: Int
    /// Steps still to walk (today's, for an every-day reward).
    let left: Int
    var countsDays = false
    /// A day was missed, so it's out of reach.
    var missed = false

    init?(_ value: Any?) {
        guard let x = value as? [String: Any], let need = (x["need"] as? NSNumber)?.intValue else { return nil }
        done = (x["done"] as? NSNumber)?.intValue ?? 0
        self.need = need
        left = (x["left"] as? NSNumber)?.intValue ?? max(need - done, 0)
        countsDays = x["days"] as? Bool ?? false
        missed = x["missed"] as? Bool ?? false
    }
}

/// Someone in the race to your goal reward, and how far along they are.
struct Racer: Identifiable, Equatable {
    let id: String
    let name: String
    let photoURL: URL?
    /// Steps toward the reward, capped at the reward's steps.
    let steps: Int
    let isYou: Bool
    let finished: Bool
    /// When their phone last sent steps: every 20 seconds while they walk with the app
    /// open, about hourly when it's closed.
    var updatedAt: Date? = nil

    var firstName: String { name.components(separatedBy: " ").first ?? name }
}

/// Live leaderboard from Firestore's `walkers` collection. Each signed-in
/// user writes their own document (`walkers/{uid}`) with their name and spent
/// steps, plus their phone's raw Health days in `walkers/{uid}/devices/{deviceId}`.
/// The server works out the step totals from those and writes them back.
@MainActor
final class LeaderboardStore: ObservableObject {
    @Published private(set) var entries: [LeaderboardEntry] = []
    @Published private(set) var errorMessage: String?

    /// Your own totals as shown on this phone (server + steps since), so your
    /// row doesn't lag behind the number on the Walk page.
    @Published private(set) var yours: (uid: String, total: Int, week: Int)?

    /// Your own record, live (you may not be in the top 100 the board listens to): your
    /// spent steps and your progress toward each reward, as the server has them.
    @Published private(set) var mine: LeaderboardEntry?

    private var listener: ListenerRegistration?
    private var mineListener: ListenerRegistration?
    private var lastUploaded: Upload?
    /// When steps were last sent, and a send waiting for the gap to pass.
    private var lastSent = Date.distantPast
    private var pendingSend: Task<Void, Never>?
    /// Live steps change every few seconds while walking; send at most this often.
    private static let minGap: TimeInterval = 20
    /// Counts recalc requests so only the newest answer is used.
    private var recalcCount = 0

    private struct Upload: Equatable {
        let uid: String
        let localTotal: Int
        let localWeek: Int
        /// The goal reward's id, so friends see what you're going for.
        let goal: String?
        let days: [String: Int]?
    }

    /// What `/api/steps/recalc` answers.
    struct Recalc: Decodable {
        let totalSteps: Int
        let weekSteps: Int
        let week: String
    }

    nonisolated private static let recalcURL = Backend.url("/api/steps/recalc")
    nonisolated private static let lastContactKey = "walk.lastServerContact"

    /// With nothing new to send, still tells the server this phone is alive, at most once
    /// an hour, so the dashboard can tell "not walking" from "not syncing".
    nonisolated static func checkIn(background: Bool = false) {
        let last = UserDefaults.standard.object(forKey: lastContactKey) as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) > 3600 else { return }
        UserDefaults.standard.set(Date.now, forKey: lastContactKey)
        Task { await recalc(background: background, ping: true) }
    }

    /// Random ID for this install, made once. Names this phone's doc under `devices`.
    nonisolated static var deviceID: String {
        let key = "walk.deviceId"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    nonisolated static var weekKey: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "YYYY-'W'ww"
        return formatter.string(from: .now)
    }

    /// One `walkers/{uid}` record as the app uses it.
    nonisolated private static func entry(_ id: String, _ data: [String: Any]) -> LeaderboardEntry {
        LeaderboardEntry(
            id: id,
            name: data["name"] as? String ?? "Walker",
            photoURL: (data["photoURL"] as? String).flatMap(URL.init(string:)),
            totalSteps: (data["totalSteps"] as? NSNumber)?.intValue ?? 0,
            weekSteps: (data["weekSteps"] as? NSNumber)?.intValue ?? 0,
            week: data["week"] as? String ?? "",
            spentSteps: (data["spentSteps"] as? NSNumber)?.intValue ?? 0,
            test: data["test"] as? Bool ?? false,
            // When their phone last sent steps: the server's note or the app's own write, whichever is newer.
            updatedAt: [data["stepsAt"], data["updatedAt"]].compactMap { ($0 as? Timestamp)?.dateValue() }.max(),
            rewardSpent: (data["rewardSpent"] as? NSNumber)?.intValue ?? 0,
            available: (data["available"] as? NSNumber)?.intValue,
            progress: (data["progress"] as? [String: Any] ?? [:]).compactMapValues(RewardProgress.init)
        )
    }

    func startListening() {
        guard AuthStore.isConfigured, listener == nil, let uid = Auth.auth().currentUser?.uid else { return }
        let walkers = Firestore.firestore().collection("walkers")
        listener = walkers
            .order(by: "totalSteps", descending: true)
            .limit(to: 100)
            .addSnapshotListener { [weak self] snapshot, error in
                let entries = snapshot?.documents.map { Self.entry($0.documentID, $0.data()) }
                let message = error?.localizedDescription
                Task { @MainActor in
                    if let entries { self?.entries = entries }
                    self?.errorMessage = message
                }
            }
        mineListener = walkers.document(uid).addSnapshotListener { [weak self] snapshot, _ in
            guard let snapshot else { return }
            let mine = snapshot.data().map { Self.entry(uid, $0) }
            Task { @MainActor in
                if self?.mine != mine { self?.mine = mine }
            }
        }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
        mineListener?.remove()
        mineListener = nil
        entries = []
        mine = nil
    }

    /// Saves the signed-in user's name, goal reward and this phone's Health days,
    /// then asks the server to recalculate. Skips it all when nothing changed.
    /// The server's answer goes back to `steps`; failures are ignored (the
    /// server also recalculates everyone daily).
    func upload(_ steps: StepStore) {
        let wait = Self.minGap - Date.now.timeIntervalSince(lastSent)
        guard wait <= 0 else {
            // Sends the newest counts once the gap has passed.
            if pendingSend == nil {
                pendingSend = Task { [weak self, weak steps] in
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled, let self, let steps else { return }
                    self.pendingSend = nil
                    self.upload(steps)
                }
            }
            return
        }
        send(steps)
    }

    /// Sends anything waiting right away (when the app goes to the background).
    func flush(_ steps: StepStore) {
        pendingSend?.cancel()
        pendingSend = nil
        send(steps)
    }

    private func send(_ steps: StepStore) {
        guard AuthStore.isConfigured, let user = Auth.auth().currentUser else { return }
        // Until Health has answered there are no real days to send.
        let days = steps.access == .ready && steps.hasLoaded ? steps.dailySteps : nil
        let upload = Upload(uid: user.uid, localTotal: steps.stepsSinceJoining, localWeek: steps.localWeek,
                            goal: steps.goalReward?.id, days: days)
        if upload == lastUploaded {
            if days != nil { Self.checkIn() }
            return
        }
        lastUploaded = upload
        lastSent = .now

        var data: [String: Any] = [
            "name": user.displayName ?? "Walker",
            "goal": upload.goal.map { $0 as Any } ?? FieldValue.delete(),
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        data["photoURL"] = user.photoURL?.absoluteString
        #if targetEnvironment(simulator)
        data["test"] = true // keeps Simulator runs off real people's leaderboard
        #endif
        let walker = Firestore.firestore().collection("walkers").document(user.uid)
        walker.setData(data, merge: true) { [weak self] error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor in
                self?.errorMessage = message
                self?.lastUploaded = nil
            }
        }

        guard let days else { return }
        recalcCount += 1
        let count = recalcCount
        let uid = user.uid
        Task { [weak self] in
            do {
                try await Self.saveDevice(uid: uid, days: days)
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.lastUploaded = nil
                return
            }
            guard let result = await Self.recalc(),
                  let self, count == self.recalcCount, Auth.auth().currentUser?.uid == uid else { return }
            steps.applyServerSync(.init(total: result.totalSteps, week: result.weekSteps, weekKey: result.week,
                                        localTotal: upload.localTotal, localWeek: upload.localWeek), uid: uid)
        }
    }

    /// This phone's Health days (raw, per local day) for the server to count from:
    /// `walkers/{uid}/devices/{deviceId}`. Also used by `BackgroundSteps`.
    nonisolated static func saveDevice(uid: String, days: [String: Int]) async throws {
        let device: [String: Any] = [
            "platform": "ios",
            "build": Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0,
            "timezone": TimeZone.current.identifier,
            "updatedAt": FieldValue.serverTimestamp(),
            "days": days,
        ]
        try await Firestore.firestore().collection("walkers").document(uid)
            .collection("devices").document(deviceID).setData(device)
    }

    /// Asks the server to work out the signed-in user's totals again.
    /// Returns `nil` on any failure. `background` tells the dashboard whether the app was
    /// closed. With `ping` nothing is recounted: it only shows the phone still reaches us.
    @discardableResult
    nonisolated static func recalc(background: Bool = false, ping: Bool = false) async -> Recalc? {
        guard let user = Auth.auth().currentUser, let token = try? await user.getIDToken() else { return nil }
        var request = URLRequest(url: recalcURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["source": background ? "background" : "foreground"]
        if ping { body["ping"] = true }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        UserDefaults.standard.set(Date.now, forKey: lastContactKey)
        return try? JSONDecoder().decode(Recalc.self, from: data)
    }

    /// Sets the totals your own row shows (what the Walk page shows).
    func showYourSteps(uid: String?, total: Int, week: Int) {
        let new = uid.map { (uid: $0, total: total, week: week) }
        if new?.uid == yours?.uid, new?.total == yours?.total, new?.week == yours?.week { return }
        yours = new
    }

    /// Everyone to show, highest total first. Test accounts only show to themselves.
    var ranked: [LeaderboardEntry] {
        let you = Auth.auth().currentUser?.uid
        var list = entries.filter { !$0.test || $0.id == you }
        if let yours, yours.uid == you, let index = list.firstIndex(where: { $0.id == yours.uid }) {
            list[index].totalSteps = yours.total
            list[index].weekSteps = yours.week
            list[index].week = Self.weekKey
            list.sort { $0.totalSteps > $1.totalSteps }
        }
        return list
    }

    /// 1-based all-time rank of a user, if they're in the top 100.
    func rank(of uid: String?) -> Int? {
        guard let uid else { return nil }
        return ranked.firstIndex { $0.id == uid }.map { $0 + 1 }
    }

    /// Top walkers this week (only people who've synced this week).
    var thisWeek: [LeaderboardEntry] {
        let key = Self.weekKey
        return ranked.filter { $0.week == key && $0.weekSteps > 0 }.sorted { $0.weekSteps > $1.weekSteps }
    }

    // MARK: - Race to the reward

    /// The leaderboard for one reward: the same race its track shows, furthest along first,
    /// leaving out people who haven't started (you always show).
    func board(for goal: Reward, steps: StepStore, uid: String?, name: String, photoURL: URL?) -> [Racer] {
        race(for: goal, yours: steps.progress(toward: goal), uid: uid, name: name, photoURL: photoURL)
            .filter { $0.steps > 0 || $0.isYou }
    }

    /// Everyone racing to `goal`, closest to it first: steps, or days for an every-day reward.
    /// Everyone else's progress is the server's; yours also has the steps since it last counted.
    func race(for goal: Reward, yours: (done: Int, need: Int, missed: Bool), uid: String?, name: String,
              photoURL: URL?) -> [Racer] {
        var racers = ranked
            .filter { $0.id != uid }
            .map { entry -> Racer in
                var done = entry.progress[goal.claimKey]?.done
                // Before the server has worked theirs out: an ordinary reward is just their steps to use.
                if done == nil, goal.schedule == nil { done = entry.availableSteps }
                let steps = min(done ?? 0, yours.need)
                return Racer(id: entry.id, name: entry.name, photoURL: entry.photoURL,
                             steps: steps, isYou: false, finished: steps >= yours.need, updatedAt: entry.updatedAt)
            }
        racers.append(Racer(id: uid ?? "you", name: name, photoURL: photoURL,
                            steps: min(yours.done, yours.need), isYou: true,
                            finished: yours.done >= yours.need))
        return racers.sorted { $0.steps > $1.steps }
    }
}
