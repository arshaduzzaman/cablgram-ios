import SwiftUI

/// The Messages tab, like Instagram's DMs: your friends in a row at the top, then your
/// conversations. Chats and the Friends page push on top (the dock hides in a chat).
struct MessagesView: View {
    @Environment(InboxStore.self) private var inbox

    var body: some View {
        NavigationStack(path: Binding(get: { inbox.path }, set: { inbox.path = $0 })) {
            InboxHome()
                .navigationDestination(for: InboxRoute.self) { route in
                    switch route {
                    case .friends: FriendsView()
                    case .chat(let uid): ConversationView(other: uid)
                    }
                }
        }
        .tint(.brand)
    }
}

// MARK: - Inbox

private struct InboxHome: View {
    @Environment(InboxStore.self) private var inbox
    @EnvironmentObject private var friends: FriendsStore
    @EnvironmentObject private var auth: AuthStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if friends.friends.isEmpty {
                    findFriendsCard
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 8)
                } else {
                    friendsRow
                }

                if !friends.requests.isEmpty {
                    sectionHeader
                }

                if inbox.conversations.isEmpty {
                    if !friends.friends.isEmpty { emptyChats }
                } else {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        LazyVStack(spacing: 0) {
                            ForEach(inbox.conversations) { conversation in
                                row(conversation, now: context.date)
                            }
                        }
                    }
                }
            }
        }
        .collapsesDock()
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .top, spacing: 0) {
            InboxHeader(back: { inbox.close() }) {
                Text("Messages").font(.title2.bold())
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .animation(.snappy, value: inbox.conversations.map(\.id))
        .animation(.snappy, value: friends.friends.map(\.id))
    }

    // MARK: Friends row

    /// Friends you talked to most recently first, then whoever walked most this week.
    private var sortedFriends: [FriendLink] {
        friends.friends.sorted { a, b in
            let la = inbox.conversation(with: a.id)?.lastAt ?? .distantPast
            let lb = inbox.conversation(with: b.id)?.lastAt ?? .distantPast
            if la != lb { return la > lb }
            return (friends.walkers[a.id]?.stepsThisWeek ?? 0) > (friends.walkers[b.id]?.stepsThisWeek ?? 0)
        }
    }

    private var friendsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                addBubble
                ForEach(sortedFriends) { link in
                    friendBubble(link)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 14)
        }
    }

    private func friendBubble(_ link: FriendLink) -> some View {
        let walker = friends.walkers[link.id]
        let name = walker?.name ?? link.name
        let unread = inbox.conversation(with: link.id).map { inbox.unread($0) } ?? 0
        return Button {
            Haptics.tap()
            inbox.push(link.id)
        } label: {
            VStack(spacing: 6) {
                Avatar(url: walker?.photoURL ?? link.photoURL, name: name, size: 62)
                    .overlay(alignment: .bottomTrailing) {
                        if isActive(walker?.updatedAt) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 3))
                                .offset(x: 1, y: 1)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if unread > 0 {
                            Circle()
                                .fill(Color.brand)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 3))
                                .offset(x: 1, y: 1)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                VStack(spacing: 1) {
                    Text(shortName(name))
                        .font(.caption)
                        .foregroundStyle(Color.primary)
                        .fontWeight(unread > 0 ? .bold : .medium)
                        .lineLimit(1)
                    Text(stepsLabel(walker?.stepsThisWeek ?? 0))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 70)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SquishPress())
        .animation(.snappy, value: unread)
        .accessibilityLabel("\(name), \(stepsLabel(walker?.stepsThisWeek ?? 0))\(isActive(walker?.updatedAt) ? ", active now" : "")\(unread > 0 ? ", unread messages" : "")")
        .accessibilityHint("Opens your chat")
    }

    /// The first circle in the row: add friends (with a count when someone asked you).
    private var addBubble: some View {
        let count = friends.requests.count
        return Button {
            Haptics.tap()
            inbox.showFriends()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: 62, height: 62)
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
                .overlay(alignment: .topTrailing) { UnreadBadge(count: count).offset(x: 2, y: -2) }
                VStack(spacing: 1) {
                    Text("Add")
                        .font(.caption.weight(.medium))
                    Text(count > 0 ? (count == 1 ? "1 request" : "\(count) requests") : "friends")
                        .font(.caption2)
                        .foregroundStyle(count > 0 ? Color.brand : .secondary)
                }
                .lineLimit(1)
                .frame(width: 70)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SquishPress())
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: count)
        .accessibilityLabel(count > 0 ? "Add friends, \(count) requests" : "Add friends")
    }

    /// Steps this week, short: "640 steps", "9.8k steps".
    private func stepsLabel(_ steps: Int) -> String {
        steps >= 10_000 ? "\(steps / 1000)k steps"
            : steps >= 1000 ? String(format: "%.1fk steps", Double(steps) / 1000)
            : "\(steps) steps"
    }

    /// Their phone sent steps in the last 10 minutes.
    private func isActive(_ updated: Date?) -> Bool {
        guard let updated else { return false }
        return Date().timeIntervalSince(updated) < 600
    }

    private var findFriendsCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.brand.opacity(0.12)).frame(width: 52, height: 52)
                Image(systemName: "person.2.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.brand)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Find your friends")
                    .font(.subheadline.weight(.bold))
                Text("Add them by phone number")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                Haptics.tap()
                inbox.showFriends()
            } label: {
                Text("Find")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(Color.brand, in: Capsule())
            }
            .buttonStyle(SquishPress())
        }
        .padding(14)
        .card(cornerRadius: 18)
    }

    // MARK: Conversations

    private var sectionHeader: some View {
        HStack {
            Spacer()
            if !friends.requests.isEmpty {
                Button {
                    Haptics.tap()
                    inbox.showFriends()
                } label: {
                    Text(friends.requests.count == 1 ? "1 request" : "\(friends.requests.count) requests")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.brand)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private var emptyChats: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.brand.opacity(0.1)).frame(width: 84, height: 84)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.brand)
            }
            Text("No messages yet")
                .font(.headline)
            Text("Say hi or throw an egg 🥚 — tap a friend above.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
        .padding(.horizontal, 32)
    }

    private func row(_ conversation: Conversation, now: Date) -> some View {
        let unread = inbox.unread(conversation)
        let walker = friends.walkers[conversation.other]
        let name = walker?.name ?? conversation.name
        let typing = inbox.isTyping(conversation)
        let line = preview(conversation, name: name, unread: unread > 0, now: now)
        return Button {
            Haptics.tap()
            inbox.push(conversation.other)
        } label: {
            HStack(spacing: 12) {
                Avatar(url: walker?.photoURL ?? conversation.photoURL, name: name, size: 56)
                    .overlay(alignment: .bottomTrailing) {
                        if isActive(walker?.updatedAt) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 15, height: 15)
                                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 3))
                                .offset(x: 1, y: 1)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 15, weight: unread > 0 ? .semibold : .regular))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    HStack(spacing: 0) {
                        if typing {
                            Text("typing…")
                                .foregroundStyle(Color.brand)
                                .transition(.opacity)
                        } else {
                            Text(line.text)
                                .lineLimit(1)
                                .layoutPriority(-1)
                                .foregroundStyle(unread > 0 ? Color.primary : Color.secondary)
                                .transition(.opacity)
                            if line.age, let at = conversation.lastAt {
                                Text(" · \(ChatTime.short(at, now: now))")
                                    .lineLimit(1)
                                    .fixedSize()
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                    }
                    .font(.system(size: 14, weight: unread > 0 && !typing ? .semibold : .regular))
                    .animation(.easeInOut(duration: 0.2), value: typing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if unread > 0 {
                    Circle()
                        .fill(Color.brand)
                        .frame(width: 8, height: 8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPress())
        .animation(.snappy, value: unread)
        .accessibilityHint(unread > 0 ? "\(unread) unread" : "")
    }

    /// The second line of a row, Instagram style: their newest message, "You: …", or
    /// "Seen 2h" once they've read yours (with the age after it unless it's "Seen").
    private func preview(_ conversation: Conversation, name: String, unread: Bool, now: Date) -> (text: String, age: Bool) {
        let mine = conversation.lastFrom == auth.user?.uid
        if mine, !unread, let at = conversation.lastAt, conversation.seen(at),
           let read = conversation.read[conversation.other] {
            let age = ChatTime.short(read, now: now)
            return (age == "now" ? "Seen just now" : "Seen \(age)", false)
        }
        let quote = conversation.lastText.isEmpty ? "" : ": “\(conversation.lastText)”"
        switch conversation.lastKind {
        case .egg:
            return (mine ? "🥚 You egged \(shortName(name))\(quote)" : "🥚 Egged you\(quote)", true)
        case .text:
            return (mine ? "You: \(conversation.lastText)" : conversation.lastText, true)
        }
    }
}

/// Top-right of Messages: opens the Friends page, with a pink count of friend requests.
private struct AddFriendButton: View {
    @Environment(InboxStore.self) private var inbox
    @EnvironmentObject private var friends: FriendsStore

    var body: some View {
        let count = friends.requests.count
        Button {
            Haptics.tap()
            inbox.showFriends()
        } label: {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 40, height: 40)
                .overlay(alignment: .topTrailing) {
                    UnreadBadge(count: count).offset(x: 2, y: 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(SquishPress())
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: count)
        .accessibilityLabel(count > 0 ? "Add friends, \(count) requests" : "Add friends")
    }
}
