import Foundation
import HealthKit
import UIKit
import FirebaseAuth

/// Health steps per local calendar day, as the server wants them.
enum HealthDays {
    /// Steps typed in by hand in the Health app don't count, only ones the
    /// iPhone, Watch or a fitness app measured. Samples without the key count.
    static func notUserEntered() -> NSPredicate {
        NSPredicate(format: "metadata.%K != YES", HKMetadataKeyWasUserEntered)
    }

    /// Each day from the join day (at most the newest 60 days) to today, keyed "yyyy-MM-dd".
    static func fetch(from health: HKHealthStore, joinDate: Date) async -> [String: Int] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let oldest = calendar.date(byAdding: .day, value: -59, to: today) ?? today
        let start = max(calendar.startOfDay(for: joinDate), oldest)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: nil),
            notUserEntered(),
        ])
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.stepCount), predicate: predicate),
            options: .cumulativeSum,
            anchorDate: start,
            intervalComponents: DateComponents(day: 1)
        )
        guard let collection = try? await descriptor.result(for: health) else { return [:] }
        var days: [String: Int] = [:]
        collection.enumerateStatistics(from: start, to: .now) { statistics, _ in
            let steps = statistics.sumQuantity()?.doubleValue(for: .count()) ?? 0
            days[key(for: statistics.startDate)] = Int(steps)
        }
        return days
    }

    /// A local calendar day's key, "yyyy-MM-dd".
    static func key(for date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Sends new steps to the server while the app is closed or in the background.
/// iOS wakes the app when Health records steps (at most about once an hour); the app then
/// sends this phone's days and asks the server to recount, so races and the leaderboard
/// stay current without opening Cablgram. While the app is on screen, `StepStore` and
/// `LeaderboardStore` do this instead.
@MainActor
enum BackgroundSteps {
    private static let health = HKHealthStore()
    private static var observer: HKObserverQuery?
    private static var running = false

    /// Call from `didFinishLaunching`: iOS only delivers to observers set up at launch.
    static func start() {
        guard HKHealthStore.isHealthDataAvailable(), observer == nil else { return }
        let type = HKQuantityType(.stepCount)
        let query = HKObserverQuery(sampleType: type, predicate: nil) { _, done, error in
            guard error == nil else { done(); return }
            Task { @MainActor in
                await sendIfInBackground()
                done() // tells iOS we're finished, or it slows down future wake-ups
            }
        }
        observer = query
        health.execute(query)
        health.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
    }

    private static func sendIfInBackground() async {
        // On screen, the app's own stores handle it.
        guard UIApplication.shared.applicationState != .active, !running,
              AuthStore.isConfigured, let uid = Auth.auth().currentUser?.uid,
              let joinDate = UserDefaults.standard.object(forKey: "walk.joinDate") as? Date else { return }
        running = true
        defer { running = false }
        // A little extra time in case iOS suspends the app mid-upload.
        let task = UIApplication.shared.beginBackgroundTask(withName: "steps")
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }

        let days = await HealthDays.fetch(from: health, joinDate: joinDate)
        guard !days.isEmpty else { return }
        do {
            try await LeaderboardStore.saveDevice(uid: uid, days: days)
            _ = await LeaderboardStore.recalc()
        } catch {}
    }
}
