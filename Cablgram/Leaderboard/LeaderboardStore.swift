import Foundation
import FirebaseAuth
import FirebaseFirestore

struct LeaderboardEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let photoURL: URL?
    let totalSteps: Int
    let weekSteps: Int
    /// Week (e.g. 2026-W45) that `weekSteps` belongs to.
    let week: String
}

/// Live leaderboard from Firestore's `walkers` collection. Each signed-in
/// user writes their own document (`walkers/{uid}`) with their step totals.
@MainActor
final class LeaderboardStore: ObservableObject {
    @Published private(set) var entries: [LeaderboardEntry] = []
    @Published private(set) var errorMessage: String?

    private var listener: ListenerRegistration?
    private var lastUploaded: (uid: String, total: Int, week: Int)?

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
                        week: data["week"] as? String ?? ""
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
    func upload(totalSteps: Int, weekSteps: Int) {
        guard AuthStore.isConfigured, let user = Auth.auth().currentUser else { return }
        if let last = lastUploaded, last.uid == user.uid, last.total == totalSteps, last.week == weekSteps {
            return
        }
        lastUploaded = (user.uid, totalSteps, weekSteps)

        var data: [String: Any] = [
            "name": user.displayName ?? "Walker",
            "totalSteps": totalSteps,
            "weekSteps": weekSteps,
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
            return (entries + Self.sampleWalkers).sorted { $0.totalSteps > $1.totalSteps }
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

    #if DEBUG
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
