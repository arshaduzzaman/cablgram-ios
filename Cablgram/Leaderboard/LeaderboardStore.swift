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

    private var listener: ListenerRegistration?
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
        let spent: Int
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

    nonisolated private static let recalcURL = URL(string: "https://cablgram-admin.vercel.app/api/steps/recalc")!

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

    func startListening() {
        guard AuthStore.isConfigured, listener == nil, Auth.auth().currentUser != nil else { return }
        listener = Firestore.firestore()
            .collection("walkers")
            .order(by: "totalSteps", descending: true)
            .limit(to: 100)
            .addSnapshotListener { [weak self] snapshot, error in
                let entries = snapshot?.documents.map { doc in
                    let data = doc.data()
                    return LeaderboardEntry(
                        id: doc.documentID,
                        name: data["name"] as? String ?? "Walker",
                        photoURL: (data["photoURL"] as? String).flatMap(URL.init(string:)),
                        totalSteps: (data["totalSteps"] as? NSNumber)?.intValue ?? 0,
                        weekSteps: (data["weekSteps"] as? NSNumber)?.intValue ?? 0,
                        week: data["week"] as? String ?? "",
                        spentSteps: (data["spentSteps"] as? NSNumber)?.intValue ?? 0,
                        test: data["test"] as? Bool ?? false,
                        // When their phone last sent steps: the server's note or the app's own write, whichever is newer.
                        updatedAt: [data["stepsAt"], data["updatedAt"]].compactMap { ($0 as? Timestamp)?.dateValue() }.max()
                    )
                }
                let message = error?.localizedDescription
                Task { @MainActor in
                    if let entries { self?.entries = entries }
                    self?.errorMessage = message
                }
            }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
        entries = []
    }

    /// Saves the signed-in user's name, spent steps, goal reward and this phone's Health days,
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
                            spent: steps.spentSteps, goal: steps.goalReward?.id, days: days)
        if upload == lastUploaded { return }
        lastUploaded = upload
        lastSent = .now

        var data: [String: Any] = [
            "name": user.displayName ?? "Walker",
            "spentSteps": upload.spent,
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
    /// Returns `nil` on any failure.
    nonisolated static func recalc() async -> Recalc? {
        guard let user = Auth.auth().currentUser, let token = try? await user.getIDToken() else { return nil }
        var request = URLRequest(url: recalcURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
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

    /// Everyone racing to `goal`, closest to it first, by total steps.
    func race(for goal: Reward, yourSteps: Int, uid: String?, name: String, photoURL: URL?) -> [Racer] {
        var racers = ranked
            .filter { $0.id != uid }
            .map { Racer(id: $0.id, name: $0.name, photoURL: $0.photoURL,
                         steps: min($0.totalSteps, goal.steps), isYou: false,
                         finished: $0.totalSteps >= goal.steps, updatedAt: $0.updatedAt) }
        racers.append(Racer(id: uid ?? "you", name: name, photoURL: photoURL,
                            steps: min(yourSteps, goal.steps), isYou: true,
                            finished: yourSteps >= goal.steps))
        return racers.sorted { $0.steps > $1.steps }
    }
}
