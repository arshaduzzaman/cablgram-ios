import Foundation
import FirebaseAuth
import FirebaseFirestore

/// Where you stand with someone: you asked them, they asked you, or you're friends.
enum FriendStatus: String {
    case sent, received, friends
}

/// One entry in your own list, `friends/{yourUid}/list/{theirUid}`. Only the server
/// writes these (cablgram-admin /api/friends); both people's lists change together.
struct FriendLink: Identifiable, Equatable {
    let id: String
    let status: FriendStatus
    let name: String
    let photoURL: URL?
    let since: Date?
}

/// A friend's `walkers/{uid}` document: their steps and what they're going for.
struct FriendWalker: Equatable {
    let name: String
    let photoURL: URL?
    let totalSteps: Int
    let weekSteps: Int
    /// Week (e.g. 2026-W45) that `weekSteps` belongs to.
    let week: String
    let spentSteps: Int
    /// The id of the reward they're aiming for, if any.
    let goal: String?
    let updatedAt: Date?

    /// Steps this week, or 0 when they haven't synced this week.
    var stepsThisWeek: Int { week == LeaderboardStore.weekKey ? weekSteps : 0 }
    /// Steps they can still spend on rewards.
    var availableSteps: Int { max(totalSteps - spentSteps, 0) }
    @MainActor var goalReward: Reward? { goal.flatMap { id in Reward.all.first { $0.id == id } } }
}

/// Someone found by phone number, and where you stand with them.
struct FoundPerson: Equatable {
    let uid: String
    let name: String
    let photoURL: URL?
    var status: FriendStatus?
}

/// Your friends, live from Firestore, plus finding, adding, accepting and removing
/// people through the server.
@MainActor
final class FriendsStore: ObservableObject {
    @Published private(set) var links: [FriendLink] = []
    @Published private(set) var walkers: [String: FriendWalker] = [:]
    @Published private(set) var found: FoundPerson?
    @Published private(set) var searching = false
    @Published var searchError: String?
    @Published var actionError: String?
    /// People with a request on its way to the server, so their buttons wait.
    @Published private(set) var busy: Set<String> = []

    private var uid: String?
    private var listListener: ListenerRegistration?
    private var walkerListeners: [String: ListenerRegistration] = [:]

    private static let url = URL(string: "https://cablgram-admin.vercel.app/api/friends")!

    var requests: [FriendLink] { links.filter { $0.status == .received }.sorted { $0.name < $1.name } }
    var sent: [FriendLink] { links.filter { $0.status == .sent }.sorted { $0.name < $1.name } }
    /// Friends, most steps this week first.
    var friends: [FriendLink] {
        links.filter { $0.status == .friends }.sorted {
            let a = walkers[$0.id]?.stepsThisWeek ?? 0, b = walkers[$1.id]?.stepsThisWeek ?? 0
            return a != b ? a > b : $0.name < $1.name
        }
    }

    /// Where you stand with someone right now (the live list wins over a search answer).
    func status(of uid: String) -> FriendStatus? {
        if let link = links.first(where: { $0.id == uid }) { return link.status }
        return found?.uid == uid ? found?.status : nil
    }

    // MARK: - Listening

    /// Listens to the signed-in user's list (and each friend's walker document).
    func listen(uid: String?) {
        guard uid != self.uid else { return }
        stop()
        self.uid = uid
        guard AuthStore.isConfigured, let uid else { return }
        listListener = Firestore.firestore().collection("friends").document(uid).collection("list")
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let snapshot else { return }
                let links = snapshot.documents.compactMap { doc -> FriendLink? in
                    let data = doc.data()
                    guard let status = (data["status"] as? String).flatMap(FriendStatus.init(rawValue:)) else { return nil }
                    return FriendLink(id: doc.documentID, status: status,
                                      name: data["name"] as? String ?? "Walker",
                                      photoURL: (data["photoURL"] as? String).flatMap(URL.init(string:)),
                                      since: (data["since"] as? Timestamp)?.dateValue())
                }
                Task { @MainActor in
                    guard let self, self.uid == uid else { return }
                    self.links = links
                    self.followWalkers()
                }
            }
    }

    func stop() {
        listListener?.remove()
        listListener = nil
        walkerListeners.values.forEach { $0.remove() }
        walkerListeners = [:]
        links = []
        walkers = [:]
        found = nil
        searchError = nil
        actionError = nil
        uid = nil
    }

    /// Keeps one `walkers/{uid}` listener per friend.
    private func followWalkers() {
        let friendIDs = Set(links.filter { $0.status == .friends }.map(\.id))
        for (id, listener) in walkerListeners where !friendIDs.contains(id) {
            listener.remove()
            walkerListeners[id] = nil
            walkers[id] = nil
        }
        for id in friendIDs where walkerListeners[id] == nil {
            walkerListeners[id] = Firestore.firestore().collection("walkers").document(id)
                .addSnapshotListener { [weak self] snapshot, _ in
                    guard let data = snapshot?.data() else { return }
                    let walker = FriendWalker(
                        name: data["name"] as? String ?? "Walker",
                        photoURL: (data["photoURL"] as? String).flatMap(URL.init(string:)),
                        totalSteps: (data["totalSteps"] as? NSNumber)?.intValue ?? 0,
                        weekSteps: (data["weekSteps"] as? NSNumber)?.intValue ?? 0,
                        week: data["week"] as? String ?? "",
                        spentSteps: (data["spentSteps"] as? NSNumber)?.intValue ?? 0,
                        goal: data["goal"] as? String,
                        updatedAt: (data["updatedAt"] as? Timestamp)?.dateValue())
                    Task { @MainActor in
                        guard let self, self.walkerListeners[id] != nil else { return }
                        self.walkers[id] = walker
                    }
                }
        }
    }

    // MARK: - Server

    /// Looks someone up by the number typed after +880.
    func find(_ typed: String) async {
        guard let phone = AuthStore.normalizedPhone(typed) else {
            searchError = "Type a Bangladeshi mobile number, like 01712 345678."
            return
        }
        searching = true
        defer { searching = false }
        do {
            // The server takes the local form, e.g. 01712345678.
            let answer = try await call(["action": "find", "phone": "0" + phone.dropFirst(4)])
            guard let uid = answer["uid"] as? String else { throw ProfileError.message("Something went wrong. Try again.") }
            found = FoundPerson(uid: uid, name: answer["name"] as? String ?? "Walker",
                                photoURL: (answer["photoURL"] as? String).flatMap(URL.init(string:)),
                                status: (answer["status"] as? String).flatMap(FriendStatus.init(rawValue:)))
            searchError = nil
        } catch {
            found = nil
            searchError = error.localizedDescription
            Haptics.error()
        }
    }

    func clearSearch() {
        found = nil
        searchError = nil
    }

    /// Asks to be friends (or accepts, if they had already asked you).
    func add(_ uid: String) async { await act("add", uid) }
    func accept(_ uid: String) async { await act("accept", uid) }
    /// Declines a request, cancels yours, or unfriends.
    func remove(_ uid: String) async { await act("remove", uid) }

    /// Throws an egg at a friend, with an optional message (the server trims it to 80).
    /// Throws the server's sentence as is, e.g. when you've thrown 5 at them today.
    /// Returns the new egg's id.
    @discardableResult
    func egg(_ uid: String, message: String) async throws -> String? {
        var body = ["action": "egg", "uid": uid]
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { body["message"] = String(text.prefix(80)) }
        return try await call(body)["id"] as? String
    }

    /// Sends a friend a text (the server keeps it to 500 characters). Throws the
    /// server's sentence as is.
    func message(_ uid: String, text: String) async throws {
        _ = try await call(["action": "message", "uid": uid, "text": String(text.prefix(500))])
    }

    /// Clears your unread count for the conversation with `uid`.
    func markRead(_ uid: String) async {
        _ = try? await call(["action": "read", "uid": uid])
    }

    private func act(_ action: String, _ uid: String) async {
        guard !busy.contains(uid) else { return }
        busy.insert(uid)
        defer { busy.remove(uid) }
        do {
            let answer = try await call(["action": action, "uid": uid])
            let status = (answer["status"] as? String).flatMap(FriendStatus.init(rawValue:))
            if found?.uid == uid { found?.status = status }
            actionError = nil
            if status == .friends || status == .sent { Haptics.success() }
        } catch {
            if found?.uid == uid { searchError = error.localizedDescription } else { actionError = error.localizedDescription }
            Haptics.error()
        }
    }

    /// POSTs `body` to /api/friends with your ID token. Returns the JSON answer, or
    /// throws the server's `error` sentence as is.
    private func call(_ body: [String: String]) async throws -> [String: Any] {
        guard AuthStore.isConfigured, let user = Auth.auth().currentUser else {
            throw ProfileError.message("Sign in to add friends.")
        }
        let token: String
        do { token = try await user.getIDToken() } catch { throw ProfileError.message("No internet connection.") }
        var request = URLRequest(url: Self.url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw ProfileError.message("The server took too long. Try again.")
        } catch {
            throw ProfileError.message("No internet connection.")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ProfileError.message(json["error"] as? String ?? "Something went wrong. Try again.")
        }
        return json
    }
}
