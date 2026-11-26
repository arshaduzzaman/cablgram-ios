import SwiftUI

struct Reward: Identifiable, Hashable {
    /// Also the built-in photo's file name: `<id>.jpg` (or .png) in Cablgram/RewardImages/
    /// shows on the card when the dashboard hasn't set a photo.
    let id: String
    let title: String
    /// Who gives the reward, shown above the title. `nil` for none.
    let partner: String?
    /// Steps needed: since joining, minus steps spent. For a timed reward, steps walked
    /// in its period (or on each of its days).
    let steps: Int
    /// The dashboard's icon name (food, pizza, burger, drink, coffee, game, console, ticket, shirt, gift).
    var icon: String = "gift"
    /// Photo set on the dashboard. Wins over the built-in photo.
    var imageURL: URL? = nil
    /// Shown on the claim screen ("Pick up at any Uncle Bobo's").
    var details: String? = nil
    /// How many can be given out; `nil` for no limit.
    var stock: Int? = nil
    var claimedCount = 0
    /// Ask for a delivery address when claiming.
    var needsAddress = false
    /// Set for a timed reward (daily, weekly, between dates); nil for the ordinary kind.
    var schedule: RewardSchedule? = nil
    /// Timed rewards: claims so far in each recent period, by the period's first day.
    var periodClaims: [String: Int] = [:]
    /// Timed rewards: the period this copy stands for (one row on the Walk page per period).
    var span: RewardSpan? = nil

    /// What your claim for this is filed under: the reward, plus the period for a timed one.
    var claimKey: String { span.map { "\(id)__\($0.start)" } ?? id }

    var fullName: String { [partner, title].compactMap { $0 }.joined(separator: " ") }

    /// Every one has been given out (only matters if you haven't claimed it yourself).
    /// A timed reward's limit is per period.
    var soldOut: Bool {
        guard let stock else { return false }
        if schedule != nil { return span.map { periodClaims[$0.start] ?? 0 >= stock } ?? false }
        return claimedCount >= stock
    }

    /// Icon shown until a photo loads.
    var systemImage: String {
        switch icon {
        case "food": "takeoutbag.and.cup.and.straw.fill"
        case "pizza": "fork.knife"
        case "burger": "fork.knife.circle.fill"
        case "drink": "waterbottle.fill"
        case "coffee": "cup.and.saucer.fill"
        case "game": "opticaldisc.fill"
        case "console": "gamecontroller.fill"
        case "ticket": "ticket.fill"
        case "shirt": "tshirt.fill"
        default: "gift.fill"
        }
    }

    /// The rewards, live from the dashboard (cablgram-admin → Rewards), cheapest first.
    /// Until they arrive (or if none are set up) it's the built-in list below.
    @MainActor static var all: [Reward] { RewardStore.shared.rewards }

    /// What the app shows before the dashboard's list loads.
    static let builtIn: [Reward] = [
        Reward(id: "unclebobos-chicken", title: "Chicken", partner: "Uncle Bobo's", steps: 10_000, icon: "food"),
        Reward(id: "liberty-pizza", title: "Slice", partner: "Liberty Pizza", steps: 15_000, icon: "pizza"),
        Reward(id: "smashed-chicken-burger", title: "Smashed Chicken Burger", partner: nil, steps: 15_000, icon: "burger"),
        Reward(id: "gta-6", title: "GTA 6", partner: nil, steps: 75_000, icon: "game", needsAddress: true),
        Reward(id: "ps5", title: "PlayStation 5", partner: nil, steps: 500_000, icon: "console", needsAddress: true),
    ]
}

extension Reward {
    private static var photoCache: [String: UIImage] = [:]

    /// The reward's built-in photo from Cablgram/RewardImages, if there is one.
    var photo: UIImage? {
        if let cached = Self.photoCache[id] { return cached }
        for ext in ["jpg", "jpeg", "png", "webp", "heic"] {
            let url = Bundle.main.url(forResource: id, withExtension: ext)
                ?? Bundle.main.url(forResource: id, withExtension: ext, subdirectory: "RewardImages")
            if let url, let image = UIImage(contentsOfFile: url.path) {
                Self.photoCache[id] = image
                return image
            }
        }
        return nil
    }
}

/// The reward's photo (the dashboard's, then the built-in one), or a placeholder with its icon.
struct RewardImage: View {
    let reward: Reward

    var body: some View {
        if let url = reward.imageURL {
            AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    builtIn
                }
            }
        } else {
            builtIn
        }
    }

    @ViewBuilder
    private var builtIn: some View {
        if let photo = reward.photo {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color(.secondarySystemBackground)
                Image(systemName: reward.systemImage)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
