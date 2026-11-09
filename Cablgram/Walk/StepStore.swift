import Foundation
import HealthKit

/// Reads step counts from Apple Health and tracks which rewards were claimed.
///
/// Rewards count steps taken since the user first opened the Walk tab, so old
/// Health history can't unlock prizes instantly.
@MainActor
final class StepStore: ObservableObject {
    enum Access { case notRequested, ready, unavailable }

    @Published private(set) var access: Access = .notRequested
    @Published private(set) var stepsSinceJoining = 0
    @Published private(set) var stepsThisWeek = 0
    /// True once the first step count has arrived (or Health is unavailable),
    /// so the UI can tell real progress apart from the initial load.
    @Published private(set) var hasLoaded = false
    @Published private(set) var claimedRewardIDs: Set<String>
    /// The reward the user picked to aim for. `nil` means "the next one".
    @Published private(set) var goalRewardID: String?
    /// Steps spent on eggs and headlines. They come off what counts toward
    /// rewards, but never off the leaderboard (that's what you walked).
    @Published private(set) var spentSteps: Int

    private let health = HKHealthStore()
    private let stepType = HKQuantityType(.stepCount)
    private let defaults = UserDefaults.standard
    private var observer: HKObserverQuery?

    let joinDate: Date

    #if DEBUG
    /// Fake steps for testing in the Simulator, which has no step data.
    @Published private(set) var testSteps: Int
    #endif

    init() {
        if let saved = defaults.object(forKey: "walk.joinDate") as? Date {
            joinDate = saved
        } else {
            joinDate = .now
            defaults.set(joinDate, forKey: "walk.joinDate")
        }
        claimedRewardIDs = Set(defaults.stringArray(forKey: "walk.claimed") ?? [])
        goalRewardID = defaults.string(forKey: "walk.goalReward")
        spentSteps = defaults.integer(forKey: "walk.spentSteps")
        #if DEBUG
        // `-resetClaims` launch argument: forget claimed rewards on this phone (test builds only).
        if ProcessInfo.processInfo.arguments.contains("-resetClaims") {
            claimedRewardIDs = []
            defaults.removeObject(forKey: "walk.claimed")
        }
        #endif
        #if DEBUG
        testSteps = defaults.integer(forKey: "walk.testSteps")
        #endif
    }

    /// Every step walked since joining (shown on the leaderboard).
    var totalSteps: Int {
        #if DEBUG
        return stepsSinceJoining + testSteps
        #else
        return stepsSinceJoining
        #endif
    }

    /// Steps you have to use: walked minus spent. These count toward rewards.
    var availableSteps: Int { max(totalSteps - spentSteps, 0) }

    /// Spends steps if you have enough. Returns whether it worked.
    func spend(_ amount: Int) -> Bool {
        guard amount > 0, availableSteps >= amount else { return false }
        spentSteps += amount
        defaults.set(spentSteps, forKey: "walk.spentSteps")
        return true
    }

    /// Takes the spent total saved in the cloud if it's higher (e.g. after
    /// reinstalling, or spending on another phone).
    func adoptSpentSteps(_ cloud: Int) {
        guard cloud > spentSteps else { return }
        spentSteps = cloud
        defaults.set(spentSteps, forKey: "walk.spentSteps")
    }

    var unlockedCount: Int {
        Reward.all.filter { availableSteps >= $0.steps }.count
    }

    /// The reward shown at the top of the Walk page: the one the user picked,
    /// or the first one not yet claimed.
    var goalReward: Reward? {
        if let id = goalRewardID, let picked = Reward.all.first(where: { $0.id == id }), !isClaimed(picked) {
            return picked
        }
        return Reward.all.first { !isClaimed($0) }
    }

    /// Steps still needed for the goal reward (0 when it's unlocked).
    var stepsToGoal: Int {
        guard let goal = goalReward else { return 0 }
        return max(goal.steps - availableSteps, 0)
    }

    func setGoal(_ reward: Reward) {
        goalRewardID = reward.id
        defaults.set(reward.id, forKey: "walk.goalReward")
    }

    /// Average steps a day since joining.
    var dailyPace: Int {
        let calendar = Calendar.current
        let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: joinDate), to: .now).day ?? 0) + 1
        return totalSteps / max(days, 1)
    }

    var nextReward: Reward? {
        Reward.all.first { $0.steps > availableSteps }
    }

    func isUnlocked(_ reward: Reward) -> Bool { availableSteps >= reward.steps }
    func isClaimed(_ reward: Reward) -> Bool { claimedRewardIDs.contains(reward.id) }

    func claim(_ reward: Reward) {
        guard isUnlocked(reward) else { return }
        claimedRewardIDs.insert(reward.id)
        defaults.set(Array(claimedRewardIDs), forKey: "walk.claimed")
    }

    // MARK: - Health

    func start() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            access = .unavailable
            hasLoaded = true
            return
        }
        do {
            try await health.requestAuthorization(toShare: [], read: [stepType])
            access = .ready
        } catch {
            access = .unavailable
            hasLoaded = true
            return
        }
        await refresh()
        observeNewSteps()
    }

    func refresh() async {
        guard access == .ready else { return }
        let startOfWeek = Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start
            ?? Calendar.current.startOfDay(for: .now)
        stepsSinceJoining = await sumOfSteps(from: joinDate)
        stepsThisWeek = await sumOfSteps(from: startOfWeek)
        hasLoaded = true
    }

    private func sumOfSteps(from start: Date) async -> Int {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: stepType, predicate: predicate),
            options: .cumulativeSum
        )
        // Health doesn't say whether read access was denied; a denied or empty
        // store both just return no data, so treat both as 0.
        let sum = try? await descriptor.result(for: health)?.sumQuantity()
        return Int(sum?.doubleValue(for: .count()) ?? 0)
    }

    /// Refreshes the counts whenever Health records new steps.
    private func observeNewSteps() {
        guard observer == nil else { return }
        let query = HKObserverQuery(sampleType: stepType, predicate: nil) { [weak self] _, done, _ in
            Task { @MainActor in
                await self?.refresh()
                done()
            }
        }
        observer = query
        health.execute(query)
    }

    #if DEBUG
    func addTestSteps(_ count: Int) {
        testSteps += count
        defaults.set(testSteps, forKey: "walk.testSteps")
    }

    func resetTestProgress() {
        testSteps = 0
        spentSteps = 0
        claimedRewardIDs = []
        defaults.set(0, forKey: "walk.testSteps")
        defaults.set(0, forKey: "walk.spentSteps")
        defaults.removeObject(forKey: "walk.claimed")
    }
    #endif
}
