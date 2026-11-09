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
    let week: String
    /// Steps spent on eggs and headlines (kept so it follows you between phones).
    var spentSteps: Int = 0
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

    var firstName: String { name.components(separatedBy: " ").first ?? name }
}

/// Live leaderboard from Firestore's `walkers` collection. Each signed-in
/// user writes their own document (`walkers/{uid}`) with their step totals.
@MainActor
final class LeaderboardStore: ObservableObject {
    @Published private(set) var entries: [LeaderboardEntry] = []
    @Published private(set) var errorMessage: String?

    #if DEBUG
    /// Sample walkers, ticking up in real time (test builds only).
    @Published private(set) var samples: [LeaderboardEntry] = LeaderboardStore.sampleWalkers
    /// Sample walkers' progress in the race to the current goal reward.
    @Published private(set) var sampleRace: [String: Int] = [:]
    private var raceGoal: (id: String, steps: Int)?
    private var finishedAt: [String: Date] = [:]
    private var simulation: Task<Void, Never>?
    #endif

    private var listener: ListenerRegistration?

    init() {
        #if DEBUG
        startSimulation()
        #endif
    }
    private var lastUploaded: (uid: String, total: Int, week: Int, spent: Int)?

    static var weekKey: String {
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
                        spentSteps: (data["spentSteps"] as? NSNumber)?.intValue ?? 0
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

    /// Saves the signed-in user's steps, skipping writes when nothing changed.
    func upload(totalSteps: Int, weekSteps: Int, spentSteps: Int) {
        guard AuthStore.isConfigured, let user = Auth.auth().currentUser else { return }
        if let last = lastUploaded, last.uid == user.uid, last.total == totalSteps,
           last.week == weekSteps, last.spent == spentSteps {
            return
        }
        lastUploaded = (user.uid, totalSteps, weekSteps, spentSteps)

        var data: [String: Any] = [
            "name": user.displayName ?? "Walker",
            "totalSteps": totalSteps,
            "weekSteps": weekSteps,
            "spentSteps": spentSteps,
            "week": Self.weekKey,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        data["photoURL"] = user.photoURL?.absoluteString
        Firestore.firestore().collection("walkers").document(user.uid).setData(data, merge: true) { [weak self] error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor in
                self?.errorMessage = message
                self?.lastUploaded = nil
            }
        }
    }

    /// Everyone to show, highest total first. In test builds this can include
    /// made-up sample walkers; they're never uploaded and never in release builds.
    var ranked: [LeaderboardEntry] {
        #if DEBUG
        if Self.showSamples {
            return (entries + samples).sorted { $0.totalSteps > $1.totalSteps }
        }
        #endif
        return entries
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

    /// Everyone racing to `goal`, closest to it first. Real walkers use their
    /// total steps; in test builds sample walkers race too.
    func race(for goal: Reward, yourSteps: Int, uid: String?, name: String, photoURL: URL?) -> [Racer] {
        var racers = entries
            .filter { $0.id != uid }
            .map { Racer(id: $0.id, name: $0.name, photoURL: $0.photoURL,
                         steps: min($0.totalSteps, goal.steps), isYou: false,
                         finished: $0.totalSteps >= goal.steps) }
        #if DEBUG
        if Self.showSamples, raceGoal?.id == goal.id {
            racers += samples.map { sample in
                let steps = min(sampleRace[sample.id] ?? 0, goal.steps)
                return Racer(id: sample.id, name: sample.name, photoURL: nil, steps: steps,
                             isYou: false, finished: steps >= goal.steps)
            }
        }
        #endif
        racers.append(Racer(id: uid ?? "you", name: name, photoURL: photoURL,
                            steps: min(yourSteps, goal.steps), isYou: true,
                            finished: yourSteps >= goal.steps))
        return racers.sorted { $0.steps > $1.steps }
    }

    /// Lines up the sample walkers for a race to `goal` (test builds only):
    /// a few just ahead of you, the rest behind.
    func prepareRace(for goal: Reward, yourSteps: Int) {
        #if DEBUG
        guard raceGoal?.id != goal.id else { return }
        raceGoal = (goal.id, goal.steps)
        finishedAt = [:]
        let you = min(yourSteps, goal.steps)
        let ahead = [0.93, 0.82, 0.7, 0.57, 0.44, 0.31, 0.2]
        var race: [String: Int] = [:]
        for (index, sample) in samples.enumerated() {
            if index < ahead.count {
                race[sample.id] = you + Int(Double(max(goal.steps - you, 1)) * ahead[index])
            } else {
                race[sample.id] = Int(Double(you) * Double.random(in: 0.2...0.95))
            }
        }
        sampleRace = race
        #endif
    }

    #if DEBUG
    /// Every second, sample walkers take a few steps, like people out walking.
    private func startSimulation() {
        simulation = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    private func tick() {
        guard Self.showSamples else { return }
        var race = sampleRace
        samples = samples.map { sample in
            // Most are walking at any moment; some pause.
            guard Double.random(in: 0...1) < 0.65 else { return sample }
            let stepsNow = Int.random(in: 2...14)
            var updated = sample
            updated.totalSteps += stepsNow
            updated.weekSteps += stepsNow
            if let goal = raceGoal, let current = race[sample.id] {
                race[sample.id] = min(current + stepsNow, goal.steps)
            }
            return updated
        }
        // Whoever reached the reward keeps their spot a few seconds, then
        // starts another race from further back.
        if let goal = raceGoal {
            for (id, steps) in race where steps >= goal.steps {
                if let done = finishedAt[id] {
                    if Date.now.timeIntervalSince(done) > 6 {
                        race[id] = Int(Double(goal.steps) * Double.random(in: 0.05...0.25))
                        finishedAt[id] = nil
                    }
                } else {
                    finishedAt[id] = .now
                }
            }
        }
        sampleRace = race
    }

    static let sampleWalkersKey = "debug.sampleWalkers"

    /// Sample walkers on/off (Menu, debug builds). On by default.
    static var showSamples: Bool {
        UserDefaults.standard.object(forKey: sampleWalkersKey) as? Bool ?? true
    }

    /// Made-up walkers with common Bangladeshi names, for trying the
    /// leaderboard before real users join. Test builds only; not real people.
    static let sampleWalkers: [LeaderboardEntry] = [
        ("Tanvir Ahmed", 184_250, 12_480), ("Nusrat Jahan", 171_900, 9_820),
        ("Rafiqul Islam", 158_340, 11_050), ("Farhana Akter", 142_760, 7_640),
        ("Sabbir Hossain", 129_510, 13_210), ("Sumaiya Rahman", 118_030, 6_930),
        ("Arif Chowdhury", 104_870, 8_410), ("Tasnim Haque", 93_220, 10_370),
        ("Mahfuz Alam", 81_690, 5_280), ("Shaila Sultana", 72_450, 7_960),
        ("Imran Kabir", 61_380, 4_120), ("Rumana Begum", 52_910, 6_340),
        ("Fahim Mahmud", 43_770, 3_890), ("Jannatul Ferdous", 35_160, 5_510),
        ("Rakib Uddin", 27_480, 2_740), ("Sadia Islam", 19_620, 4_380),
        ("Nayeem Hasan", 12_350, 1_970), ("Mim Akter", 6_840, 2_610),
    ].enumerated().map { index, walker in
        LeaderboardEntry(id: "sample-\(index)", name: walker.0, photoURL: nil,
                         totalSteps: walker.1, weekSteps: walker.2, week: weekKey)
    }
    #endif
}
