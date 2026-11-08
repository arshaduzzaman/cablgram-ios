import SwiftUI

struct Reward: Identifiable, Hashable {
    /// Also the photo's file name: put `<id>.jpg` (or .png) in
    /// Cablgram/RewardImages/ and it shows up on the reward card.
    let id: String
    let title: String
    /// Who gives the reward, shown above the title. `nil` for none.
    let partner: String?
    /// Total steps (since joining) needed to unlock.
    let steps: Int
    /// Icon shown until a photo is added.
    let systemImage: String

    var fullName: String { [partner, title].compactMap { $0 }.joined(separator: " ") }

    /// Edit this list to change the prizes. Keep it sorted by `steps`.
    static let all: [Reward] = [
        Reward(id: "liberty-pizza", title: "Slice", partner: "Liberty Pizza",
               steps: 10_000, systemImage: "fork.knife"),
        Reward(id: "unclebobos-chicken", title: "Chicken", partner: "Uncle Bobo's",
               steps: 10_000, systemImage: "takeoutbag.and.cup.and.straw.fill"),
        Reward(id: "smashed-chicken-burger", title: "Smashed Chicken Burger", partner: nil,
               steps: 15_000, systemImage: "fork.knife.circle.fill"),
        Reward(id: "gta-6", title: "GTA 6", partner: nil,
               steps: 75_000, systemImage: "opticaldisc.fill"),
        Reward(id: "ps5", title: "PlayStation 5", partner: nil,
               steps: 500_000, systemImage: "gamecontroller.fill"),
    ]
}

extension Reward {
    private static var photoCache: [String: UIImage] = [:]

    /// The reward's photo from Cablgram/RewardImages, if one was added.
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

/// The reward's photo, or a branded placeholder with its icon.
struct RewardImage: View {
    let reward: Reward

    var body: some View {
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
