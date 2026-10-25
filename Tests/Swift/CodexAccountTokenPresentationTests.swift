import Foundation
import XCTest

final class CodexAccountTokenPresentationTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!
    private let scopeA = String(repeating: "a", count: 64)
    private let scopeB = String(repeating: "b", count: 64)

    private func activity(scope: String? = nil, days: [CodexAccountTokenDay]? = nil,
                          lifetime: Int? = nil, asOf: String? = "2026-10-24") -> CodexAccountTokenActivity {
        CodexAccountTokenActivity(workspaceAccountIDHash: scope ?? scopeA, dailyUsage: days,
                                  lifetimeTokens: lifetime, statsAsOf: asOf)
    }

    private func reading(_ value: CodexAccountTokenActivity?, source: UsageDataSource = .accountAPI,
                         status: UsageDataStatus = .ready, measuredAt: Date? = nil) -> UsageValue<CodexAccountTokenActivity> {
        UsageValue(status: status, source: source, measuredAt: measuredAt ?? now,
                   lastAttemptAt: now, message: "Official account token activity.", value: value)
    }

    private func presentation(_ value: CodexAccountTokenActivity) -> CodexAccountTokenPresentation {
        CodexAccountTokenPresentation(reading(value), expectedScope: scopeA, relativeTo: now)
    }

    private func serviceDays(_ count: Int) -> [CodexAccountTokenDay] {
        let calendar = CodexAccountTokenDay.labelCalendar
        let end = ISO8601DateFormatter().date(from: "2026-10-24T00:00:00Z")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return (0..<count).map { index in
            let date = calendar.date(byAdding: .day, value: index - count + 1, to: end)!
            return CodexAccountTokenDay(date: formatter.string(from: date), tokens: index + 1)
        }
    }

    func testStrictServiceDateLabelsDoNotNormalizeInvalidDates() {
        for date in ["2026-02-29", "2026-04-31", "2026-1-04", "2026-10-24T00:00:00Z", "2026-00-24", "0000-01-01"] {
            XCTAssertNil(CodexAccountTokenDay.parseCalendarDate(date), date)
        }
        XCTAssertNotNil(CodexAccountTokenDay.parseCalendarDate("2024-02-29"))
        XCTAssertNotNil(CodexAccountTokenDay.parseCalendarDate("2026-10-25"))
    }

    func testFastDateParserMatchesFoundationAcrossLeapCenturiesAndHistoricalCutover() {
        let calendar = CodexAccountTokenDay.labelCalendar
        for (year, month, day) in [(1, 1, 1), (1500, 2, 29), (1582, 10, 4), (1582, 10, 10), (1582, 10, 15),
                                    (1600, 2, 29), (1700, 2, 29), (1900, 2, 28), (1900, 2, 29),
                                    (1970, 1, 1), (2000, 2, 29), (2100, 2, 29), (2400, 2, 29), (9999, 12, 31)] {
            let text = String(format: "%04d-%02d-%02d", year, month, day)
            let candidate = calendar.date(from: DateComponents(year: year, month: month, day: day))!
            let actual = calendar.dateComponents([.year, .month, .day], from: candidate)
            let expected = actual.year == year && actual.month == month && actual.day == day ? candidate : nil
            XCTAssertEqual(CodexAccountTokenDay.parseCalendarDate(text), expected, text)
        }
        for text in ["２０２６-10-24", "2026/10/24", "2026-10-24 ", "2026-10-2x"] {
            XCTAssertNil(CodexAccountTokenDay.parseCalendarDate(text), text)
        }
    }

    func testOneYearOutOfOrderHistoryUsesOnlyLatestSevenDaysWithoutLosingSourceArray() {
        let days = serviceDays(365)
        let input = activity(days: Array(days.reversed()))
        let result = presentation(input)
        XCTAssertEqual(result.value, "365")
        XCTAssertEqual(result.history?.map(\.value), (359...365).map { Optional($0) })
        XCTAssertEqual(result.data.value?.dailyUsage, input.dailyUsage)
        XCTAssertEqual(result.caption, "tokens today")
    }

    func testManyDaysHistoryStillValidatesConflictsOutsideDisplayedWeek() {
        let days = serviceDays(10_000)
        let result = presentation(activity(days: days))
        XCTAssertEqual(result.history?.map(\.value), (9_994...10_000).map { Optional($0) })
        XCTAssertEqual(result.countDescription, "10,000 tokens today")
        let conflicting = days + [.init(date: days[0].date, tokens: 99)]
        XCTAssertEqual(presentation(activity(days: conflicting)).data.status, .unavailable)
        var invalid = days
        invalid[0] = .init(date: "2025-02-29", tokens: 1)
        XCTAssertNil(presentation(activity(days: invalid)).data.value)
    }

    func testTodayCaptionKeepsSourcePeriodInTimingAcrossLocalDayAndDSTBoundary() {
        let value = activity(days: [.init(date: "2026-10-24", tokens: 111)], lifetime: 9_999)
        let result = presentation(value)
        XCTAssertEqual(result.value, "111")
        XCTAssertEqual(result.caption, "tokens today")
        XCTAssertEqual(result.countDescription, "111 tokens today")
        XCTAssertTrue(result.timingDescription.contains("Service bucket date 2026-10-24"))
        XCTAssertEqual(result.historyLabel, "7 days through Oct 24")
        XCTAssertEqual(result.history?.last?.value, 111)
        XCTAssertEqual(result.history?.count, 7)
        XCTAssertEqual(result.data.value?.statsAsOf, "2026-10-24")
    }

    func testSparseDaysStayUnknownAndReportedZeroStaysZero() {
        let result = presentation(activity(days: [.init(date: "2026-10-24", tokens: 50),
                                                 .init(date: "2026-10-22", tokens: 0)]))
        XCTAssertEqual(result.history?.map(\.value), [nil, nil, nil, nil, 0, nil, 50])
    }

    func testLifetimeOnlyAndKnownZeroDoNotBecomeTodayReadings() {
        let possibilities: [[CodexAccountTokenDay]?] = [nil, []]
        for days in possibilities {
            let result = presentation(activity(days: days, lifetime: 0))
            XCTAssertEqual(result.value, "0")
            XCTAssertEqual(result.caption, "tokens total")
            XCTAssertEqual(result.status.severity, .normal)
            XCTAssertNil(result.history)
        }
    }

    func testMissingMetricsNeverInventZeroOrLiveData() {
        for value in [activity(), activity(days: [])] {
            XCTAssertEqual(presentation(value).value, "—")
            XCTAssertEqual(presentation(value).data.status, .unavailable)
        }
        let empty = CodexAccountTokenPresentation(reading(nil), expectedScope: scopeA, relativeTo: now)
        XCTAssertEqual(empty.data.status, .unavailable)
    }

    func testInvalidAndConflictingDataNeverShowsAWorkspaceValue() {
        for value in [
            activity(scope: scopeB, days: [.init(date: "2026-10-24", tokens: 111)]),
            activity(days: [.init(date: "2026-02-29", tokens: 111)]),
            activity(days: [.init(date: "2026-10-24", tokens: -1)]),
            activity(days: [.init(date: "2026-10-24", tokens: 1), .init(date: "2026-10-24", tokens: 2)]),
            activity(lifetime: -1)
        ] {
            XCTAssertEqual(presentation(value).value, "—")
            XCTAssertNil(presentation(value).history)
        }
    }

    func testIdenticalDuplicateDaysAreNeverAddedTogether() {
        let result = presentation(activity(days: [.init(date: "2026-10-24", tokens: 111),
                                                 .init(date: "2026-10-24", tokens: 111)]))
        XCTAssertEqual(result.value, "111")
        XCTAssertEqual(result.history?.last?.value, 111)
    }

    func testOnlyOfficialSourcesAndPastMeasurementAreAccepted() {
        let value = activity(days: [.init(date: "2026-10-24", tokens: 111)])
        let unverified = CodexAccountTokenPresentation(reading(value, source: .codexBarLocal),
                                                       expectedScope: scopeA, relativeTo: now)
        let future = CodexAccountTokenPresentation(reading(value, measuredAt: now.addingTimeInterval(1)),
                                                   expectedScope: scopeA, relativeTo: now)
        XCTAssertEqual(unverified.value, "—")
        XCTAssertEqual(future.value, "—")
    }

    func testOldReadingKeepsItsSourceDateInTimingAndBecomesStale() {
        let value = activity(days: [.init(date: "2025-10-24", tokens: 111)])
        let result = CodexAccountTokenPresentation(reading(value, measuredAt: now.addingTimeInterval(-10_801)),
                                                   expectedScope: scopeA, relativeTo: now)
        XCTAssertEqual(result.value, "111")
        XCTAssertEqual(result.caption, "tokens today")
        XCTAssertTrue(result.timingDescription.contains("Service bucket date 2025-10-24"))
        XCTAssertEqual(result.historyLabel, "7 days through Oct 24, 2025")
        XCTAssertEqual(result.data.status, .stale)
    }

    func testAPIActivityRoundTripsWithoutFabricatedBreakdown() throws {
        let source = activity(days: [.init(date: "2026-10-24", tokens: 111)])
        let data = try JSONEncoder().encode(source)
        XCTAssertEqual(try JSONDecoder().decode(CodexAccountTokenActivity.self, from: data), source)
        let text = String(decoding: data, as: UTF8.self)
        for absent in ["inputTokens", "outputTokens", "cachedInputTokens", "reasoningTokens", "sessionCount"] {
            XCTAssertFalse(text.contains(absent))
        }
    }

    func testFetchTimeAndStatisticsCutoffRemainSeparate() {
        var value = activity(days: [.init(date: "2026-10-24", tokens: 111)])
        value.serviceGeneratedAt = now.addingTimeInterval(-2)
        let result = CodexAccountTokenPresentation(reading(value), expectedScope: scopeA, relativeTo: now,
                                                   calendar: CodexAccountTokenDay.labelCalendar)
        XCTAssertEqual(result.caption, "tokens today")
        XCTAssertEqual(result.fetchedAtLabel, "Fetched 12:00 GMT")
        XCTAssertTrue(result.timingDescription.contains("Service report date 2026-10-24"))
        XCTAssertTrue(result.timingDescription.contains("Fetched 2026-10-25 12:00:00"))
        XCTAssertTrue(result.timingDescription.contains("Response generated 2026-10-25 11:59:58"))
    }

    func testCacheRetainsOriginalFetchClockRatherThanLatestAttempt() {
        let source = reading(activity(days: [.init(date: "2026-10-24", tokens: 111)]),
                             source: .cache, status: .stale, measuredAt: now.addingTimeInterval(-3_600))
        let result = CodexAccountTokenPresentation(source, expectedScope: scopeA, relativeTo: now,
                                                   calendar: CodexAccountTokenDay.labelCalendar)
        XCTAssertEqual(result.fetchedAtLabel, "Fetched 11:00 GMT")
        XCTAssertFalse(result.timingDescription.contains("Fetched 2026-10-25 12:00"))
    }

    func testPreviousDayFetchIncludesDateAndUnknownHasNoFetchLabel() {
        let source = reading(activity(days: [.init(date: "2026-10-24", tokens: 111)]),
                             source: .cache, status: .stale, measuredAt: now.addingTimeInterval(-86_400))
        let result = CodexAccountTokenPresentation(source, expectedScope: scopeA, relativeTo: now,
                                                   calendar: CodexAccountTokenDay.labelCalendar)
        XCTAssertEqual(result.fetchedAtLabel, "Fetched Oct 24 12:00 GMT")
        XCTAssertNil(CodexAccountTokenPresentation(reading(nil), expectedScope: scopeA, relativeTo: now).fetchedAtLabel)
    }

    func testLegacyActivityWithoutResponseTimestampStillDecodes() throws {
        let data = Data("""
        {"workspaceAccountIDHash":"\(scopeA)","dailyUsage":[{"date":"2026-10-24","tokens":111}],"statsAsOf":"2026-10-24"}
        """.utf8)
        let decoded = try JSONDecoder().decode(CodexAccountTokenActivity.self, from: data)
        XCTAssertNil(decoded.serviceGeneratedAt)
        XCTAssertEqual(decoded.statsAsOf, "2026-10-24")
    }

    func testFetchLabelDisambiguatesRepeatedClockDuringAutumnDSTChange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let fetchedAt = ISO8601DateFormatter().date(from: "2026-10-25T00:45:00Z")!
        let afterFallback = ISO8601DateFormatter().date(from: "2026-10-25T01:15:00Z")!
        let source = reading(activity(days: [.init(date: "2026-10-24", tokens: 111)]), measuredAt: fetchedAt)
        let result = CodexAccountTokenPresentation(source, expectedScope: scopeA, relativeTo: afterFallback, calendar: calendar)
        XCTAssertEqual(result.fetchedAtLabel, "Fetched 02:45 GMT+2")
    }

    func testClockLabelsMatchExistingLocaleFormattingAcrossTimeZonesAndCalendars() {
        for zoneID in ["GMT", "Europe/Berlin", "America/New_York", "Asia/Kolkata", "Australia/Eucla", "America/St_Johns"] {
            for identifier in [Calendar.Identifier.gregorian, .hebrew] {
                var calendar = Calendar(identifier: identifier)
                calendar.timeZone = TimeZone(identifier: zoneID)!
                for age in [3600.0, 90_000.0] {
                    let fetchedAt = now.addingTimeInterval(-age)
                    let result = CodexAccountTokenPresentation(reading(activity(days: [.init(date: "2026-10-24", tokens: 1)]),
                        measuredAt: fetchedAt), expectedScope: scopeA, relativeTo: now, calendar: calendar)
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.calendar = calendar
                    formatter.timeZone = calendar.timeZone
                    formatter.dateFormat = calendar.isDate(fetchedAt, inSameDayAs: now) ? "HH:mm zzz" : "MMM d HH:mm zzz"
                    XCTAssertEqual(result.fetchedAtLabel, "Fetched \(formatter.string(from: fetchedAt))", zoneID)
                    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
                    XCTAssertTrue(result.timingDescription.contains("Fetched \(formatter.string(from: fetchedAt))"), zoneID)
                }
            }
        }
    }

    func testSelectedModulesUseIndependentAPIValuesAndNeverLegacyFallback() throws {
        let base = UsageSnapshot.monitoringPreview
        var accounts = try XCTUnwrap(base.codexAccounts.value)
        accounts[0].workspaceAccountIDHash = scopeA
        accounts[0].tokenActivity = reading(activity(days: [.init(date: "2026-10-24", tokens: 111)]))
        accounts[1].workspaceAccountIDHash = scopeB
        accounts[1].tokenActivity = reading(activity(scope: scopeB, days: [.init(date: "2026-10-24", tokens: 222)]))
        func project(_ accounts: [CodexAccountUsage]) -> [WidgetActivityItem] {
            let snapshot = UsageSnapshot(schemaVersion: 7, generatedAt: now, codexTokens: base.codexTokens,
                cursorCosts: base.cursorCosts, cursorQuota: base.cursorQuota, codexQuota: base.codexQuota,
                claudeTokens: base.claudeTokens, claudeQuota: base.claudeQuota, deepseekUsage: base.deepseekUsage,
                codexAccounts: UsageValue(status: .ready, source: .accountAPI, measuredAt: now,
                    lastAttemptAt: now, message: nil, value: accounts))
            let composition = WidgetComposition(snapshot: snapshot, providers: [.codex], size: .extraLarge,
                referenceDate: now, selectedModuleIDs: accounts.reversed().map { "codex-workspace:\($0.id)" })
            return WidgetActivityPresentation(snapshot: snapshot, composition: composition, referenceDate: now).items
        }
        let result = project(accounts)
        XCTAssertEqual(result.map(\.value), ["222", "111"])
        XCTAssertTrue(result.allSatisfy { $0.caption == "tokens today" && $0.aggregationNote == nil })
        XCTAssertTrue(result.allSatisfy { $0.historyTimeZoneIdentifier == nil })
        accounts[1].tokenActivity = .unavailable("The account login no longer matches.")
        XCTAssertEqual(project(accounts).map(\.value), ["—", "111"])
    }
}
