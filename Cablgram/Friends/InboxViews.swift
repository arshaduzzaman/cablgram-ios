import SwiftUI

// MARK: - Badge and button

/// A pink count bubble, like the ones on app icons.
struct UnreadBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Color.brand, in: Capsule())
                .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                .contentTransition(.numericText(value: Double(count)))
                .transition(.scale(scale: 0.3).combined(with: .opacity))
                .accessibilityHidden(true)
        }
    }
}

/// Rows darken a touch under your finger.
struct RowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.black.opacity(configuration.isPressed ? 0.05 : 0))
    }
}

// MARK: - Conversation

/// Instagram DM colours, in Cablgram pink.
enum ChatStyle {
    /// Received bubbles (#EFEFEF).
    static let received = Color(red: 239 / 255, green: 239 / 255, blue: 239 / 255)
    /// The composer's outline (#DBDBDB).
    static let outline = Color(red: 219 / 255, green: 219 / 255, blue: 219 / 255)
    static let avatar: CGFloat = 28
    static let gutter: CGFloat = 8

    /// 1–3 emoji and nothing else: shown big, without a bubble.
    static func isBigEmoji(_ text: String) -> Bool {
        let characters = text.filter { !$0.isWhitespace }
        guard (1...3).contains(characters.count) else { return false }
        return characters.allSatisfy { character in
            let scalars = character.unicodeScalars
            return scalars.contains { $0.properties.isEmojiPresentation }
                || (scalars.count > 1 && scalars.first?.properties.isEmoji == true)
        }
    }

    /// "Active now", "Active 23m ago", "Active 3h ago", "Active yesterday", "Active 4d ago".
    static func active(_ date: Date, now: Date) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        if seconds < 300 { return "Active now" }
        if seconds < 3600 { return "Active \(Int(seconds / 60))m ago" }
        if Calendar.current.isDateInToday(date) || seconds < 6 * 3600 { return "Active \(Int(seconds / 3600))h ago" }
        if Calendar.current.isDateInYesterday(date) { return "Active yesterday" }
        return "Active \(max(Int(seconds / 86_400), 2))d ago"
    }
}

/// How far your last message got, shown under it.
private enum Receipt: Equatable {
    case sending, sent, delivered, seen

    var label: String {
        switch self {
        case .sending: "Sending…"
        case .sent: "Sent"
        case .delivered: "Delivered"
        case .seen: "Seen"
        }
    }
}

/// A chat with one friend, like an Instagram DM: grouped bubbles, time separators, egg cards
/// with walk-off progress, typing dots, Sent / Delivered / Seen under your last message, and
/// a pill composer with an egg button.
struct ConversationView: View {
    let other: String

    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var steps: StepStore
    @EnvironmentObject private var friends: FriendsStore
    @Environment(InboxStore.self) private var inbox
    @Environment(EggStore.self) private var eggs
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var chat: ChatStore?
    @State private var draft = ""
    @State private var eggTarget: EggTarget?
    /// Messages there when the chat opened (they don't pop in or buzz).
    @State private var seen: Set<String>?
    /// Bubbles showing their time.
    @State private var timed: Set<String> = []
    @State private var haptics = EggHaptics()
    /// An egg thrown at you hitting the screen (once per egg).
    @State private var splat: ScreenSplat.Hit?
    @FocusState private var typing: Bool
    /// The chat's width (bubbles go up to 70% of it).
    @State private var width: CGFloat = 390
    /// The bottom of the chat is on screen.
    @State private var atBottom = true
    /// Something arrived while you were scrolled up.
    @State private var newBelow = false

    private var me: String { auth.user?.uid ?? "" }
    private var conversation: Conversation? { inbox.conversation(with: other) }
    private var walker: FriendWalker? { friends.walkers[other] }
    private var name: String { walker?.name ?? conversation?.name ?? friendLink?.name ?? "Walker" }
    private var photoURL: URL? { walker?.photoURL ?? conversation?.photoURL ?? friendLink?.photoURL }
    private var friendLink: FriendLink? { friends.links.first { $0.id == other } }
    private var isFriend: Bool { friends.status(of: other) == .friends }
    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var theyType: Bool { conversation.map(inbox.isTyping) ?? false }
    private var maxBubble: CGFloat { max(width * 0.7, 160) }
    /// Changes whenever a message is added (yours or theirs).
    private var lastKey: String {
        "\(chat?.messages.last?.id ?? "")|\(chat?.pending.last?.id ?? "")"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let chat, chat.loaded, chat.messages.isEmpty, chat.pending.isEmpty {
                        intro
                    }
                    ForEach(rows) { row in
                        rowView(row)
                            .id(row.id)
                    }
                    if theyType {
                        typingRow
                            .id("typing")
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear {
                            atBottom = true
                            withAnimation(.snappy) { newBelow = false }
                        }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)
                .animation(.easeInOut(duration: 0.25), value: theyType)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay(alignment: .bottom) {
                if newBelow {
                    Button {
                        Haptics.tap()
                        withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                        newBelow = false
                    } label: {
                        HStack(spacing: 5) {
                            Text("New message")
                            Image(systemName: "arrow.down")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.brand)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Color.white, in: Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                    }
                    .buttonStyle(SquishPress())
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .onChange(of: lastKey) { old, _ in
                let mine = chat?.pending.isEmpty == false || chat?.messages.last?.from == me
                if atBottom || mine || old.hasPrefix("|") {
                    withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                } else {
                    withAnimation(.snappy) { newBelow = true }
                }
            }
            .onChange(of: theyType) { _, on in
                guard on, atBottom else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(50))
                    withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onChange(of: typing) { _, focused in
                guard focused else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            InboxHeader(back: { inbox.back() }) {
                header
            } trailing: {
                if isFriend { headerEggButton }
            }
            .overlay(alignment: .bottom) { Divider() }
        }
        .background(Color(.systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .eggSheet($eggTarget)
        .overlay {
            if let splat {
                ScreenSplat(hit: splat) {
                    withAnimation(.easeOut(duration: 0.2)) { self.splat = nil }
                }
                .id(splat.id)
                .transition(.opacity)
            }
        }
        .onAppear(perform: start)
        .onDisappear {
            chat?.setTyping(false)
            chat?.stop()
            if PushRouter.shared.viewingChat == other { PushRouter.shared.viewingChat = nil }
        }
        .onChange(of: chat?.messages.map(\.id)) { _, _ in arrived() }
        .onChange(of: conversation.map { inbox.unread($0) }) { _, unread in
            if (unread ?? 0) > 0, scenePhase == .active { markRead() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { markRead() } else { chat?.setTyping(false) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Avatar(url: photoURL, name: name, size: 32)
                .overlay(alignment: .bottomTrailing) {
                    if let updated = walker?.updatedAt, Date().timeIntervalSince(updated) < 600 {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                            .offset(x: 1, y: 1)
                    }
                }
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let subtitle = subtitle(now: context.date) {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .id(subtitle)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: theyType)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "typing…", when they were last active, or their steps this week.
    private func subtitle(now: Date) -> String? {
        if theyType { return "typing…" }
        if let updated = walker?.updatedAt { return ChatStyle.active(updated, now: now) }
        if let walker { return "\(walker.stepsThisWeek.formatted()) steps this week" }
        return nil
    }

    private var headerEggButton: some View {
        Button {
            Haptics.press()
            typing = false
            eggTarget = EggTarget(uid: other, name: name, photoURL: photoURL)
        } label: {
            EggIcon()
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                .frame(width: 25, height: 25)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SquishPress())
        .accessibilityLabel("Throw an egg at \(name)")
    }

    private var intro: some View {
        VStack(spacing: 10) {
            Avatar(url: photoURL, name: name, size: 84)
                .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
            Text(name).font(.title3.weight(.bold))
            Text(isFriend ? "Say hi, or throw an egg to get \(shortName(name)) walking." : "You can only message friends.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 24)
    }

    // MARK: Rows

    private enum Row: Identifiable {
        case time(Date)
        case message(DirectMessage, first: Bool, last: Bool)
        case pending(PendingMessage, first: Bool, last: Bool)
        case receipt(Receipt)

        var id: String {
            switch self {
            case .time(let date): "time-\(date.timeIntervalSince1970)"
            case .message(let message, _, _): message.id
            case .pending(let message, _, _): "pending-\(message.id)"
            case .receipt: "receipt"
            }
        }
    }

    /// Messages with a time between any two more than 30 minutes apart, grouped into runs by
    /// sender (two minutes apart at most; an egg card is a run of its own), and how far your
    /// last message got when it's the newest one.
    private var rows: [Row] {
        guard let chat else { return [] }
        struct Item { let from: String; let at: Date; let isEgg: Bool; let make: (Bool, Bool) -> Row }
        var items = chat.messages.map { message in
            Item(from: message.from, at: message.at, isEgg: message.kind == .egg) { .message(message, first: $0, last: $1) }
        }
        items += chat.pending.map { message in
            Item(from: me, at: max(message.at, chat.messages.last?.at ?? .distantPast), isEgg: false) {
                .pending(message, first: $0, last: $1)
            }
        }
        func joins(_ a: Item, _ b: Item) -> Bool {
            a.from == b.from && !a.isEgg && !b.isEgg && b.at.timeIntervalSince(a.at) < 120
        }
        var rows: [Row] = []
        for (index, item) in items.enumerated() {
            let previous = index > 0 ? items[index - 1] : nil
            let next = index + 1 < items.count ? items[index + 1] : nil
            if previous.map({ item.at.timeIntervalSince($0.at) > 1800 }) ?? true {
                rows.append(.time(item.at))
            }
            rows.append(item.make(previous.map { !joins($0, item) } ?? true, next.map { !joins(item, $0) } ?? true))
        }
        if let receipt { rows.append(.receipt(receipt)) }
        return rows
    }

    /// Under your last message while it's the newest in the chat.
    private var receipt: Receipt? {
        guard let chat else { return nil }
        if let pending = chat.pending.last { return pending.failed ? nil : .sending }
        guard let last = chat.messages.last, last.from == me else { return nil }
        guard let conversation else { return .sent }
        if conversation.seen(last.at) { return .seen }
        if conversation.reached(last.at) { return .delivered }
        return .sent
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .time(let date):
            Text(ChatTime.separator(date))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
                .padding(.bottom, 6)
        case .message(let message, let first, let last):
            if message.kind == .egg {
                let mine = message.from == me
                HStack(alignment: .bottom, spacing: ChatStyle.gutter) {
                    if !mine { Avatar(url: photoURL, name: name, size: ChatStyle.avatar) }
                    EggMessageCard(message: message, mine: mine, otherName: name,
                                   target: eggTotal(for: message), cleanedFlag: message.eggId.flatMap { inbox.eggCleaned[$0] },
                                   isNew: seen.map { !$0.contains(message.id) } ?? false)
                }
                .padding(.top, 8)
                .task(id: eggCheckKey(message)) { await checkEgg(message) }
            } else {
                bubble(id: message.id, text: message.text, at: message.at, mine: message.from == me,
                       first: first, last: last, pending: false, failed: false)
            }
        case .pending(let message, let first, let last):
            bubble(id: message.id, text: message.text, at: message.at, mine: true,
                   first: first, last: last, pending: true, failed: message.failed)
        case .receipt(let receipt):
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                Text(receipt.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .id(receipt.label)
                    .transition(.opacity)
                if receipt == .seen {
                    Avatar(url: photoURL, name: name, size: 14)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .padding(.top, 4)
            .padding(.trailing, 4)
            .animation(.easeInOut(duration: 0.25), value: receipt)
            .accessibilityElement(children: .combine)
        }
    }

    private func bubble(id: String, text: String, at: Date, mine: Bool, first: Bool, last: Bool,
                        pending: Bool, failed: Bool) -> some View {
        let big: CGFloat = 22, small: CGFloat = 5
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: mine ? big : (first ? big : small),
            bottomLeadingRadius: mine ? big : (last ? big : small),
            bottomTrailingRadius: mine ? (last ? big : small) : big,
            topTrailingRadius: mine ? (first ? big : small) : big,
            style: .continuous)
        let emoji = ChatStyle.isBigEmoji(text)
        let showsTime = timed.contains(id) || failed
        return VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            HStack(alignment: .bottom, spacing: ChatStyle.gutter) {
                if mine {
                    Spacer(minLength: 0)
                } else if last {
                    Avatar(url: photoURL, name: name, size: ChatStyle.avatar)
                } else {
                    Color.clear.frame(width: ChatStyle.avatar, height: 1)
                }
                if failed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.red)
                        .padding(.bottom, 8)
                        .transition(.scale.combined(with: .opacity))
                }
                Group {
                    if emoji {
                        Text(text)
                            .font(.system(size: 44))
                            .padding(.vertical, 2)
                    } else {
                        Text(text)
                            .font(.system(size: 17))
                            .foregroundStyle(mine ? Color.white : Color.black)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(mine ? Color.brand : ChatStyle.received, in: shape)
                    }
                }
                .opacity(pending && !failed ? 0.6 : 1)
                .contentShape(shape)
                .onTapGesture {
                    if failed, let chat {
                        Haptics.tap()
                        withAnimation(.snappy) { chat.retry(id, via: friends) }
                    } else {
                        Haptics.select()
                        withAnimation(.snappy) { if timed.contains(id) { timed.remove(id) } else { timed.insert(id) } }
                    }
                }
                .contextMenu {
                    Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
                    if failed, let chat {
                        Button { chat.retry(id, via: friends) } label: { Label("Try again", systemImage: "arrow.clockwise") }
                        Button(role: .destructive) { withAnimation(.snappy) { chat.discard(id) } } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .frame(maxWidth: maxBubble, alignment: mine ? .trailing : .leading)
                if !mine { Spacer(minLength: 0) }
            }
            if showsTime {
                Group {
                    if failed {
                        Text("Not sent. Tap to try again.").foregroundStyle(.red)
                    } else {
                        Text(at, format: .dateTime.hour().minute()).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, mine ? 4 : ChatStyle.avatar + ChatStyle.gutter + 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, first ? 8 : 2)
        .transition(reduceMotion ? .opacity : .asymmetric(
            insertion: .scale(scale: 0.85, anchor: mine ? .bottomTrailing : .bottomLeading).combined(with: .opacity),
            removal: .opacity))
        .animation(.snappy, value: failed)
    }

    /// Their avatar and a grey bubble with three bouncing dots.
    private var typingRow: some View {
        HStack(alignment: .bottom, spacing: ChatStyle.gutter) {
            Avatar(url: photoURL, name: name, size: ChatStyle.avatar)
            TypingDots()
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(ChatStyle.received, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) is typing")
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 0) {
            if isFriend {
                HStack(alignment: .bottom, spacing: 8) {
                    Button {
                        Haptics.press()
                        typing = false
                        eggTarget = EggTarget(uid: other, name: name, photoURL: photoURL)
                    } label: {
                        EggIcon()
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                            .frame(width: 18, height: 18)
                            .frame(width: 34, height: 34)
                            .background(Color.brand, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(SquishPress())
                    .padding(.leading, 5)
                    .padding(.bottom, 4)
                    .accessibilityLabel("Throw an egg at \(name)")

                    TextField("Message…", text: $draft, axis: .vertical)
                        .font(.system(size: 16))
                        .lineLimit(1...5)
                        .focused($typing)
                        .padding(.vertical, 11)
                        .padding(.trailing, canSend ? 0 : 14)
                        .onChange(of: draft) { _, text in
                            if text.count > ChatStore.maxLength { draft = String(text.prefix(ChatStore.maxLength)) }
                            chat?.setTyping(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                    if canSend {
                        Button(action: send) {
                            Text("Send")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Color.brand)
                                .padding(.horizontal, 14)
                                .frame(height: 42)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
                    }
                }
                .frame(minHeight: 44)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(ChatStyle.outline, lineWidth: 1))
                .animation(.easeOut(duration: 0.18), value: canSend)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 8)
            } else {
                Text("You can only message friends.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .overlay(alignment: .top) { Divider() }
            }
        }
        .background(Color(.systemBackground))
    }

    private func send() {
        guard canSend, let chat else { return }
        Haptics.tap()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { chat.send(draft, via: friends) }
        draft = ""
    }

    // MARK: Behaviour

    private func start() {
        PushRouter.shared.viewingChat = other
        if chat == nil, !me.isEmpty { chat = ChatStore(me: me, other: other) }
        chat?.start()
        markRead()
        if inbox.eggOnOpen == other {
            inbox.eggOnOpen = nil
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                eggTarget = EggTarget(uid: other, name: name, photoURL: photoURL)
            }
        }
    }

    private func markRead() {
        inbox.markedRead(other)
        chat?.markRead()
        Task { await friends.markRead(other) }
    }

    /// Eggs thrown at you that haven't hit your screen yet (on opening the chat, or arriving
    /// while it's open): the newest one splats across the screen, once.
    private func arrived() {
        guard let chat, chat.loaded else { return }
        if scenePhase == .active, chat.messages.last?.from == other { chat.markRead() }
        let ids = Set(chat.messages.map(\.id))
        if seen == nil { seen = ids } else { seen = seen?.union(ids) }
        let unseen = chat.messages.filter { $0.kind == .egg && $0.from != me && !SplatSeen.contains($0.id) }
        guard let newest = unseen.last else { return }
        SplatSeen.insert(unseen.map(\.id))
        guard splat == nil else { return }
        Task {
            // Let the chat settle (and the slide-in finish) before it hits.
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.easeIn(duration: 0.1)) {
                splat = ScreenSplat.Hit(id: newest.id, senderName: name, message: newest.text)
            }
        }
    }

    /// The step total an egg message is walked off against: yours, or your friend's.
    private func eggTotal(for message: DirectMessage) -> Int {
        message.from == me
            ? walker?.totalSteps ?? eggs.total(of: other) ?? message.stepsAtThrow
            : steps.totalSteps
    }

    private func eggCheckKey(_ message: DirectMessage) -> String {
        "\(message.eggId ?? "")|\(message.eggId.map(eggs.isUncleaned) ?? false)"
    }

    private func checkEgg(_ message: DirectMessage) async {
        guard let id = message.eggId, message.progress(total: eggTotal(for: message)) < 1 else { return }
        if eggs.isUncleaned(id) {
            inbox.setEgg(id, cleaned: false)
        } else {
            await inbox.checkEgg(id)
        }
    }
}

/// Three grey dots in a wave, like Instagram's typing bubble (0.9 s loop).
struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = (t / 0.9 - Double(index) * 0.18).truncatingRemainder(dividingBy: 1)
                    let wave = reduceMotion ? 0.5 : max(0, sin(phase * 2 * .pi))
                    Circle()
                        .fill(Color(white: 0.56))
                        .frame(width: 8, height: 8)
                        .scaleEffect(0.8 + 0.3 * wave)
                        .opacity(0.45 + 0.55 * wave)
                        .offset(y: -3 * wave)
                }
            }
            .frame(height: 10)
        }
    }
}


// MARK: - Egg message

/// An egg in the chat: who threw it, what they said, and how far it's been walked off.
private struct EggMessageCard: View {
    let message: DirectMessage
    let mine: Bool
    let otherName: String
    /// The target's step total right now.
    let target: Int
    /// `friendEggs/{id}.cleaned`, once known.
    let cleanedFlag: Bool?
    let isNew: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Bool
    @State private var showsTime = false
    @State private var burst: Double = 0
    @State private var wasClean: Bool?

    init(message: DirectMessage, mine: Bool, otherName: String, target: Int, cleanedFlag: Bool?, isNew: Bool) {
        self.message = message
        self.mine = mine
        self.otherName = otherName
        self.target = target
        self.cleanedFlag = cleanedFlag
        self.isNew = isNew
        _shown = State(initialValue: !isNew)
    }

    private var progress: Double { message.progress(total: target) }
    private var clean: Bool { progress >= 1 || cleanedFlag == true }
    private var left: Int { message.stepsLeft(total: target) }

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            card
                .frame(maxWidth: 290, alignment: .leading)
            if !mine { Spacer(minLength: 40) }
        }
        .scaleEffect(shown ? 1 : 0.6, anchor: mine ? .bottomTrailing : .bottomLeading)
        .opacity(shown ? 1 : 0)
        .onAppear {
            wasClean = clean
            guard !shown else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.25) : .spring(response: 0.45, dampingFraction: 0.55)) {
                shown = true
            }
        }
        .onChange(of: clean) { _, now in
            guard now, wasClean == false else { wasClean = now; return }
            wasClean = true
            if !mine { Haptics.celebrate() }
            if !reduceMotion { withAnimation(.easeOut(duration: 1.1)) { burst = 1 } }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(.white)
                    Text("🥚").font(.system(size: 20))
                    SparkleBurst(progress: burst)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mine ? "You egged \(shortName(otherName))" : "\(shortName(otherName)) egged you")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.black)
                    Button {
                        Haptics.select()
                        withAnimation(.snappy) { showsTime.toggle() }
                    } label: {
                        Text(message.at, format: showsTime
                             ? .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
                             : .dateTime.hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.black.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                }
            }

            if !message.text.isEmpty {
                Text("“\(message.text)”")
                    .font(.body.italic())
                    .foregroundStyle(.black.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if clean {
                Label {
                    Text("Walked off").font(.footnote.weight(.semibold))
                } icon: {
                    Text("✨")
                }
                .foregroundStyle(EggArt.yolkRim)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.black.opacity(0.08))
                            Capsule()
                                .fill(LinearGradient(colors: [EggArt.yolk, EggArt.yolkRim], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(6, geo.size.width * progress))
                        }
                    }
                    .frame(height: 6)
                    Text(mine
                         ? "\(shortName(otherName)) has \(left.formatted()) steps to go"
                         : "Walk \(message.stepsToClean.formatted()) steps to clean it off · \(left.formatted()) to go")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.black.opacity(0.55))
                        .contentTransition(.numericText(value: Double(left)))
                }
                .transition(.opacity)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.eggCream)
                .overlay(SplatPattern(seed: message.eggId ?? message.id))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(EggArt.yolk.opacity(0.35), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .animation(.smooth(duration: 0.8), value: progress)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: clean)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Times

enum ChatTime {
    /// "now", "5m", "14:05", "Yesterday", "Mon", "12 Nov".
    static func short(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if calendar.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if seconds < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// Between messages: "Today 10:23 PM", "Yesterday 9:02 AM", "Mon 4:15 PM", "12 Nov 4:15 PM".
    static func separator(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        if now.timeIntervalSince(date) < 6 * 86_400 { return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return "\(date.formatted(.dateTime.day().month(.abbreviated))) \(time)"
        }
        return "\(date.formatted(.dateTime.day().month(.abbreviated).year())) \(time)"
    }

    /// "Today", "Yesterday", "Monday", "12 Nov", "12 Nov 2025".
    static func day(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if now.timeIntervalSince(date) < 6 * 86_400 { return date.formatted(.dateTime.weekday(.wide)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.wide))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
