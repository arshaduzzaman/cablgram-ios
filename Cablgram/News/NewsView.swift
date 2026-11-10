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
                            lovers: social.loves(post.id),
                            myLoveKey: social.myKey,
                            onLove: { on in social.setLove(on, on: post.id) },
                            myName: auth.displayName,
                            myPhotoURL: auth.user?.photoURL,
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
        .collapsesDock()
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
    /// Egg in hand: drag to aim, let go to throw.
    case aiming
}

/// How far the post is knocked about by a hit.
private struct ShakeValues {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var angle: Double = 0
    var scale: CGFloat = 1
}

/// One double-tap heart: where it pops, tilted a little each time.
private struct LoveBurst: Equatable {
    let id = UUID()
    let point: CGPoint
    let tilt = Double.random(in: -14...14)
}

/// One post: Cablgram's avatar on the left, then name, time, the headline
/// people paid steps for, the photo (with everyone's eggs on it), and a
/// slim counts row.
private struct PostRow: View {
    let post: NewsPost
    let eggs: [EggMark]
    let headlines: [Headline]
    let myID: String?
    /// Everyone who loved this post (user ids), and how to love or unlove it.
    let lovers: Set<String>
    let myLoveKey: String
    let onLove: (Bool) -> Void
    let myName: String
    let myPhotoURL: URL?
    let availableSteps: Int
    /// Spends steps; returns whether there were enough.
    let spend: (Int) -> Bool
    let onThrowEgg: (CGPoint) -> String
    let onHeadline: (String, Int) -> Void

    @State private var image: UIImage?
    @State private var loadFailed = false

    @State private var mode: HoldMode = .idle
    /// Where the hold started, as fractions of the photo.
    /// While aiming: where your finger (and the egg) is, and where it will
    /// land, as fractions of the photo.
    @State private var aimHand: CGPoint?
    @State private var aimTarget: CGPoint?
    /// Goes up each time an egg lands, to shake the post.
    @State private var shakes = 0
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
    /// Your splats outlined right now (after you tap one).
    /// Splats hidden with a tap, to see the photo clearly.
    @State private var splatsHidden = false
    /// The heart that pops where you double-tapped.
    @State private var loveBurst: LoveBurst?
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
                                 revealStart: revealStart, scale: eggScale, highlighted: crowded ? myEggs : [],
                                 animating: !landing.isEmpty || animateUntil > .now)
                            .opacity(splatsHidden ? 0 : 1)
                    }
                    .overlay {
                        PhotoTouchLayer(onHoldBegan: holdBegan,
                                        onHoldMoved: holdMoved,
                                        onHoldEnded: holdEnded,
                                        onTaps: taps)
                    }
                    .overlay { myMarkers.opacity(splatsHidden ? 0 : 1).allowsHitTesting(!splatsHidden) }
                    .overlay { loveBurstView }
                    .overlay { holdOverlay }
                    .animation(.easeInOut(duration: 0.25), value: splatsHidden)
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
        // A hard hit knocks the post about for a moment.
        .keyframeAnimator(initialValue: ShakeValues(), trigger: shakes) { content, v in
            content
                .rotationEffect(.degrees(v.angle))
                .offset(x: v.x, y: v.y)
                .scaleEffect(v.scale)
        } keyframes: { _ in
            KeyframeTrack(\.x) {
                SpringKeyframe(-11, duration: 0.05)
                SpringKeyframe(9, duration: 0.06)
                SpringKeyframe(-6, duration: 0.06)
                SpringKeyframe(3, duration: 0.07)
                SpringKeyframe(0, duration: 0.12)
            }
            KeyframeTrack(\.y) {
                SpringKeyframe(5, duration: 0.05)
                SpringKeyframe(-3, duration: 0.07)
                SpringKeyframe(0, duration: 0.14)
            }
            KeyframeTrack(\.angle) {
                SpringKeyframe(-1.6, duration: 0.05)
                SpringKeyframe(1.2, duration: 0.07)
                SpringKeyframe(-0.5, duration: 0.07)
                SpringKeyframe(0, duration: 0.12)
            }
            KeyframeTrack(\.scale) {
                SpringKeyframe(0.975, duration: 0.05)
                SpringKeyframe(1.0, duration: 0.25)
            }
        }
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

    /// While aiming: the egg in your hand, a dotted arc, and the target.
    @ViewBuilder
    private var holdOverlay: some View {
        if mode == .aiming, let hand = aimHand, let target = aimTarget {
            GeometryReader { geo in
                let h = CGPoint(x: hand.x * geo.size.width, y: hand.y * geo.size.height)
                let t = CGPoint(x: target.x * geo.size.width, y: target.y * geo.size.height)
                let lift = min(90, max(40, hypot(t.x - h.x, t.y - h.y) * 0.5))
                let control = CGPoint(x: (h.x + t.x) / 2, y: min(h.y, t.y) - lift)
                // Dotted flight path.
                Path { path in
                    path.move(to: h)
                    path.addQuadCurve(to: t, control: control)
                }
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [0.1, 9]))
                .shadow(color: .black.opacity(0.4), radius: 2)
                // Target.
                ZStack {
                    Circle()
                        .strokeBorder(Color.brand, style: StrokeStyle(lineWidth: 3, dash: [6, 5]))
                        .frame(width: 58, height: 58)
                    Circle().fill(Color.brand).frame(width: 9, height: 9)
                }
                .background(Circle().fill(.white.opacity(0.18)).frame(width: 58, height: 58))
                .shadow(color: .black.opacity(0.3), radius: 3)
                .position(t)
                // Egg in your hand, just above your finger.
                Canvas { context, size in
                    let egg = EggArt.egg(center: CGPoint(x: size.width / 2, y: size.height / 2),
                                         size: 34, angle: .degrees(-14))
                    context.drawLayer { layer in
                        layer.addFilter(.shadow(color: .black.opacity(0.4), radius: 4, y: 3))
                        layer.fill(egg, with: .color(EggArt.shell))
                    }
                    context.stroke(egg, with: .color(Color(white: 0.7)), lineWidth: 1)
                }
                .frame(width: 50, height: 50)
                .position(x: h.x, y: h.y - 34)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    // MARK: - Counts row

    private var actions: some View {
        HStack(spacing: 16) {
            Button {
                let loving = !loved
                if loving { Haptics.success() } else { Haptics.tap() }
                onLove(loving)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: loved ? "heart.fill" : "heart")
                        .font(.system(size: 19))
                        .foregroundStyle(loved ? Color.brand : .primary)
                        .symbolEffect(.bounce, value: loved)
                    if !lovers.isEmpty {
                        Text(lovers.count.formatted())
                            .font(.subheadline.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: Double(lovers.count)))
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .animation(.snappy, value: lovers.count)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loved ? "Unlove" : "Love")
            .accessibilityValue(lovers.count == 1 ? "1 love" : "\(lovers.count) loves")

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

            Button {
                Haptics.tap()
                showHeadlines = true
            } label: {
                Image(systemName: "pencil.line")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Write a headline")

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
        case .aiming: return "Aim, then let go to throw"
        case .idle:
            if splatsHidden { return "Eggs hidden · tap the photo to show" }
            if !revealed && !eggs.isEmpty {
                return eggs.count == 1 ? "1 egg hidden · throw one to see it" : "\(eggs.count) eggs hidden · throw one to see them"
            }
            return eggs.isEmpty && headlines.isEmpty ? "Hold to throw an egg · double-tap to love" : ""
        }
    }

    // MARK: - Taps and love

    private var loved: Bool { lovers.contains(myLoveKey) }

    /// One tap hides or shows the eggs, two love the post.
    private func taps(_ count: Int, at point: CGPoint, in size: CGSize) {
        guard mode == .idle, size.width > 0, size.height > 0 else { return }
        let spot = CGPoint(x: point.x / size.width, y: point.y / size.height)
        switch count {
        case 2:
            Haptics.success()
            if !loved { onLove(true) }
            let burst = LoveBurst(point: spot)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { loveBurst = burst }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(750))
                if loveBurst?.id == burst.id {
                    withAnimation(.easeOut(duration: 0.25)) { loveBurst = nil }
                }
            }
        default:
            // Only worth hiding once there are splats you can see.
            guard revealed, !eggs.isEmpty else { return }
            Haptics.soft()
            splatsHidden.toggle()
        }
    }

    /// The big heart that pops where you double-tapped.
    private var loveBurstView: some View {
        GeometryReader { geo in
            if let loveBurst {
                Image(systemName: "heart.fill")
                    .font(.system(size: 92))
                    .foregroundStyle(Color.brand)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                    .rotationEffect(.degrees(loveBurst.tilt))
                    .position(x: loveBurst.point.x * geo.size.width, y: loveBurst.point.y * geo.size.height)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
                    .id(loveBurst.id)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Eggs

    /// Your profile picture pinned beside each of your splats. When the post
    /// is crowded with other people's, yours also get a pink outline.
    private var myMarkers: some View {
        GeometryReader { geo in
            let radius = EggArt.size * geo.size.width * eggScale.to
            // Just one picture: by your latest splat.
            ForEach(eggs.filter { $0.id == latestMine }) { egg in
                let center = CGPoint(x: egg.x * geo.size.width, y: egg.y * geo.size.height)
                ZStack(alignment: .topTrailing) {
                    Color.clear
                        .frame(width: radius * 2, height: radius * 2)
                    Avatar(url: myPhotoURL, name: myName, size: 24)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .offset(x: 10, y: -10)
                }
                .allowsHitTesting(false)
                .position(center)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Your egg")
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: landing.keys.sorted())
    }

    /// Your most recent splat that has finished landing.
    private var latestMine: String? {
        eggs.filter { myEggs.contains($0.id) && landing[$0.id] == nil }
            .last?.id
    }

    /// Enough other people's splats that yours need an outline to stand out.
    private var crowded: Bool {
        revealed && eggs.count - myEggs.count >= 4
    }

    /// Eggs you threw: from this session, or saved under your account.
    private var myEggs: Set<String> {
        var ids = thrownHere
        if let myID { ids.formUnion(eggs.filter { $0.uid == myID }.map(\.id)) }
        return ids
    }

    /// Everyone's splats show once you've thrown an egg at this post.
    private var revealed: Bool { !myEggs.isEmpty }

    // MARK: - Gestures

    /// Hold: an egg appears where you pressed, which stays put as the
    /// anchor, with the target straight ahead of it.
    private func holdBegan(at point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        aimHand = CGPoint(x: point.x / size.width, y: point.y / size.height)
        aim(at: point, in: size)
        Haptics.press()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { mode = .aiming }
    }

    /// Drag to aim: the direction from the anchor to your finger sets the
    /// angle, and dragging further throws further.
    private func holdMoved(to point: CGPoint, in size: CGSize) {
        guard mode == .aiming else { return }
        aim(at: point, in: size)
    }

    private func aim(at point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        guard let hand = aimHand else { return }
        let anchor = CGPoint(x: hand.x * size.width, y: hand.y * size.height)
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        let pulled = hypot(dx, dy)
        // Until you drag a little, aim straight up.
        let direction = pulled < 14 ? CGVector(dx: 0, dy: -1) : CGVector(dx: dx / pulled, dy: dy / pulled)
        let reach = 110 + max(pulled - 14, 0) * 1.6
        let x = anchor.x + direction.dx * reach
        let y = anchor.y + direction.dy * reach
        aimTarget = CGPoint(x: min(max(x / size.width, 0.04), 0.96),
                            y: min(max(y / size.height, 0.04), 0.96))
    }

    /// Let go to throw from your hand to the target.
    private func holdEnded() {
        if mode == .aiming, let target = aimTarget {
            throwEgg(at: target, from: aimHand)
        }
        withAnimation(.snappy) { mode = .idle }
        aimHand = nil
        aimTarget = nil
    }

    /// Throws an egg (free) at `spot`, flying from `from` (your finger) or
    /// from below the photo. It hits hard: a big splat and the post shakes.
    private func throwEgg(at spot: CGPoint, from: CGPoint? = nil) {
        let firstHere = !revealed
        splatsHidden = false
        let id = onThrowEgg(spot)
        thrownHere.insert(id)
        knownEggs?.insert(id)
        let landingInfo = EggLanding(start: .now, thrown: true, from: from, strong: true)
        landing[id] = landingInfo
        eggHaptics.throwAndSplat(flight: landingInfo.impactTime())
        finishLanding(id)
        // Shake the post the moment it hits.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(landingInfo.impactTime()))
            shakes += 1
        }
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
        aimHand = nil
        aimTarget = nil
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
    /// Taps on the photo: 1 hides or shows eggs, 2 loves.
    var onTaps: (Int, CGPoint, CGSize) -> Void

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

        // One recognizer, with taps counted here: a double-tap loves the
        // post the instant the second tap lands (no waiting to see if a
        // third comes), and a lone tap waits a moment to make sure.
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = c
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PhotoTouchLayer?
        weak var view: UIView?

        private var count = 0
        private var lastTap: Date = .distantPast
        private var pendingSingle: DispatchWorkItem?
        private static let gap: TimeInterval = 0.28

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            let point = g.location(in: view)
            let size = view.bounds.size
            let now = Date.now
            count = now.timeIntervalSince(lastTap) < Self.gap ? count + 1 : 1
            lastTap = now
            pendingSingle?.cancel()
            pendingSingle = nil
            switch count {
            case 1:
                let single = DispatchWorkItem { [weak self] in
                    self?.parent?.onTaps(1, point, size)
                }
                pendingSingle = single
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.gap, execute: single)
            case 2:
                parent?.onTaps(2, point, size)
            default:
                break
            }
        }

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

        /// Pauses scrolling while holding: the feed, and the swipe between
        /// tabs, so sliding to a bubble never scrolls or changes tab.
        private var locked: [UIScrollView] = []

        private func setScrollLocked(_ lock: Bool) {
            if lock {
                guard locked.isEmpty else { return }
                var ancestor = view?.superview
                while let current = ancestor {
                    if let scroll = current as? UIScrollView, scroll.panGestureRecognizer.isEnabled {
                        scroll.panGestureRecognizer.isEnabled = false
                        locked.append(scroll)
                    }
                    ancestor = current.superview
                }
            } else {
                locked.forEach { $0.panGestureRecognizer.isEnabled = true }
                locked = []
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
