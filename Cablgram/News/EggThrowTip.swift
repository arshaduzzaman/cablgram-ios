import SwiftUI

/// A small looping demo over the first post's photo until you throw your first egg:
/// a finger presses and holds, pulls back, lets go, and an egg flies up and splats.
struct EggThrowTip: View {
    private struct Frame {
        var finger = 0.0      // finger opacity
        var press = 1.0       // finger scale (pressed is smaller)
        var hold = 0.0        // ring around the finger filling while holding
        var pull = 0.0        // how far the finger has pulled back, in points
        var flight = 0.0      // 0 = in the hand, 1 = landed
        var egg = 0.0         // egg opacity
        var splat = 0.0       // splat scale
    }

    /// How far above the finger the egg lands.
    private let reach: CGFloat = 120

    var body: some View {
        GeometryReader { geo in
            let start = CGPoint(x: geo.size.width * 0.5, y: geo.size.height * 0.62)
            ZStack {
                Color.clear
                    .keyframeAnimator(initialValue: Frame(), repeating: true) { _, f in
                        demo(f, start: start)
                    } keyframes: { _ in
                        KeyframeTrack(\.finger) {
                            LinearKeyframe(0, duration: 0.2)
                            LinearKeyframe(1, duration: 0.25)
                            LinearKeyframe(1, duration: 1.25)
                            LinearKeyframe(0, duration: 0.2)
                            LinearKeyframe(0, duration: 1.1)
                        }
                        KeyframeTrack(\.press) {
                            LinearKeyframe(1, duration: 0.45)
                            SpringKeyframe(0.82, duration: 0.25)
                            LinearKeyframe(0.82, duration: 0.95)
                            SpringKeyframe(1.1, duration: 0.2)
                            LinearKeyframe(1, duration: 1.15)
                        }
                        KeyframeTrack(\.hold) {
                            LinearKeyframe(0, duration: 0.5)
                            LinearKeyframe(1, duration: 0.4)
                            LinearKeyframe(1, duration: 0.8)
                            LinearKeyframe(0, duration: 0.1)
                            LinearKeyframe(0, duration: 1.2)
                        }
                        KeyframeTrack(\.pull) {
                            LinearKeyframe(0, duration: 0.95)
                            CubicKeyframe(34, duration: 0.5)
                            LinearKeyframe(34, duration: 0.25)
                            SpringKeyframe(0, duration: 0.3)
                            LinearKeyframe(0, duration: 1.0)
                        }
                        KeyframeTrack(\.egg) {
                            LinearKeyframe(0, duration: 0.7)
                            LinearKeyframe(1, duration: 0.2)
                            LinearKeyframe(1, duration: 1.1)
                            LinearKeyframe(0, duration: 0.01)
                            LinearKeyframe(0, duration: 0.99)
                        }
                        KeyframeTrack(\.flight) {
                            LinearKeyframe(0, duration: 1.7)
                            CubicKeyframe(1, duration: 0.3)
                            LinearKeyframe(1, duration: 1.0)
                        }
                        KeyframeTrack(\.splat) {
                            LinearKeyframe(0, duration: 2.0)
                            SpringKeyframe(1, duration: 0.35, spring: .bouncy)
                            LinearKeyframe(1, duration: 0.4)
                            LinearKeyframe(0, duration: 0.25)
                        }
                    }

                VStack {
                    Spacer()
                    Text("Hold, pull back, let go to throw 🥚")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.bottom, geo.size.height * 0.1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Tip: press and hold the photo, pull back, and let go to throw an egg.")
    }

    private func demo(_ f: Frame, start: CGPoint) -> some View {
        let hand = CGPoint(x: start.x, y: start.y + f.pull)
        let target = CGPoint(x: start.x, y: start.y - reach)
        let eggPoint = CGPoint(x: hand.x + (target.x - hand.x) * f.flight,
                               y: hand.y + (target.y - hand.y) * f.flight - sin(f.flight * .pi) * 30)
        return ZStack {
            // Where it'll land, while pulling back.
            Path { p in
                p.move(to: hand)
                p.addLine(to: target)
            }
            .stroke(.white.opacity(0.85 * min(f.pull / 20, 1) * (1 - f.flight)),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 7]))

            Circle()
                .fill(Color(red: 1, green: 0.8, blue: 0.2))
                .background(Circle().fill(.white).scaleEffect(1.9))
                .frame(width: 22, height: 22)
                .scaleEffect(f.splat)
                .opacity(f.splat)
                .position(target)

            Ellipse()
                .fill(.white)
                .overlay(Ellipse().stroke(Color(white: 0.7), lineWidth: 1))
                .frame(width: 18 - 6 * f.flight, height: 23 - 8 * f.flight)
                .rotationEffect(.degrees(f.flight * 400))
                .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                .opacity(f.egg)
                .position(x: eggPoint.x, y: eggPoint.y - 26 * (1 - f.flight))

            // The finger, with a ring filling while it holds.
            ZStack {
                Circle()
                    .trim(from: 0, to: f.hold)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 54, height: 54)
                Circle()
                    .fill(.white.opacity(0.35))
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .frame(width: 40, height: 40)
            }
            .scaleEffect(f.press)
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .opacity(f.finger)
            .position(hand)
        }
    }
}
