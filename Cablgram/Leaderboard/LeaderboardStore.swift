import Foundation
import FirebaseAuth
import FirebaseFirestore

struct LeaderboardEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let photoURL: URL?
    let totalSteps: Int
    let todaySteps: Int
    /// Local date (yyyy-MM-dd) that `todaySteps` belongs to.
    let day: String
}

/// Live leaderboard from Firestore's `walkers` collection. Each signed-in
/// user writes their own document (`walkers/{uid}`) with their step totals.
@MainActor
final class LeaderboardStore: ObservableObject {
    @Published private(set) var entries: [LeaderboardEntry] = []
    @Published private(set) var errorMessage: String?

    private var listener: ListenerRegistration?
    private var lastUploaded: (uid: String, total: Int, today: Int)?

    static var todayKey: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
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
                        todaySteps: (data["todaySteps"] as? NSNumber)?.intValue ?? 0,
                        day: data["day"] as? String ?? ""
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
    func upload(totalSteps: Int, todaySteps: Int) {
        guard AuthStore.isConfigured, let user = Auth.auth().currentUser else { return }
        if let last = lastUploaded, last.uid == user.uid, last.total == totalSteps, last.today == todaySteps {
            return
        }
        lastUploaded = (user.uid, totalSteps, todaySteps)

        var data: [String: Any] = [
            "name": user.displayName ?? "Walker",
            "totalSteps": totalSteps,
            "todaySteps": todaySteps,
            "day": Self.todayKey,
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

    /// Top walkers today (only people who've synced today).
    var today: [LeaderboardEntry] {
        let key = Self.todayKey
        return entries.filter { $0.day == key && $0.todaySteps > 0 }.sorted { $0.todaySteps > $1.todaySteps }
    }
}
