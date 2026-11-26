import Foundation
import FirebaseAuth
import FirebaseFirestore

/// A claim you sent, from `rewardClaims/{uid}__{rewardId}` (with `__{period}` added for a
/// timed reward). Only the server writes these:
/// the app sends a claim through cablgram-admin /api/rewards/claim and an admin approves,
/// rejects or marks it delivered on the dashboard.
struct RewardClaim: Identifiable, Equatable {
    enum Status: String {
        case pending, approved, delivered, rejected

        var label: String {
            switch self {
            case .pending: "Waiting for review"
            case .approved: "Approved"
            case .delivered: "Delivered"
            case .rejected: "Not approved"
            }
        }
    }

    /// The same as `Reward.claimKey`.
    var id: String { period.map { "\(rewardID)__\($0)" } ?? rewardID }
    let rewardID: String
    /// Timed rewards: the period claimed (its first day) and how to say it ("Thu 26 Nov").
    var period: String? = nil
    var periodLabel: String? = nil
    /// The reward's name when you claimed it (it may since be edited or removed).
    let rewardName: String
    let status: Status
    /// The admin's note: pickup details, or why it wasn't approved.
    let message: String?
    let createdAt: Date
    /// Steps the claim cost (given back if it's rejected), and for a timed reward the days they came from.
    var stepsSpent = 0
    var spentDays: [String: Int] = [:]
}

/// The rewards (edited on the dashboard) and your claims, both live from Firestore.
@MainActor
final class RewardStore: ObservableObject {
    static let shared = RewardStore()

    @Published private(set) var rewards: [Reward] = Reward.builtIn
    /// Timed rewards (daily, weekly, between dates) from `timedRewards`. Empty until they load.
    @Published private(set) var timed: [Reward] = []
    /// Your claims by `Reward.claimKey`.
    @Published private(set) var claims: [String: RewardClaim] = [:]

    private var catalogListener: ListenerRegistration?
    private var timedListener: ListenerRegistration?
    private var claimsListener: ListenerRegistration?
    private var uid: String?

    private static let claimURL = Backend.url("/api/rewards/claim")

    /// Listens for the signed-in user (rules only let signed-in people read), and stops on sign-out.
    func start(uid: String?) {
        guard AuthStore.isConfigured, uid != self.uid else { return }
        self.uid = uid
        claimsListener?.remove()
        claimsListener = nil
        claims = [:]
        guard let uid else {
            catalogListener?.remove()
            catalogListener = nil
            timedListener?.remove()
            timedListener = nil
            rewards = Reward.builtIn
            timed = []
            return
        }

        if timedListener == nil {
            timedListener = Firestore.firestore().collection("timedRewards").addSnapshotListener { [weak self] snapshot, _ in
                guard let snapshot else { return }
                let live = snapshot.documents.compactMap(Self.reward).filter { $0.schedule != nil }
                    .sorted { $0.steps != $1.steps ? $0.steps < $1.steps : $0.fullName < $1.fullName }
                Task { @MainActor in self?.timed = live }
            }
        }

        if catalogListener == nil {
            catalogListener = Firestore.firestore().collection("rewards").addSnapshotListener { [weak self] snapshot, _ in
                guard let snapshot else { return }
                let live = snapshot.documents.compactMap(Self.reward)
                    .sorted { $0.steps != $1.steps ? $0.steps < $1.steps : $0.fullName < $1.fullName }
                // No rewards set up on the dashboard yet: keep the built-in ones.
                Task { @MainActor in self?.rewards = snapshot.isEmpty ? Reward.builtIn : live }
            }
        }
        claimsListener = Firestore.firestore().collection("rewardClaims").whereField("uid", isEqualTo: uid)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let snapshot else { return }
                let mine = Dictionary(snapshot.documents.compactMap(Self.claim).map { ($0.id, $0) }) { a, _ in a }
                Task { @MainActor in
                    guard self?.uid == uid else { return }
                    self?.claims = mine
                }
            }
    }

    /// Your claims, newest first.
    var history: [RewardClaim] { claims.values.sorted { $0.createdAt > $1.createdAt } }

    /// Sends a claim. The server recounts your steps first. Throws the server's sentence to show.
    func claim(_ reward: Reward, address: String?, note: String?) async throws {
        guard AuthStore.isConfigured, let user = Auth.auth().currentUser else {
            throw ProfileError.message("Sign in to claim rewards.")
        }
        let token: String
        do { token = try await user.getIDToken() } catch { throw ProfileError.message("No internet connection.") }
        var body: [String: String] = ["rewardId": reward.id]
        if let span = reward.span { body["period"] = span.start }
        if let address, !address.isEmpty { body["address"] = address }
        if let note, !note.isEmpty { body["note"] = note }

        var request = URLRequest(url: Self.claimURL, timeoutInterval: 20)
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
            throw ProfileError.message("Couldn't reach Cablgram. Check your connection and try again.")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ProfileError.message(json["error"] as? String ?? "Something went wrong. Try again.")
        }
        // Show it as waiting right away (with what it cost); the listener brings the saved claim a moment later.
        let sent = json["claim"] as? [String: Any] ?? [:]
        claims[reward.claimKey] = RewardClaim(rewardID: reward.id, period: reward.span?.start,
                                              periodLabel: reward.span.map(RewardDays.label),
                                              rewardName: reward.fullName, status: .pending,
                                              message: nil, createdAt: .now,
                                              stepsSpent: (sent["stepsSpent"] as? NSNumber)?.intValue ?? 0,
                                              spentDays: (sent["spentDays"] as? [String: NSNumber] ?? [:]).mapValues(\.intValue))
    }

    // MARK: - Parsing

    nonisolated private static func reward(_ doc: QueryDocumentSnapshot) -> Reward? {
        let x = doc.data()
        guard x["active"] as? Bool != false, let title = x["title"] as? String else { return nil }
        let text = { (key: String) in (x[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return Reward(
            id: doc.documentID,
            title: title,
            partner: text("partner"),
            steps: (x["steps"] as? NSNumber)?.intValue ?? 0,
            icon: text("icon") ?? "gift",
            imageURL: text("imageUrl").flatMap(URL.init(string:)),
            details: text("description"),
            stock: (x["stock"] as? NSNumber)?.intValue,
            claimedCount: (x["claimedCount"] as? NSNumber)?.intValue ?? 0,
            needsAddress: x["needsAddress"] as? Bool ?? false,
            schedule: (x["period"] as? String).flatMap(RewardSchedule.Kind.init(rawValue:)).map {
                RewardSchedule(kind: $0, from: text("from"), to: text("to"),
                               weekdays: (x["weekdays"] as? [NSNumber] ?? []).map(\.intValue),
                               everyDay: x["everyDay"] as? Bool ?? false)
            },
            periodClaims: (x["periodClaims"] as? [String: NSNumber] ?? [:]).mapValues(\.intValue)
        )
    }

    nonisolated private static func claim(_ doc: QueryDocumentSnapshot) -> RewardClaim? {
        let x = doc.data()
        guard let rewardID = x["rewardId"] as? String else { return nil }
        let text = { (key: String) in (x[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return RewardClaim(
            rewardID: rewardID,
            period: text("period"),
            periodLabel: text("periodLabel"),
            rewardName: x["rewardName"] as? String ?? rewardID,
            status: (x["status"] as? String).flatMap(RewardClaim.Status.init(rawValue:)) ?? .pending,
            message: (x["message"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            createdAt: (x["createdAt"] as? Timestamp)?.dateValue() ?? .now,
            stepsSpent: (x["stepsSpent"] as? NSNumber)?.intValue ?? 0,
            spentDays: (x["spentDays"] as? [String: NSNumber] ?? [:]).mapValues(\.intValue)
        )
    }
}
