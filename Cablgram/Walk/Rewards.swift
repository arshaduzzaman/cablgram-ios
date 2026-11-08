import Foundation

struct Reward: Identifiable, Hashable {
    let id: String
    let title: String
    /// Total steps (since joining) needed to unlock.
    let steps: Int
    let systemImage: String

    /// Edit this list to change the prizes. Keep it sorted by `steps`.
    static let all: [Reward] = [
        Reward(id: "badge", title: "Cablgram Walker Badge", steps: 5_000, systemImage: "rosette"),
        Reward(id: "stickers", title: "Cablgram Sticker Pack", steps: 15_000, systemImage: "seal.fill"),
        Reward(id: "tshirt", title: "Cablgram T-Shirt", steps: 30_000, systemImage: "tshirt.fill"),
        Reward(id: "headphones", title: "Wireless Headphones", steps: 60_000, systemImage: "headphones"),
        Reward(id: "ps5", title: "PlayStation 5", steps: 100_000, systemImage: "gamecontroller.fill"),
    ]
}
