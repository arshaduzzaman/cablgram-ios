import SwiftUI

/// Full leaderboard, opened from "See all" on the Walk page.
struct LeaderboardView: View {
    enum Period: String, CaseIterable, Identifiable {
        case allTime = "All time"
        case today = "Today"
        var id: String { rawValue }
    }

    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var leaderboard: LeaderboardStore
    @State private var period: Period = .allTime

    private var rows: [LeaderboardEntry] {
        period == .allTime ? leaderboard.entries : leaderboard.today
    }

    private func steps(of entry: LeaderboardEntry) -> Int {
        period == .allTime ? entry.totalSteps : entry.todaySteps
    }

    private var myRank: Int? {
        guard let uid = auth.user?.uid else { return nil }
        return rows.firstIndex { $0.id == uid }.map { $0 + 1 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: period) { _, _ in Haptics.select() }

                if let notice = LeaderboardNotice.current(auth: auth, leaderboard: leaderboard, isEmpty: rows.isEmpty,
                                                          emptyText: period == .today
                                                              ? "Nobody has walked yet today. Be the first!"
                                                              : "No walkers yet. Start walking to take #1!") {
                    notice
                } else {
                    if let myRank {
                        HStack {
                            Text("You're #\(myRank)").font(.headline)
                            Spacer()
                            Text(period == .allTime ? "all time" : "today")
                                .font(.subheadline)
                                .opacity(0.85)
                        }
                        .padding(.vertical, 4)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                            LeaderRow(rank: index + 1, entry: entry, steps: steps(of: entry),
                                      isMe: entry.id == auth.user?.uid)
                            if index < rows.count - 1 { Divider().padding(.leading, 64) }
                        }
                    }
                    .card(cornerRadius: 18)
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
                .foregroundStyle(isMe ? Color.brand : .primary)
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
            return LeaderboardNotice(text: "Sign in with Google to join the leaderboard.",
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
