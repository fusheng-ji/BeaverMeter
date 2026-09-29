import CodexBarCore
import Foundation
import XCTest

final class ClaudeCollectionTests: XCTestCase {
    private var now: Date {
        ISO8601DateFormatter().date(from: "2026-09-23T12:00:00Z")!
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("beavermeter-claude-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func usage(_ json: String) throws -> ClaudeOAuthUsageResponse {
        try JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: Data(json.utf8))
    }

    func testTightestWindowWinsIncludingModelScopedWeeks() throws {
        let response = try usage("""
        {"five_hour":{"utilization":38,"resets_at":"2026-09-23T15:00:00.000000+00:00"},
         "seven_day":{"utilization":12.5,"resets_at":"2026-09-27T00:00:00Z"},
         "seven_day_opus":{"utilization":71,"resets_at":"2026-09-27T00:00:00Z"},
         "seven_day_sonnet":null}
        """)
        let quota = try XCTUnwrap(ClaudeQuotaCollector.tightestQuota(in: response, now: now))
        XCTAssertEqual(quota.label, "Claude Opus Week")
        XCTAssertEqual(quota.remainingPercent, 29)
        XCTAssertEqual(quota.windowSeconds, 604_800)
        XCTAssertEqual(quota.resetAt, ISO8601DateFormatter().date(from: "2026-09-27T00:00:00Z"))
    }

    func testFiveHourWindowAndOverLimitClamp() throws {
        let response = try usage("""
        {"five_hour":{"utilization":104,"resets_at":"2026-09-23T15:00:00Z"},
         "seven_day":{"utilization":40,"resets_at":null}}
        """)
        let quota = try XCTUnwrap(ClaudeQuotaCollector.tightestQuota(in: response, now: now))
        XCTAssertEqual(quota.label, "Claude 5h")
        XCTAssertEqual(quota.remainingPercent, 0)
        XCTAssertEqual(quota.windowSeconds, 18_000)
    }

    func testResponseWithoutWindowsHasNoQuota() throws {
        XCTAssertNil(ClaudeQuotaCollector.tightestQuota(in: try usage(#"{"five_hour":null}"#), now: now))
    }

    func testCredentialsRequireAnUnexpiredAccessToken() throws {
        let future = (now.timeIntervalSince1970 + 3_600) * 1_000
        let past = (now.timeIntervalSince1970 - 60) * 1_000
        XCTAssertEqual(
            try ClaudeQuotaCollector.accessToken(
                fromCredentials: Data(#"{"claudeAiOauth":{"accessToken":" demo ","expiresAt":\#(future)}}"#.utf8),
                now: now
            ),
            "demo"
        )
        XCTAssertThrowsError(try ClaudeQuotaCollector.accessToken(
            fromCredentials: Data(#"{"claudeAiOauth":{"accessToken":"demo","expiresAt":\#(past)}}"#.utf8), now: now
        )) { XCTAssertEqual($0 as? ClaudeQuotaError, .expired) }
        XCTAssertThrowsError(try ClaudeQuotaCollector.accessToken(
            fromCredentials: Data(#"{"mcpOAuth":{}}"#.utf8), now: now
        )) { XCTAssertEqual($0 as? ClaudeQuotaError, .notLoggedIn) }
    }

    func testQuotaFailureKeepsPreviousValueAsStale() async throws {
        let previous = UsageValue(status: .ready, source: .accountAPI, measuredAt: now.addingTimeInterval(-300),
                                  lastAttemptAt: now.addingTimeInterval(-300), message: nil,
                                  value: UsageSnapshot.preview.claudeQuota.value)
        let result = await ClaudeQuotaCollector.collect(
            previous: previous, now: now,
            environment: ["CLAUDE_USAGE_FIXTURE": try workspace().appendingPathComponent("missing.json").path]
        )
        XCTAssertEqual(result.status, .stale)
        XCTAssertEqual(result.source, .cache)
        XCTAssertEqual(result.value, previous.value)
        XCTAssertTrue(result.message?.hasPrefix("Claude quota refresh failed") == true)
    }

    func testTokenTotalsIncludeBothCacheCounters() throws {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-09-23", inputTokens: 200, outputTokens: 100, cacheReadTokens: 1_900,
            cacheCreationTokens: 300, totalTokens: 2_500, requestCount: 7, costUSD: 0.0123,
            modelsUsed: ["claude-sonnet-4-5"], modelBreakdowns: nil
        )
        let totals = try ClaudeTokenCollector.totals(from: entry)
        XCTAssertEqual(totals.totalTokens, 2_500)
        XCTAssertEqual(totals.cacheCreationTokens, 300)
        XCTAssertEqual(totals.cacheReadTokens, 1_900)
        XCTAssertEqual(totals.costUSD, 0.0123)

        let zero = try ClaudeTokenCollector.totals(from: nil)
        XCTAssertEqual(zero.totalTokens, 0)
        XCTAssertNil(zero.costUSD)
    }

    func testMissingClaudeHomeIsUnavailableRatherThanZero() async throws {
        let root = try workspace()
        let configured = ["CLAUDE_CONFIG_DIR": root.path]
        XCTAssertFalse(ClaudeTokenCollector.projectsRootExists(environment: configured))
        XCTAssertFalse(ClaudeTokenCollector.projectsRootExists(environment: [:], homeDirectory: root))

        let result = await ClaudeTokenCollector.collect(
            previous: .unavailable("none"), now: now, cacheRoot: root.appendingPathComponent("cache"),
            environment: configured
        )
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertNil(result.value)

        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude/projects"),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(ClaudeTokenCollector.projectsRootExists(environment: [:], homeDirectory: root))
    }

    func testTokenFixtureIsReportedAsLiveLocalUsage() async throws {
        let fixture = try workspace().appendingPathComponent("tokens.json")
        let totals = try XCTUnwrap(UsageSnapshot.preview.claudeTokens.value)
        try JSONEncoder().encode(totals).write(to: fixture)
        let result = await ClaudeTokenCollector.collect(
            previous: .unavailable("none"), now: now, cacheRoot: fixture.deletingLastPathComponent(),
            environment: ["CLAUDE_TOKEN_FIXTURE": fixture.path]
        )
        XCTAssertEqual(result.status, .ready)
        XCTAssertEqual(result.source, .codexBarLocal)
        XCTAssertEqual(result.value, totals)
    }
}
