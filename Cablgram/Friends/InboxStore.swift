import SwiftUI
import Observation
import FirebaseFirestore

/// One conversation with a friend, `conversations/{a_b}` (the two uids sorted). Only the
/// server writes these (cablgram-admin /api/friends).
struct Conversation: Identifiable, Equatable {
    let id: String
    /// The other person's uid.
    let other: String
    let name: String
    let photoURL: URL?
    let lastFrom: String?
    let lastText: String
    let lastKind: DirectMessage.Kind
    let lastAt: Date?
    /// Messages you haven't read yet, as the server counts them.
    let unread: Int
    /// When each member last started typing (their key is removed when they stop).
    let typing: [String: Date]
    /// When each member's phone last got the conversation's newest message.
    let delivered: [String: Date]
    /// When each member last read the conversation.
    let read: [String: Date]

    init?(_ doc: QueryDocumentSnapshot, me: String) {
        let data = doc.data(with: .estimate)
        guard let members = data["members"] as? [String],
              let other = members.first(where: { $0 != me }) ?? (members.count == 2 ? me : nil) else { return nil }
        id = doc.documentID
        self.other = other
        name = (data["names"] as? [String: String])?[other] ?? "Walker"
        photoURL = ((data["photos"] as? [String: String])?[other]).flatMap(URL.init(string:))
        let last = data["last"] as? [String: Any] ?? [:]
        lastFrom = last["from"] as? String
        lastText = (last["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        lastKind = (last["kind"] as? String).flatMap(DirectMessage.Kind.init(rawValue:)) ?? .text
        lastAt = (data["lastAt"] as? Timestamp)?.dateValue() ?? (last["at"] as? Timestamp)?.dateValue()
        unread = ((data["unread"] as? [String: Any])?[me] as? NSNumber)?.intValue ?? 0
        func dates(_ key: String) -> [String: Date] {
            (data[key] as? [String: Any] ?? [:]).compactMapValues { ($0 as? Timestamp)?.dateValue() }
        }
        typing = dates("typing")
        delivered = dates("delivered")
        read = dates("read")
    }

    /// The other person has read everything up to `date`.
    func seen(_ date: Date) -> Bool { read[other].map { $0 >= date } ?? false }
    /// The other person's phone has everything up to `date`.
    func reached(_ date: Date) -> Bool { seen(date) || (delivered[other].map { $0 >= date } ?? false) }
}

/// Your own receipts on a conversation (`typing`, `delivered` and `read`, keyed by your uid).
/// Only ever updates an existing conversation (the server creates them).
enum Receipts {
    private static func update(_ id: String, _ fields: [String: Any]) {
        guard AuthStore.isConfigured else { return }
        Firestore.firestore().collection("conversations").document(id).updateData(fields) { _ in }
    }

    static func typing(_ id: String, me: String, _ on: Bool) {
        update(id, ["typing.\(me)": on ? FieldValue.serverTimestamp() : FieldValue.delete()])
    }

    static func delivered(_ id: String, me: String) {
        update(id, ["delivered.\(me)": FieldValue.serverTimestamp()])
    }

    static func read(_ id: String, me: String) {
        update(id, ["read.\(me)": FieldValue.serverTimestamp(), "delivered.\(me)": FieldValue.serverTimestamp()])
    }
}

/// A message in a conversation, `conversations/{id}/messages/{msgId}`: a text, or an
/// egg the sender threw (walked off between `stepsAtThrow` and `cleanAt`).
struct DirectMessage: Identifiable, Equatable {
    enum Kind: String { case text, egg }

    let id: String
    let from: String
    let kind: Kind
    let text: String
    let at: Date
    let eggId: String?
    let stepsAtThrow: Int
    let cleanAt: Int

    init?(_ doc: QueryDocumentSnapshot) {
        guard let from = doc.get("from") as? String else { return nil }
        id = doc.documentID
        self.from = from
        kind = (doc.get("kind") as? String).flatMap(Kind.init(rawValue:)) ?? .text
        text = (doc.get("text") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        at = (doc.get("at", serverTimestampBehavior: .estimate) as? Timestamp)?.dateValue() ?? Date()
        eggId = doc.get("eggId") as? String
        stepsAtThrow = (doc.get("stepsAtThrow") as? NSNumber)?.intValue ?? 0
        cleanAt = (doc.get("cleanAt") as? NSNumber)?.intValue ?? stepsAtThrow + 1_000
    }

    var stepsToClean: Int { max(cleanAt - stepsAtThrow, 1) }
    func progress(total: Int) -> Double { min(max(Double(total - stepsAtThrow) / Double(stepsToClean), 0), 1) }
    func stepsLeft(total: Int) -> Int { max(cleanAt - total, 0) }
}

/// A text you sent that the conversation hasn't shown yet: greyed while it's on its way,
/// red with a retry when it failed.
struct PendingMessage: Identifiable, Equatable {
    let id = UUID().uuidString
    let text: String
    var at = Date()
    var failed = false
    /// The server took it; waiting for it to show up in the conversation.
    var accepted = false
    /// Messages already there when it was sent, so the right one confirms it.
    var before: Set<String> = []
}

/// A screen pushed on the Messages tab.
enum InboxRoute: Hashable {
    /// The Friends page (search, requests, your friends).
    case friends
    /// The conversation with this uid.
    case chat(String)
}

/// Your conversations, live, plus which chat is open. Shared by the Messages tab, the
/// dock badge and push notifications.
@MainActor
@Observable
final class InboxStore {
    /// Newest first.
    private(set) var conversations: [Conversation] = []
    private(set) var myUid: String?
    /// Screens pushed on the Messages tab.
    var path: [InboxRoute] = []
    /// Bumped to ask the shell to switch to the Messages tab.
    private(set) var tabRequest = 0
    /// The Messages screen is open (it slides in over everything from the top-right button).
    var isOpen = false
    /// A chat that should open with the egg sheet up.
    var eggOnOpen: String?
    /// `lastAt` of each conversation when you last read it, so the badge clears at once.
    private var readAt: [String: Date] = [:]
    /// Whether egg messages' eggs were cleaned (from `friendEggs/{id}`).
    private(set) var eggCleaned: [String: Bool] = [:]

    /// Conversations (ids) where the other person is typing right now.
    private(set) var typingNow: Set<String> = []
    /// Each conversation's typing stamp for the other person, and when this phone first saw it.
    @ObservationIgnored private var typingSeen: [String: (stamp: Date, seenAt: Date)] = [:]
    @ObservationIgnored private var typingTimer: Task<Void, Never>?
    /// The newest message each conversation was marked delivered for.
    @ObservationIgnored private var deliveredFor: [String: Date] = [:]

    @ObservationIgnored private var listener: ListenerRegistration?

    func isTyping(_ conversation: Conversation) -> Bool { typingNow.contains(conversation.id) }

    static func conversationID(_ a: String, _ b: String) -> String { [a, b].sorted().joined(separator: "_") }

    /// Unread messages for you, after anything you've just read.
    func unread(_ conversation: Conversation) -> Int {
        if let read = readAt[conversation.id], let last = conversation.lastAt, last <= read { return 0 }
        return conversation.unread
    }

    var unreadTotal: Int { conversations.reduce(0) { $0 + unread($1) } }

    func conversation(with uid: String) -> Conversation? { conversations.first { $0.other == uid } }

    /// A conversation is on top of the Messages tab (the dock hides).
    var inChat: Bool {
        if case .chat = path.last { return true }
        return false
    }

    /// From anywhere in the app: switches to the Messages tab and opens the chat with
    /// `uid` if given (optionally with the egg sheet up), or the inbox itself.
    func open(_ uid: String? = nil, egg: Bool = false) {
        if let uid {
            eggOnOpen = egg ? uid : nil
            if path.last != .chat(uid) { path = [.chat(uid)] }
        } else {
            path = []
        }
        tabRequest += 1
        isOpen = true
    }

    /// Closes the Messages screen (back to wherever you were).
    func close() {
        isOpen = false
        path = []
    }

    /// From inside the Messages tab: pushes the chat with `uid` on what's showing.
    func push(_ uid: String) {
        guard path.last != .chat(uid) else { return }
        path.append(.chat(uid))
    }

    /// Pushes the Friends page.
    /// One screen back (chat or Friends page → where you came from).
    func back() {
        if !path.isEmpty { path.removeLast() }
    }

    func showFriends() {
        guard path.last != .friends else { return }
        path.append(.friends)
    }

    /// Marks the chat with `uid` read here (the caller tells the server).
    func markedRead(_ uid: String) {
        guard let conversation = conversation(with: uid) else { return }
        readAt[conversation.id] = conversation.lastAt ?? Date()
    }

    func setEgg(_ id: String, cleaned: Bool) {
        if eggCleaned[id] != cleaned { eggCleaned[id] = cleaned }
    }

    /// Checks `friendEggs/{id}.cleaned` once.
    func checkEgg(_ id: String) async {
        guard AuthStore.isConfigured,
              let snapshot = try? await Firestore.firestore().collection("friendEggs").document(id).getDocument() else { return }
        setEgg(id, cleaned: snapshot.get("cleaned") as? Bool ?? false)
    }

    // MARK: - Listening

    func listen(uid: String?) {
        guard uid != myUid else { return }
        listener?.remove()
        listener = nil
        conversations = []
        readAt = [:]
        eggCleaned = [:]
        typingNow = []
        typingSeen = [:]
        deliveredFor = [:]
        // Signing in keeps a chat a notification asked to open (cold start); switching users doesn't.
        if myUid != nil { path = []; isOpen = false }
        myUid = uid
        guard AuthStore.isConfigured, let uid else { return }
        // No orderBy (no index needed); sorted here.
        listener = Firestore.firestore().collection("conversations")
            .whereField("members", arrayContains: uid)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let snapshot else { return }
                let list = snapshot.documents.compactMap { Conversation($0, me: uid) }
                    .sorted { ($0.lastAt ?? .distantPast) > ($1.lastAt ?? .distantPast) }
                Task { @MainActor in
                    guard let self, self.myUid == uid else { return }
                    self.conversations = list
                    self.markDelivered(me: uid)
                    self.refreshTyping()
                }
            }
    }

    /// Tells senders their newest message reached this phone.
    private func markDelivered(me: String) {
        for conversation in conversations {
            guard let last = conversation.lastAt, conversation.lastFrom != nil, conversation.lastFrom != me,
                  last > (conversation.delivered[me] ?? .distantPast),
                  last > (deliveredFor[conversation.id] ?? .distantPast) else { continue }
            deliveredFor[conversation.id] = last
            Receipts.delivered(conversation.id, me: me)
        }
    }

    /// Who's typing: a stamp under 6 seconds old (timed on this phone, so clocks don't matter;
    /// stamps left behind long ago don't count).
    private func refreshTyping() {
        let now = Date()
        var typing = Set<String>()
        for conversation in conversations {
            guard let stamp = conversation.typing[conversation.other] else {
                typingSeen[conversation.id] = nil
                continue
            }
            if typingSeen[conversation.id]?.stamp != stamp { typingSeen[conversation.id] = (stamp, now) }
            guard let seen = typingSeen[conversation.id] else { continue }
            if now.timeIntervalSince(seen.seenAt) < 6, abs(seen.seenAt.timeIntervalSince(stamp)) < 60 {
                typing.insert(conversation.id)
            }
        }
        if typing != typingNow { typingNow = typing }
        typingTimer?.cancel()
        typingTimer = nil
        guard !typing.isEmpty else { return }
        typingTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.refreshTyping()
        }
    }
}

/// One open chat: its latest 200 messages, live, and the texts you're sending.
@MainActor
@Observable
final class ChatStore {
    let me: String
    let other: String
    private(set) var messages: [DirectMessage] = []
    private(set) var pending: [PendingMessage] = []
    private(set) var loaded = false
    /// The server's sentence for the last failed send.
    private(set) var sendError: String?

    @ObservationIgnored private var listener: ListenerRegistration?
    /// When your typing stamp was last written (nil: not typing).
    @ObservationIgnored private var typingSent: Date?

    static let maxLength = 500

    var conversationID: String { InboxStore.conversationID(me, other) }

    /// Tells the other person you're typing (at most every 3 seconds) or that you stopped.
    func setTyping(_ on: Bool) {
        if on {
            if let sent = typingSent, Date().timeIntervalSince(sent) < 3 { return }
            typingSent = Date()
            Receipts.typing(conversationID, me: me, true)
        } else {
            guard typingSent != nil else { return }
            typingSent = nil
            Receipts.typing(conversationID, me: me, false)
        }
    }

    /// You've seen everything in the chat.
    func markRead() {
        Receipts.read(conversationID, me: me)
    }

    init(me: String, other: String) {
        self.me = me
        self.other = other
    }

    func start() {
        guard listener == nil, AuthStore.isConfigured else { return }
        let id = InboxStore.conversationID(me, other)
        listener = Firestore.firestore().collection("conversations").document(id).collection("messages")
            .order(by: "at")
            .limit(toLast: 200)
            .addSnapshotListener { [weak self] snapshot, _ in
                let list = snapshot?.documents.compactMap(DirectMessage.init)
                Task { @MainActor in
                    guard let self else { return }
                    if let list { self.messages = list }
                    self.loaded = true
                    self.confirmPending()
                }
            }
    }

    func stop() {
        listener?.remove()
        listener = nil
    }

    /// Shows the text at once and sends it.
    func send(_ raw: String, via friends: FriendsStore) {
        let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxLength))
        guard !text.isEmpty else { return }
        setTyping(false)
        let message = PendingMessage(text: text, before: Set(messages.map(\.id)))
        pending.append(message)
        post(message.id, via: friends)
    }

    func retry(_ id: String, via friends: FriendsStore) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].failed = false
        pending[index].at = Date()
        post(id, via: friends)
    }

    func discard(_ id: String) {
        pending.removeAll { $0.id == id }
    }

    private func post(_ id: String, via friends: FriendsStore) {
        guard let text = pending.first(where: { $0.id == id })?.text else { return }
        sendError = nil
        Task {
            do {
                try await friends.message(other, text: text)
                if let index = pending.firstIndex(where: { $0.id == id }) { pending[index].accepted = true }
                confirmPending()
            } catch {
                if let index = pending.firstIndex(where: { $0.id == id }) { pending[index].failed = true }
                sendError = error.localizedDescription
                Haptics.error()
            }
        }
    }

    /// Drops texts the conversation now shows.
    private func confirmPending() {
        var claimed = Set<String>()
        pending.removeAll { item in
            guard !item.failed else { return false }
            guard let match = messages.first(where: {
                $0.from == me && $0.kind == .text && $0.text == item.text
                    && !item.before.contains($0.id) && !claimed.contains($0.id)
            }) else { return false }
            claimed.insert(match.id)
            return true
        }
    }
}
