import SwiftUI
import UIKit

/// Cablgram's posts as a Threads-style feed: flat rows, hairlines between
/// them, and the photo itself is the control. Hold it to get 🥚 and ✍️,
/// then slide onto one: throw a rotten egg where you pressed, or spend steps
/// on a headline. Everything is shared live.
struct NewsView: View {
    var openWalk: () -> Void = {}

    @EnvironmentObject private var steps: StepStore
    @EnvironmentObject private var auth: AuthStore
    @StateObject private var feed = NewsFeed()
    @StateObject private var social = NewsSocial()
    /// Posts currently on screen; only these are listened to.
    @State private var onScreen: [String] = []

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                stepsRow

                if let message = feed.errorMessage, feed.posts.isEmpty {
                    ContentUnavailableView("No news right now",
                                           systemImage: "wifi.exclamationmark",
                                           description: Text(message))
                        .padding(.top, 60)
                }

                ForEach(feed.posts) { post in
                    PostRow(post: post,
                            eggs: social.eggs(post.id),
                            headlines: social.headlines(post.id),
                            myID: auth.user?.uid,
                            availableSteps: steps.availableSteps,
                            spend: { amount in steps.spend(amount) },
                            onThrowEgg: { spot in social.throwEgg(at: spot, on: post.id) },
                            onHeadline: { text, amount in
                                social.postHeadline(text, steps: amount, by: auth.displayName, on: post.id)
                            })
                        .hairline()
                        .onAppear {
                            if !onScreen.contains(post.id) { onScreen.append(post.id) }
                            if post.id == feed.posts.last?.id { Task { await feed.loadMore() } }
                        }
                        .onDisappear { onScreen.removeAll { $0 == post.id } }
                }

                if feed.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(24)
                }
            }
        }
        .background(Color(.systemBackground))
        .refreshable {
            Haptics.soft()
            await feed.refresh()
        }
        .task {
            // Shows last time's posts straight away, then swaps in fresh ones.
            await feed.refresh()
        }
        .onChange(of: onScreen) { _, ids in social.watch(ids) }
        .overlay(alignment: .top) {
            if let problem = social.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.85), in: Capsule())
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: problem) {
                        try? await Task.sleep(for: .seconds(5))
                        withAnimation { social.problem = nil }
                    }
            }
        }
        .animation(.snappy, value: social.problem)
    }

    /// This week's steps in one slim line, linking to the Walk tab.
    private var stepsRow: some View {
        Button(action: openWalk) {
            HStack(spacing: 12) {
                if let goal = steps.goalReward {
                    RewardImage(reward: goal)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: "figure.walk")
                        .font(.headline)
                        .foregroundStyle(Color.brand)
                        .frame(width: 44, height: 44)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(steps.stepsThisWeek.formatted()) steps this week")
                        .font(.subheadline.weight(.semibold))
                    if let goal = steps.goalReward {
                        Text(steps.stepsToGoal == 0 ? "\(goal.fullName) is ready to claim" : "\(steps.stepsToGoal.formatted()) steps to \(goal.fullName)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hairline()
    }
}

// MARK: - Post

/// What a hold on the photo is doing.
private enum HoldMode: Equatable {
    case idle
    /// 🥚 and ✍️ are showing; slide onto one.
    case choosing
    /// Finger is on 🥚: let go to throw.
    case eggReady
    /// Finger is on ✍️: let go to write a headline.
    case headlineReady
}

private enum HoldChoice { case egg, headline }

/// One post: Cablgram's avatar on the left, then name, time, the headline
/// people paid steps for, the photo (with everyone's eggs on it), and a
/// slim counts row.
private struct PostRow: View {
    let post: NewsPost
    let eggs: [EggMark]
    let headlines: [Headline]
    let myID: String?
    let availableSteps: Int
    /// Spends steps; returns whether there were enough.
    let spend: (Int) -> Bool
    let onThrowEgg: (CGPoint) -> String
    let onHeadline: (String, Int) -> Void

    @State private var image: UIImage?
    @State private var loadFailed = false

    @State private var mode: HoldMode = .idle
    /// Where the hold started, as fractions of the photo.
    @State private var pressPoint: CGPoint?
    @State private var hovered: HoldChoice?
    @State private var notice: String?
    @State private var showHeadlines = false

    /// Eggs flying or landing right now.
    @State private var landing: [String: EggLanding] = [:]
    /// Eggs already on the photo when it appeared (they don't animate).
    @State private var knownEggs: Set<String>?
    /// Eggs thrown from this phone this session (before Firestore says so).
    @State private var thrownHere: Set<String> = []
    /// When everyone else's splats start popping in after your first egg.
    @State private var revealStart: Date?
    @State private var eggScale = EggScale.steady(1)
    /// Keeps the egg animation running until this time.
    @State private var animateUntil = Date.distantPast
    @State private var eggHaptics = EggHaptics()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CablgramAvatar(size: 36)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    Text("cablgram")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.brand)
                    if let date = post.date {
                        Text(NewsFormat.shortAge(date))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let top = headlines.first {
                    headline(top)
                }

                photo

                actions
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .onDisappear { cancelHold() }
        .onChange(of: eggs.map(\.id), initial: true) { _, ids in noticeNewEggs(ids) }
        .sheet(isPresented: $showHeadlines) {
            HeadlineSheet(headlines: headlines, availableSteps: availableSteps) { text, steps in
                guard spend(steps) else { return false }
                onHeadline(text, steps)
                Haptics.celebrate()
                return true
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Headline

    /// The headline with the most steps behind it. Tap to see the rest or
    /// write a better one.
    private func headline(_ top: Headline) -> some View {
        Button {
            Haptics.tap()
            showHeadlines = true
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(top.text)
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Image(systemName: "pencil.line")
                    Text("\(top.firstName) · \(top.steps.formatted()) steps")
                        .monospacedDigit()
                    if headlines.count > 1 {
                        Text("· \(headlines.count - 1) more")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("See all headlines or write your own")
    }

    // MARK: - Photo

    private var photo: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        EggLayer(eggs: eggs, landing: landing, mine: myEggs, revealed: revealed,
                                 revealStart: revealStart, scale: eggScale,
                                 animating: !landing.isEmpty || animateUntil > .now)
                    }
                    .overlay {
                        PhotoTouchLayer(onHoldBegan: holdBegan,
                                        onHoldMoved: holdMoved,
                                        onHoldEnded: holdEnded)
                    }
                    .overlay { holdOverlay }
            } else {
                ZStack {
                    Color(.secondarySystemBackground)
                    if loadFailed {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                .aspectRatio(1, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(.separator).opacity(0.5), lineWidth: 1 / 3)
                .allowsHitTesting(false)
        )
        .task(id: post.imageUrl) {
            if image == nil { image = PhotoCache.shared.cached(post.imageUrl) }
            guard image == nil else { return }
            image = await PhotoCache.shared.load(post.imageUrl)
            loadFailed = image == nil
        }
    }

    /// 🥚 and ✍️ above your finger while choosing, like Facebook reactions,
    /// and a target where the egg will land.
    @ViewBuilder
    private var holdOverlay: some View {
        if mode == .choosing || mode == .eggReady || mode == .headlineReady {
            GeometryReader { geo in
                if let pressPoint, mode != .headlineReady {
                    Circle()
                        .strokeBorder(Color.brand, style: StrokeStyle(lineWidth: 3, dash: [6, 5]))
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(.white.opacity(0.15)))
                        .scaleEffect(mode == .eggReady ? 1.15 : 1)
                        .position(x: pressPoint.x * geo.size.width, y: pressPoint.y * geo.size.height)
                }
                HStack(spacing: 10) {
                    choiceBubble(.egg, emoji: "🥚", title: "Egg · \(EggPrice.steps)")
                    choiceBubble(.headline, emoji: "✍️", title: "Headline")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.white, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                .position(menuCenter(in: geo.size))
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
            .allowsHitTesting(false)
        }
    }

    private func choiceBubble(_ choice: HoldChoice, emoji: String, title: String) -> some View {
        let isHovered = hovered == choice
        return VStack(spacing: 3) {
            Text(emoji)
                .font(.system(size: 30))
                .frame(width: 50, height: 50)
                .background(isHovered ? Color.brand.opacity(0.15) : Color(.secondarySystemBackground), in: Circle())
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.black)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: 58)
        .scaleEffect(isHovered ? 1.3 : 1, anchor: .bottom)
        .animation(.spring(response: 0.25, dampingFraction: 0.55), value: isHovered)
    }

    /// Where the menu sits: above the finger, kept inside the photo.
    private func menuCenter(in size: CGSize) -> CGPoint {
        guard let pressPoint else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        let x = min(max(pressPoint.x * size.width, 80), size.width - 80)
        var y = pressPoint.y * size.height - 86
        if y < 50 { y = pressPoint.y * size.height + 86 }
        return CGPoint(x: x, y: min(y, size.height - 50))
    }

    /// Centre of each bubble in the menu, for working out which one the
    /// finger is on.
    private func spot(_ choice: HoldChoice, in size: CGSize) -> CGPoint {
        let center = menuCenter(in: size)
        let offset: CGFloat = switch choice { case .egg: -34; case .headline: 34 }
        return CGPoint(x: center.x + offset, y: center.y - 6)
    }

    // MARK: - Counts row

    private var actions: some View {
        HStack(spacing: 16) {
            if !eggs.isEmpty {
                HStack(spacing: 3) {
                    Text("🥚")
                        .font(.system(size: 15))
                    Text(eggs.count.formatted())
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: Double(eggs.count)))
                }
                .animation(.snappy, value: eggs.count)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(eggs.count == 1 ? "1 egg thrown" : "\(eggs.count) eggs thrown")
            }

            Spacer(minLength: 0)

            Text(hint)
                .font(.caption)
                .foregroundStyle(notice == nil && mode == .idle ? .tertiary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .animation(.snappy, value: hint)
        }
    }

    private var hint: String {
        if let notice { return notice }
        switch mode {
        case .choosing: return "Slide to Egg or Headline"
        case .eggReady: return "Let go to throw · \(EggPrice.steps) steps"
        case .headlineReady: return "Let go to write a headline"
        case .idle:
            if !revealed && !eggs.isEmpty {
                return eggs.count == 1 ? "1 egg hidden · throw one to see it" : "\(eggs.count) eggs hidden · throw one to see them"
            }
            return eggs.isEmpty && headlines.isEmpty ? "Hold the photo" : ""
        }
    }

    // MARK: - Eggs

    /// Eggs you threw: from this session, or saved under your account.
    private var myEggs: Set<String> {
        var ids = thrownHere
        if let myID { ids.formUnion(eggs.filter { $0.uid == myID }.map(\.id)) }
        return ids
    }

    /// Everyone's splats show once you've thrown an egg at this post.
    private var revealed: Bool { !myEggs.isEmpty }

    // MARK: - Gestures

    private func holdBegan(at point: CGPoint, in size: CGSize) {
        pressPoint = CGPoint(x: point.x / size.width, y: point.y / size.height)
        hovered = nil
        Haptics.press()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { mode = .choosing }
    }

    /// The finger picks a bubble; letting go uses it, and sliding off
    /// cancels it.
    private func holdMoved(to point: CGPoint, in size: CGSize) {
        guard mode == .choosing || mode == .eggReady || mode == .headlineReady else { return }
        let reach: CGFloat = 36
        let choice = [HoldChoice.egg, .headline].first { choice in
            let c = spot(choice, in: size)
            return hypot(point.x - c.x, point.y - c.y) < reach
        }
        guard choice != hovered else { return }
        hovered = choice
        switch choice {
        case .egg:
            Haptics.select()
            withAnimation(.snappy) { mode = .eggReady }
        case .headline:
            Haptics.select()
            withAnimation(.snappy) { mode = .headlineReady }
        case nil:
            withAnimation(.snappy) { mode = .choosing }
        }
    }

    private func holdEnded() {
        switch mode {
        case .eggReady:
            if let pressPoint { throwEgg(at: pressPoint) }
        case .headlineReady:
            showHeadlines = true
        case .choosing:
            Haptics.soft()
        case .idle:
            break
        }
        hovered = nil
        withAnimation(.snappy) { mode = .idle }
    }

    private func throwEgg(at spot: CGPoint) {
        guard spend(EggPrice.steps) else {
            Haptics.error()
            show("An egg costs \(EggPrice.steps) steps. Go for a walk!")
            return
        }
        let firstHere = !revealed
        let id = onThrowEgg(spot)
        thrownHere.insert(id)
        knownEggs?.insert(id)
        landing[id] = EggLanding(start: .now, thrown: true)
        eggHaptics.throwAndSplat(flight: EggLanding.flight)
        finishLanding(id)
        if firstHere {
            reveal()
        } else {
            resize(to: eggs.count + 1)
        }
    }

    /// Your first egg on a post: once it lands, everyone else's splats pop
    /// in, then they all shrink together, like zooming out on the wall.
    private func reveal() {
        let others = eggs.count
        let start = Date.now.addingTimeInterval(EggLanding.flight + 0.3)
        revealStart = start
        let popIn = min(0.8, Double(others) * 0.06) + 0.35
        eggScale = EggScale(from: 1, to: EggScale.target(for: others + 1),
                            start: start.addingTimeInterval(popIn), duration: 1.1)
        keepAnimating(until: eggScale.end.addingTimeInterval(2.5))
        if others > 0 {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(EggLanding.flight + 0.3))
                Haptics.soft()
            }
        }
    }

    /// Eases splats to the right size for `count` eggs.
    private func resize(to count: Int) {
        let target = EggScale.target(for: count)
        let now = Date.now
        let current = eggScale.value(at: now)
        guard abs(current - target) > 0.01 else { return }
        eggScale = EggScale(from: current, to: target, start: now, duration: 0.7)
        keepAnimating(until: eggScale.end)
    }

    private func keepAnimating(until date: Date) {
        animateUntil = max(animateUntil, date)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(date.timeIntervalSinceNow, 0) + 0.1))
            // Changing it re-renders, so the animation clock can pause.
            if animateUntil <= .now { animateUntil = .distantPast }
        }
    }

    /// Eggs other people throw land live while you watch, once you've
    /// thrown one yourself.
    private func noticeNewEggs(_ ids: [String]) {
        guard var known = knownEggs else {
            knownEggs = Set(ids)
            // Already thrown here before: everything shows, at the right size.
            if revealed { eggScale = .steady(EggScale.target(for: ids.count)) }
            return
        }
        let fresh = ids.filter { !known.contains($0) }
        guard !fresh.isEmpty else { return }
        fresh.forEach { known.insert($0) }
        knownEggs = known
        guard revealed else { return }
        for id in fresh where !thrownHere.contains(id) {
            landing[id] = EggLanding(start: .now, thrown: false)
            finishLanding(id)
        }
        if fresh.contains(where: { !thrownHere.contains($0) }) { eggHaptics.splat() }
        resize(to: ids.count)
    }

    private func finishLanding(_ id: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(EggLanding.total))
            landing[id] = nil
        }
    }

    /// Resets a hold that's cut short (row scrolled away).
    private func cancelHold() {
        hovered = nil
        mode = .idle
    }

    private func show(_ message: String) {
        notice = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if notice == message { notice = nil }
        }
    }
}

// MARK: - Headlines

/// Every headline written for a post, most steps first, and a box to write
/// your own. Yours goes on top if you spend more than the current one.
private struct HeadlineSheet: View {
    let headlines: [Headline]
    let availableSteps: Int
    /// Returns whether it went through (enough steps).
    let onPost: (String, Int) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var amount = 0
    @FocusState private var typing: Bool

    /// The least it takes to go on top.
    private var minimum: Int {
        max(Headline.minimumSteps, (headlines.first?.steps ?? 0) + (headlines.isEmpty ? 0 : Headline.outbidBy))
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAfford: Bool { availableSteps >= minimum }
    private var canPost: Bool { trimmed.count >= 3 && canAfford && amount >= minimum && amount <= availableSteps }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(headlines.isEmpty ? "Write the headline for this post" : "Write a better headline",
                                  text: $text, axis: .vertical)
                            .font(.system(size: 20, weight: .heavy))
                            .lineLimit(1...3)
                            .focused($typing)
                            .onChange(of: text) { _, new in
                                if new.count > Headline.maxLength { text = String(new.prefix(Headline.maxLength)) }
                            }
                        HStack {
                            Text(headlines.isEmpty
                                 ? "The headline with the most steps shows on the post."
                                 : "Beat \(headlines[0].steps.formatted()) steps to go on top.")
                            Spacer()
                            Text("\(text.count)/\(Headline.maxLength)")
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if canAfford {
                        stepsPicker
                    } else {
                        Label("You need \(minimum.formatted()) steps. You have \(availableSteps.formatted()). Go for a walk!",
                              systemImage: "figure.walk")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.brand)
                    }

                    Button {
                        guard canPost else { return }
                        if onPost(trimmed, amount) { dismiss() }
                    } label: {
                        Text(canAfford ? "Spend \(amount.formatted()) steps" : "Not enough steps")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(canPost ? Color.brand : Color.brand.opacity(0.4), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canPost)

                    Text("Spent steps come off your reward progress. Your walked total on the leaderboard stays the same.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !headlines.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Headlines")
                                .font(.headline)
                                .padding(.bottom, 8)
                            ForEach(Array(headlines.enumerated()), id: \.element.id) { index, line in
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.subheadline.weight(.bold).monospacedDigit())
                                        .foregroundStyle(index == 0 ? Color.brand : .secondary)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(line.text)
                                            .font(.subheadline.weight(index == 0 ? .bold : .regular))
                                        Text("\(line.firstName) · \(line.steps.formatted()) steps")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 10)
                                .hairline(leading: 30)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle(headlines.isEmpty ? "Write a headline" : "Headlines")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .tint(.brand)
        .onAppear {
            amount = min(max(minimum, 0), max(availableSteps, minimum))
            typing = true
        }
    }

    /// How many steps to spend: − and + in hundreds, from the minimum up to
    /// everything you have.
    private var stepsPicker: some View {
        HStack(spacing: 16) {
            stepButton("minus", enabled: amount - 100 >= minimum) { amount -= 100 }
            VStack(spacing: 0) {
                Text(amount.formatted())
                    .font(.system(size: 34, weight: .bold).monospacedDigit())
                    .contentTransition(.numericText(value: Double(amount)))
                    .animation(.snappy, value: amount)
                Text("of \(availableSteps.formatted()) steps you have")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            stepButton("plus", enabled: amount + 100 <= availableSteps) { amount += 100 }
        }
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            action()
        } label: {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(enabled ? Color.brand : .secondary)
                .frame(width: 48, height: 48)
                .background(Color(.secondarySystemBackground), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .buttonRepeatBehavior(.enabled)
    }
}

/// Transparent UIKit layer over a post photo. A hold only starts once the
/// finger has stayed still, so the feed always scrolls normally; once it
/// starts, scrolling pauses until the finger lifts.
private struct PhotoTouchLayer: UIViewRepresentable {
    var onHoldBegan: (CGPoint, CGSize) -> Void
    var onHoldMoved: (CGPoint, CGSize) -> Void
    var onHoldEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let c = context.coordinator
        c.view = view

        let hold = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.handleHold(_:)))
        hold.minimumPressDuration = 0.3
        hold.allowableMovement = 8
        hold.delegate = c
        view.addGestureRecognizer(hold)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PhotoTouchLayer?
        weak var view: UIView?
        private weak var lockedScroll: UIScrollView?

        @objc func handleHold(_ g: UILongPressGestureRecognizer) {
            guard let view, let parent else { return }
            let point = g.location(in: view)
            switch g.state {
            case .began:
                setScrollLocked(true)
                parent.onHoldBegan(point, view.bounds.size)
            case .changed:
                parent.onHoldMoved(point, view.bounds.size)
            case .ended, .cancelled, .failed:
                setScrollLocked(false)
                parent.onHoldEnded()
            default:
                break
            }
        }

        /// Pauses the feed's scrolling while holding (and cancels a scroll
        /// that may have started), then gives it back.
        private func setScrollLocked(_ locked: Bool) {
            if locked {
                guard lockedScroll == nil else { return }
                var ancestor = view?.superview
                while let current = ancestor, !(current is UIScrollView) { ancestor = current.superview }
                guard let scroll = ancestor as? UIScrollView else { return }
                scroll.panGestureRecognizer.isEnabled = false
                lockedScroll = scroll
            } else if let scroll = lockedScroll {
                scroll.panGestureRecognizer.isEnabled = true
                lockedScroll = nil
            }
        }

        // Let the feed keep scrolling alongside these until a hold starts.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// Cablgram's profile picture in the feed (Assets: CablgramAvatar).
struct CablgramAvatar: View {
    var size: CGFloat = 36

    var body: some View {
        Image("CablgramAvatar")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color(.separator).opacity(0.5), lineWidth: 1 / 3))
    }
}
