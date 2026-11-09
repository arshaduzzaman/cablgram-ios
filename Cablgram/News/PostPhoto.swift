import SwiftUI
import UIKit

/// Small helpers shared by the feed.
enum NewsFormat {
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

    /// The burn grows the longer you hold.
    static func burnRadius(after seconds: TimeInterval) -> Double {
        min(0.035 + seconds * 0.06, 0.22)
    }
}

// MARK: - Fire

/// Charred edges around every burn hole, and live flames and smoke around
/// the one being burned right now. Drawn in the photo's coordinates.
struct BurnScars: View {
    let burns: [BurnMark]
    let active: BurnMark?
    let time: Double

    private static let char = Color(red: 0.09, green: 0.05, blue: 0.02)
    private static let scorch = Color(red: 0.36, green: 0.2, blue: 0.08)
    private static let ember = Color(red: 1, green: 0.42, blue: 0.05)
    private static let flameColor = Color(red: 1, green: 0.55, blue: 0.08)
    private static let core = Color(red: 1, green: 0.86, blue: 0.25)

    var body: some View {
        Canvas { context, size in
            for burn in burns {
                scar(burn, in: &context, size: size, hot: false)
            }
            if let active {
                scar(active, in: &context, size: size, hot: true)
                flames(active, in: &context, size: size)
            }
        }
        .allowsHitTesting(false)
    }

    private func scar(_ burn: BurnMark, in context: inout GraphicsContext, size: CGSize, hot: Bool) {
        let center = CGPoint(x: burn.x * size.width, y: burn.y * size.height)
        let radius = burn.r * size.width
        // Brown scorch fading into the photo, then black char at the edge,
        // then a thin glowing ember line.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: max(radius * 0.18, 3)))
            layer.fill(Self.ragged(center: center, radius: radius * 1.55, seed: burn.id),
                       with: .color(Self.scorch.opacity(0.75)))
        }
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: max(radius * 0.05, 1.5)))
            layer.fill(Self.ragged(center: center, radius: radius * 1.2, seed: burn.id),
                       with: .color(Self.char.opacity(0.95)))
        }
        context.stroke(Self.ragged(center: center, radius: radius * 1.03, seed: burn.id),
                       with: .color((hot ? Self.core : Self.ember).opacity(hot ? 1 : 0.85)),
                       lineWidth: hot ? 3.5 : 1.8)
    }

    private func flames(_ burn: BurnMark, in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: burn.x * size.width, y: burn.y * size.height)
        let radius = burn.r * size.width
        let count = 22
        for i in 0..<count {
            let angle = Double(i) / Double(count) * 2 * .pi + time * 0.4
            let flicker = 0.5 + 0.5 * sin(time * 11 + Double(i) * 1.9)
            let length = radius * (0.35 + 0.45 * flicker)
            let base = CGPoint(x: center.x + cos(angle) * radius * 1.04,
                               y: center.y + sin(angle) * radius * 1.04)
            // Flames lean upward, like real fire.
            let tip = CGPoint(x: base.x + cos(angle) * length * 0.6,
                              y: base.y + sin(angle) * length * 0.6 - length * 0.7)
            context.fill(Self.flame(base: base, tip: tip, angle: angle, width: radius * 0.16, length: length),
                         with: .color(Self.flameColor.opacity(0.9)))
            let innerTip = CGPoint(x: base.x + (tip.x - base.x) * 0.55, y: base.y + (tip.y - base.y) * 0.55)
            context.fill(Self.flame(base: base, tip: innerTip, angle: angle, width: radius * 0.08, length: length * 0.55),
                         with: .color(Self.core.opacity(0.95)))
        }
        // Smoke rising off the hole.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius * 0.25))
            for k in 0..<6 {
                let phase = (time * 0.7 + Double(k) / 6).truncatingRemainder(dividingBy: 1)
                let drift = sin(time * 1.3 + Double(k)) * radius * 0.3
                let puff = radius * (0.35 + phase * 0.9)
                let y = center.y - radius - phase * radius * 2.6
                layer.fill(Path(ellipseIn: CGRect(x: center.x + drift - puff / 2, y: y - puff / 2,
                                                  width: puff, height: puff)),
                           with: .color(Color(white: 0.25).opacity((1 - phase) * 0.45)))
            }
        }
    }

    /// One teardrop flame from `base` on the hole's edge to `tip`.
    private static func flame(base: CGPoint, tip: CGPoint, angle: Double, width: CGFloat, length: CGFloat) -> Path {
        let side = CGPoint(x: -sin(angle) * width, y: cos(angle) * width)
        var path = Path()
        path.move(to: CGPoint(x: base.x + side.x, y: base.y + side.y))
        path.addQuadCurve(to: tip, control: CGPoint(x: base.x + side.x * 0.4, y: tip.y + length * 0.35))
        path.addQuadCurve(to: CGPoint(x: base.x - side.x, y: base.y - side.y),
                          control: CGPoint(x: base.x - side.x * 0.4, y: tip.y + length * 0.35))
        path.closeSubpath()
        return path
    }

    /// An uneven, organic circle (like paper eaten by fire), the same shape
    /// every time for the same burn.
    static func ragged(center: CGPoint, radius: CGFloat, seed: String) -> Path {
        let points = 56
        let p1 = NewsFormat.seed(seed) * 2 * .pi
        let p2 = NewsFormat.seed(seed + "b") * 2 * .pi
        let p3 = NewsFormat.seed(seed + "c") * 2 * .pi
        var path = Path()
        for i in 0..<points {
            let angle = Double(i) / Double(points) * 2 * .pi
            let wobble = 1
                + 0.11 * sin(3 * angle + p1)
                + 0.07 * sin(7 * angle + p2)
                + 0.035 * sin(17 * angle + p3)
            let r = radius * wobble
            let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Voice

/// A voice note pinned to the photo. Tap to hear it.
struct VoiceBubble: View {
    let note: VoiceNote
    let isPlaying: Bool
    let isMine: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: {
            Haptics.select()
            onTap()
        }) {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .fill(Color.brand)
                        .frame(width: 38, height: 38)
                        .overlay(Circle().stroke(.white, lineWidth: 2.5))
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    Image(systemName: isPlaying ? "waveform" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                }
                .scaleEffect(isPlaying ? 1.15 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isPlaying)

                Text("\(note.firstName) · \(Int(note.seconds.rounded()))s")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if isMine {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete my voice note", systemImage: "trash")
                }
            }
        }
        .accessibilityLabel("Voice note from \(note.firstName), \(Int(note.seconds.rounded())) seconds")
    }
}

/// The pink circle under your finger while recording: it swells with your
/// voice, and a ring fills up toward the 10-second limit.
struct RecordingPulse: View {
    let level: Double
    let elapsed: TimeInterval

    var body: some View {
        VStack(spacing: 6) {
            Text(String(format: "0:%02d", Int(elapsed)))
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.65), in: Capsule())

            ZStack {
                Circle()
                    .fill(Color.brand.opacity(0.3))
                    .frame(width: 96, height: 96)
                    .scaleEffect(0.7 + level * 0.6)
                Circle()
                    .trim(from: 0, to: elapsed / VoiceRecorder.maxSeconds)
                    .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 66, height: 66)
                Circle()
                    .fill(Color.brand)
                    .frame(width: 54, height: 54)
                Image(systemName: "mic.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            .animation(.easeOut(duration: 0.08), value: level)
        }
        .offset(y: -40)
    }
}

/// Post photos, kept in memory so scrolling back doesn't reload them.
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

