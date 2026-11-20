import SwiftUI

// MARK: - Splats

/// One settled splat drawn on a 100-point grid and scaled to fit, so it stays crisp
/// and keeps its proportions on any avatar. Each egg lands in its own spot and angle.
struct SplatMark: View {
    let seed: String
    var index: Int = 0

    var body: some View {
        Canvas { context, size in
            let k = min(size.width, size.height) / 100
            let rand = EggArt.Rand(seed)
            // The first one near the middle, extra eggs pushed out to the sides.
            let reach = index == 0 ? 14.0 : 26.0
            let dx = (rand.next(index, 90) - 0.5) * 2 * reach
            let dy = (rand.next(index, 91) - 0.6) * 2 * reach * 0.8
            context.scaleBy(x: k, y: k)
            context.translateBy(x: 50 + dx, y: 50 + dy)
            context.rotate(by: .degrees(rand.next(index, 92) * 70 - 35))
            EggArt.draw(seed, at: .zero, radius: index == 0 ? 30 : 24, progress: .final, in: &context)
        }
    }
}

// MARK: - Egg button

/// A round egg button for friend rows.
struct EggButton: View {
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            EggIcon()
                .stroke(.primary, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.52, height: size * 0.52)
                .frame(width: size, height: size)
                .background(Color.black.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(SquishPress())
    }
}

/// Buttons dip under your finger and spring back.
struct SquishPress: ButtonStyle {
    var scale: CGFloat = 0.88

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

// MARK: - Throwing

extension View {
    /// Presents the egg sheet for `item`.
    func eggSheet(_ item: Binding<EggTarget?>) -> some View {
        modifier(EggSheetPresenter(item: item))
    }
}

private struct EggSheetPresenter: ViewModifier {
    @Binding var item: EggTarget?
    @EnvironmentObject private var friends: FriendsStore
    @Environment(EggStore.self) private var eggs: EggStore?

    func body(content: Content) -> some View {
        content.sheet(item: $item) { target in
            EggSheet(target: target)
                .environmentObject(friends)
                .environment(eggs)
        }
    }
}

/// A bottom sheet for throwing an egg at a friend.
struct EggSheet: View {
    let target: EggTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        EggComposer(target: target) { dismiss() }
            .overlay(alignment: .topTrailing) {
                Button {
                    Haptics.tap()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.black.opacity(0.06), in: Circle())
                }
                .buttonStyle(SquishPress())
                .padding(16)
                .accessibilityLabel("Close")
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
    }
}

/// The friend's big picture, an optional message with quick picks, and a big
/// "Throw egg" button. Throwing flies an egg up from the button in an arc and splats
/// it on their picture, then calls `onDone`.
struct EggComposer: View {
    let target: EggTarget
    var onDone: () -> Void

    @EnvironmentObject private var friends: FriendsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var message = ""
    @State private var errorText: String?
    @State private var sending = false
    /// When the egg left your hand.
    @State private var thrown: Date?
    @State private var seed = UUID().uuidString
    @State private var squash = false
    @State private var shakes = 0
    @State private var avatarFrame: CGRect = .zero
    @State private var buttonFrame: CGRect = .zero
    @State private var haptics = EggHaptics()
    @FocusState private var typing: Bool

    static let maxLength = 80
    static let chips = ["Get moving 😤", "Couch potato 🥔", "I'm catching up 👀", "Walk with me?"]
    private let avatarSize: CGFloat = 132
    private var flight: TimeInterval { reduceMotion ? 0 : 0.55 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 22) {
                    avatar
                        .padding(.top, 36)

                    VStack(spacing: 6) {
                        Text("Egg \(target.firstName)")
                            .font(.title2.weight(.bold))
                        Text("They'll have to walk 1,000 steps to clean it off.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    messageField
                    chips

                    if let errorText {
                        Text(errorText)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .modifier(Shake(amount: CGFloat(shakes)))
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)

            throwButton
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .coordinateSpace(name: "eggSheet")
        .overlay { flightLayer }
        .background(Color(.systemBackground))
        .animation(.snappy, value: errorText)
    }

    // MARK: Parts

    private var avatar: some View {
        Avatar(url: target.photoURL, name: target.name, size: avatarSize)
            .overlay(Circle().stroke(.white, lineWidth: 4))
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
            .scaleEffect(x: squash ? 1.1 : 1, y: squash ? 0.86 : 1, anchor: .bottom)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("eggSheet")) } action: { avatarFrame = $0 }
    }

    private var messageField: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("Say something… (optional)", text: $message, axis: .vertical)
                .lineLimit(1...3)
                .focused($typing)
                .submitLabel(.done)
                .onChange(of: message) { _, text in
                    if text.contains("\n") { message = text.replacingOccurrences(of: "\n", with: ""); typing = false }
                    if message.count > Self.maxLength { message = String(message.prefix(Self.maxLength)) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .disabled(thrown != nil)
            Text("\(message.count)/\(Self.maxLength)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(message.count >= Self.maxLength ? Color.brand : Color.secondary)
                .contentTransition(.numericText(value: Double(message.count)))
                .animation(.snappy, value: message.count)
        }
    }

    private var chips: some View {
        FlowLayout(spacing: 8) {
            ForEach(Self.chips, id: \.self) { chip in
                let picked = message == chip
                Button {
                    Haptics.select()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { message = picked ? "" : chip }
                } label: {
                    Text(chip)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(picked ? Color.white : Color.primary)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(picked ? Color.brand : Color.black.opacity(0.06), in: Capsule())
                }
                .buttonStyle(SquishPress(scale: 0.92))
                .disabled(thrown != nil)
            }
        }
    }

    private var throwButton: some View {
        Button(action: throwEgg) {
            HStack(spacing: 10) {
                if sending {
                    ProgressView().tint(.white)
                } else if thrown != nil {
                    Text("Splat! 🥚")
                } else {
                    EggIcon()
                        .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: 22, height: 22)
                    Text("Throw egg")
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Color.brand, in: Capsule())
            .shadow(color: Color.brand.opacity(0.3), radius: 12, y: 6)
            .contentShape(Capsule())
        }
        .buttonStyle(SquishPress(scale: 0.95))
        .disabled(sending || thrown != nil)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("eggSheet")) } action: { buttonFrame = $0 }
    }

    /// The egg in flight and the splat on their picture.
    private var flightLayer: some View {
        TimelineView(.animation(paused: thrown == nil)) { timeline in
            Canvas { context, _ in
                guard let thrown else { return }
                let t = timeline.date.timeIntervalSince(thrown)
                let hit = CGPoint(x: avatarFrame.midX, y: avatarFrame.midY)
                let radius = avatarSize * 0.36
                if t < flight {
                    drawFlight(t / flight, to: hit, radius: radius, in: &context)
                } else if reduceMotion {
                    var faded = context
                    faded.opacity = min((t - flight) / 0.35, 1)
                    EggArt.draw(seed, at: hit, radius: radius, progress: .final, in: &faded)
                } else {
                    EggArt.draw(seed, at: hit, radius: radius,
                                progress: EggLayer.progress(after: t - flight, strong: true), in: &context)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func drawFlight(_ f: Double, to hit: CGPoint, radius: CGFloat, in context: inout GraphicsContext) {
        let start = CGPoint(x: buttonFrame.midX, y: buttonFrame.minY)
        let control = CGPoint(x: (start.x + hit.x) / 2 + 70, y: min(start.y, hit.y) - 90)
        // Quick out of the hand, easing a little as it arrives.
        let t = CGFloat(1 - pow(1 - f, 1.6))
        let point = CGPoint(x: (1 - t) * (1 - t) * start.x + 2 * (1 - t) * t * control.x + t * t * hit.x,
                            y: (1 - t) * (1 - t) * start.y + 2 * (1 - t) * t * control.y + t * t * hit.y)
        let eggSize = 54 - 18 * t
        // Its shadow closing in on their face.
        let shadow = CGRect(x: hit.x - eggSize * 0.45, y: hit.y - eggSize * 0.2, width: eggSize * 0.9, height: eggSize * 0.4)
        context.fill(Path(ellipseIn: shadow), with: .color(.black.opacity(0.06 + 0.18 * Double(t))))
        let egg = EggArt.egg(center: point, size: eggSize, angle: .degrees(Double(t) * 560))
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.3), radius: 5, y: 4))
            layer.fill(egg, with: .color(EggArt.shell))
        }
        context.stroke(egg, with: .color(Color(white: 0.7)), lineWidth: 1)
    }

    // MARK: Throw

    private func throwEgg() {
        guard !sending, thrown == nil else { return }
        typing = false
        Haptics.press()
        sending = true
        errorText = nil
        Task {
            do {
                if let id = try await friends.egg(target.uid, message: message) { seed = id }
            } catch {
                sending = false
                errorText = error.localizedDescription
                withAnimation(.linear(duration: 0.4)) { shakes += 1 }
                Haptics.error()
                return
            }
            sending = false
            thrown = .now
            if reduceMotion {
                Haptics.success()
            } else {
                haptics.throwAndSplat(flight: flight)
                try? await Task.sleep(for: .seconds(flight))
                withAnimation(.spring(response: 0.16, dampingFraction: 0.5)) { squash = true }
                try? await Task.sleep(for: .milliseconds(110))
                withAnimation(.spring(response: 0.45, dampingFraction: 0.42)) { squash = false }
                try? await Task.sleep(for: .milliseconds(200))
                Haptics.success()
            }
            try? await Task.sleep(for: .seconds(1.25))
            onDone()
        }
    }
}

/// A quick side-to-side shake, for errors.
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(amount * .pi * 4), y: 0))
    }
}

/// Lays chips out in rows, wrapping onto the next line, centred.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].items.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += row.items.isEmpty ? size.width : size.width + spacing
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.items.isEmpty }
    }
}

// MARK: - Egg cards

/// Cream card colour for egg moments.
extension Color {
    static let eggCream = Color(red: 1, green: 0.965, blue: 0.87)
}

/// A faint splat in the corner of egg cards.
struct SplatPattern: View {
    var seed = "pattern"

    var body: some View {
        GeometryReader { geo in
            SplatMark(seed: seed)
                .frame(width: 120, height: 120)
                .rotationEffect(.degrees(18))
                .opacity(0.35)
                .position(x: geo.size.width - 22, y: 18)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Little sparkles flying out and fading, driven by `progress` 0...1.
struct SparkleBurst: View, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) / 8 * 2 * .pi + 0.3
                let distance = 10 + 30 * EggArt.easeOut(progress)
                Image(systemName: i.isMultiple(of: 2) ? "sparkle" : "circle.fill")
                    .font(.system(size: i.isMultiple(of: 2) ? 10 : 4, weight: .bold))
                    .foregroundStyle(i.isMultiple(of: 3) ? Color.brand : EggArt.yolk)
                    .scaleEffect(1.2 - 0.6 * progress)
                    .offset(x: cos(angle) * distance, y: sin(angle) * distance)
                    .opacity(progress <= 0 || progress >= 1 ? 0 : 1 - progress * progress)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

func shortName(_ name: String) -> String {
    name.split(separator: " ").first.map(String.init) ?? name
}
