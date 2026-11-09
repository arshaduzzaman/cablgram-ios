import Foundation
import FirebaseAuth
import FirebaseFirestore

/// A pink handprint someone left on a post's photo, at a spot given as
/// fractions of the photo's size.
struct SlapMark: Identifiable, Equatable {
    let id: String
    let x: Double
    let y: Double
    /// Tilt in degrees, so a pile of slaps looks hand-made.
    let angle: Double
}

/// Slaps, voice notes, eggs and step-bought headlines on posts, shared through Firestore so everyone sees
/// everyone's marks live:
///
///     newsPosts/{postId}                 { slaps }
///     newsPosts/{postId}/marks/{id}      { uid, x, y, a, at }
///     newsPosts/{postId}/voices/{id}     { uid, author, x, y, secs, audio, at }
///     newsPosts/{postId}/eggs/{id}       { uid, x, y, at }
///     newsPosts/{postId}/headlines/{id}  { uid, author, text, steps, at }
///
/// Only the posts on screen are listened to. Without a signed-in
/// user (or Firebase), marks stay on this phone for the session.
@MainActor
final class NewsSocial: ObservableObject {
    @Published private(set) var slapCounts: [String: Int] = [:]
    @Published private(set) var marks: [String: [SlapMark]] = [:]
    @Published private(set) var voices: [String: [VoiceNote]] = [:]
    @Published private(set) var eggs: [String: [EggMark]] = [:]
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

    func slapCount(_ postID: String) -> Int { slapCounts[postID] ?? 0 }
    func marks(_ postID: String) -> [SlapMark] { marks[postID] ?? [] }
    func voices(_ postID: String) -> [VoiceNote] { voices[postID] ?? [] }
    func eggs(_ postID: String) -> [EggMark] { eggs[postID] ?? [] }
    func headlines(_ postID: String) -> [Headline] { headlines[postID] ?? [] }

    // MARK: - Listening

    /// Listens to exactly these posts, dropping listeners for any others.
    func watch(_ ids: [String]) {
        for (id, registrations) in listeners where !ids.contains(id) {
            registrations.forEach { $0.remove() }
            listeners[id] = nil
        }
        guard uid != nil else { return }

        for id in ids where listeners[id] == nil {
            let doc = post(id)

            let count = doc.addSnapshotListener { [weak self] snapshot, _ in
                let slaps = (snapshot?.data()?["slaps"] as? NSNumber)?.intValue ?? 0
                Task { @MainActor in self?.slapCounts[id] = slaps }
            }

            let marks = doc.collection("marks")
                .order(by: "at", descending: true)
                .limit(to: 60)
                .addSnapshotListener { [weak self] snapshot, _ in
                    guard let documents = snapshot?.documents else { return }
                    let marks = documents.map { mark in
                        let data = mark.data()
                        return SlapMark(id: mark.documentID,
                                        x: Self.number(data["x"]),
                                        y: Self.number(data["y"]),
                                        angle: Self.number(data["a"]))
                    }
                    Task { @MainActor in self?.marks[id] = marks }
                }

            let voices = doc.collection("voices")
                .order(by: "at", descending: true)
                .limit(to: 20)
                .addSnapshotListener { [weak self] snapshot, _ in
                    guard let documents = snapshot?.documents else { return }
                    let voices: [VoiceNote] = documents.reversed().compactMap { note in
                        let data = note.data()
                        guard let audio = data["audio"] as? Data else { return nil }
                        return VoiceNote(id: note.documentID,
                                         author: data["author"] as? String ?? "Someone",
                                         authorID: data["uid"] as? String,
                                         x: Self.number(data["x"]),
                                         y: Self.number(data["y"]),
                                         seconds: Self.number(data["secs"]),
                                         audio: audio)
                    }
                    Task { @MainActor in self?.voices[id] = voices }
                }

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

            listeners[id] = [count, marks, voices, eggs, headlines]
        }
    }

    // MARK: - Writing

    /// Slaps a post, leaving a handprint at `point` (fractions of the photo).
    func slap(_ postID: String, at point: CGPoint) {
        let mark = SlapMark(id: UUID().uuidString,
                            x: min(max(point.x, 0.04), 0.96),
                            y: min(max(point.y, 0.04), 0.96),
                            angle: Double.random(in: -40...20))
        guard let uid else {
            slapCounts[postID, default: 0] += 1
            marks[postID, default: []].insert(mark, at: 0)
            return
        }
        let doc = post(postID)
        doc.setData(["slaps": FieldValue.increment(Int64(1))], merge: true, completion: report("slap"))
        doc.collection("marks").document(mark.id).setData([
            "uid": uid,
            "x": mark.x,
            "y": mark.y,
            "a": mark.angle,
            "at": FieldValue.serverTimestamp(),
        ], completion: report("slap"))
    }

    /// Pins a voice note at `point` (fractions of the photo).
    func postVoice(_ audio: Data, seconds: Double, at point: CGPoint, by author: String, on postID: String) {
        let note = VoiceNote(id: UUID().uuidString, author: author, authorID: uid,
                             x: min(max(point.x, 0.06), 0.94), y: min(max(point.y, 0.06), 0.94),
                             seconds: seconds, audio: audio)
        guard let uid else {
            voices[postID, default: []].append(note)
            return
        }
        post(postID).collection("voices").document(note.id).setData([
            "uid": uid,
            "author": author,
            "x": note.x,
            "y": note.y,
            "secs": (seconds * 10).rounded() / 10,
            "audio": audio,
            "at": FieldValue.serverTimestamp(),
        ], completion: report("voice note"))
    }

    func deleteVoice(_ noteID: String, on postID: String) {
        guard uid != nil else {
            voices[postID]?.removeAll { $0.id == noteID }
            return
        }
        post(postID).collection("voices").document(noteID).delete(completion: report("delete"))
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
