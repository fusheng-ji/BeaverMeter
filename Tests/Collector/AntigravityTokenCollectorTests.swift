import CodexBarCore
import Foundation
import XCTest

final class AntigravityTokenCollectorTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }
    private var empty: UsageValue<AntigravityTokenTotals> { .unavailable("No local logs") }

    private func entry(date: String = "2026-10-31", input: Int? = 10, cacheRead: Int? = 20,
                       cacheWrite: Int? = 30, output: Int? = 40, reasoning: Int? = 50,
                       total: Int? = 150) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(date: date, inputTokens: input, outputTokens: output,
            cacheReadTokens: cacheRead, cacheCreationTokens: cacheWrite, reasoningTokens: reasoning,
            totalTokens: total, requestCount: 3, costUSD: nil, modelsUsed: nil, modelBreakdowns: nil)
    }

    private func snapshot(_ entries: [CostUsageDailyReport.Entry], complete: Bool = true,
                          at date: Date? = nil) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(sessionTokens: entries.first?.totalTokens, sessionCostUSD: nil,
            last30DaysTokens: nil, last30DaysCostUSD: nil, historyDays: 1,
            historyCoverageIsEstablished: complete, daily: entries, updatedAt: date ?? now)
    }

    private func collect(_ snapshot: CostUsageTokenSnapshot,
                         previous: UsageValue<AntigravityTokenTotals>? = nil,
                         at date: Date? = nil) async -> UsageValue<AntigravityTokenTotals> {
        await AntigravityTokenCollector.collect(previous: previous ?? empty, now: date ?? now,
            cacheRoot: FileManager.default.temporaryDirectory, environment: [:], calendar: calendar,
            loadSnapshot: { _, _, _, _ in snapshot })
    }

    func testTokenCategoriesAreIndependentAdditiveCountsWithoutPricing() async throws {
        let reading = await collect(snapshot([entry()]))
        let totals = try XCTUnwrap(reading.value)
        XCTAssertEqual(reading.status, .ready)
        XCTAssertEqual(reading.source, .codexBarLocal)
        XCTAssertEqual(totals.totalTokens, 150)
        XCTAssertEqual(totals.inputTokens, 10)
        XCTAssertEqual(totals.cacheReadTokens, 20)
        XCTAssertEqual(totals.cacheCreationTokens, 30)
        XCTAssertEqual(totals.outputTokens, 40)
        XCTAssertEqual(totals.reasoningTokens, 50)
        XCTAssertEqual(totals.requestCount, 3)
        let encoded = String(decoding: try JSONEncoder().encode(totals), as: UTF8.self)
        XCTAssertFalse(encoded.contains("cost"))
    }

    func testMissingBreakdownPreservesUnknownAndUsesExplicitTotal() async throws {
        let reading = await collect(snapshot([entry(cacheRead: nil, total: 500)]))
        XCTAssertEqual(reading.value?.totalTokens, 500)
        XCTAssertNil(reading.value?.cacheReadTokens)
        XCTAssertEqual(reading.value?.inputTokens, 10)
    }

    func testMissingTotalAndBreakdownIsUnavailable() async throws {
        let reading = await collect(snapshot([entry(cacheRead: nil, total: nil)]))
        XCTAssertEqual(reading.status, .unavailable)
        XCTAssertNil(reading.value)
    }

    func testNegativeAndOverflowingCountersAreNotPublished() async throws {
        for invalid in [entry(input: -1), entry(input: Int.max)] {
            let reading = await collect(snapshot([invalid]))
            XCTAssertEqual(reading.status, .unavailable)
            XCTAssertNil(reading.value)
        }
    }

    func testCompleteScanWithoutTodayRecordsProvesZero() async throws {
        let reading = await collect(snapshot([]))
        XCTAssertEqual(reading.status, .ready)
        XCTAssertEqual(reading.value?.totalTokens, 0)
        XCTAssertEqual(reading.value?.requestCount, 0)
    }

    func testIncompleteOrUnavailableScanCannotInventZero() async throws {
        let reading = await collect(snapshot([], complete: false))
        XCTAssertEqual(reading.status, .unavailable)
        XCTAssertNil(reading.value)
    }

    func testPositiveSessionTotalWithoutTodayEntryIsNotAProvenZero() async throws {
        let inconsistent = CostUsageTokenSnapshot(sessionTokens: 50, sessionCostUSD: nil,
            last30DaysTokens: nil, last30DaysCostUSD: nil, historyDays: 1,
            historyCoverageIsEstablished: true, daily: [], updatedAt: now)
        let reading = await collect(inconsistent)
        XCTAssertEqual(reading.status, .unavailable)
        XCTAssertNil(reading.value)
    }

    func testIncompleteScanKeepsSameDayCacheWithoutRefreshingMeasurement() async throws {
        let original = await collect(snapshot([entry()]))
        let reading = await collect(snapshot([], complete: false), previous: original,
                                    at: now.addingTimeInterval(60))
        XCTAssertEqual(reading.status, .stale)
        XCTAssertEqual(reading.source, .cache)
        XCTAssertEqual(reading.value?.totalTokens, 150)
        XCTAssertEqual(reading.measuredAt, now)
    }

    func testCompleteScanAcceptsLowerCorrectedValueAndZero() async throws {
        let original = await collect(snapshot([entry()]))
        let lower = await collect(snapshot([entry(input: 1, cacheRead: 2, cacheWrite: 3,
                                                   output: 4, reasoning: 5, total: 15)]), previous: original)
        XCTAssertEqual(lower.status, .ready)
        XCTAssertEqual(lower.value?.totalTokens, 15)
        let zero = await collect(snapshot([]), previous: original)
        XCTAssertEqual(zero.status, .ready)
        XCTAssertEqual(zero.value?.totalTokens, 0)
    }

    func testLocalMidnightNeverRelabelsPreviousDayCacheAsToday() async throws {
        let before = ISO8601DateFormatter().date(from: "2026-10-31T22:59:00Z")!
        let after = ISO8601DateFormatter().date(from: "2026-10-31T23:01:00Z")!
        let previous = await collect(snapshot([entry()], at: before), at: before)
        let reading = await collect(snapshot([], complete: false, at: after), previous: previous, at: after)
        XCTAssertEqual(reading.status, .unavailable)
        XCTAssertNil(reading.value)
        let next = await collect(snapshot([entry(date: "2026-11-01", input: 1, cacheRead: 0,
            cacheWrite: 0, output: 2, reasoning: 0, total: 3)], at: after), previous: previous, at: after)
        XCTAssertEqual(next.value?.totalTokens, 3)
    }

    func testDSTFallbackUsesLocalDateInsteadOfFixedTwentyFourHourOffset() async throws {
        let before = ISO8601DateFormatter().date(from: "2026-10-25T00:30:00Z")!
        let after = ISO8601DateFormatter().date(from: "2026-10-25T01:30:00Z")!
        let previous = await collect(snapshot([entry(date: "2026-10-25")], at: before), at: before)
        let reading = await collect(snapshot([], complete: false, at: after), previous: previous, at: after)
        XCTAssertEqual(reading.status, .stale)
        XCTAssertEqual(reading.value?.totalTokens, 150)
    }

    func testYesterdaySnapshotCannotBePublishedAsReadyToday() async throws {
        let yesterday = now.addingTimeInterval(-86_400)
        let reading = await collect(snapshot([entry(date: "2026-10-30")], at: yesterday))
        XCTAssertEqual(reading.status, .unavailable)
        XCTAssertNil(reading.value)
    }

    func testCancelledScanDoesNotPublishFreshTotal() async throws {
        let reading = await AntigravityTokenCollector.collect(previous: empty, now: now,
            cacheRoot: FileManager.default.temporaryDirectory, environment: [:], calendar: calendar,
            loadSnapshot: { _, _, _, _ in throw CancellationError() })
        XCTAssertEqual(reading.status, .unavailable)
        XCTAssertNil(reading.value)
    }
}
