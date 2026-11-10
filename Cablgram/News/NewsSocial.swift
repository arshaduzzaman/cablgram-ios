import Foundation
import FirebaseAuth
import FirebaseFirestore

/// Eggs and step-bought headlines on posts, shared through Firestore so
/// everyone sees them live:
///
///     newsPosts/{postId}/loves/{uid}     { uid, at }
///     newsPosts/{postId}/eggs/{id}       { uid, x, y, at }
///     newsPosts/{postId}/headlines/{id}  { uid, author, text, steps, at }
///
/// Only the posts on screen are listened to. Without a signed-in
/// user (or Firebase), marks stay on this phone for the session.
@MainActor
final class NewsSocial: ObservableObject {
    @Published private(set) var eggs: [String: [EggMark]] = [:]
    /// Who loved each post (user ids).
    @Published private(set) var loves: [String: Set<String>] = [:]
    /// Headlines people paid steps for, most steps first.
    @Published private(set) var headlines: [String: [Headline]] = [:]
    /// Set when saving something fails, so the feed can say so.
    @Published var problem: String?

    private var listeners: [String: [ListenerRegistration]] = [:]

    private var uid: String? {
        AuthStore.isConfigured ? Auth.auth().currentUser?.uid : nil
    }

    private func post(_ id: String) -> DocumentReference {
        Firestore.firestore().collection("newsPosts").document(id)
    }

    func eggs(_ postID: String) -> [EggMark] { eggs[postID] ?? [] }
    func loves(_ postID: String) -> Set<String> { loves[postID] ?? [] }

    /// How this phone's love is recorded: your user id, or a stand-in
    /// when not signed in.
    var myKey: String { uid ?? "this-phone" }
    func headlines(_ postID: String) -> [Headline] { headlines[postID] ?? [] }

    // MARK: - Listening

    /// Listens to exactly these posts, dropping listeners for any others.
    func watch(_ ids: [String]) {
        for (id, registrations) in listeners where !ids.contains(id) {
            registrations.forEach { $0.remove() }
            listeners[id] = nil
        }
        #if DEBUG
        // `-sampleEggs` launch argument: scatter made-up eggs on posts so the
        // reveal can be tried without other people (test builds only).
        if uid == nil, ProcessInfo.processInfo.arguments.contains("-sampleEggs") {
            for id in ids where eggs[id] == nil {
                let count = Int.random(in: 3...28)
                eggs[id] = (0..<count).map { i in
                    EggMark(id: "sample-\(id)-\(i)", x: .random(in: 0.08...0.92), y: .random(in: 0.08...0.92), uid: "sample")
                }
            }
        }
        #endif
        guard uid != nil else { return }

        for id in ids where listeners[id] == nil {
            let doc = post(id)

            let eggs = doc.collection("eggs")
                .order(by: "at", descending: true)
                .limit(to: 150)
                .addSnapshotListener { [weak self] snapshot, error in
                    if let error { print("[Cablgram] eggs listener: \(error.localizedDescription)") }
                    guard let documents = snapshot?.documents else { return }
                    let eggs = documents.reversed().map { egg in
                        let data = egg.data()
                        return EggMark(id: egg.documentID,
                                       x: Self.number(data["x"]),
                                       y: Self.number(data["y"]),
                                       uid: data["uid"] as? String)
                    }
                    Task { @MainActor in self?.eggs[id] = eggs }
                }

            let headlines = doc.collection("headlines")
                .order(by: "steps", descending: true)
                .limit(to: 10)
                .addSnapshotListener { [weak self] snapshot, _ in
                    guard let documents = snapshot?.documents else { return }
                    let headlines = documents.map { line in
                        let data = line.data()
                        return Headline(id: line.documentID,
                                        text: data["text"] as? String ?? "",
                                        author: data["author"] as? String ?? "Someone",
                                        steps: Int(Self.number(data["steps"])),
                                        uid: data["uid"] as? String)
                    }
                    Task { @MainActor in self?.headlines[id] = headlines }
                }

            let loves = doc.collection("loves")
                .limit(to: 2000)
                .addSnapshotListener { [weak self] snapshot, _ in
                    guard let documents = snapshot?.documents else { return }
                    let lovers = Set(documents.map(\.documentID))
                    Task { @MainActor in self?.loves[id] = lovers }
                }

            listeners[id] = [eggs, headlines, loves]
        }
    }

    // MARK: - Writing

    /// Loves (or unloves) a post. One love per person.
    func setLove(_ on: Bool, on postID: String) {
        guard let uid else {
            if on { loves[postID, default: []].insert(myKey) } else { loves[postID]?.remove(myKey) }
            return
        }
        let doc = post(postID).collection("loves").document(uid)
        if on {
            doc.setData(["uid": uid, "at": FieldValue.serverTimestamp()], completion: report("love"))
        } else {
            doc.delete(completion: report("love"))
        }
    }

    /// Throws an egg at `point` (fractions of the photo). Returns its id so
    /// the thrower's phone can animate the throw.
    @discardableResult
    func throwEgg(at point: CGPoint, on postID: String) -> String {
        let egg = EggMark(id: UUID().uuidString,
                          x: min(max(point.x, 0.03), 0.97), y: min(max(point.y, 0.03), 0.97), uid: uid)
        guard let uid else {
            eggs[postID, default: []].append(egg)
            return egg.id
        }
        post(postID).collection("eggs").document(egg.id).setData([
            "uid": uid,
            "x": Self.round(egg.x),
            "y": Self.round(egg.y),
            "at": FieldValue.serverTimestamp(),
        ], completion: report("egg"))
        return egg.id
    }

    /// Puts up a headline paid for with `steps` (already spent by the caller).
    func postHeadline(_ text: String, steps: Int, by author: String, on postID: String) {
        let line = Headline(id: UUID().uuidString, text: text, author: author, steps: steps, uid: uid)
        guard let uid else {
            headlines[postID, default: []].append(line)
            headlines[postID]?.sort { $0.steps > $1.steps }
            return
        }
        post(postID).collection("headlines").document(line.id).setData([
            "uid": uid,
            "author": author,
            "text": text,
            "steps": steps,
            "at": FieldValue.serverTimestamp(),
        ], completion: report("headline"))
    }

    /// Turns a failed save into a message on screen (and in the log).
    private func report(_ what: String) -> (Error?) -> Void {
        { [weak self] error in
            guard let error else {
                print("[Cablgram] saved \(what)")
                return
            }
            print("[Cablgram] couldn't save \(what): \(error.localizedDescription)")
            let message = (error as NSError).code == FirestoreErrorCode.permissionDenied.rawValue
                ? "Couldn't save your \(what): Firestore rules are blocking it"
                : "Couldn't save your \(what): \(error.localizedDescription)"
            Task { @MainActor in self?.problem = message }
        }
    }

    // MARK: - Decoding

    private nonisolated static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    private nonisolated static func round(_ value: CGFloat) -> Double {
        (Double(value) * 10_000).rounded() / 10_000
    }
}

/// A headline someone wrote for a post, paid for in steps. The one with
/// the most steps behind it is shown on the post.
struct Headline: Identifiable, Equatable {
    let id: String
    let text: String
    let author: String
    let steps: Int
    let uid: String?

    var firstName: String { author.components(separatedBy: " ").first ?? author }

    /// The least a headline can cost.
    static let minimumSteps = 500
    /// How much more than the current top headline it takes to replace it.
    static let outbidBy = 100
    static let maxLength = 80
}
