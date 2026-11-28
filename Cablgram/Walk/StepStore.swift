import Foundation
import Combine
import HealthKit
import CoreMotion
import FirebaseAuth
import FirebaseFirestore

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
    /// Steps spent on headlines, as the server last had it. They come off what counts
    /// toward rewards, but never off the leaderboard (that's what you walked).
    @Published private(set) var spentSteps: Int
    /// Your own `walkers` record: the server's count of your steps to use and your progress
    /// toward each reward. Nil when signed out or before it loads.
    @Published private(set) var server: LeaderboardEntry?

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
        defaults.removeObject(forKey: "walk.spentDays") // the server keeps these now
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

    /// Takes your record from the server (nil when signed out).
    func setServer(_ entry: LeaderboardEntry?) {
        server = entry
        guard let entry, entry.spentSteps != spentSteps else { return }
        spentSteps = entry.spentSteps
        defaults.set(spentSteps, forKey: "walk.spentSteps")
    }

    /// Steps this phone has counted since the server last worked out your record.
    private var sinceServer: Int { server.map { max(totalSteps - $0.totalSteps, 0) } ?? 0 }

    /// Steps your claims have used (a rejected claim gives them back), from your own claims.
    var rewardSpent: Int {
        RewardStore.shared.claims.values.filter { $0.status != .rejected }.reduce(0) { $0 + $1.stepsSpent }
    }

    /// Steps you have to use: walked minus spent (on headlines and rewards claimed). The
    /// server's count plus the steps since; before it has one, worked out here.
    var availableSteps: Int {
        if let counted = server?.available { return counted + sinceServer }
        return max(totalSteps - spentSteps - rewardSpent, 0)
    }

    /// How far you are toward `reward`: your steps to use for an ordinary one; for a
    /// limited-time one, steps (or days) in its period. `missed` means it's out of reach.
    /// The server works it out (cablgram-admin lib/progress.ts); steps walked since are added.
    func progress(toward reward: Reward) -> (done: Int, need: Int, missed: Bool) {
        if let got = server?.progress[reward.claimKey] {
            if got.countsDays { return (got.done, got.need, got.missed) }
            // A period that's over gets nothing from today's steps.
            let running = reward.span.map { $0.end >= RewardDays.key(.now) } ?? true
            return (min(got.done + (running ? sinceServer : 0), got.need), got.need, false)
        }
        // The server hasn't counted this one yet (a period that just began, or not signed in).
        guard let schedule = reward.schedule else { return (min(availableSteps, reward.steps), reward.steps, false) }
        return (0, schedule.everyDay ? reward.span.map(RewardDays.count) ?? 1 : reward.steps, false)
    }

    /// A limited-time reward with the period that's running today, or nil when it isn't running.
    func timedOffer(_ id: String, at now: Date = .now) -> Reward? {
        guard var reward = RewardStore.shared.timed.first(where: { $0.id == id }),
              let span = reward.schedule?.span(on: RewardDays.key(now)) else { return nil }
        reward.span = span
        return reward
    }

    var unlockedCount: Int {
        Reward.all.filter { availableSteps >= $0.steps }.count
    }

    /// The reward shown at the top of the Walk page: the one the user picked,
    /// or the first one not yet claimed.
    var goalReward: Reward? {
        if let id = goalRewardID, let picked = Reward.all.first(where: { $0.id == id }) ?? timedOffer(id),
           !isClaimed(picked), !picked.soldOut {
            return picked
        }
        return Reward.all.first { !isClaimed($0) && !$0.soldOut }
    }

    /// Steps still needed for the goal reward (0 when it's unlocked).
    var stepsToGoal: Int {
        guard let goal = goalReward else { return 0 }
        // Day by day for an every-day reward: what's left of today's target.
        if let got = server?.progress[goal.claimKey] { return max(got.left - sinceServer, 0) }
        let got = progress(toward: goal)
        return goal.schedule?.everyDay == true ? goal.steps : max(got.need - got.done, 0)
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

    func isUnlocked(_ reward: Reward) -> Bool {
        let got = progress(toward: reward)
        return got.done >= got.need
    }
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
        // Skipping the setup screen is reported from there; this keeps the result current.
        if defaults.bool(forKey: "setup.stepsChecked") { await report() }
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

    /// The same check without asking for anything, for the daily report to the dashboard.
    private func quietCheck() async -> (Check, chip: Int?) {
        guard access == .ready else { return (.unavailable, nil) }
        let chip = await HealthDays.chipToday()
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        if await sumOfSteps(from: weekAgo) > 0 { return (.working, chip) }
        switch CMPedometer.authorizationStatus() {
        case .denied, .restricted: return (.motionOff, chip)
        case .authorized: return ((chip ?? 0) > 0 ? .healthOff : .noSteps, chip)
        default: return (.noSteps, chip)
        }
    }

    /// Tells the admin dashboard what the step check found (users/{uid}.stepCheck), so
    /// people whose iPhone isn't counting show up there. Written when it changes, and
    /// once a day otherwise.
    func report(_ check: Check? = nil, skipped: Bool = false) async {
        guard AuthStore.isConfigured, let uid = Auth.auth().currentUser?.uid else { return }
        let found: Check, chip: Int?
        if let check {
            (found, chip) = (check, await HealthDays.chipToday())
        } else {
            (found, chip) = await quietCheck()
        }
        let today = HealthDays.key(for: .now)
        let mark = "\(uid)|\(found)|\(skipped)|\(today)"
        guard defaults.string(forKey: "walk.reportedCheck") != mark else { return }
        defaults.set(mark, forKey: "walk.reportedCheck")
        var data: [String: Any] = [
            "platform": "ios",
            "result": "\(found)",
            "skipped": skipped,
            "healthToday": healthDays[today] ?? 0,
            "at": FieldValue.serverTimestamp(),
        ]
        if let chip { data["chipToday"] = chip }
        try? await Firestore.firestore().collection("users").document(uid).setData(["stepCheck": data], merge: true)
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
        defaults.set(0, forKey: "walk.testSteps")
    }
    #endif
}
