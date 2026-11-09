import SwiftUI
import UIKit

/// One post as a polaroid lying on the table. On top of the pile you can
/// flick it away, double-tap it to leave a handprint, or hold it to draw.
struct PileCard: View {
    let post: NewsPost
    let isTop: Bool
    /// Room for the photo, inside the white border.
    let maxPhotoSize: CGSize
    let marks: [SlapMark]
    let drawings: [DoodleComment]
    let isDrawing: Bool
    let myID: String?
    /// Goes up on every slap, to shake the card.
    let slapPulse: Int
    let onDrawingChange: (Bool) -> Void
    let onSlap: (CGPoint) -> Void
    let onPost: ([Stroke]) -> Void
    let onDelete: (UUID) -> Void
    let onTossed: () -> Void

    private let border: CGFloat = 10
    private let captionHeight: CGFloat = 42

    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var drag: CGSize = .zero
    @State private var armed = false
    @State private var isDragging = false
    /// Which drawing is shown on its own; nil shows them all at once.
    @State private var shownIndex: Int?

    // Drawing in progress
    @State private var draft: [Stroke] = []
    @State private var current: Stroke?
    @State private var ink: InkColor = .pink
    @State private var haptics = DrawHaptics()
    @State private var lastPoint: CGPoint?
    @State private var lastTime: Date?
    @State private var lastAngle: CGFloat?

    private let brush = BrushSize.medium
    private let tossDistance: CGFloat = 120

    /// Each photo lands at its own slight angle, the same every time.
    private var restingAngle: Double { (PileCard.seed(post.id) - 0.5) * 11 }
    private var restingOffset: CGSize {
        let s = PileCard.seed(post.id + "o")
        return CGSize(width: (s - 0.5) * 22, height: (PileCard.seed(post.id + "y") - 0.5) * 16)
    }

    /// The photo's size on screen: as big as fits, keeping its shape.
    private var photoSize: CGSize {
        let aspect = image.map { $0.size.width / max($0.size.height, 1) } ?? 1
        var width = maxPhotoSize.width
        var height = width / aspect
        if height > maxPhotoSize.height {
            height = maxPhotoSize.height
            width = height * aspect
        }
        return CGSize(width: floor(width), height: floor(height))
    }

    private var shownDrawing: DoodleComment? {
        guard let shownIndex, drawings.indices.contains(shownIndex) else { return nil }
        return drawings[shownIndex]
    }

    var body: some View {
        polaroid
            .overlay(alignment: .topLeading) {
                if isTop {
                    ZStack(alignment: .topLeading) {
                        PileTouchLayer(isDrawing: isDrawing,
                               onHold: holdBegan,
                               onStroke: { point, time in continueStroke(at: point, time: time) },
                               onStrokeEnded: endStroke,
                               onDoubleTap: doubleTap,
                               onDrag: dragChanged,
                                       onDragEnded: dragEnded)

                        photoControls
                            .frame(width: photoSize.width, height: photoSize.height)
                            .offset(x: border, y: border)
                    }
                }
            }
        .keyframeAnimator(initialValue: 0.0, trigger: slapPulse) { content, shake in
            content.offset(x: shake).rotationEffect(.degrees(shake / 4))
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(-14, duration: 0.06)
                SpringKeyframe(10, duration: 0.07)
                SpringKeyframe(-5, duration: 0.07)
                SpringKeyframe(0, duration: 0.12)
            }
        }
        .scaleEffect(isDrawing ? 1.03 : (isDragging ? 1.04 : 1))
        .rotationEffect(.degrees(isDrawing ? 0 : restingAngle + drag.width / 16))
        .offset(isDrawing ? .zero : CGSize(width: restingOffset.width + drag.width,
                                            height: restingOffset.height + drag.height))
        .shadow(color: .black.opacity(isTop ? (isDragging ? 0.28 : 0.18) : 0.1),
                radius: isTop ? (isDragging ? 22 : 12) : 4, y: isTop ? (isDragging ? 14 : 6) : 2)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isDrawing)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragging)
        .allowsHitTesting(isTop)
        .onChange(of: isDrawing) { _, drawing in
            if drawing {
                draft = []
                haptics.pickUp()
            } else {
                draft = []
                current = nil
                haptics.stop()
            }
        }
        .onChange(of: drawings.count) { old, new in
            if let shownIndex, shownIndex >= new { self.shownIndex = nil }
        }
    }

    // MARK: - Polaroid

    private var polaroid: some View {
        VStack(spacing: 0) {
            photo
                .padding([.top, .horizontal], border)

            HStack(spacing: 6) {
                CablgramAvatar(size: 20)
                Text("cablgram")
                    .font(.footnote.weight(.semibold))
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.brand)
                Spacer(minLength: 8)
                if let date = post.date {
                    Text(PileCard.shortAge(date))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.black)
            .padding(.horizontal, border + 2)
            .frame(width: photoSize.width + border * 2, height: captionHeight)
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private var photo: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.systemGray6)
                if loadFailed {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
        }
        .frame(width: photoSize.width, height: photoSize.height)
        .overlay { handprints }
        .overlay {
            DoodleCanvas(strokes: isDrawing ? draft : (shownDrawing?.strokes ?? drawings.flatMap(\.strokes)),
                         current: current)
        }
        .clipped()
        .task(id: post.imageUrl) {
            if image == nil { image = PhotoCache.shared.cached(post.imageUrl) }
            guard image == nil else { return }
            image = await PhotoCache.shared.load(post.imageUrl)
            loadFailed = image == nil
        }
    }

    /// Everyone's slaps, as pink hands where they landed.
    private var handprints: some View {
        GeometryReader { geo in
            ForEach(marks) { mark in
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: max(geo.size.width * 0.12, 18)))
                    .foregroundStyle(Color.brand)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .rotationEffect(.degrees(mark.angle))
                    .position(x: mark.x * geo.size.width, y: mark.y * geo.size.height)
                    .transition(.scale(scale: 2.6).combined(with: .opacity))
            }
        }
        .opacity(isDrawing ? 0.35 : 0.92)
        .animation(.spring(response: 0.25, dampingFraction: 0.55), value: marks.map(\.id))
        .allowsHitTesting(false)
    }

    // MARK: - Controls on the photo

    @ViewBuilder
    private var photoControls: some View {
        if isDrawing {
            drawControls
        } else if !drawings.isEmpty {
            VStack {
                HStack {
                    drawingsChip
                    Spacer()
                }
                Spacer()
            }
            .padding(8)
        }
    }

    /// "3 drawings": tap to see them one at a time, then all together again.
    private var drawingsChip: some View {
        HStack(spacing: 6) {
            Button {
                Haptics.select()
                withAnimation(.snappy) {
                    let next = (shownIndex ?? -1) + 1
                    shownIndex = next < drawings.count ? next : nil
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "pencil.tip")
                    if let shown = shownDrawing, let index = shownIndex {
                        Text("\(shown.author.components(separatedBy: " ").first ?? shown.author) · \(PileCard.shortAge(shown.date))")
                        Text("\(index + 1)/\(drawings.count)")
                            .foregroundStyle(.white.opacity(0.7))
                    } else {
                        Text(drawings.count == 1 ? "1 drawing" : "\(drawings.count) drawings")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(.black.opacity(0.6), in: Capsule())
            }
            .buttonStyle(.plain)

            if let shown = shownDrawing, let myID, shown.authorID == myID {
                Button {
                    Haptics.warning()
                    onDelete(shown.id)
                    shownIndex = nil
                } label: {
                    Image(systemName: "trash")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.6), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete your drawing")
            }
        }
    }

    /// Colours, undo, cancel and Post, sitting on the photo while drawing.
    private var drawControls: some View {
        VStack {
            HStack {
                Button {
                    if !draft.isEmpty { haptics.wipe() } else { Haptics.tap() }
                    onDrawingChange(false)
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(0.55), in: Circle())
                }
                Spacer()
                Button {
                    guard !draft.isEmpty else { return }
                    Haptics.celebrate()
                    onPost(draft)
                    shownIndex = nil
                    onDrawingChange(false)
                } label: {
                    Text("Post")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(draft.isEmpty ? Color.brand.opacity(0.5) : Color.brand, in: Capsule())
                }
                .disabled(draft.isEmpty)
            }

            Spacer()

            HStack(spacing: 10) {
                ForEach(InkColor.allCases) { option in
                    Button {
                        guard ink != option else { return }
                        haptics.pick()
                        ink = option
                    } label: {
                        Circle()
                            .fill(option.color)
                            .frame(width: 22, height: 22)
                            .overlay(Circle().stroke(.white, lineWidth: ink == option ? 2.5 : 1))
                            .scaleEffect(ink == option ? 1.18 : 1)
                            .animation(.snappy, value: ink)
                    }
                }
                Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 20)
                Button {
                    guard !draft.isEmpty else { return }
                    haptics.undo()
                    withAnimation(.snappy) { _ = draft.removeLast() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white.opacity(draft.isEmpty ? 0.4 : 1))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
        }
        .padding(10)
        .transition(.opacity)
    }

    // MARK: - Touches

    /// Converts a point on the card to fractions of the photo, or nil when
    /// it's off the photo (on the white border).
    private func photoFraction(_ point: CGPoint, clamped: Bool) -> CGPoint? {
        guard photoSize.width > 0, photoSize.height > 0 else { return nil }
        let x = (point.x - border) / photoSize.width
        let y = (point.y - border) / photoSize.height
        if clamped { return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1)) }
        return (0...1).contains(x) && (0...1).contains(y) ? CGPoint(x: x, y: y) : nil
    }

    /// A hold on the photo starts drawing right there.
    private func holdBegan(at point: CGPoint) -> Bool {
        guard photoFraction(point, clamped: false) != nil else { return false }
        if !isDrawing { onDrawingChange(true) }
        return true
    }

    private func doubleTap(at point: CGPoint) {
        guard !isDrawing else { return }
        let spot = photoFraction(point, clamped: true) ?? CGPoint(x: 0.5, y: 0.5)
        onSlap(spot)
    }

    private func dragChanged(_ translation: CGSize) {
        if !isDragging { isDragging = true }
        drag = translation
        let far = hypot(translation.width, translation.height) > tossDistance
        if far != armed {
            armed = far
            if far { Haptics.select() }
        }
    }

    private func dragEnded(_ translation: CGSize, velocity: CGSize) {
        isDragging = false
        armed = false
        let distance = hypot(translation.width, translation.height)
        let speed = hypot(velocity.width, velocity.height)
        guard distance > tossDistance || speed > 900 else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.62)) { drag = .zero }
            return
        }
        // Fly off the way it was thrown.
        var dx = translation.width + velocity.width * 0.25
        var dy = translation.height + velocity.height * 0.25
        let length = max(hypot(dx, dy), 1)
        dx /= length
        dy /= length
        Haptics.press()
        withAnimation(.easeOut(duration: 0.3)) {
            drag = CGSize(width: dx * 1_300, height: dy * 1_300)
        } completion: {
            onTossed()
        }
    }

    // MARK: - Drawing

    private func continueStroke(at cardPoint: CGPoint, time: Date) {
        guard let normalized = photoFraction(cardPoint, clamped: true) else { return }
        let point = CGPoint(x: normalized.x * photoSize.width, y: normalized.y * photoSize.height)
        guard current != nil, let last = lastPoint, let lastTime else {
            current = Stroke(points: [normalized], color: ink, width: brush.rawValue)
            lastPoint = point
            self.lastTime = time
            lastAngle = nil
            haptics.strokeBegan(brush: brush)
            return
        }
        let dx = point.x - last.x, dy = point.y - last.y
        let distance = hypot(dx, dy)
        guard distance >= 1.5 else { return }
        let seconds = max(time.timeIntervalSince(lastTime), 0.004)
        let angle = atan2(dy, dx)
        var turn: CGFloat = 0
        if let lastAngle {
            turn = abs(angle - lastAngle)
            if turn > .pi { turn = 2 * .pi - turn }
        }
        current?.points.append(normalized)
        haptics.strokeMoved(distance: distance, speed: distance / seconds, turn: turn, brush: brush)
        lastPoint = point
        self.lastTime = time
        lastAngle = angle
    }

    private func endStroke() {
        if let current { draft.append(current) }
        current = nil
        lastPoint = nil
        lastTime = nil
        lastAngle = nil
        haptics.strokeEnded()
    }

    // MARK: - Helpers

    /// A stable number from 0 to 1 for a string (Swift's hashValue changes every launch).
    static func seed(_ text: String) -> Double {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Double(hash % 10_000) / 10_000
    }

    /// "now", "5m", "3h", "2d", or a date for older posts.
    static func shortAge(_ date: Date) -> String {
        let seconds = max(0, Int(-date.timeIntervalSinceNow))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        case ..<604_800: return "\(seconds / 86_400)d"
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}

/// Transparent UIKit layer over the top card. A flick throws the card, a
/// hold on the photo turns into drawing (the same touch keeps drawing), and
/// a double-tap slaps where it lands. UIKit recognizers keep these apart
/// cleanly: moving early is a throw, staying still is a hold.
struct PileTouchLayer: UIViewRepresentable {
    var isDrawing: Bool
    /// Returns whether the hold started drawing.
    var onHold: (CGPoint) -> Bool
    var onStroke: (CGPoint, Date) -> Void
    var onStrokeEnded: () -> Void
    var onDoubleTap: (CGPoint) -> Void
    var onDrag: (CGSize) -> Void
    var onDragEnded: (CGSize, CGSize) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let c = context.coordinator
        c.view = view

        let hold = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.handleHold(_:)))
        hold.minimumPressDuration = 0.3
        hold.allowableMovement = 10
        hold.delegate = c
        view.addGestureRecognizer(hold)
        c.hold = hold

        let toss = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handleToss(_:)))
        toss.maximumNumberOfTouches = 1
        toss.delegate = c
        view.addGestureRecognizer(toss)
        c.toss = toss

        let draw = ImmediatePanGestureRecognizer(target: c, action: #selector(Coordinator.handleDraw(_:)))
        draw.maximumNumberOfTouches = 1
        draw.isEnabled = false
        view.addGestureRecognizer(draw)
        c.draw = draw

        let doubleTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = c
        view.addGestureRecognizer(doubleTap)
        c.doubleTap = doubleTap
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.applyMode()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PileTouchLayer?
        weak var view: UIView?
        weak var hold: UILongPressGestureRecognizer?
        weak var toss: UIPanGestureRecognizer?
        weak var draw: UIPanGestureRecognizer?
        weak var doubleTap: UITapGestureRecognizer?
        /// True while a hold is drawing; it keeps the touch until lift-off.
        private var holdDrawing = false

        func applyMode() {
            let drawing = parent?.isDrawing ?? false
            // Never disable the hold mid-touch: that would cut the stroke.
            if !holdDrawing { hold?.isEnabled = !drawing }
            draw?.isEnabled = drawing
            toss?.isEnabled = !drawing
            doubleTap?.isEnabled = !drawing
        }

        @objc func handleHold(_ g: UILongPressGestureRecognizer) {
            guard let view, let parent else { return }
            let point = g.location(in: view)
            switch g.state {
            case .began:
                holdDrawing = parent.onHold(point)
                if holdDrawing { parent.onStroke(point, .now) }
            case .changed:
                if holdDrawing { parent.onStroke(point, .now) }
            case .ended, .cancelled, .failed:
                if holdDrawing { parent.onStrokeEnded() }
                holdDrawing = false
                applyMode()
            default:
                break
            }
        }

        @objc func handleDraw(_ g: UIPanGestureRecognizer) {
            guard let view, let parent else { return }
            switch g.state {
            case .began, .changed:
                parent.onStroke(g.location(in: view), .now)
            case .ended, .cancelled, .failed:
                parent.onStrokeEnded()
            default:
                break
            }
        }

        @objc func handleToss(_ g: UIPanGestureRecognizer) {
            guard let parent else { return }
            // Window coordinates: the card rotates as it moves, so its own
            // coordinates would wobble.
            let t = g.translation(in: nil)
            switch g.state {
            case .began, .changed:
                parent.onDrag(CGSize(width: t.x, height: t.y))
            case .ended, .cancelled, .failed:
                let v = g.velocity(in: nil)
                parent.onDragEnded(CGSize(width: t.x, height: t.y), CGSize(width: v.x, height: v.y))
            default:
                break
            }
        }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            parent?.onDoubleTap(g.location(in: view))
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            if g === toss {
                let holding = hold?.state == .began || hold?.state == .changed
                return !(parent?.isDrawing ?? false) && !holdDrawing && !holding
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// Post photos, kept in memory so cards coming back don't reload.
@MainActor
final class PhotoCache {
    static let shared = PhotoCache()
    private let cache = NSCache<NSString, UIImage>()

    func cached(_ url: String) -> UIImage? { cache.object(forKey: url as NSString) }

    func load(_ url: String) async -> UIImage? {
        if let hit = cached(url) { return hit }
        guard let link = URL(string: url),
              let (data, _) = try? await URLSession.shared.data(from: link),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSString)
        return image
    }

    /// Fetches photos for cards further down the pile ahead of time.
    func prefetch(_ urls: [String]) {
        for url in urls where cached(url) == nil {
            Task { _ = await load(url) }
        }
    }
}

extension Notification.Name {
    static let deviceDidShake = Notification.Name("deviceDidShake")
}

extension UIWindow {
    /// Shake to throw every photo back on the pile.
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
