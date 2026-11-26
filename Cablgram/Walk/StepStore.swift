import Foundation
import Combine
import HealthKit
import CoreMotion

/// Reads step counts from Apple Health. Rewards and your claims come from `RewardStore`.
///
/// Rewards count steps taken since the user first opened the Walk tab, so old
/// Health history can't unlock prizes instantly.
@MainActor
final class StepStore: ObservableObject {
    enum Access { case notRequested, ready, unavailable }

    @Published private(set) var access: Access = .notRequested
    /// Health steps since joining, counted on this phone (`localTotal` in the step contract).
    @Published private(set) var stepsSinceJoining = 0
    /// Health steps this week, counted on this phone (`localWeek` in the step contract).
    @Published private(set) var localWeek = 0
    /// Health steps per local calendar day ("yyyy-MM-dd"), newest 60 days since
    /// joining. Sent to the server, which works out the real totals.
    @Published private(set) var dailySteps: [String: Int] = [:]
    /// The server's totals from the last recalc, for the signed-in user.
    @Published private(set) var sync: ServerSync?
    /// True once the first step count has arrived (or Health is unavailable),
    /// so the UI can tell real progress apart from the initial load.
    @Published private(set) var hasLoaded = false
    /// The reward the user picked to aim for. `nil` means "the next one".
    @Published private(set) var goalRewardID: String?
    /// Steps spent on eggs and headlines. They come off what counts toward
    /// rewards, but never off the leaderboard (that's what you walked).
    @Published private(set) var spentSteps: Int

    private let health = HKHealthStore()
    private let stepType = HKQuantityType(.stepCount)
    private let defaults = UserDefaults.standard
    private var observer: HKObserverQuery?
    /// Counts today's steps live from the motion chip while the app is open. Health only
    /// gets the iPhone's steps every few minutes, which is too slow for a race.
    private let pedometer = CMPedometer()
    private var pedometerDay: Date?
    /// Today's steps from the motion chip (iPhone only, no Watch).
    @Published private(set) var pedometerToday = 0
    /// Health's own counts from the last refresh, before today's live steps are added.
    private var healthTotal = 0
    private var healthWeek = 0
    private var healthDays: [String: Int] = [:]
    private var syncUID: String?
    /// Re-renders views that read rewards or claims through this store when either changes.
    private var rewardChanges: AnyCancellable?

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
        goalRewardID = defaults.string(forKey: "walk.goalReward")
        spentSteps = defaults.integer(forKey: "walk.spentSteps")
        // Claims used to be kept only on the phone; they're on the server now.
        defaults.removeObject(forKey: "walk.claimed")
        #if DEBUG
        testSteps = defaults.integer(forKey: "walk.testSteps")
        #endif
        rewardChanges = RewardStore.shared.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Every step walked since joining (shown on the leaderboard): the server's
    /// total plus whatever this phone counted since that sync, so it stays live
    /// without waiting on the network. Before any sync it's the phone's own count.
    var totalSteps: Int {
        var total = stepsSinceJoining
        if let sync {
            total = sync.total + max(0, stepsSinceJoining - sync.localTotal)
        }
        #if DEBUG
        total += testSteps
        #endif
        return total
    }

    /// Steps this week, worked out like `totalSteps`. A server value from a
    /// past week is ignored.
    var stepsThisWeek: Int {
        var week = localWeek
        if let sync, sync.weekKey == LeaderboardStore.weekKey {
            week = sync.week + max(0, localWeek - sync.localWeek)
        }
        return week
    }

    // MARK: - Server totals

    /// What the server said after a recalc, and this phone's own counts at the
    /// moment of that upload (so later steps can be added on top).
    struct ServerSync: Codable, Equatable {
        var total: Int
        var week: Int
        var weekKey: String
        var localTotal: Int
        var localWeek: Int
    }

    /// Switches the server totals to `uid`'s (saved per user), or clears them
    /// when signed out.
    func setUser(_ uid: String?) {
        guard uid != syncUID else { return }
        syncUID = uid
        sync = uid.flatMap { uid in
            defaults.data(forKey: "walk.sync.\(uid)").flatMap { try? JSONDecoder().decode(ServerSync.self, from: $0) }
        }
    }

    /// Saves the server's totals after a successful recalc for `uid`.
    func applyServerSync(_ value: ServerSync, uid: String) {
        guard uid == syncUID else { return }
        sync = value
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: "walk.sync.\(uid)")
        }
    }

    /// Steps per day for timed rewards' progress (the server counts for itself before a claim).
    var rewardDays: [String: Int] {
        #if DEBUG
        // Test steps count as walked today, so timed rewards can be tried in the Simulator.
        var days = dailySteps
        days[HealthDays.key(for: .now), default: 0] += testSteps
        return days
        #else
        return dailySteps
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
        if let id = goalRewardID, let picked = Reward.all.first(where: { $0.id == id }), !isClaimed(picked), !picked.soldOut {
            return picked
        }
        return Reward.all.first { !isClaimed($0) && !$0.soldOut }
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
    /// Your claim for `reward`, whatever its status.
    func claim(for reward: Reward) -> RewardClaim? { RewardStore.shared.claims[reward.claimKey] }

    /// Claimed and not rejected (a rejected one can be claimed again).
    func isClaimed(_ reward: Reward) -> Bool {
        guard let claim = claim(for: reward) else { return false }
        return claim.status != .rejected
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
        startLiveSteps()
    }

    func refresh() async {
        guard access == .ready else { return }
        let startOfWeek = Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start
            ?? Calendar.current.startOfDay(for: .now)
        healthTotal = await sumOfSteps(from: joinDate)
        healthWeek = await sumOfSteps(from: startOfWeek)
        healthDays = await stepsPerDay()
        startLiveSteps()
        // Don't wait for the live updates' first answer: read the motion chip now, so
        // the count sent on opening isn't Health's alone (which is often behind).
        if let chip = await HealthDays.chipToday(), chip > pedometerToday { pedometerToday = chip }
        applyCounts()
        hasLoaded = true
    }

    /// Health's counts, topped up with today's live steps when the motion chip is ahead
    /// of Health (it usually is while you walk). Set together so one change means one upload.
    private func applyCounts() {
        let today = HealthDays.key(for: .now)
        let healthToday = healthDays[today] ?? 0
        // Health, the motion chip, or the most this phone has already sent today: whichever is highest.
        let days = HealthDays.withChip(healthDays, chip: pedometerToday)
        let extra = max(0, (days[today] ?? 0) - healthToday)
        if stepsSinceJoining != healthTotal + extra { stepsSinceJoining = healthTotal + extra }
        if localWeek != healthWeek + extra { localWeek = healthWeek + extra }
        if days != dailySteps { dailySteps = days }
    }

    /// Follows today's steps on the motion chip, every few seconds while you walk.
    /// Restarts at midnight. Does nothing if Motion & Fitness is off.
    private func startLiveSteps() {
        guard CMPedometer.isStepCountingAvailable(), CMPedometer.authorizationStatus() != .denied else { return }
        let today = Calendar.current.startOfDay(for: .now)
        guard pedometerDay != today else { return }
        pedometer.stopUpdates()
        pedometerDay = today
        pedometerToday = 0
        pedometer.startUpdates(from: today) { [weak self] data, _ in
            guard let steps = data?.numberOfSteps.intValue else { return }
            Task { @MainActor in
                guard let self, self.pedometerDay == today else { return }
                if Calendar.current.startOfDay(for: .now) != today {
                    // A new day: count from midnight again.
                    await self.refresh()
                    return
                }
                guard steps != self.pedometerToday else { return }
                self.pedometerToday = steps
                self.applyCounts()
            }
        }
    }

    // MARK: - Setup check

    /// Whether step counting really works, for the setup screen.
    enum Check: Equatable {
        /// Health has steps from the past week: all good.
        case working
        /// The motion chip counts steps but Health gives Cablgram none: Steps is off for
        /// Cablgram in Health (or Health hasn't got them yet).
        case healthOff
        /// Motion & Fitness is off for Cablgram.
        case motionOff
        /// No steps anywhere yet (a new phone, or Fitness Tracking is off).
        case noSteps
        /// No Health on this device.
        case unavailable
    }

    /// Asks for Health access if needed, then looks for steps in Health and on the motion chip.
    func check() async -> Check {
        if access == .notRequested { await start() }
        guard access == .ready else { return .unavailable }
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        if await sumOfSteps(from: weekAgo) > 0 {
            await refresh()
            return .working
        }
        guard CMPedometer.isStepCountingAvailable() else { return .noSteps }
        if CMPedometer.authorizationStatus() == .denied || CMPedometer.authorizationStatus() == .restricted {
            return .motionOff
        }
        // Also asks for Motion & Fitness the first time.
        let chipSteps = await withCheckedContinuation { (done: CheckedContinuation<Int, Never>) in
            pedometer.queryPedometerData(from: weekAgo, to: .now) { data, _ in
                done.resume(returning: data?.numberOfSteps.intValue ?? 0)
            }
        }
        if CMPedometer.authorizationStatus() == .denied { return .motionOff }
        startLiveSteps()
        return chipSteps > 0 ? .healthOff : .noSteps
    }

    /// Steps typed in by hand in the Health app don't count, only ones the
    /// iPhone, Watch or a fitness app measured. Samples without the key count.
    private static let notUserEntered = NSPredicate(format: "metadata.%K != YES", HKMetadataKeyWasUserEntered)

    /// Health steps for each local calendar day from the join day (at most the
    /// newest 60 days) to today, keyed "yyyy-MM-dd".
    private func stepsPerDay() async -> [String: Int] {
        await HealthDays.fetch(from: health, joinDate: joinDate)
    }

    private func sumOfSteps(from start: Date) async -> Int {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: nil),
            Self.notUserEntered,
        ])
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
        defaults.set(0, forKey: "walk.testSteps")
        defaults.set(0, forKey: "walk.spentSteps")
    }
    #endif
}
