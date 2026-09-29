import CodexBarCore
import Foundation

/// Today's Claude Code tokens from local transcripts. CodexBarCore owns the
/// transcript parsing, streamed-chunk de-duplication and price table.
enum ClaudeTokenCollector {
    static func collect(
        previous: UsageValue<ClaudeTokenTotals>,
        now: Date,
        cacheRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        calendar: Calendar = .current
    ) async -> UsageValue<ClaudeTokenTotals> {
        do {
            if let fixture = environment["CLAUDE_TOKEN_FIXTURE"] {
                let totals = try JSONDecoder().decode(
                    ClaudeTokenTotals.self, from: Data(contentsOf: URL(fileURLWithPath: fixture))
                )
                return value(totals, now: now, complete: true)
            }
            guard projectsRootExists(environment: environment) else {
                return UsageValue(
                    status: .unavailable, source: .none, measuredAt: nil, lastAttemptAt: now,
                    message: "Run Claude Code once so local session logs are available.", value: nil
                )
            }
            let snapshot = try await CostUsageFetcher(cacheRoot: cacheRoot, calendar: calendar).loadTokenSnapshot(
                provider: .claude,
                environment: environment,
                now: now,
                forceRefresh: true,
                historyDays: 1,
                allowPricingRefresh: false,
                refreshPricingInBackground: false,
                includePiSessions: false
            )
            let totals = try totals(from: snapshot.currentDayEntry(calendar: calendar))
            return value(totals, now: now, complete: snapshot.historyCoverageIsEstablished)
        } catch {
            return CollectorSupport.stale(
                previous: previous,
                attemptedAt: now,
                status: .error,
                message: "Claude usage could not be refreshed: \(error.localizedDescription)"
            )
        }
    }

    static func totals(from entry: CostUsageDailyReport.Entry?) throws -> ClaudeTokenTotals {
        let input = max(0, entry?.inputTokens ?? 0)
        let cacheCreation = max(0, entry?.cacheCreationTokens ?? 0)
        let cacheRead = max(0, entry?.cacheReadTokens ?? 0)
        let output = max(0, entry?.outputTokens ?? 0)
        let total = try [cacheCreation, cacheRead, output].reduce(input, CodexUsageSupport.adding)
        return ClaudeTokenTotals(
            totalTokens: total,
            inputTokens: input,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            outputTokens: output,
            costUSD: entry?.costUSD
        )
    }

    /// Mirrors CodexBarCore's root order so a machine without Claude Code
    /// reports "no data" instead of a misleading zero.
    static func projectsRootExists(
        environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let roots: [URL]
        if let configured = CodexUsageSupport.nonempty(environment["CLAUDE_CONFIG_DIR"]) {
            roots = [URL(fileURLWithPath: configured, isDirectory: true).appendingPathComponent("projects")]
        } else {
            roots = [
                homeDirectory.appendingPathComponent(".config/claude/projects"),
                homeDirectory.appendingPathComponent(".claude/projects"),
                homeDirectory.appendingPathComponent("Library/Application Support/Claude"),
            ]
        }
        return roots.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func value(_ totals: ClaudeTokenTotals, now: Date, complete: Bool) -> UsageValue<ClaudeTokenTotals> {
        UsageValue(
            status: complete ? .ready : .stale,
            source: .codexBarLocal,
            measuredAt: now,
            lastAttemptAt: now,
            message: complete ? nil : "Indexing Claude sessions; today's total may increase on the next refresh.",
            value: totals
        )
    }
}
