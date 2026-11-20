import SwiftUI
import Observation
import FirebaseFirestore

/// An egg a friend threw at someone, `friendEggs/{id}`. Only the server writes these.
/// It stays on the person until they walk `cleanAt - stepsAtThrow` steps.
struct FriendEgg: Identifiable, Equatable {
    let id: String
    let from: String
    let to: String
    let fromName: String
    let fromPhotoURL: URL?
    let message: String
    let at: Date
    let stepsAtThrow: Int
    let cleanAt: Int

    /// Steps it takes to walk this egg off.
    var stepsToClean: Int { max(cleanAt - stepsAtThrow, 1) }

    /// How much of it is cleaned off at `total` steps (0...1).
    func progress(total: Int) -> Double {
        min(max(Double(total - stepsAtThrow) / Double(stepsToClean), 0), 1)
    }

    func stepsLeft(total: Int) -> Int { max(cleanAt - total, 0) }

    init?(_ doc: QueryDocumentSnapshot) {
        let data = doc.data()
        guard let from = data["from"] as? String, let to = data["to"] as? String else { return nil }
        id = doc.documentID
        self.from = from
        self.to = to
        fromName = data["fromName"] as? String ?? "A friend"
        fromPhotoURL = (data["fromPhotoURL"] as? String).flatMap(URL.init(string:))
        message = (data["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        at = (data["at"] as? Timestamp)?.dateValue() ?? Date()
        stepsAtThrow = (data["stepsAtThrow"] as? NSNumber)?.intValue ?? 0
        cleanAt = (data["cleanAt"] as? NSNumber)?.intValue ?? stepsAtThrow + 1_000
    }
}

/// Someone you can throw an egg at.
struct EggTarget: Identifiable, Equatable {
    let uid: String
    let name: String
    let photoURL: URL?
    var id: String { uid }
    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}

/// Live uncleaned eggs on you and on your friends, and the step totals they're walked
/// off against (egg messages in conversations show the progress).
/// An egg counts while the server hasn't cleaned it and the person's steps are still
/// short of `cleanAt` (older apps only get cleaned once a day by the server).
@MainActor
@Observable
final class EggStore {
    /// Uncleaned eggs on you, oldest first.
    private(set) var onMe: [FriendEgg] = []
    /// Uncleaned eggs on your friends, by the friend's uid.
    private(set) var onFriends: [String: [FriendEgg]] = [:]
    /// Step totals the eggs are measured against (your shown total, friends' walker totals).
    private(set) var totals: [String: Int] = [:]
    private(set) var myUid: String?

    @ObservationIgnored private var meListener: ListenerRegistration?
    @ObservationIgnored private var friendListeners: [ListenerRegistration] = []
    @ObservationIgnored private var followed: [String] = []
    @ObservationIgnored private var chunks: [Int: [FriendEgg]] = [:]

    // MARK: - Reading

    func total(of uid: String) -> Int? { totals[uid] }

    /// Eggs still on `uid`, oldest first.
    func eggs(on uid: String) -> [FriendEgg] {
        let source = uid == myUid ? onMe : onFriends[uid] ?? []
        guard let total = totals[uid] else { return source }
        return source.filter { total < $0.cleanAt }
    }

    /// Whether the server still has egg `id` as uncleaned (only eggs on you and friends).
    func isUncleaned(_ id: String) -> Bool {
        onMe.contains { $0.id == id } || onFriends.values.contains { $0.contains { $0.id == id } }
    }

    /// How far `uid` is through cleaning `egg` off.
    func progress(_ egg: FriendEgg) -> Double {
        egg.progress(total: totals[egg.to] ?? egg.stepsAtThrow)
    }

    // MARK: - Feeding

    func setTotal(_ total: Int, for uid: String) {
        if totals[uid] != total { totals[uid] = total }
    }

    func setTotals(_ new: [String: Int]) {
        for (uid, total) in new where uid != myUid { setTotal(total, for: uid) }
    }

    // MARK: - Listening

    func listen(uid: String?) {
        guard uid != myUid else { return }
        meListener?.remove()
        meListener = nil
        follow([])
        onMe = []
        totals = [:]
        myUid = uid
        guard AuthStore.isConfigured, let uid else { return }
        meListener = Firestore.firestore().collection("friendEggs")
            .whereField("to", isEqualTo: uid)
            .whereField("cleaned", isEqualTo: false)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let snapshot else { return }
                let eggs = snapshot.documents.compactMap(FriendEgg.init).sorted { $0.at < $1.at }
                Task { @MainActor in
                    guard let self, self.myUid == uid else { return }
                    self.onMe = eggs
                }
            }
    }

    /// Follows the eggs on these friends (Firestore takes 30 uids per `in` query).
    func follow(_ friendIDs: [String]) {
        let ids = friendIDs.sorted()
        guard ids != followed else { return }
        followed = ids
        friendListeners.forEach { $0.remove() }
        friendListeners = []
        chunks = [:]
        onFriends = [:]
        guard AuthStore.isConfigured, !ids.isEmpty else { return }
        let groups = stride(from: 0, to: ids.count, by: 30).map { Array(ids[$0..<min($0 + 30, ids.count)]) }
        for (index, group) in groups.enumerated() {
            let listener = Firestore.firestore().collection("friendEggs")
                .whereField("to", in: group)
                .whereField("cleaned", isEqualTo: false)
                .addSnapshotListener { [weak self] snapshot, _ in
                    guard let snapshot else { return }
                    let eggs = snapshot.documents.compactMap(FriendEgg.init)
                    Task { @MainActor in
                        guard let self, self.followed == ids else { return }
                        self.chunks[index] = eggs
                        self.onFriends = Dictionary(grouping: self.chunks.values.flatMap { $0 }, by: \.to)
                            .mapValues { $0.sorted { $0.at < $1.at } }
                    }
                }
            friendListeners.append(listener)
        }
    }
}

/// Keeps friends, eggs and conversations live for the signed-in user, and feeds the eggs the step
/// totals they're measured against. Invisible; lives in MainView.
struct FriendsSync: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var steps: StepStore
    @EnvironmentObject private var friends: FriendsStore
    @Environment(EggStore.self) private var eggs
    @Environment(InboxStore.self) private var inbox

    var body: some View {
        Color.clear
            .task(id: auth.user?.uid) {
                friends.listen(uid: auth.user?.uid)
                eggs.listen(uid: auth.user?.uid)
                inbox.listen(uid: auth.user?.uid)
                if let uid = auth.user?.uid { eggs.setTotal(steps.totalSteps, for: uid) }
            }
            .onChange(of: friends.friends.map(\.id), initial: true) { _, ids in eggs.follow(ids) }
            .onChange(of: friends.walkers.mapValues(\.totalSteps), initial: true) { _, totals in
                eggs.setTotals(totals)
            }
            .onChange(of: steps.totalSteps, initial: true) { _, total in
                if let uid = auth.user?.uid { eggs.setTotal(total, for: uid) }
            }
    }
}
