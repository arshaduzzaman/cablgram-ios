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

