import SwiftUI
import UIKit

/// Cablgram's posts as a Threads-style feed: flat rows, hairlines between
/// them, and the photo itself is the control. Double-tap to slap; hold to
/// get 🔥 and 🎙, then slide onto one: burn a hole right where you pressed,
/// or talk and pin a voice note there. Everything is shared live.
struct NewsView: View {
    var openWalk: () -> Void = {}

    @EnvironmentObject private var steps: StepStore
    @EnvironmentObject private var auth: AuthStore
    @StateObject private var feed = NewsFeed()
    @StateObject private var social = NewsSocial()
    @StateObject private var recorder = VoiceRecorder()
    @StateObject private var player = VoicePlayer()
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
                            slapCount: social.slapCount(post.id),
                            voices: social.voices(post.id),
                            burns: social.burns(post.id),
                            myID: auth.user?.uid,
                            recorder: recorder,
                            player: player,
                            onSlap: { spot in social.slap(post.id, at: spot) },
                            onVoice: { spot, audio, seconds in
                                social.postVoice(audio, seconds: seconds, at: spot,
                                                 by: auth.displayName, on: post.id)
                            },
                            onDeleteVoice: { id in social.deleteVoice(id, on: post.id) },
                            onBurn: { spot, radius in social.burn(post.id, at: spot, radius: radius) })
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
            if feed.posts.isEmpty { await feed.refresh() }
        }
        .onChange(of: onScreen) { _, ids in social.watch(ids) }
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
    /// 🔥 and 🎙 are showing; slide onto one.
    case choosing
    case burning
    case recording
}

private enum HoldChoice { case burn, voice }

/// One post: Cablgram's avatar on the left, then name, time, the photo
/// (with everyone's burns and voice notes on it), and a slim counts row.
private struct PostRow: View {
    let post: NewsPost
    let slapCount: Int
    let voices: [VoiceNote]
    let burns: [BurnMark]
    let myID: String?
    @ObservedObject var recorder: VoiceRecorder
    @ObservedObject var player: VoicePlayer
    let onSlap: (CGPoint) -> Void
    let onVoice: (CGPoint, Data, Double) -> Void
    let onDeleteVoice: (String) -> Void
    let onBurn: (CGPoint, Double) -> Void

    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var showBurst = false

    @State private var mode: HoldMode = .idle
    /// Where the hold started, as fractions of the photo.
    @State private var pressPoint: CGPoint?
    @State private var hovered: HoldChoice?
    @State private var burnStart: Date?
    @State private var burnHaptics = BurnHaptics()
    @State private var notice: String?

    /// Past this much burned away, the post is ash for everyone.
    private static let ashLine = 0.5

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

                photo

                actions
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .onDisappear { cancelHold() }
    }

    // MARK: - Photo

    private var photo: some View {
        Group {
            if let image {
                let ash = burnedFraction(aspect: image.size.height / max(image.size.width, 1)) >= Self.ashLine
                TimelineView(.animation(paused: burnStart == nil)) { timeline in
                    let active = activeBurn(at: timeline.date)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .grayscale(ash ? 1 : 0)
                        .brightness(ash ? -0.2 : 0)
                        .overlay {
                            BurnScars(burns: burns, active: active,
                                      time: timeline.date.timeIntervalSinceReferenceDate)
                        }
                        .mask { holes(active: active) }
                }
                .overlay { pins }
                .overlay {
                    PhotoTouchLayer(onHoldBegan: holdBegan,
                                    onHoldMoved: holdMoved,
                                    onHoldEnded: holdEnded,
                                    onDoubleTap: doubleTap)
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
        .overlay {
            // Big hand that pops up on a double-tap, like Instagram's heart.
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 84))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(-20))
                .shadow(color: .black.opacity(0.25), radius: 8)
                .scaleEffect(showBurst ? 1 : 0.4)
                .opacity(showBurst ? 1 : 0)
                .allowsHitTesting(false)
        }
        .task(id: post.imageUrl) {
            if image == nil { image = PhotoCache.shared.cached(post.imageUrl) }
            guard image == nil else { return }
            image = await PhotoCache.shared.load(post.imageUrl)
            loadFailed = image == nil
        }
    }

    /// Cuts the burn holes right through the photo.
    private func holes(active: BurnMark?) -> some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            context.blendMode = .clear
            for burn in burns + [active].compactMap({ $0 }) {
                let center = CGPoint(x: burn.x * size.width, y: burn.y * size.height)
                context.fill(BurnScars.ragged(center: center, radius: burn.r * size.width, seed: burn.id),
                             with: .color(.black))
            }
        }
    }

    /// Voice notes pinned where they were recorded, and the recording pulse.
    private var pins: some View {
        GeometryReader { geo in
            ForEach(voices) { note in
                VoiceBubble(note: note,
                            isPlaying: player.playingID == note.id,
                            isMine: myID != nil && note.authorID == myID,
                            onTap: { player.toggle(note) },
                            onDelete: { onDeleteVoice(note.id) })
                    .position(x: note.x * geo.size.width, y: note.y * geo.size.height)
                    .transition(.scale.combined(with: .opacity))
            }
            if mode == .recording, let pressPoint {
                RecordingPulse(level: recorder.level, elapsed: recorder.elapsed)
                    .position(x: pressPoint.x * geo.size.width, y: pressPoint.y * geo.size.height)
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: voices.map(\.id))
    }

    /// 🔥 and 🎙 above your finger while choosing, like Facebook reactions.
    @ViewBuilder
    private var holdOverlay: some View {
        if mode == .choosing {
            GeometryReader { geo in
                HStack(spacing: 14) {
                    choiceBubble(.burn, icon: "flame.fill", title: "Burn", color: .orange)
                    choiceBubble(.voice, icon: "mic.fill", title: "Voice", color: .brand)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.white, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                .position(menuCenter(in: geo.size))
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
            .allowsHitTesting(false)
        }
    }

    private func choiceBubble(_ choice: HoldChoice, icon: String, title: String, color: Color) -> some View {
        let isHovered = hovered == choice
        return VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(color, in: Circle())
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.black)
        }
        .scaleEffect(isHovered ? 1.35 : 1, anchor: .bottom)
        .animation(.spring(response: 0.25, dampingFraction: 0.55), value: isHovered)
    }

    /// Where the menu sits: above the finger, kept inside the photo.
    private func menuCenter(in size: CGSize) -> CGPoint {
        guard let pressPoint else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        let x = min(max(pressPoint.x * size.width, 90), size.width - 90)
        var y = pressPoint.y * size.height - 80
        if y < 50 { y = pressPoint.y * size.height + 80 }
        return CGPoint(x: x, y: min(y, size.height - 50))
    }

    // MARK: - Counts row

    private var actions: some View {
        HStack(spacing: 16) {
            SlapButton(count: slapCount) { slap(at: CGPoint(x: 0.5, y: 0.5), burst: false) }

            if !voices.isEmpty {
                let playingHere = voices.contains { $0.id == player.playingID }
                Button {
                    Haptics.select()
                    if playingHere { player.stop() } else { player.playAll(voices) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: playingHere ? "stop.fill" : "play.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.brand)
                        Text(voices.count == 1 ? "1 voice" : "\(voices.count) voices")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !burns.isEmpty {
                let people = Set(burns.map { $0.uid ?? $0.id }).count
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.orange)
                    Text(people.formatted())
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(people == 1 ? "Burned by 1 person" : "Burned by \(people) people")
            }

            Spacer(minLength: 0)

            Text(hint)
                .font(.caption)
                .foregroundStyle(notice == nil && mode == .idle ? .tertiary : .secondary)
                .lineLimit(1)
                .animation(.snappy, value: hint)
        }
    }

    private var hint: String {
        if let notice { return notice }
        switch mode {
        case .choosing: return "Slide to Burn or Voice"
        case .burning: return "Burning… let go to stop"
        case .recording: return "Talking… let go to pin it"
        case .idle: return voices.isEmpty && burns.isEmpty ? "Hold the photo" : ""
        }
    }

    // MARK: - Gestures

    private func doubleTap(at point: CGPoint, in size: CGSize) {
        guard mode == .idle else { return }
        slap(at: CGPoint(x: point.x / size.width, y: point.y / size.height), burst: true)
    }

    private func slap(at spot: CGPoint, burst: Bool) {
        Haptics.slap()
        onSlap(spot)
        guard burst else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { showBurst = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.easeOut(duration: 0.2)) { showBurst = false }
        }
    }

    private func holdBegan(at point: CGPoint, in size: CGSize) {
        pressPoint = CGPoint(x: point.x / size.width, y: point.y / size.height)
        hovered = nil
        player.stop()
        Haptics.press()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { mode = .choosing }
    }

    /// While choosing, the finger picks 🔥 or 🎙; touching one starts it.
    private func holdMoved(to point: CGPoint, in size: CGSize) {
        guard mode == .choosing else { return }
        let center = menuCenter(in: size)
        let burnSpot = CGPoint(x: center.x - 32, y: center.y - 6)
        let voiceSpot = CGPoint(x: center.x + 32, y: center.y - 6)
        let reach: CGFloat = 38
        let choice: HoldChoice? =
            hypot(point.x - burnSpot.x, point.y - burnSpot.y) < reach ? .burn :
            hypot(point.x - voiceSpot.x, point.y - voiceSpot.y) < reach ? .voice : nil
        guard choice != hovered else { return }
        hovered = choice
        switch choice {
        case .burn: startBurning()
        case .voice: startRecording()
        case nil: break
        }
    }

    private func startBurning() {
        burnStart = .now
        burnHaptics.ignite()
        withAnimation(.snappy) { mode = .burning }
    }

    private func startRecording() {
        guard recorder.hasPermission else {
            let denied = recorder.wasDenied
            Task { _ = await recorder.requestPermission() }
            show(denied ? "Allow the mic in Settings" : "Allow the mic, then try again")
            Haptics.error()
            withAnimation(.snappy) { mode = .idle }
            return
        }
        guard recorder.start() else {
            show("Couldn't start the mic")
            withAnimation(.snappy) { mode = .idle }
            return
        }
        Haptics.success()
        withAnimation(.snappy) { mode = .recording }
    }

    private func holdEnded() {
        switch mode {
        case .burning:
            if let pressPoint, let burnStart {
                burnHaptics.extinguish()
                onBurn(pressPoint, NewsFormat.burnRadius(after: Date.now.timeIntervalSince(burnStart)))
            }
        case .recording:
            if let pressPoint, let note = recorder.stop() {
                Haptics.success()
                onVoice(pressPoint, note.audio, note.seconds)
            } else {
                Haptics.warning()
                show("Hold a little longer to record")
            }
        case .choosing:
            Haptics.soft()
        case .idle:
            break
        }
        burnStart = nil
        hovered = nil
        withAnimation(.snappy) { mode = .idle }
    }

    /// Stops a burn or recording that's cut short (row scrolled away).
    private func cancelHold() {
        if mode == .burning { burnHaptics.extinguish() }
        if mode == .recording { _ = recorder.stop() }
        burnStart = nil
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

    // MARK: - Burns

    private func activeBurn(at date: Date) -> BurnMark? {
        guard mode == .burning, let pressPoint, let burnStart else { return nil }
        return BurnMark(id: "active", x: pressPoint.x, y: pressPoint.y,
                        r: NewsFormat.burnRadius(after: date.timeIntervalSince(burnStart)), uid: nil)
    }

    /// How much of the photo is burned away, 0 to 1.
    private func burnedFraction(aspect: Double) -> Double {
        guard !burns.isEmpty else { return 0 }
        let n = 24
        var hit = 0
        for i in 0..<n {
            for j in 0..<n {
                let px = (Double(i) + 0.5) / Double(n)
                let py = (Double(j) + 0.5) / Double(n)
                if burns.contains(where: { burn in
                    let dx = px - burn.x
                    let dy = (py - burn.y) * aspect
                    return dx * dx + dy * dy <= burn.r * burn.r * 1.1
                }) { hit += 1 }
            }
        }
        return Double(hit) / Double(n * n)
    }
}

/// Hand icon and count. Every tap adds a slap.
private struct SlapButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: count > 0 ? "hand.raised.fill" : "hand.raised")
                    .font(.system(size: 19))
                    .rotationEffect(.degrees(-20))
                    .foregroundStyle(count > 0 ? Color.brand : .primary)
                    .symbolEffect(.bounce, value: count)
                if count > 0 {
                    Text(count.formatted())
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            .padding(.vertical, 6)
            .padding(.trailing, 4)
            .contentShape(Rectangle())
            .animation(.snappy, value: count)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count == 1 ? "1 slap" : "\(count) slaps")
        .accessibilityHint("Slap this post")
    }
}

/// Transparent UIKit layer over a post photo. A hold only starts once the
/// finger has stayed still, so the feed always scrolls normally; once it
/// starts, scrolling pauses until the finger lifts. Double-tap slaps.
private struct PhotoTouchLayer: UIViewRepresentable {
    var onHoldBegan: (CGPoint, CGSize) -> Void
    var onHoldMoved: (CGPoint, CGSize) -> Void
    var onHoldEnded: () -> Void
    var onDoubleTap: (CGPoint, CGSize) -> Void

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

        let doubleTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = c
        view.addGestureRecognizer(doubleTap)
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

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            parent?.onDoubleTap(g.location(in: view), view.bounds.size)
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
