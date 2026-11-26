import SwiftUI

/// Full leaderboard, opened from "See all" on the Walk page.
struct LeaderboardView: View {
    enum Period: String, CaseIterable, Identifiable {
        /// Progress toward your goal reward (what its race shows). Only offered when you have a goal.
        case reward = "Your goal"
        case allTime = "All time"
        case thisWeek = "This week"
        var id: String { rawValue }
    }

    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var leaderboard: LeaderboardStore
    @EnvironmentObject private var stepStore: StepStore
    @State private var period: Period = .reward

    private var goal: Reward? { stepStore.goalReward }
    /// Without a goal there's no reward board: fall back to all time.
    private var shown: Period { period == .reward && goal == nil ? .allTime : period }

    private var rows: [LeaderboardEntry] {
        switch shown {
        case .reward: goal.map { leaderboard.rewardRows(for: $0, steps: stepStore, auth: auth) } ?? []
        case .allTime: leaderboard.ranked
        case .thisWeek: leaderboard.thisWeek
        }
    }

    private func steps(of entry: LeaderboardEntry) -> Int {
        shown == .thisWeek ? entry.weekSteps : entry.totalSteps
    }

    private var myRank: Int? {
        guard let uid = auth.user?.uid else { return nil }
        return rows.firstIndex { $0.id == uid }.map { $0 + 1 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Period", selection: Binding(get: { shown }, set: { period = $0 })) {
                    ForEach(Period.allCases.filter { $0 != .reward || goal != nil }) {
                        Text($0 == .reward ? (goal?.title ?? $0.rawValue) : $0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: period) { _, _ in Haptics.select() }

                if let notice = LeaderboardNotice.current(auth: auth, leaderboard: leaderboard, isEmpty: rows.isEmpty,
                                                          emptyText: shown == .thisWeek
                                                              ? "Nobody has walked yet this week. Be the first!"
                                                              : "No walkers yet. Start walking to take #1!") {
                    notice
                } else {
                    if shown == .reward, let goal {
                        Text(goal.schedule == nil
                             ? "Steps each walker has to use toward \(goal.fullName)."
                             : "Steps each walker has in this period toward \(goal.fullName), minus any they spent.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let myRank {
                        HStack {
                            Text("You're #\(myRank)").font(.headline)
                            Spacer()
                            Text(shown == .reward ? "to \(goal?.fullName ?? "your goal")\(goal?.schedule == nil ? "" : " · \(goal?.periodName().lowercased() ?? "")")"
                                 : shown == .allTime ? "all time" : "this week")
                                .lineLimit(1)
                                .font(.subheadline)
                                .opacity(0.85)
                        }
                        .padding(.vertical, 4)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                            LeaderRow(rank: index + 1, entry: entry, steps: steps(of: entry),
                                      isMe: entry.id == auth.user?.uid,
                                      note: shown == .reward ? goal.flatMap { leaderboard.rewardNote(entry, goal: $0, steps: stepStore) } : nil)
                            if index < rows.count - 1 { Divider().padding(.leading, 64) }
                        }
                    }
                    .card(cornerRadius: 18)
                    .animation(.smooth(duration: 0.6), value: rows.map(\.id))
                }
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
    }
}

/// One leaderboard line: rank or medal, photo, name, steps.
struct LeaderRow: View {
    let rank: Int
    let entry: LeaderboardEntry
    let steps: Int
    let isMe: Bool
    /// Shown after the number on a reward's board: "days", or a trophy once they've reached it.
    var note: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(rank <= 3 ? Color.brand : .secondary)
                .frame(width: 28)
            Avatar(url: entry.photoURL, name: entry.name, size: 36)
            Text(isMe ? "\(entry.name) (you)" : entry.name)
                .font(.subheadline.weight(isMe ? .bold : .medium))
                .lineLimit(1)
            Spacer()
            Text(steps.formatted())
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText(value: Double(steps)))
                .animation(.smooth(duration: 0.8), value: steps)
                .foregroundStyle(isMe ? Color.brand : .primary)
            if let note {
                Text(note).font(.subheadline)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isMe ? Color.brand.opacity(0.08) : .clear)
    }
}

/// Message shown instead of the leaderboard when there's nothing to list.
struct LeaderboardNotice: View {
    let text: String
    let icon: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(cornerRadius: 18)
    }

    @MainActor
    static func current(auth: AuthStore, leaderboard: LeaderboardStore, isEmpty: Bool, emptyText: String) -> LeaderboardNotice? {
        if !AuthStore.isConfigured || auth.user == nil {
            return LeaderboardNotice(text: "Sign in to join the leaderboard.",
                                     icon: "person.crop.circle.badge.exclamationmark")
        }
        if let error = leaderboard.errorMessage {
            return LeaderboardNotice(text: "Couldn't load the leaderboard: \(error)", icon: "exclamationmark.triangle.fill")
        }
        if isEmpty {
            return LeaderboardNotice(text: emptyText, icon: "trophy")
        }
        return nil
    }
}

extension LeaderboardStore {
    /// A reward's board as leaderboard rows: `totalSteps` holds each walker's progress toward it.
    func rewardRows(for goal: Reward, steps: StepStore, auth: AuthStore) -> [LeaderboardEntry] {
        board(for: goal, steps: steps, uid: auth.user?.uid, name: auth.user?.displayName ?? "You", photoURL: auth.user?.photoURL)
            .map { LeaderboardEntry(id: $0.id, name: $0.name, photoURL: $0.photoURL, totalSteps: $0.steps,
                                    weekSteps: 0, week: "", updatedAt: $0.updatedAt) }
    }

    /// What follows a walker's number on a reward's board.
    func rewardNote(_ entry: LeaderboardEntry, goal: Reward, steps: StepStore) -> String? {
        let need = steps.progress(toward: goal).need
        if entry.totalSteps >= need { return "🏆" }
        return goal.schedule?.everyDay == true ? (entry.totalSteps == 1 ? "day" : "days") : nil
    }
}
