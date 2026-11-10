import SwiftUI
import CoreHaptics

/// A rotten egg someone threw at a post, where it hit (fractions of the photo).
struct EggMark: Identifiable, Equatable {
    let id: String
    let x: Double
    let y: Double
    let uid: String?
}

// MARK: - Drawing

/// How far along a splat is. `final` is how it stays on the photo.
struct SplatProgress {
    /// The egg white and yolk spreading out (springs past 1, then settles).
    var spread: Double
    /// Droplets flying out from the hit.
    var droplets: Double
    /// Drips sliding down the photo.
    var drips: Double
    /// Shell pieces flying off (0 = at the hit, 1 = landed). Some fade out.
    var shells: Double
    /// How far droplets and shell fly (bigger for hard hits).
    var burst: Double = 1

    static let final = SplatProgress(spread: 1, droplets: 1, drips: 1, shells: 1)
}

/// Draws egg splats: glossy egg white, a yolk, droplets, drips running down
/// the photo and bits of shell. The same egg always lands the same shape.
enum EggArt {
    static let white = Color(red: 1, green: 0.99, blue: 0.94)
    static let yolk = Color(red: 1, green: 0.74, blue: 0.08)
    static let yolkRim = Color(red: 0.92, green: 0.5, blue: 0.02)
    static let shell = Color(red: 0.97, green: 0.93, blue: 0.84)

    /// Splat size, as a fraction of the photo's width.
    static let size = 0.12

    static func draw(_ seed: String, at center: CGPoint, radius r: CGFloat,
                     progress p: SplatProgress, in context: inout GraphicsContext) {
        let rand = Rand(seed)
        let spread = CGFloat(p.spread)

        // Drips hang under the egg white and slide down: wide where they
        // leave the puddle, thin in the middle, a fat drop at the end.
        for i in 0..<2 {
            let dx = (rand.next(i, 1) - 0.5) * 1.1 * r
            let length = r * (0.7 + rand.next(i, 2) * 1.2) * CGFloat(p.drips)
            let width = r * (0.2 + rand.next(i, 3) * 0.1)
            guard length > 2 else { continue }
            let x = center.x + dx
            let top = center.y + r * 0.45
            let neck = width * 0.32
            let bulb = width * 0.55
            var drip = Path()
            drip.move(to: CGPoint(x: x - width, y: top - width * 0.6))
            drip.addQuadCurve(to: CGPoint(x: x - neck, y: top + length * 0.55),
                              control: CGPoint(x: x - neck, y: top))
            drip.addLine(to: CGPoint(x: x - neck, y: top + length - bulb))
            drip.addArc(center: CGPoint(x: x, y: top + length), radius: bulb,
                        startAngle: .degrees(-110), endAngle: .degrees(-70), clockwise: true)
            drip.addLine(to: CGPoint(x: x + neck, y: top + length * 0.55))
            drip.addQuadCurve(to: CGPoint(x: x + width, y: top - width * 0.6),
                              control: CGPoint(x: x + neck, y: top))
            drip.closeSubpath()
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.2), radius: 1.5, y: 1))
                layer.fill(drip, with: .color(white))
            }
        }

        // Egg white: an uneven, glossy puddle.
        let whitePath = blob(center: center, radius: r * spread, rand: rand, salt: 10, wobble: 0.22)
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.25), radius: 2, y: 1))
            layer.fill(whitePath, with: .color(white))
        }
        context.stroke(whitePath, with: .color(.white), lineWidth: 1.2)
        // Shine on the egg white.
        let shine = CGRect(x: center.x - r * 0.62 * spread, y: center.y - r * 0.55 * spread,
                           width: r * 0.45 * spread, height: r * 0.22 * spread)
        context.fill(Path(ellipseIn: shine), with: .color(.white))

        // Yolk, a little off-centre.
        let yolkCenter = CGPoint(x: center.x + (rand.next(0, 20) - 0.5) * r * 0.35,
                                 y: center.y + (rand.next(0, 21) - 0.5) * r * 0.3)
        let yolkRadius = r * 0.42 * min(spread * 1.1, 1.12)
        let yolkPath = blob(center: yolkCenter, radius: yolkRadius, rand: rand, salt: 30, wobble: 0.06)
        context.fill(yolkPath, with: .color(yolk))
        context.stroke(yolkPath, with: .color(yolkRim), lineWidth: 1.5)
        context.fill(Path(ellipseIn: CGRect(x: yolkCenter.x - yolkRadius * 0.55, y: yolkCenter.y - yolkRadius * 0.6,
                                            width: yolkRadius * 0.5, height: yolkRadius * 0.32)),
                     with: .color(.white.opacity(0.75)))

        // Droplets thrown out around the hit.
        for i in 0..<9 {
            let angle = rand.next(i, 40) * 2 * .pi
            let distance = r * (1.15 + rand.next(i, 41) * 0.9) * CGFloat(easeOut(p.droplets) * p.burst)
            let size = r * (0.07 + rand.next(i, 42) * 0.1)
            let point = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
            let color = i % 4 == 0 ? yolk : white
            context.fill(Path(ellipseIn: CGRect(x: point.x - size, y: point.y - size, width: size * 2, height: size * 2)),
                         with: .color(color.opacity(0.95)))
        }

        // Bits of shell. Most fly off and vanish; three stay stuck on.
        for i in 0..<6 {
            let stays = i < 3
            let angle = rand.next(i, 50) * 2 * .pi
            let reach = stays ? 0.7 + rand.next(i, 51) * 0.5 : 1.6 + rand.next(i, 51) * 1.4
            let t = CGFloat(easeOut(p.shells))
            let distance = r * CGFloat(reach * p.burst) * t
            let fade = stays ? 1 : max(1 - p.shells * 1.2, 0)
            guard fade > 0 else { continue }
            let point = CGPoint(x: center.x + cos(angle) * distance,
                                y: center.y + sin(angle) * distance + (stays ? 0 : t * t * r * 0.8))
            let size = r * (0.12 + rand.next(i, 52) * 0.1)
            let spin = Angle.radians(rand.next(i, 53) * .pi * 2 + Double(t) * (stays ? 0 : 5))
            var shard = Path()
            shard.move(to: CGPoint(x: 0, y: -size))
            shard.addLine(to: CGPoint(x: size * 0.9, y: size * 0.2))
            shard.addLine(to: CGPoint(x: size * 0.2, y: size * 0.8))
            shard.addLine(to: CGPoint(x: -size * 0.8, y: size * 0.4))
            shard.closeSubpath()
            let placed = shard.applying(CGAffineTransform(rotationAngle: spin.radians)
                .concatenating(CGAffineTransform(translationX: point.x, y: point.y)))
            context.fill(placed, with: .color(shell.opacity(fade)))
            context.stroke(placed, with: .color(Color(white: 0.55).opacity(0.8 * fade)), lineWidth: 0.8)
        }
    }

    /// The outer edge of a settled splat's egg white, for outlining it.
    static func outline(_ seed: String, at center: CGPoint, radius r: CGFloat) -> Path {
        blob(center: center, radius: r, rand: Rand(seed), salt: 10, wobble: 0.22)
    }

    /// A whole egg, for the throw.
    static func egg(center: CGPoint, size: CGFloat, angle: Angle) -> Path {
        let w = size * 0.78, h = size
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -h / 2))
        path.addCurve(to: CGPoint(x: w / 2, y: h * 0.12),
                      control1: CGPoint(x: w * 0.36, y: -h / 2), control2: CGPoint(x: w / 2, y: -h * 0.18))
        path.addCurve(to: CGPoint(x: 0, y: h / 2),
                      control1: CGPoint(x: w / 2, y: h * 0.38), control2: CGPoint(x: w * 0.3, y: h / 2))
        path.addCurve(to: CGPoint(x: -w / 2, y: h * 0.12),
                      control1: CGPoint(x: -w * 0.3, y: h / 2), control2: CGPoint(x: -w / 2, y: h * 0.38))
        path.addCurve(to: CGPoint(x: 0, y: -h / 2),
                      control1: CGPoint(x: -w / 2, y: -h * 0.18), control2: CGPoint(x: -w * 0.36, y: -h / 2))
        path.closeSubpath()
        return path.applying(CGAffineTransform(rotationAngle: angle.radians)
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
    }

    private static func blob(center: CGPoint, radius: CGFloat, rand: Rand, salt: Int, wobble: Double) -> Path {
        let points = 48
        let p1 = rand.next(salt, 1) * 2 * .pi, p2 = rand.next(salt, 2) * 2 * .pi, p3 = rand.next(salt, 3) * 2 * .pi
        var path = Path()
        for i in 0..<points {
            let a = Double(i) / Double(points) * 2 * .pi
            let k = 1 + wobble * (0.55 * sin(3 * a + p1) + 0.3 * sin(5 * a + p2) + 0.15 * sin(11 * a + p3))
            let point = CGPoint(x: center.x + cos(a) * radius * k, y: center.y + sin(a) * radius * k)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    static func easeOut(_ t: Double) -> Double {
        let c = min(max(t, 0), 1)
        return 1 - pow(1 - c, 3)
    }

    /// Repeatable random numbers from a seed, so every phone draws the same splat.
    struct Rand {
        let base: Double
        init(_ seed: String) { base = NewsFormat.seed(seed) * 1_000 }
        func next(_ i: Int, _ salt: Int) -> Double {
            let x = sin(base + Double(i) * 12.9898 + Double(salt) * 78.233) * 43_758.5453
            return x - floor(x)
        }
    }
}

// MARK: - Animation

/// One egg in the air or just landed. `thrown` eggs fly in from below
/// first; eggs other people throw just land.
struct EggLanding: Equatable {
    let start: Date
    let thrown: Bool
    /// Where the throw starts (your finger), as fractions of the photo; nil
    /// throws from below the photo.
    var from: CGPoint? = nil
    /// A hard hit: a punchier splat with droplets and shell flying further.
    var strong: Bool = false

    static let flight: TimeInterval = 0.42
    static let total: TimeInterval = 2.8

    func impactTime() -> TimeInterval {
        guard thrown else { return 0 }
        return from == nil ? Self.flight : 0.3
    }
}

/// How big splats are drawn, animating smoothly between sizes: the more
/// eggs on a post, the smaller each one, so a crowded photo reads like
/// zooming out on a wall of eggs.
struct EggScale: Equatable {
    var from: Double
    var to: Double
    var start: Date
    var duration: TimeInterval

    static func steady(_ value: Double) -> EggScale {
        EggScale(from: value, to: value, start: .distantPast, duration: 0)
    }

    var end: Date { start.addingTimeInterval(duration) }

    func value(at date: Date) -> Double {
        guard duration > 0 else { return to }
        let t = min(max(date.timeIntervalSince(start) / duration, 0), 1)
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        return from + (to - from) * eased
    }

    /// Splat size for a post with `count` eggs: full size up to five, then
    /// shrinking (never below a third) as the photo fills up.
    static func target(for count: Int) -> Double {
        count <= 5 ? 1 : max(0.32, (5 / Double(count)).squareRoot())
    }
}

/// Splats on the photo, with any eggs that are mid-flight or landing
/// animated. Other people's splats stay hidden until you've thrown one;
/// then they pop in one after another. Yours are drawn on top, and get a
/// pink outline when highlighted (a crowded post). Draws in the photo's coordinates.
struct EggLayer: View {
    let eggs: [EggMark]
    let landing: [String: EggLanding]
    /// Eggs you threw: always shown.
    let mine: Set<String>
    /// Whether everyone else's eggs are shown.
    let revealed: Bool
    /// When the others start popping in (nil: they're just there).
    let revealStart: Date?
    let scale: EggScale
    /// Your splats to outline in pink right now.
    let highlighted: Set<String>
    let animating: Bool

    /// Gap between each splat popping in, kept under a second in total.
    private var stagger: TimeInterval {
        let others = eggs.count - mine.count
        return others > 1 ? min(0.06, 0.8 / Double(others)) : 0
    }

    var body: some View {
        TimelineView(.animation(paused: !animating)) { timeline in
            Canvas { context, size in
                let now = timeline.date
                let radius = EggArt.size * size.width * scale.value(at: now)

                // Everyone else's first, then yours on top.
                var order = 0
                if revealed {
                    for egg in eggs where !mine.contains(egg.id) {
                        drawEgg(egg, order: &order, now: now, size: size, radius: radius, in: &context)
                    }
                }
                var none = 0
                for egg in eggs where mine.contains(egg.id) {
                    drawEgg(egg, order: &none, now: now, size: size, radius: radius, in: &context)
                    if highlighted.contains(egg.id), landing[egg.id] == nil {
                        let center = CGPoint(x: egg.x * size.width, y: egg.y * size.height)
                        let outline = EggArt.outline(egg.id, at: center, radius: radius * 1.08)
                        context.stroke(outline, with: .color(.white), lineWidth: 5)
                        context.stroke(outline, with: .color(.brand), lineWidth: 3)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// One egg: flying, landing, popping in after the reveal, or settled.
    private func drawEgg(_ egg: EggMark, order: inout Int, now: Date, size: CGSize, radius: CGFloat,
                         in context: inout GraphicsContext) {
        let center = CGPoint(x: egg.x * size.width, y: egg.y * size.height)
        if let anim = landing[egg.id] {
            let t = now.timeIntervalSince(anim.start)
            let impact = anim.impactTime()
            if t < impact {
                flying(t / impact, from: anim.from, to: center, size: size, radius: radius, in: &context)
            } else {
                EggArt.draw(egg.id, at: center, radius: radius,
                            progress: Self.progress(after: t - impact, strong: anim.strong), in: &context)
            }
            return
        }
        if !mine.contains(egg.id), let revealStart {
            let appear = revealStart.addingTimeInterval(Double(order) * stagger)
            order += 1
            let t = now.timeIntervalSince(appear)
            if t < 0 { return }
            if t < 2.5 {
                EggArt.draw(egg.id, at: center, radius: radius, progress: Self.progress(after: t), in: &context)
                return
            }
        }
        EggArt.draw(egg.id, at: center, radius: radius, progress: .final, in: &context)
    }

    /// The egg flying in from below the photo, spinning and shrinking as it
    /// goes away from you, with its shadow closing in on the target.
    private func flying(_ f: Double, from: CGPoint?, to target: CGPoint, size: CGSize, radius: CGFloat,
                        in context: inout GraphicsContext) {
        let start = from.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            ?? CGPoint(x: size.width * 0.5 + (target.x - size.width * 0.5) * 0.3, y: size.height + radius * 2)
        let control = CGPoint(x: (start.x + target.x) / 2, y: min(start.y, target.y) - size.height * 0.25)
        let t = CGFloat(f)
        let point = CGPoint(x: (1 - t) * (1 - t) * start.x + 2 * (1 - t) * t * control.x + t * t * target.x,
                            y: (1 - t) * (1 - t) * start.y + 2 * (1 - t) * t * control.y + t * t * target.y)
        let eggSize = radius * (2.2 - 1.1 * t)
        // Shadow on the photo, growing sharper as the egg arrives.
        let shadow = CGRect(x: target.x - eggSize * 0.4, y: target.y - eggSize * 0.18,
                            width: eggSize * 0.8, height: eggSize * 0.36)
        context.fill(Path(ellipseIn: shadow), with: .color(.black.opacity(0.08 + 0.2 * Double(t))))
        let egg = EggArt.egg(center: point, size: eggSize, angle: .degrees(Double(t) * 620))
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 4, y: 3))
            layer.fill(egg, with: .color(EggArt.shell))
        }
        context.stroke(egg, with: .color(Color(white: 0.7)), lineWidth: 1)
    }

    /// The splat over time after impact: a wobbly spring out, droplets and
    /// shell flying, then slow drips.
    static func progress(after t: TimeInterval, strong: Bool = false) -> SplatProgress {
        let spring = 1 - exp(-11 * t) * cos(17 * t)
        // A hard hit squashes out wide first, then settles back.
        let punch = strong ? 0.35 * exp(-7 * t) : 0
        return SplatProgress(spread: 0.25 + 0.75 * spring + punch,
                             droplets: min(t / (strong ? 0.18 : 0.22), 1),
                             drips: EggArt.easeOut(max(t - 0.15, 0) / 2.2),
                             shells: min(t / 0.55, 1),
                             burst: strong ? 1.45 : 1)
    }
}

// MARK: - Haptics

/// A throw you can feel: a light whoosh as it flies, then a heavy, wet
/// splat with a squelch after it.
@MainActor
final class EggHaptics {
    private var engine: CHHapticEngine?
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var enabled: Bool { supported && Haptics.isEnabled }

    private func prepare() {
        guard enabled, engine == nil else { return }
        engine = try? CHHapticEngine()
        engine?.playsHapticsOnly = true
        try? engine?.start()
    }

    /// Throw plus impact, timed to the animation.
    func throwAndSplat(flight: TimeInterval) {
        prepare()
        let whoosh = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.35),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6),
        ], relativeTime: 0, duration: flight * 0.85)
        let fadeIn = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
            .init(relativeTime: 0, value: 0.2), .init(relativeTime: flight * 0.85, value: 0.9),
        ], relativeTime: 0)
        play(events: [whoosh] + splatEvents(at: flight), curves: [fadeIn])
    }

    /// Just the impact (someone else's egg landing).
    func splat() {
        prepare()
        play(events: splatEvents(at: 0), curves: [])
    }

    private func splatEvents(at t: TimeInterval) -> [CHHapticEvent] {
        [
            transient(at: t, intensity: 1, sharpness: 0.12),
            transient(at: t + 0.045, intensity: 0.7, sharpness: 0.45),
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.45),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.05),
            ], relativeTime: t + 0.06, duration: 0.18),
            transient(at: t + 0.16, intensity: 0.35, sharpness: 0.8),
        ]
    }

    private func transient(at t: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: t)
    }

    private func play(events: [CHHapticEvent], curves: [CHHapticParameterCurve]) {
        guard enabled, let engine,
              let pattern = try? CHHapticPattern(events: events, parameterCurves: curves) else { return }
        try? engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
    }
}
