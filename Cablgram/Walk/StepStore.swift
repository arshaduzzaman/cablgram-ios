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
    @Published private(set) var stepsToday = 0
    @Published private(set) var claimedRewardIDs: Set<String>

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
        #if DEBUG
        testSteps = defaults.integer(forKey: "walk.testSteps")
        #endif
    }

    /// Steps that count toward rewards.
    var totalSteps: Int {
        #if DEBUG
        return stepsSinceJoining + testSteps
        #else
        return stepsSinceJoining
        #endif
    }

    var nextReward: Reward? {
        Reward.all.first { $0.steps > totalSteps }
    }

    func isUnlocked(_ reward: Reward) -> Bool { totalSteps >= reward.steps }
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
            return
        }
        do {
            try await health.requestAuthorization(toShare: [], read: [stepType])
            access = .ready
        } catch {
            access = .unavailable
            return
        }
        await refresh()
        observeNewSteps()
    }

    func refresh() async {
        guard access == .ready else { return }
        let startOfToday = Calendar.current.startOfDay(for: .now)
        stepsSinceJoining = await sumOfSteps(from: joinDate)
        stepsToday = await sumOfSteps(from: startOfToday)
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
        claimedRewardIDs = []
        defaults.set(0, forKey: "walk.testSteps")
        defaults.removeObject(forKey: "walk.claimed")
    }
    #endif
}
