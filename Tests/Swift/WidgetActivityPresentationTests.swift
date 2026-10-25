import Foundation
import XCTest

final class WidgetActivityPresentationTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-26T12:00:00Z")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return value
    }

    private func reading<T: Codable & Hashable & Sendable>(
        _ value: T?, measuredAt: Date? = nil, status: UsageDataStatus = .ready,
        source: UsageDataSource = .codexBarLocal, message: String? = nil
    ) -> UsageValue<T> {
        UsageValue(status: status, source: source, measuredAt: measuredAt ?? now,
                   lastAttemptAt: now, message: message, value: value)
    }

    private func codex(_ count: Int) -> CodexTokenTotals {
        CodexTokenTotals(totalTokens: count, inputTokens: count, cachedInputTokens: 0,
                         outputTokens: 0, reasoningTokens: 0, sessionCount: 1)
    }

    private func claude(_ count: Int) -> ClaudeTokenTotals {
        ClaudeTokenTotals(totalTokens: count, inputTokens: count, cacheCreationTokens: 0,
                          cacheReadTokens: 0, outputTokens: 0, costUSD: nil)
    }

    private func deepseek(tokens: Int?, calls: Int?) -> DeepSeekUsageTotals {
        DeepSeekUsageTotals(monthTokens: tokens, monthRequests: calls,
                            monthCosts: [DeepSeekMoney(currency: "USD", amount: 500)],
                            balances: [DeepSeekMoney(currency: "USD", amount: 999)],
                            grantedBalances: [], totalCosts: [])
    }

    private func history(_ days: [(Date, Int)], zone: String? = nil) -> TokenHistory<CodexTokenTotals> {
        TokenHistory(sourceID: "all-configured-sources", timeZoneIdentifier: zone ?? calendar.timeZone.identifier,
                     days: days.map { TokenHistoryDay(date: $0.0, totals: codex($0.1)) }, totals: codex(999_999))
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    private func snapshot(
        codexTokens: UsageValue<CodexTokenTotals>? = nil,
        claudeTokens: UsageValue<ClaudeTokenTotals>? = nil,
        cursorCosts: UsageValue<CursorCostTotals>? = nil,
        deepseek: UsageValue<DeepSeekUsageTotals>? = nil,
        codexHistory: UsageValue<TokenHistory<CodexTokenTotals>>? = nil,
        claudeHistory: UsageValue<TokenHistory<ClaudeTokenTotals>>? = nil,
        quotaStatus: UsageDataStatus = .ready
    ) -> UsageSnapshot {
        let base = UsageSnapshot.preview
        let quota = reading(base.codexQuota.value, status: quotaStatus, source: .accountAPI, message: "quota-only status")
        return UsageSnapshot(schemaVersion: UsageSnapshot.currentSchemaVersion, generatedAt: now,
            codexTokens: codexTokens ?? reading(codex(100)),
            cursorCosts: cursorCosts ?? reading(CursorCostTotals(todayCostUSD: 1.25, recentEvents: [])),
            cursorQuota: quota, codexQuota: quota,
            claudeTokens: claudeTokens ?? reading(claude(200)), claudeQuota: quota,
            deepseekUsage: deepseek ?? reading(self.deepseek(tokens: 300, calls: 4)),
            codexHistory: codexHistory ?? .unavailable("No Codex history"),
            claudeHistory: claudeHistory ?? .unavailable("No Claude history"))
    }

    private func item(_ snapshot: UsageSnapshot, provider: MeterProvider = .codex,
                      referenceDate: Date? = nil, calendar: Calendar? = nil) -> WidgetActivityItem {
        WidgetActivityPresentation(snapshot: snapshot, providers: [provider], referenceDate: referenceDate ?? now,
                                   calendar: calendar ?? self.calendar).items[0]
    }

    func testLegacyProviderSummaryRemainsDeduplicatedAndExplicitlyScopedAcrossWorkspaces() {
        var source = snapshot()
        let quota = source.codexQuota
        source.codexAccounts = reading((1...5).map { number in
            CodexAccountUsage(id: "workspace-\(number)", homeID: "home-\(number)", displayName: "Workspace \(number)",
                              quota: quota, resetCards: .unavailable("No inventory"), planName: "Pro")
        })
        let model = WidgetActivityPresentation(snapshot: source, providers: [.cursor, .codex, .codex, .claude, .cursor],
                                               referenceDate: now, calendar: calendar)
        XCTAssertEqual(model.items.map(\.provider), [.cursor, .codex, .claude])
        XCTAssertEqual(Set(model.items.map(\.id)).count, 3)
        let codex = model.items[1]
        XCTAssertEqual(codex.value, "100")
        XCTAssertEqual(codex.aggregationNote, "All workspaces")
        XCTAssertTrue(codex.accessibilityText.contains("All workspaces"))
        XCTAssertFalse(codex.accessibilityText.contains("Workspace 1"))
        XCTAssertNil(model.items[0].aggregationNote)
        XCTAssertTrue(WidgetActivityPresentation(snapshot: source, providers: [], referenceDate: now).items.isEmpty)
    }

    func testDailyTokenValuesKeepZeroAndHideBothProvidersPreviousDay() {
        let zero = snapshot(codexTokens: reading(codex(0)), claudeTokens: reading(claude(0)))
        for provider in [MeterProvider.codex, .claude] {
            let current = item(zero, provider: provider)
            XCTAssertEqual(current.value, "0")
            XCTAssertEqual(current.caption, "tokens today")
            XCTAssertEqual(current.status.severity, .normal)
        }
        let old = snapshot(codexTokens: reading(codex(123), measuredAt: day(-1)),
                           claudeTokens: reading(claude(456), measuredAt: day(-1)))
        for provider in [MeterProvider.codex, .claude] {
            XCTAssertEqual(item(old, provider: provider).value, "—")
            XCTAssertEqual(item(old, provider: provider).status.severity, .warning)
        }
    }

    func testUnmeasuredFutureAndNegativeDailyTokensAreUnknown() {
        let unmeasured = UsageValue(status: UsageDataStatus.ready, source: UsageDataSource.codexBarLocal,
                                    measuredAt: nil, lastAttemptAt: now, message: nil, value: codex(123))
        let readings = [unmeasured, reading(codex(123), measuredAt: now.addingTimeInterval(60)), reading(codex(-1))]
        for data in readings {
            let result = item(snapshot(codexTokens: data))
            XCTAssertEqual(result.value, "—")
            XCTAssertNotEqual(result.status.severity, .normal)
        }
    }

    func testDailyPreviewRemainsFrozenButRealReadingsUseSelectedCalendarDay() {
        let preview = reading(codex(123), measuredAt: day(-2), source: .preview)
        XCTAssertEqual(item(snapshot(codexTokens: preview)).value, "123")
        let instant = ISO8601DateFormatter().date(from: "2026-10-26T00:30:00Z")!
        let measurement = instant.addingTimeInterval(-3_600)
        let source = snapshot(codexTokens: reading(codex(123), measuredAt: measurement))
        XCTAssertEqual(item(source, referenceDate: instant).value, "123")
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(item(source, referenceDate: instant, calendar: utc).value, "—")
    }

    func testCursorUsesTodayActualChargeAndDoesNotInventCallCount() {
        let source = snapshot(cursorCosts: reading(CursorCostTotals(todayCostUSD: 0, recentEvents: [])))
        let result = item(source, provider: .cursor)
        XCTAssertEqual(result.value, "$0.00")
        XCTAssertEqual(result.compactValue, "$0.00")
        XCTAssertEqual(result.caption, "actual charge today")
        XCTAssertNil(result.history)
        XCTAssertNil(result.historyStatus)
        XCTAssertFalse(result.accessibilityText.contains("remaining"))
        XCTAssertFalse(result.accessibilityText.contains("calls"))
        let old = reading(CursorCostTotals(todayCostUSD: 9.99, recentEvents: []), measuredAt: day(-1))
        XCTAssertEqual(item(snapshot(cursorCosts: old), provider: .cursor).value, "—")
        for amount in [Double.nan, .infinity, -1] {
            let invalid = reading(CursorCostTotals(todayCostUSD: amount, recentEvents: []))
            XCTAssertEqual(item(snapshot(cursorCosts: invalid), provider: .cursor).value, "—")
        }
    }

    func testCursorAmountCompactsWithCurrencyWhileFullChargeRemainsInAccessibility() {
        for (amount, full, compact) in [(1_280.0, "$1,280.00", "$1.3K"),
                                        (1_280_000.0, "$1,280,000.00", "$1.3M"),
                                        (1_280_000_000.0, "$1,280,000,000.00", "$1.3B")] {
            let result = item(snapshot(cursorCosts: reading(CursorCostTotals(todayCostUSD: amount, recentEvents: []))),
                              provider: .cursor)
            XCTAssertEqual(result.value, full)
            XCTAssertEqual(result.compactValue, compact)
            XCTAssertTrue(result.accessibilityText.contains(full))
        }
        let precise = item(snapshot(cursorCosts: reading(CursorCostTotals(todayCostUSD: 1.2345, recentEvents: []))),
                           provider: .cursor)
        XCTAssertEqual(precise.value, "$1.23")
        XCTAssertTrue(precise.accessibilityText.contains("$1.2345"))
    }

    func testDeepSeekShowsMonthlyTokensAndCallsWithoutUsingBalanceOrSpend() {
        let result = item(snapshot(deepseek: reading(deepseek(tokens: 12_000, calls: 25))), provider: .deepseek)
        XCTAssertEqual(result.value, "12.0K")
        XCTAssertEqual(result.caption, "tokens this month")
        XCTAssertEqual(result.detail, "25 calls this month")
        XCTAssertNil(result.history)
        XCTAssertFalse(result.accessibilityText.contains("999"))
        XCTAssertFalse(result.accessibilityText.contains("500"))
        let callsOnly = item(snapshot(deepseek: reading(deepseek(tokens: nil, calls: 0))), provider: .deepseek)
        XCTAssertEqual(callsOnly.value, "0")
        XCTAssertEqual(callsOnly.caption, "calls this month")
        let unknown = item(snapshot(deepseek: reading(deepseek(tokens: nil, calls: nil))), provider: .deepseek)
        XCTAssertEqual(unknown.value, "—")
        XCTAssertNotEqual(unknown.status.severity, .normal)
    }

    func testDeepSeekPriorMonthActivityIsHiddenButCurrentCachedMonthIsMarkedStale() {
        let previousMonth = calendar.date(byAdding: .month, value: -1, to: now)!
        let old = reading(deepseek(tokens: 123, calls: 4), measuredAt: previousMonth)
        XCTAssertEqual(item(snapshot(deepseek: old), provider: .deepseek).value, "—")
        let cached = reading(deepseek(tokens: 123, calls: 4), status: .stale, source: .cache)
        let current = item(snapshot(deepseek: cached), provider: .deepseek)
        XCTAssertEqual(current.value, "123")
        XCTAssertEqual(current.status.severity, .warning)
        XCTAssertTrue(current.status.detail.contains("Stale"))
    }

    func testActivityStatusNeverInheritsQuotaAndHistoryStatusDoesNotPolluteCurrentUsage() {
        let healthy = snapshot(quotaStatus: .error)
        for provider in MeterProvider.allCases {
            let result = item(healthy, provider: provider)
            XCTAssertEqual(result.status.severity, .normal)
            XCTAssertFalse(result.accessibilityText.contains("quota-only status"))
            XCTAssertFalse(result.accessibilityText.contains("No Codex history"))
        }
        let stale = reading(codex(100), status: .stale, source: .cache, message: "retained local activity")
        let result = item(snapshot(codexTokens: stale, codexHistory: reading(history([(day(0), 20)]))))
        XCTAssertEqual(result.status.severity, .warning)
        XCTAssertEqual(result.historyStatus?.severity, .normal)
        XCTAssertTrue(result.accessibilityText.contains("retained local activity"))
    }

    func testSevenHistorySlotsKeepGapsAndZeroAndIgnoreFutureAndOutsideWindow() {
        let history = history([(day(-7), 777), (day(-6), 0), (day(-4), 100), (day(-1), 200), (day(0), 300),
                               (day(1), 999), (now.addingTimeInterval(60), 123_456)])
        let result = item(snapshot(codexHistory: reading(history)))
        XCTAssertEqual(result.history?.map(\.value), [0, nil, 100, nil, nil, 200, 300])
        XCTAssertEqual(result.history?.map(\.date), (-6...0).map(day))
        XCTAssertEqual(result.historyLabel, "Last 7 days")
        XCTAssertEqual(result.historyTimeZoneIdentifier, "Europe/Berlin")
        XCTAssertEqual(result.historyStatus?.severity, .normal)
    }

    func testHistoryUsesSourceTimeZoneInsteadOfCallersCalendarDate() {
        let instant = ISO8601DateFormatter().date(from: "2026-10-26T00:30:00Z")!
        var sourceCalendar = calendar
        sourceCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let sourceToday = sourceCalendar.startOfDay(for: instant)
        let source = history([(sourceToday, 25), (sourceToday.addingTimeInterval(86_400), 999)],
                             zone: sourceCalendar.timeZone.identifier)
        let result = item(snapshot(codexHistory: reading(source, measuredAt: instant)), referenceDate: instant)
        XCTAssertEqual(result.history?.last?.date, sourceToday)
        XCTAssertEqual(result.history?.last?.value, 25)
        XCTAssertEqual(result.historyTimeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(calendar.component(.day, from: instant), 26)
        XCTAssertEqual(sourceCalendar.component(.day, from: result.history!.last!.date), 25)
    }

    func testHistorySlotsFollowCalendarDaysAcrossDaylightSavingTransition() {
        let source = history((-6...0).map { (day($0), $0 + 6) })
        let result = item(snapshot(codexHistory: reading(source)))
        let dates = result.history!.map(\.date)
        XCTAssertEqual(result.history!.map(\.value), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(Set(dates).count, 7)
        XCTAssertTrue(zip(dates.dropFirst(), dates).contains { $0.timeIntervalSince($1) == 25 * 3_600 })
    }

    func testMissingInvalidAndUnavailableHistoryNeverBecomesZeroBars() {
        let known = history([(day(0), 10)])
        let unmeasured = UsageValue(status: UsageDataStatus.ready, source: UsageDataSource.codexBarLocal,
                                    measuredAt: nil, lastAttemptAt: now, message: nil, value: known)
        for data in [UsageValue<TokenHistory<CodexTokenTotals>>.unavailable("No history"),
                     reading(history([(day(0), 10)], zone: "invalid/timezone")),
                     reading(known, status: .unavailable), reading(known, status: .unauthenticated),
                     unmeasured, reading(known, measuredAt: now.addingTimeInterval(60)), reading(history([]))] {
            let result = item(snapshot(codexHistory: data))
            XCTAssertEqual(result.history?.count, 7)
            XCTAssertTrue(result.history!.allSatisfy { $0.value == nil })
            XCTAssertNotEqual(result.historyStatus?.severity, .normal)
        }
    }

    func testOldHistoryRetainsOnlyItsActualDaysAndHasIndependentStaleStatus() {
        let old = reading(history([(day(-1), 99)]), measuredAt: day(-1))
        let result = item(snapshot(codexHistory: old))
        XCTAssertEqual(result.value, "100")
        XCTAssertEqual(result.status.severity, .normal)
        XCTAssertEqual(result.history?.dropLast().last?.value, 99)
        XCTAssertNil(result.history?.last?.value)
        XCTAssertNotEqual(result.historyStatus?.severity, .normal)
        XCTAssertTrue(result.historyStatus?.detail.contains("cache") == true)
        XCTAssertFalse(result.accessibilityText.contains("History"))
    }

    func testCachedHistoryKeepsKnownZeroAndConflictingDuplicateDaysStayUnknown() {
        let cached = reading(history([(day(-1), 0), (day(0), 5)]), status: .stale, source: .cache)
        let result = item(snapshot(codexHistory: cached))
        XCTAssertEqual(result.history?.suffix(2).map(\.value), [0, 5])
        XCTAssertEqual(result.historyStatus?.severity, .warning)
        let duplicates = history([(day(0), 5), (day(0), 8), (day(-1), -1)])
        let ambiguous = item(snapshot(codexHistory: reading(duplicates)))
        XCTAssertTrue(ambiguous.history!.allSatisfy { $0.value == nil })
    }

    func testClaudeHistoryUsesItsOwnTotalsAndDoesNotBorrowCodexDays() {
        let history = TokenHistory(sourceID: "claude-local", timeZoneIdentifier: calendar.timeZone.identifier,
                                   days: [TokenHistoryDay(date: day(0), totals: claude(17))], totals: claude(17))
        let source = snapshot(codexHistory: reading(self.history([(day(0), 999)])), claudeHistory: reading(history))
        let result = item(source, provider: .claude)
        XCTAssertEqual(result.value, "200")
        XCTAssertEqual(result.history?.last?.value, 17)
        XCTAssertNil(result.aggregationNote)
    }
}
