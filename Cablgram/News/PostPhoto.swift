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

/// Post photos, kept in memory so scrolling back doesn't reload them.
@MainActor
final class PhotoCache {
    static let shared = PhotoCache()
    private let cache = NSCache<NSString, UIImage>()

    func cached(_ url: String) -> UIImage? { cache.object(forKey: url as NSString) }

    /// A small, already-decoded copy for thumbnails.
    func cachedThumbnail(_ url: String, maxSide: CGFloat) -> UIImage? {
        cache.object(forKey: "\(url)#\(Int(maxSide))" as NSString)
    }

    func thumbnail(_ url: String, maxSide: CGFloat) async -> UIImage? {
        let key = "\(url)#\(Int(maxSide))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let link = URL(string: url),
              let (data, _) = try? await session.data(from: link),
              let full = UIImage(data: data) else { return nil }
        let scale = min(1, maxSide / max(full.size.width, full.size.height, 1))
        let size = CGSize(width: full.size.width * scale, height: full.size.height * scale)
        guard let small = await full.byPreparingThumbnail(ofSize: size) else { return nil }
        cache.setObject(small, forKey: key)
        return small
    }

    /// Photos are also kept on disk (up to 300 MB), so they show instantly
    /// next time the app opens instead of downloading again.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 30_000_000, diskCapacity: 300_000_000,
                                   directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                                       .appendingPathComponent("photos"))
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    func load(_ url: String) async -> UIImage? {
        if let hit = cached(url) { return hit }
        guard let link = URL(string: url),
              let (data, _) = try? await session.data(from: link),
              let decoded = UIImage(data: data) else { return nil }
        // Decode now, off the main thread, rather than while drawing.
        let image = await decoded.byPreparingForDisplay() ?? decoded
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

