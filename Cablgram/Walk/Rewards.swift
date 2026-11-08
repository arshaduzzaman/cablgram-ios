import Foundation

struct Reward: Identifiable, Hashable {
    let id: String
    let title: String
    /// Who gives the reward, shown under the title.
    let partner: String
    /// Total steps (since joining) needed to unlock.
    let steps: Int
    let systemImage: String

    /// Edit this list to change the prizes. Keep it sorted by `steps`.
    static let all: [Reward] = [
        Reward(id: "badge", title: "Walker Badge", partner: "Cablgram",
               steps: 5_000, systemImage: "rosette"),
        Reward(id: "unclebobos-chicken", title: "Free Chicken", partner: "Uncle Bobo's",
               steps: 10_000, systemImage: "fork.knife"),
        Reward(id: "liberty-pizza", title: "Pizza Slice", partner: "Liberty Pizza",
               steps: 10_000, systemImage: "takeoutbag.and.cup.and.straw.fill"),
        Reward(id: "stickers", title: "Sticker Pack", partner: "Cablgram",
               steps: 15_000, systemImage: "seal.fill"),
        Reward(id: "tshirt", title: "Cablgram T-Shirt", partner: "Cablgram",
               steps: 30_000, systemImage: "tshirt.fill"),
        Reward(id: "headphones", title: "Wireless Headphones", partner: "Cablgram",
               steps: 60_000, systemImage: "headphones"),
        Reward(id: "ps5", title: "PlayStation 5", partner: "Cablgram",
               steps: 100_000, systemImage: "gamecontroller.fill"),
    ]
}
