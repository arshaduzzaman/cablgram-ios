import SwiftUI

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

                if !AuthStore.isConfigured || auth.user == nil {
                    notice("Sign in with Google to join the leaderboard.", icon: "person.crop.circle.badge.exclamationmark")
                } else if let error = leaderboard.errorMessage {
                    notice("Couldn't load the leaderboard: \(error)", icon: "exclamationmark.triangle.fill")
                } else if rows.isEmpty {
                    notice(period == .today ? "Nobody has walked yet today. Be the first!" : "No walkers yet. Start walking to take #1!",
                           icon: "trophy")
                } else {
                    if let myRank {
                        HStack {
                            Text("You're #\(myRank)")
                                .font(.headline)
                            Spacer()
                            Text(period == .allTime ? "all time" : "today")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .foregroundStyle(.white)
                        .background(.brandGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                            row(rank: index + 1, entry: entry)
                            if index < rows.count - 1 { Divider().padding(.leading, 64) }
                        }
                    }
                    .card(cornerRadius: 18)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func row(rank: Int, entry: LeaderboardEntry) -> some View {
        let isMe = entry.id == auth.user?.uid
        return HStack(spacing: 12) {
            Text(rank <= 3 ? ["🥇", "🥈", "🥉"][rank - 1] : "\(rank)")
                .font(rank <= 3 ? .title3 : .subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28)
            Avatar(url: entry.photoURL, name: entry.name, size: 36)
            Text(isMe ? "\(entry.name) (you)" : entry.name)
                .font(.subheadline.weight(isMe ? .bold : .medium))
                .lineLimit(1)
            Spacer()
            Text(steps(of: entry).formatted())
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(isMe ? Color.brand : .primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isMe ? Color.brand.opacity(0.08) : .clear)
    }

    private func notice(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(cornerRadius: 18)
    }
}
