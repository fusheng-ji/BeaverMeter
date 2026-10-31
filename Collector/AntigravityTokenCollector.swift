import CodexBarCore
import Foundation

/// Today's local Antigravity activity is independent from the logged-in
/// account's quota and is never converted into subscription utilization.
enum AntigravityTokenCollector {
    typealias SnapshotLoader = @Sendable ([String: String], Date, URL, Calendar) async throws -> CostUsageTokenSnapshot

    static func collect(
        previous: UsageValue<AntigravityTokenTotals>,
        now: Date,
        cacheRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        calendar: Calendar = .current,
        loadSnapshot: SnapshotLoader = loadLocal
    ) async -> UsageValue<AntigravityTokenTotals> {
        do {
            if let fixture = environment["ANTIGRAVITY_TOKEN_FIXTURE"] {
                let totals = try JSONDecoder().decode(AntigravityTokenTotals.self,
                    from: Data(contentsOf: URL(fileURLWithPath: fixture)))
                return value(totals, now: now)
            }
            try Task.checkCancellation()
            let snapshot = try await loadSnapshot(environment, now, cacheRoot, calendar)
            try Task.checkCancellation()
            guard snapshot.historyCoverageIsEstablished else {
                return fallback(previous: previous, now: now, calendar: calendar,
                    message: "Antigravity local logs are unavailable or still being scanned; today's total is unknown.")
            }
            guard calendar.isDate(snapshot.updatedAt, inSameDayAs: now) else {
                return fallback(previous: previous, now: now, calendar: calendar,
                    message: "Today's Antigravity local logs are awaiting refresh.")
            }
            let entry = snapshot.currentDayEntry(calendar: calendar)
            if entry == nil, let reported = snapshot.sessionTokens, reported != 0 {
                throw TokenError.missingTotal
            }
            let totals = try totals(from: entry)
            return value(totals, now: now)
        } catch {
            return fallback(previous: previous, now: now, calendar: calendar,
                message: error is CancellationError ? "Antigravity local-log refresh was cancelled."
                    : "Antigravity local logs could not be refreshed. BeaverMeter will retry automatically.")
        }
    }

    static func totals(from entry: CostUsageDailyReport.Entry?) throws -> AntigravityTokenTotals {
        guard let entry else {
            // Only called after coverage was established for today's date.
            return AntigravityTokenTotals(totalTokens: 0, inputTokens: 0, cacheReadTokens: 0,
                cacheCreationTokens: 0, outputTokens: 0, reasoningTokens: 0, requestCount: 0)
        }
        let components = [entry.inputTokens, entry.cacheReadTokens, entry.cacheCreationTokens,
                          entry.outputTokens, entry.reasoningTokens]
        guard components.allSatisfy({ $0.map { $0 >= 0 } ?? true }),
              entry.requestCount.map({ $0 >= 0 }) ?? true,
              entry.totalTokens.map({ $0 >= 0 }) ?? true else { throw TokenError.invalidCounters }
        let total: Int
        if components.allSatisfy({ $0 != nil }) {
            total = try components.compactMap { $0 }.reduce(0, CodexUsageSupport.adding)
        } else if let reported = entry.totalTokens {
            total = reported
        } else {
            throw TokenError.missingTotal
        }
        return AntigravityTokenTotals(totalTokens: total, inputTokens: entry.inputTokens,
            cacheReadTokens: entry.cacheReadTokens, cacheCreationTokens: entry.cacheCreationTokens,
            outputTokens: entry.outputTokens, reasoningTokens: entry.reasoningTokens,
            requestCount: entry.requestCount)
    }

    private enum TokenError: Error { case invalidCounters, missingTotal }

    private static func value(_ totals: AntigravityTokenTotals, now: Date) -> UsageValue<AntigravityTokenTotals> {
        UsageValue(status: .ready, source: .codexBarLocal, measuredAt: now,
                   lastAttemptAt: now, message: nil, value: totals)
    }

    private static func fallback(previous: UsageValue<AntigravityTokenTotals>, now: Date,
                                 calendar: Calendar, message: String) -> UsageValue<AntigravityTokenTotals> {
        if let measuredAt = previous.measuredAt, let totals = previous.value,
           previous.source == .codexBarLocal || previous.source == .cache,
           measuredAt <= now, calendar.isDate(measuredAt, inSameDayAs: now) {
            return UsageValue(status: .stale, source: .cache, measuredAt: measuredAt,
                              lastAttemptAt: now, message: message, value: totals)
        }
        return UsageValue(status: .unavailable, source: .none, measuredAt: nil,
                          lastAttemptAt: now, message: message, value: nil)
    }

    private static func loadLocal(environment: [String: String], now: Date,
                                  cacheRoot: URL, calendar: Calendar) async throws -> CostUsageTokenSnapshot {
        try await AntigravityLogScope.withScope(environment: environment, cacheRoot: cacheRoot) { scoped in
            try await CostUsageFetcher(cacheRoot: cacheRoot, calendar: calendar).loadTokenSnapshot(
                provider: .antigravity, environment: scoped, now: now, forceRefresh: true,
                historyDays: 1, allowPricingRefresh: false, refreshPricingInBackground: false,
                includePiSessions: false)
        }
    }
}
