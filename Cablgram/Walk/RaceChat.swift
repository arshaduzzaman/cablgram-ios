import SwiftUI
import FirebaseAuth
import FirebaseFirestore

/// One message in a race chat.
struct ChatMessage: Identifiable, Equatable {
    let id: String
    let uid: String
    let name: String
    let photoURL: URL?
    let text: String
    let at: Date
    /// Set for the server's "X egged Y" event messages (`kind == "egg"`).
    var egg: ChatEgg? = nil
}

/// The egg in an egg event message: who got hit, and what was said.
struct ChatEgg: Equatable {
    let toUid: String
    let toName: String
    let toPhotoURL: URL?
    let message: String
    let eggId: String?
}

/// Live chat for everyone going for the same reward: `raceChats/{rewardID}/messages`.
/// Shared with Android. Holds the latest 100 messages, oldest first.
@MainActor
final class RaceChatStore: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var errorMessage: String?
    private(set) var rewardID: String?
    private var listener: ListenerRegistration?

    static let maxLength = 300

    var canChat: Bool { AuthStore.isConfigured && Auth.auth().currentUser != nil }

    /// Switches to the chat for `rewardID` (nil stops listening).
    func listen(to rewardID: String?) {
        guard rewardID != self.rewardID else { return }
        listener?.remove()
        listener = nil
        messages = []
        self.rewardID = rewardID
        guard let rewardID, canChat else { return }
        listener = Firestore.firestore().collection("raceChats").document(rewardID).collection("messages")
            .order(by: "at", descending: true)
            .limit(to: 100)
            .addSnapshotListener { [weak self] snapshot, error in
                let messages = snapshot?.documents.compactMap { doc -> ChatMessage? in
                    guard let uid = doc.get("uid") as? String, let text = doc.get("text") as? String else { return nil }
                    // A message you just sent has no server time yet: estimate it.
                    let at = (doc.get("at", serverTimestampBehavior: .estimate) as? Timestamp)?.dateValue() ?? Date()
                    var egg: ChatEgg?
                    if doc.get("kind") as? String == "egg", let toUid = doc.get("toUid") as? String {
                        egg = ChatEgg(toUid: toUid,
                                      toName: doc.get("toName") as? String ?? "Walker",
                                      toPhotoURL: (doc.get("toPhotoURL") as? String).flatMap(URL.init(string:)),
                                      message: (doc.get("message") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                      eggId: doc.get("eggId") as? String)
                    }
                    return ChatMessage(id: doc.documentID, uid: uid,
                                       name: doc.get("name") as? String ?? "Walker",
                                       photoURL: (doc.get("photoURL") as? String).flatMap(URL.init(string:)),
                                       text: text, at: at, egg: egg)
                }
                Task { @MainActor in
                    guard let self else { return }
                    if let messages { self.messages = messages.reversed() }
                    self.errorMessage = error?.localizedDescription
                }
            }
    }

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let rewardID, let user = Auth.auth().currentUser else { return }
        var data: [String: Any] = [
            "uid": user.uid,
            "name": user.displayName ?? "Walker",
            "text": String(text.prefix(Self.maxLength)),
            "platform": "ios",
            "at": FieldValue.serverTimestamp(),
        ]
        if let photo = user.photoURL?.absoluteString { data["photoURL"] = photo }
        Firestore.firestore().collection("raceChats").document(rewardID).collection("messages")
            .addDocument(data: data) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.errorMessage = error.localizedDescription }
            }
        Haptics.tap()
    }

    func delete(_ message: ChatMessage) {
        guard let rewardID, message.uid == Auth.auth().currentUser?.uid else { return }
        Firestore.firestore().collection("raceChats").document(rewardID).collection("messages")
            .document(message.id).delete()
        Haptics.soft()
    }
}

/// The race chat, right on the Walk page under your goal: a scrolling box of messages
/// and a field to type in, so you never leave the page.
struct RaceChatCard: View {
    let reward: Reward
    @ObservedObject var chat: RaceChatStore
    @EnvironmentObject private var leaderboard: LeaderboardStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var friends: FriendsStore
    @Environment(EggStore.self) private var eggs: EggStore?
    @Environment(InboxStore.self) private var inbox: InboxStore?
    @State private var draft = ""
    /// Whose profile is open (tapped picture or name).
    @State private var profile: EggTarget?
    /// Messages already there when the chat loaded: egg cards among them don't pop in.
    @State private var loadedIDs: Set<String>?
    /// Egg cards that have already popped in.
    @State private var popped: Set<String> = []
    @FocusState private var typing: Bool

    private var me: String? { auth.user?.uid }
    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Race chat").font(.title3.weight(.bold))
                Text("Everyone going for \(reward.fullName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                messages
                Divider()
                composer
            }
            .card()
        }
        .onChange(of: chat.messages.map(\.id), initial: true) { _, ids in
            if loadedIDs == nil, !ids.isEmpty { loadedIDs = Set(ids) }
        }
        .onChange(of: reward.id) { _, _ in
            loadedIDs = nil
            popped = []
        }
        .sheet(item: $profile) { person in
            WalkerProfileSheet(person: person, reward: reward)
                .environmentObject(friends)
                .environmentObject(leaderboard)
                .environment(eggs)
                .environment(inbox)
        }
    }

    private func open(_ person: EggTarget) {
        guard person.uid != me else { return }
        profile = person
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if chat.messages.isEmpty {
                        Text(chat.canChat ? "No messages yet. Say hi to your rivals 👋" : "Sign in to chat.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                    ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                        if let egg = message.egg {
                            EggChatCard(message: message, egg: egg, me: me,
                                        isNew: loadedIDs.map { !$0.contains(message.id) } == true
                                            && !popped.contains(message.id),
                                        onOpen: open,
                                        onShown: { popped.insert(message.id) })
                                .id(message.id)
                        } else {
                            let previous = index > 0 ? chat.messages[index - 1] : nil
                            let showsHeader = previous == nil || previous?.uid != message.uid || previous?.egg != nil
                            bubble(message, showsHeader: showsHeader)
                                .id(message.id)
                        }
                    }
                }
                .padding(12)
            }
            .frame(height: 190)
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.messages.last?.id) { _, last in
                guard let last else { return }
                withAnimation(.snappy) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    /// Shoutbox style: everyone's messages, yours too, on the left in the same style.
    /// Your name shows as "You" in pink.
    @ViewBuilder
    private func bubble(_ message: ChatMessage, showsHeader: Bool) -> some View {
        let mine = message.uid == me
        HStack(alignment: .top, spacing: 8) {
            Avatar(url: message.photoURL, name: message.name, size: 26)
                .opacity(showsHeader ? 1 : 0)
                .frame(height: showsHeader ? 26 : 0)
                .contentShape(Circle())
                .onTapGesture { if showsHeader { openProfile(of: message) } }
            VStack(alignment: .leading, spacing: 2) {
                if showsHeader {
                    HStack(spacing: 6) {
                        Text(mine ? "You" : firstName(message.name))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(mine ? Color.brand : .primary)
                            .contentShape(Rectangle())
                            .onTapGesture { openProfile(of: message) }
                        if let entry = leaderboard.ranked.first(where: { $0.id == message.uid }) {
                            Text("\(min(entry.totalSteps, reward.steps).formatted()) steps")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(message.at, format: .dateTime.hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(message.text)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button { UIPasteboard.general.string = message.text } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        if mine {
                            Button(role: .destructive) { chat.delete(message) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
            }
        }
        .padding(.top, showsHeader ? 6 : 0)
    }

    private func openProfile(of message: ChatMessage) {
        guard message.uid != me else { return }
        Haptics.tap()
        open(EggTarget(uid: message.uid, name: message.name, photoURL: message.photoURL))
    }

    /// Sends and closes the keyboard.
    private func send() {
        guard canSend else { return }
        chat.send(draft)
        draft = ""
        typing = false
    }

    private var composer: some View {
        VStack(spacing: 4) {
            if let error = chat.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(chat.canChat ? "Message" : "Sign in to chat", text: $draft)
                    .font(.subheadline)
                    .focused($typing)
                    .disabled(!chat.canChat)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { typing = false }.fontWeight(.semibold)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onChange(of: draft) { _, text in
                        if text.count > RaceChatStore.maxLength { draft = String(text.prefix(RaceChatStore.maxLength)) }
                    }
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.brand)
                }
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.4)
                .accessibilityLabel("Send")
            }
        }
        .padding(10)
    }
}

private func firstName(_ name: String) -> String {
    name.split(separator: " ").first.map(String.init) ?? name
}
