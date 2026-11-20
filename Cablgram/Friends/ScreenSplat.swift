import SwiftUI

/// An egg someone threw at you, hitting the screen the first time you open the chat: it
/// flies in spinning, splats across the middle with a second splash and drips, the sender's
/// line shows on top, then the mess slides down and fades. Tap to clear it early.
struct ScreenSplat: View {
    struct Hit: Identifiable, Equatable {
        let id: String
        let senderName: String
        let message: String
    }

    let hit: Hit
    var onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var haptics = EggHaptics()
    @State private var finished = false

    private var flight: TimeInterval { reduceMotion ? 0 : 0.45 }
    private let hold: TimeInterval = 2.4
    private let fade: TimeInterval = 0.7
    private var total: TimeInterval { flight + hold + fade }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start)
            let gone = max(0, min((t - flight - hold) / fade, 1))
            GeometryReader { geo in
                let size = geo.size
                let center = CGPoint(x: size.width * 0.5, y: size.height * 0.42)
                let radius = size.width * 0.34
                ZStack {
                    // The screen darkens a touch as it hits.
                    Color.black.opacity(t < flight ? 0 : 0.12 * (1 - gone))

                    Canvas { ctx, _ in
                        if t < flight {
                            drawFlight(t / flight, to: center, size: size, in: &ctx)
                        } else {
                            let after = t - flight
                            // The whole mess slides down as it goes.
                            ctx.translateBy(x: 0, y: CGFloat(gone * gone) * size.height * 0.35)
                            EggArt.draw(hit.id, at: center, radius: radius,
                                        progress: EggLayer.progress(after: after, strong: true), in: &ctx)
                            if after > 0.08 {
                                EggArt.draw(hit.id + "-2",
                                            at: CGPoint(x: center.x - radius * 0.95, y: center.y + radius * 1.15),
                                            radius: radius * 0.38,
                                            progress: EggLayer.progress(after: after - 0.08), in: &ctx)
                            }
                            if after > 0.14 {
                                EggArt.draw(hit.id + "-3",
                                            at: CGPoint(x: center.x + radius * 1.0, y: center.y - radius * 0.9),
                                            radius: radius * 0.26,
                                            progress: EggLayer.progress(after: after - 0.14), in: &ctx)
                            }
                        }
                    }

                    if t >= flight + 0.25 {
                        caption
                            .position(x: size.width / 2, y: center.y + radius * 1.75)
                            .offset(y: CGFloat(gone * gone) * size.height * 0.35)
                            .transition(.opacity)
                    }
                }
                .opacity(1 - gone)
            }
            .onChange(of: t >= total) { _, over in
                if over { finish() }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .onAppear {
            start = Date()
            haptics.throwAndSplat(flight: flight)
        }
        .accessibilityElement()
        .accessibilityLabel("\(hit.senderName) egged you. \(hit.message)")
        .accessibilityAddTraits(.isButton)
    }

    private var caption: some View {
        VStack(spacing: 6) {
            Text("🥚 \(hit.senderName.components(separatedBy: " ").first ?? hit.senderName) egged you!")
                .font(.title2.weight(.heavy))
            if !hit.message.isEmpty {
                Text("“\(hit.message)”")
                    .font(.title3.weight(.semibold))
                    .italic()
                    .multilineTextAlignment(.center)
            }
            Text("Walk 1,000 steps to clean it off")
                .font(.footnote.weight(.semibold))
                .opacity(0.85)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
        .padding(.horizontal, 28)
    }

    /// The egg coming at the screen: from the top corner, spinning, growing as it nears.
    private func drawFlight(_ f: Double, to hit: CGPoint, size: CGSize, in ctx: inout GraphicsContext) {
        let start = CGPoint(x: size.width * 0.85, y: -40)
        let t = CGFloat(1 - pow(1 - f, 1.4))
        let control = CGPoint(x: size.width * 0.95, y: size.height * 0.2)
        let p = CGPoint(x: (1 - t) * (1 - t) * start.x + 2 * (1 - t) * t * control.x + t * t * hit.x,
                        y: (1 - t) * (1 - t) * start.y + 2 * (1 - t) * t * control.y + t * t * hit.y)
        let eggSize = 40 + 110 * t
        let egg = EggArt.egg(center: p, size: eggSize, angle: .degrees(Double(t) * 620))
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 8, y: 6))
            layer.fill(egg, with: .color(EggArt.shell))
        }
        ctx.stroke(egg, with: .color(Color(white: 0.7)), lineWidth: 1)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onDone()
    }
}

/// Eggs that have already hit your screen (so each one splats once, on this phone).
enum SplatSeen {
    private static let key = "inbox.splatSeen"

    static func contains(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id)
    }

    static func insert(_ ids: [String]) {
        var all = UserDefaults.standard.stringArray(forKey: key) ?? []
        all.append(contentsOf: ids.filter { !all.contains($0) })
        UserDefaults.standard.set(Array(all.suffix(500)), forKey: key)
    }
}
