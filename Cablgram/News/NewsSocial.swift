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

/// Slaps, voice notes and burns on posts, shared through Firestore so everyone sees
/// everyone's marks live:
///
///     newsPosts/{postId}                 { slaps }
///     newsPosts/{postId}/marks/{id}      { uid, x, y, a, at }
///     newsPosts/{postId}/voices/{id}     { uid, author, x, y, secs, audio, at }
///     newsPosts/{postId}/burns/{id}      { uid, x, y, r, at }
///
/// Only the posts on screen are listened to. Without a signed-in
/// user (or Firebase), marks stay on this phone for the session.
@MainActor
final class NewsSocial: ObservableObject {
    @Published private(set) var slapCounts: [String: Int] = [:]
    @Published private(set) var marks: [String: [SlapMark]] = [:]
    @Published private(set) var voices: [String: [VoiceNote]] = [:]
    @Published private(set) var burns: [String: [BurnMark]] = [:]

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
    func burns(_ postID: String) -> [BurnMark] { burns[postID] ?? [] }

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

            let burns = doc.collection("burns")
                .order(by: "at", descending: true)
                .limit(to: 300)
                .addSnapshotListener { [weak self] snapshot, _ in
                    guard let documents = snapshot?.documents else { return }
                    let burns = documents.reversed().map { burn in
                        let data = burn.data()
                        return BurnMark(id: burn.documentID,
                                        x: Self.number(data["x"]),
                                        y: Self.number(data["y"]),
                                        r: Self.number(data["r"]),
                                        uid: data["uid"] as? String)
                    }
                    Task { @MainActor in self?.burns[id] = burns }
                }

            listeners[id] = [count, marks, voices, burns]
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
        doc.setData(["slaps": FieldValue.increment(Int64(1))], merge: true)
        doc.collection("marks").document(mark.id).setData([
            "uid": uid,
            "x": mark.x,
            "y": mark.y,
            "a": mark.angle,
            "at": FieldValue.serverTimestamp(),
        ])
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
        ])
    }

    func deleteVoice(_ noteID: String, on postID: String) {
        guard uid != nil else {
            voices[postID]?.removeAll { $0.id == noteID }
            return
        }
        post(postID).collection("voices").document(noteID).delete()
    }

    /// Burns a hole of radius `r` (fraction of the photo's width) at `point`.
    func burn(_ postID: String, at point: CGPoint, radius r: Double) {
        let mark = BurnMark(id: UUID().uuidString,
                            x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1),
                            r: min(max(r, 0.02), 0.3), uid: uid)
        guard let uid else {
            burns[postID, default: []].append(mark)
            return
        }
        post(postID).collection("burns").document(mark.id).setData([
            "uid": uid,
            "x": Self.round(mark.x),
            "y": Self.round(mark.y),
            "r": Self.round(mark.r),
            "at": FieldValue.serverTimestamp(),
        ])
    }

    // MARK: - Decoding

    private nonisolated static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    private nonisolated static func round(_ value: CGFloat) -> Double {
        (Double(value) * 10_000).rounded() / 10_000
    }
}
