import SwiftUI

/// A reward's period, named by its first day ("2026-11-26"). One day long for daily rewards.
struct RewardSpan: Hashable {
    let start: String
    let end: String
}

/// When a timed reward can be earned (set on the dashboard). The steps have to be walked
/// inside a period, and a repeating reward can be claimed once per period. The server
/// (cablgram-admin lib/periods.ts) works periods out the same way and has the final say.
struct RewardSchedule: Hashable {
    enum Kind: String { case daily, weekly, dates, weekdays }

    let kind: Kind
    /// First and last day it runs ("yyyy-MM-dd"). Both set for `.dates`.
    var from: String?
    var to: String?
    /// For `.weekdays`: 0 (Sunday) to 6 (Saturday).
    var weekdays: [Int] = []
    /// The target must be walked on every day of the period, not in total over it.
    var everyDay = false

    /// The period `day` falls in, or nil when the reward isn't running that day.
    func span(on day: String) -> RewardSpan? {
        if let from, day < from { return nil }
        if let to, day > to { return nil }
        switch kind {
        case .daily:
            return RewardSpan(start: day, end: day)
        case .weekdays:
            return weekdays.contains(RewardDays.weekday(day)) ? RewardSpan(start: day, end: day) : nil
        case .weekly:
            // Sunday to Saturday, cut short where the reward starts or ends.
            let sunday = RewardDays.add(-RewardDays.weekday(day), to: day)
            let saturday = RewardDays.add(6, to: sunday)
            return RewardSpan(start: max(from ?? sunday, sunday), end: min(to ?? saturday, saturday))
        case .dates:
            guard let from, let to else { return nil }
            return RewardSpan(start: from, end: to)
        }
    }

    /// The periods that can be claimed now: the one that ended yesterday (until midday
    /// today), then the one running today.
    func openSpans(at now: Date = .now) -> [RewardSpan] {
        let today = RewardDays.key(now)
        let yesterday = RewardDays.add(-1, to: today)
        var spans: [RewardSpan] = []
        if let last = span(on: yesterday), last.end == yesterday, now <= RewardDays.claimDeadline(last) {
            spans.append(last)
        }
        if let current = span(on: today), !spans.contains(current) { spans.append(current) }
        return spans
    }
}

/// Bangladesh calendar days, which is what reward periods are made of.
enum RewardDays {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Dhaka") ?? .current
        return calendar
    }()

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func key(_ date: Date) -> String { formatter.string(from: date) }
    static func date(_ day: String) -> Date { formatter.date(from: day) ?? .now }
    static func add(_ days: Int, to day: String) -> String {
        key(calendar.date(byAdding: .day, value: days, to: date(day)) ?? date(day))
    }
    /// 0 (Sunday) to 6 (Saturday).
    static func weekday(_ day: String) -> Int { calendar.component(.weekday, from: date(day)) - 1 }
    static func count(_ span: RewardSpan) -> Int {
        (calendar.dateComponents([.day], from: date(span.start), to: date(span.end)).day ?? 0) + 1
    }
    /// When the period's last day is over.
    static func end(_ span: RewardSpan) -> Date { date(add(1, to: span.end)) }
    /// When claims close: midday after the last day, when that day's steps stop counting.
    static func claimDeadline(_ span: RewardSpan) -> Date { end(span).addingTimeInterval(12 * 3600) }

    /// "Thu 26 Nov", or "22 to 28 Nov" for several days.
    static func label(_ span: RewardSpan) -> String {
        let style = Date.FormatStyle(timeZone: calendar.timeZone).day().month(.abbreviated)
        if span.start == span.end { return date(span.start).formatted(style.weekday(.abbreviated)) }
        let sameMonth = span.start.prefix(7) == span.end.prefix(7)
        let first = sameMonth ? String(calendar.component(.day, from: date(span.start))) : date(span.start).formatted(style)
        return "\(first) to \(date(span.end).formatted(style))"
    }
}

extension Reward {
    /// How far you are in this reward's period, from the steps this phone counted per day.
    /// Counting in total, `done` and `need` are steps; counting every day, they're days.
    func progress(days: [String: Int], today: String = RewardDays.key(.now)) -> (done: Int, need: Int, missed: Bool) {
        guard let span, let schedule else { return (0, steps, false) }
        var total = 0, daysDone = 0, missed = false
        var day = span.start
        while day <= span.end, day <= today {
            let walked = days[day] ?? 0
            total += walked
            if walked >= steps { daysDone += 1 } else if day < today { missed = true }
            day = RewardDays.add(1, to: day)
        }
        return schedule.everyDay ? (daysDone, RewardDays.count(span), missed) : (total, steps, false)
    }

    /// "Today", "Yesterday", "This week", "Last week" or the dates.
    func periodName(at now: Date = .now) -> String {
        guard let span, let schedule else { return "" }
        let today = RewardDays.key(now)
        if span.start == span.end {
            if span.start == today { return "Today" }
            if span.start == RewardDays.add(-1, to: today) { return "Yesterday" }
        } else if schedule.kind == .weekly {
            return span.end >= today ? "This week" : "Last week"
        }
        return RewardDays.label(span)
    }
}

/// Rewards with a deadline (daily, weekly, between dates), each with your progress.
/// Hidden when the dashboard has none running.
struct TimedRewardsSection: View {
    @EnvironmentObject private var steps: StepStore
    @ObservedObject private var store = RewardStore.shared
    let onClaim: (Reward) -> Void

    var body: some View {
        // Redrawn each minute, so countdowns move and a new day brings the new period.
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let offers = offers(at: timeline.date)
            if !offers.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "Limited-time rewards")
                    VStack(spacing: 0) {
                        ForEach(offers, id: \.claimKey) { reward in
                            TimedRewardCard(reward: reward, now: timeline.date) { onClaim(reward) }
                                .hairline(leading: reward.claimKey == offers.last?.claimKey ? 0 : 72)
                        }
                    }
                    Text("Only steps walked in each period count. Claim by midday the day after it ends.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One row per reward and open period. A period that has ended shows only while
    /// there's something to do or see: a claim to send, or one you sent.
    private func offers(at now: Date) -> [Reward] {
        let today = RewardDays.key(now)
        let offers = store.timed.flatMap { reward -> [Reward] in
            (reward.schedule?.openSpans(at: now) ?? []).compactMap { span in
                var offer = reward
                offer.span = span
                if span.end >= today { return offer }
                if steps.claim(for: offer) != nil { return offer }
                let got = offer.progress(days: steps.rewardDays, today: today)
                return got.done >= got.need && !offer.soldOut ? offer : nil
            }
        }
        // Soonest to end first.
        return offers.sorted { ($0.span?.end ?? "", $0.steps) < ($1.span?.end ?? "", $1.steps) }
    }
}

/// One timed reward: photo, name, its period, progress and time left, and Claim once reached.
struct TimedRewardCard: View {
    @EnvironmentObject private var steps: StepStore
    let reward: Reward
    let now: Date
    let onClaim: () -> Void

    var body: some View {
        let got = reward.progress(days: steps.rewardDays, today: RewardDays.key(now))
        let reached = got.done >= got.need
        let claim = steps.claim(for: reward)
        let claimed = steps.isClaimed(reward)

        HStack(spacing: 14) {
            RewardImage(reward: reward)
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(reward.fullName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(reward.periodName(at: now).uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.5)
                    .foregroundStyle(Color.brand)
                if !reached && !claimed && !got.missed {
                    GradientProgressBar(fraction: Double(got.done) / Double(max(got.need, 1)))
                        .padding(.vertical, 3)
                }
                Text(amount(got))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let claim, claim.status != .pending, let message = claim.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(claim.status == .rejected ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !claimed {
                    Text(got.missed ? "A day was missed, so this one is out of reach." : timeLeft)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            if let claim, claimed {
                ClaimStatusLabel(status: claim.status)
            } else if reward.soldOut {
                Text("All claimed")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else if reached {
                Button {
                    Haptics.press()
                    onClaim()
                } label: {
                    Text(claim?.status == .rejected ? "Claim again" : "Claim")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Color.brand, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "lock")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 12)
    }

    private func amount(_ got: (done: Int, need: Int, missed: Bool)) -> String {
        if reward.schedule?.everyDay == true {
            return "\(reward.steps.formatted()) steps a day · \(got.done) of \(got.need) days"
        }
        return got.done >= got.need
            ? "\(reward.steps.formatted()) steps"
            : "\(got.done.formatted()) of \(reward.steps.formatted()) steps"
    }

    /// "Ends in 5 hr" while it runs, "Claim by 12:00 PM" once it's over.
    private var timeLeft: String {
        guard let span = reward.span else { return "" }
        let end = RewardDays.end(span)
        if now >= end {
            return "Claim by \(RewardDays.claimDeadline(span).formatted(date: .omitted, time: .shortened))"
        }
        let minutes = Int(end.timeIntervalSince(now) / 60)
        if minutes < 60 { return "Ends in \(max(minutes, 1)) min" }
        if minutes < 48 * 60 { return "Ends in \(minutes / 60) hr" }
        return "Ends in \(minutes / (24 * 60)) days"
    }
}
