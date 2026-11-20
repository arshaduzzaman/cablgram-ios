import SwiftUI

/// The Friends page (pushed from Messages): find people by phone number, answer requests,
/// and see how far your friends walked this week and what they're going for. Tapping a
/// friend opens your chat. Everything updates live.
struct FriendsView: View {
    @EnvironmentObject private var store: FriendsStore
    @Environment(InboxStore.self) private var inbox: InboxStore?

    @State private var number = ""
    @State private var removing: FriendLink?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                searchCard

                if let error = store.actionError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if !store.requests.isEmpty {
                    section("Requests") {
                        ForEach(store.requests) { link in
                            requestRow(link)
                            if link.id != store.requests.last?.id { Divider().padding(.leading, 72) }
                        }
                    }
                }

                if !store.friends.isEmpty {
                    section("Friends") {
                        ForEach(store.friends) { link in
                            FriendRow(link: link, walker: store.walkers[link.id]) {
                                Haptics.tap()
                                inbox?.push(link.id)
                            }
                                .contextMenu {
                                    Button("Message", systemImage: "bubble.left") {
                                        inbox?.push(link.id)
                                    }
                                    Button("Remove friend", systemImage: "person.badge.minus", role: .destructive) {
                                        removing = link
                                    }
                                }
                            if link.id != store.friends.last?.id { Divider().padding(.leading, 72) }
                        }
                    }
                }

                if !store.sent.isEmpty {
                    section("Sent") {
                        ForEach(store.sent) { link in
                            sentRow(link)
                            if link.id != store.sent.last?.id { Divider().padding(.leading, 72) }
                        }
                    }
                }

                if store.links.isEmpty {
                    Label("Add friends by their phone number to see how far they walk.", systemImage: "person.2")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(cornerRadius: 18)
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .collapsesDock()
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .top, spacing: 0) {
            InboxHeader(back: { inbox?.back() }) {
                Text("Friends").font(.title2.bold())
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("Remove \(removing?.name ?? "friend")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible, presenting: removing) { link in
            Button("Remove friend", role: .destructive) {
                Haptics.warning()
                Task { await store.remove(link.id) }
            }
        } message: { _ in
            Text("You'll stop seeing each other's steps.")
        }
    }

    // MARK: - Search

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find a friend").font(.headline)
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Text("🇧🇩 +880")
                        .font(.body.weight(.semibold))
                    Divider().frame(height: 24)
                    TextField("1712 345678", text: $number)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .focused($focused)
                        .onChange(of: number) { _, _ in
                            if store.found != nil || store.searchError != nil { store.clearSearch() }
                        }
                }
                .padding(.horizontal, 14)
                .frame(height: 50)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    Haptics.press()
                    focused = false
                    Task { await store.find(number) }
                } label: {
                    ZStack {
                        if store.searching { ProgressView().tint(.white) } else { Text("Find").font(.headline) }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 50)
                    .background(Color.brand, in: Capsule())
                    .opacity(number.filter(\.isNumber).isEmpty ? 0.5 : 1)
                }
                .disabled(store.searching || number.filter(\.isNumber).isEmpty)
            }

            if let error = store.searchError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if let person = store.found {
                HStack(spacing: 12) {
                    Avatar(url: person.photoURL, name: person.name, size: 44)
                    Text(person.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    foundButton(person)
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .card(cornerRadius: 18)
    }

    @ViewBuilder
    private func foundButton(_ person: FoundPerson) -> some View {
        let busy = store.busy.contains(person.uid)
        switch store.status(of: person.uid) {
        case nil:
            pill("Add friend", filled: true, busy: busy) { await store.add(person.uid) }
        case .sent:
            pill("Requested", filled: false, busy: busy) { await store.remove(person.uid) }
                .accessibilityHint("Cancels the request")
        case .received:
            pill("Accept", filled: true, busy: busy) { await store.accept(person.uid) }
        case .friends:
            Text("Friends ✓")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.brand)
                .padding(.horizontal, 6)
        }
    }

    // MARK: - Rows

    private func requestRow(_ link: FriendLink) -> some View {
        let busy = store.busy.contains(link.id)
        return HStack(spacing: 12) {
            Avatar(url: link.photoURL, name: link.name, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("Wants to be friends").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            pill("Decline", filled: false, busy: false) { await store.remove(link.id) }
                .disabled(busy)
            pill("Accept", filled: true, busy: busy) { await store.accept(link.id) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func sentRow(_ link: FriendLink) -> some View {
        HStack(spacing: 12) {
            Avatar(url: link.photoURL, name: link.name, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("Requested").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            pill("Cancel", filled: false, busy: store.busy.contains(link.id)) { await store.remove(link.id) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func pill(_ title: String, filled: Bool, busy: Bool, action: @escaping () async -> Void) -> some View {
        Button {
            Haptics.tap()
            Task { await action() }
        } label: {
            ZStack {
                if busy {
                    ProgressView().tint(filled ? .white : .primary)
                } else {
                    Text(title).font(.footnote.weight(.semibold))
                }
            }
            .foregroundStyle(filled ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(filled ? Color.brand : Color.black.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.bold))
            VStack(spacing: 0) { content() }
                .card(cornerRadius: 18)
        }
    }
}

/// A friend: picture and name. Tap opens your chat.
private struct FriendRow: View {
    let link: FriendLink
    let walker: FriendWalker?
    var onOpen: () -> Void

    @Environment(InboxStore.self) private var inbox: InboxStore?

    var body: some View {
        let unread = inbox?.conversation(with: link.id).map { inbox?.unread($0) ?? 0 } ?? 0
        HStack(spacing: 12) {
            Avatar(url: walker?.photoURL ?? link.photoURL, name: walker?.name ?? link.name, size: 44)
            Text(walker?.name ?? link.name)
                .font(.body.weight(.semibold))
                .lineLimit(1)
            if unread > 0 {
                UnreadBadge(count: unread)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: unread)
        .padding(.trailing, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens your chat")
    }
}
