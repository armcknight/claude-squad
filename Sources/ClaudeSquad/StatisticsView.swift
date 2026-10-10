import SwiftUI

/// Window content showing aggregate session statistics and badges.
struct StatisticsView: View {
    @ObservedObject var store: StatisticsStore

    var body: some View {
        Group {
            if let statistics = store.statistics {
                content(statistics)
            } else {
                ProgressView("Reading session history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .toolbar {
            ToolbarItem {
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh statistics")
                .disabled(store.isLoading)
            }
        }
        .onAppear {
            store.refresh()
        }
    }
}

private extension StatisticsView {
    var tileColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150), spacing: 12)]
    }

    func content(_ statistics: SessionStatistics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("Sessions") {
                    StatisticTile(title: "Total sessions", value: "\(statistics.totalSessions)")
                    StatisticTile(
                        title: "Longest session",
                        value: statistics.longestSession?.duration.formattedDuration ?? "—",
                        caption: statistics.longestSession?.projectName
                    )
                    StatisticTile(
                        title: "Longest idle gap",
                        value: statistics.longestIdleGap?.duration.formattedDuration ?? "—",
                        caption: statistics.longestIdleGap?.projectName
                    )
                    StatisticTile(
                        title: "Most concurrent",
                        value: statistics.peakConcurrency.map { "\($0.count)" } ?? "—",
                        caption: statistics.peakConcurrency.map { $0.date.formatted(date: .abbreviated, time: .shortened) }
                    )
                }

                section("New Session Frequency") {
                    StatisticTile(title: "Today", value: "\(statistics.sessionsStartedToday)")
                    StatisticTile(title: "Last 7 days", value: "\(statistics.sessionsStartedLast7Days)")
                    StatisticTile(
                        title: "Per active day",
                        value: statistics.averageSessionsPerActiveDay.formatted(.number.precision(.fractionLength(1)))
                    )
                    StatisticTile(title: "Longest streak", value: "\(statistics.longestDailyStreak) d")
                }

                section("Token Usage") {
                    StatisticTile(title: "Total", value: statistics.tokenUsage.total.compactFormatted)
                    StatisticTile(title: "Input", value: statistics.tokenUsage.input.compactFormatted)
                    StatisticTile(title: "Output", value: statistics.tokenUsage.output.compactFormatted)
                    StatisticTile(title: "Cache write", value: statistics.tokenUsage.cacheCreation.compactFormatted)
                    StatisticTile(title: "Cache read", value: statistics.tokenUsage.cacheRead.compactFormatted)
                }

                section("Badges (\(statistics.badges.filter(\.isEarned).count)/\(statistics.badges.count))") {
                    ForEach(statistics.badges) { badge in
                        BadgeTile(badge: badge)
                    }
                }
            }
            .padding()
        }
    }

    func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            LazyVGrid(columns: tileColumns, alignment: .leading, spacing: 12) {
                content()
            }
        }
    }
}

private extension Int {
    /// Compact number format, e.g. `1.2M`.
    var compactFormatted: String {
        formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}
