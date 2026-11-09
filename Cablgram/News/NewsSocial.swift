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

/// Slaps and drawings on posts, shared through Firestore so everyone sees
/// everyone's marks live:
///
///     newsPosts/{postId}                 { slaps }
///     newsPosts/{postId}/marks/{id}      { uid, x, y, a, at }
///     newsPosts/{postId}/drawings/{id}   { uid, author, at, strokes }
///
/// Only the posts on top of the pile are listened to. Without a signed-in
/// user (or Firebase), marks stay on this phone for the session.
@MainActor
final class NewsSocial: ObservableObject {
    @Published private(set) var slapCounts: [String: Int] = [:]
    @Published private(set) var marks: [String: [SlapMark]] = [:]
    @Published private(set) var drawings: [String: [DoodleComment]] = [:]

    private var listeners: [String: [ListenerRegistration]] = [:]

    private var uid: String? {
        AuthStore.isConfigured ? Auth.auth().currentUser?.uid : nil
    }

    private func post(_ id: String) -> DocumentReference {
        Firestore.firestore().collection("newsPosts").document(id)
    }

    func slapCount(_ postID: String) -> Int { slapCounts[postID] ?? 0 }
    func marks(_ postID: String) -> [SlapMark] { marks[postID] ?? [] }
    func drawings(_ postID: String) -> [DoodleComment] { drawings[postID] ?? [] }

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

            let drawings = doc.collection("drawings")
                .order(by: "at", descending: true)
                .limit(to: 30)
                .addSnapshotListener { [weak self] snapshot, _ in
                    guard let documents = snapshot?.documents else { return }
                    let drawings = documents.reversed().map(Self.drawing(from:))
                    Task { @MainActor in self?.drawings[id] = drawings }
                }

            listeners[id] = [count, marks, drawings]
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

    func postDrawing(_ strokes: [Stroke], by author: String, on postID: String) {
        guard !strokes.isEmpty else { return }
        let comment = DoodleComment(author: author, date: .now, strokes: strokes, authorID: uid)
        guard let uid else {
            drawings[postID, default: []].append(comment)
            return
        }
        post(postID).collection("drawings").document(comment.id.uuidString).setData([
            "uid": uid,
            "author": author,
            "at": FieldValue.serverTimestamp(),
            "strokes": strokes.map { stroke in
                [
                    "c": stroke.color.rawValue,
                    "w": Double(stroke.width),
                    // Flat x,y list, rounded, to keep documents small.
                    "p": stroke.points.flatMap { [Self.round($0.x), Self.round($0.y)] },
                ] as [String: Any]
            },
        ])
    }

    func deleteDrawing(_ commentID: UUID, on postID: String) {
        guard uid != nil else {
            drawings[postID]?.removeAll { $0.id == commentID }
            return
        }
        post(postID).collection("drawings").document(commentID.uuidString).delete()
    }

    // MARK: - Decoding

    private nonisolated static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    private nonisolated static func round(_ value: CGFloat) -> Double {
        (Double(value) * 10_000).rounded() / 10_000
    }

    private nonisolated static func drawing(from document: QueryDocumentSnapshot) -> DoodleComment {
        let data = document.data()
        let strokes: [Stroke] = (data["strokes"] as? [[String: Any]] ?? []).compactMap { raw in
            let flat = (raw["p"] as? [NSNumber] ?? []).map(\.doubleValue)
            guard flat.count >= 2 else { return nil }
            let points = stride(from: 0, to: flat.count - 1, by: 2).map { CGPoint(x: flat[$0], y: flat[$0 + 1]) }
            return Stroke(points: points,
                          color: InkColor(rawValue: raw["c"] as? String ?? "") ?? .pink,
                          width: CGFloat(number(raw["w"])) > 0 ? CGFloat(number(raw["w"])) : BrushSize.medium.rawValue)
        }
        return DoodleComment(id: UUID(uuidString: document.documentID) ?? UUID(),
                             author: data["author"] as? String ?? "Someone",
                             date: (data["at"] as? Timestamp)?.dateValue() ?? .now,
                             strokes: strokes,
                             authorID: data["uid"] as? String)
    }
}
