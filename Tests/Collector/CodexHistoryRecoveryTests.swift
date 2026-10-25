import Foundation
import XCTest

final class CodexHistoryRecoveryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private let now = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!

    private struct Fixture {
        let root: URL
        let home: URL
        let session: URL
        let legacy: URL

        var environment: [String: String] { ["CODEX_LEGACY_TOKEN_FIXTURE": legacy.path] }
        var configuration: CodexAccountConfiguration { .init(homes: [home.path], message: nil) }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beavermeter-codex-history-recovery-\(UUID())", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let session = home.appendingPathComponent("sessions/synthetic-session.jsonl")
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: session)
        let legacy = root.appendingPathComponent("zero-legacy.json")
        try JSONEncoder().encode(CodexTokenTotals.zero).write(to: legacy)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Fixture(root: root, home: home, session: session, legacy: legacy)
    }

    private func record(_ id: String, date: String = "2026-10-01T10:00:00Z", input: Int, output: Int = 2) throws -> String {
        let object: [String: Any] = [
            "type": "token_usage_record", "timestamp": date,
            "payload": [
                "response_id": id, "session_id": "synthetic-session",
                "usage": ["input_tokens": input, "cached_input_tokens": min(input, 3),
                          "output_tokens": output, "reasoning_output_tokens": min(output, 1)],
            ],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
    }

    /// Preserve the file identity while replacing its bytes so the real scanner
    /// recognizes truncation and rebuilds this synthetic rollout's cached records.
    private func replaceSession(_ contents: String, at file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(contents.utf8))
    }

    private func collect(
        _ fixture: Fixture,
        previous: UsageValue<TokenHistory<CodexTokenTotals>> = .unavailable("No previous history"),
        configuration: CodexAccountConfiguration? = nil,
        now: Date? = nil,
        calendar: Calendar? = nil
    ) async -> TokenHistoryCollector.CodexReading {
        await TokenHistoryCollector.codex(
            previous: previous, configuration: configuration ?? fixture.configuration,
            now: now ?? self.now, directory: fixture.root,
            environment: fixture.environment, calendar: calendar ?? self.calendar
        )
    }

    func testCompleteRescanAcceptsLowerTotalsAndClearsThePreviousWarning() async throws {
        let fixture = try fixture()
        try replaceSession(record("response", input: 900_000), at: fixture.session)
        let initial = await collect(fixture, configuration: .init(homes: [fixture.home.path], message: "Configuration recovery is pending."))
        XCTAssertEqual(initial.history.status, .stale)
        XCTAssertEqual(initial.history.value?.totals.totalTokens, 900_002)
        XCTAssertNotNil(initial.history.message)

        try replaceSession(record("response", input: 10), at: fixture.session)
        let recovered = await collect(fixture, previous: initial.history)

        XCTAssertEqual(recovered.history.status, .ready)
        XCTAssertNil(recovered.history.message)
        XCTAssertEqual(recovered.history.value?.sourceID, initial.history.value?.sourceID)
        XCTAssertEqual(recovered.history.value?.totals.totalTokens, 12)
        XCTAssertEqual(recovered.history.value?.days.last?.totals.totalTokens, 12)
        XCTAssertEqual(recovered.history.value?.days.count, 7)
    }

    func testCompleteEmptyRescanReplacesHighCachedUsageWithZero() async throws {
        let fixture = try fixture()
        try replaceSession(record("response", input: 900_000), at: fixture.session)
        let initial = await collect(fixture, configuration: .init(homes: [fixture.home.path], message: "Configuration recovery is pending."))
        XCTAssertEqual(initial.history.value?.totals.totalTokens, 900_002)
        XCTAssertEqual(initial.history.status, .stale)

        try replaceSession("", at: fixture.session)
        let recovered = await collect(fixture, previous: initial.history)

        XCTAssertEqual(recovered.history.status, .ready)
        XCTAssertNil(recovered.history.message)
        XCTAssertEqual(recovered.history.value?.totals, .zero)
        XCTAssertEqual(recovered.history.value?.days.map(\.totals), Array(repeating: .zero, count: 7))
    }

    func testIncompleteConfigurationRetainsHigherSameSourceDailyUsage() async throws {
        let fixture = try fixture()
        try replaceSession(record("response", input: 900_000), at: fixture.session)
        let initial = await collect(fixture)
        XCTAssertEqual(initial.history.status, .ready)

        try replaceSession(record("response", input: 10), at: fixture.session)
        let partial = await collect(fixture, previous: initial.history,
                                    configuration: .init(homes: [fixture.home.path], message: "Configuration is incomplete."))

        XCTAssertEqual(partial.history.status, .stale)
        XCTAssertEqual(partial.history.value?.sourceID, initial.history.value?.sourceID)
        XCTAssertEqual(partial.history.value?.totals.totalTokens, 900_002)
        XCTAssertEqual(partial.history.value?.days.last?.totals.totalTokens, 900_002)
        XCTAssertTrue(partial.history.message?.contains("retains the last same-source daily reading") == true)
    }

    func testMissingConfiguredHomeRetainsTheSameSourcesHigherCache() async throws {
        let fixture = try fixture()
        let secondHome = fixture.root.appendingPathComponent("second-home", isDirectory: true)
        try FileManager.default.createDirectory(at: secondHome, withIntermediateDirectories: true)
        let configuration = CodexAccountConfiguration(homes: [fixture.home.path, secondHome.path], message: nil)
        try replaceSession(record("response", input: 900_000), at: fixture.session)
        let initial = await collect(fixture, configuration: configuration)
        XCTAssertEqual(initial.history.status, .ready)
        XCTAssertEqual(initial.history.value?.totals.totalTokens, 900_002)

        try FileManager.default.removeItem(at: secondHome)
        try replaceSession(record("response", input: 10), at: fixture.session)
        let partial = await collect(fixture, previous: initial.history, configuration: configuration)

        XCTAssertEqual(partial.history.status, .stale)
        XCTAssertEqual(partial.history.value?.sourceID, initial.history.value?.sourceID)
        XCTAssertEqual(partial.history.value?.totals.totalTokens, 900_002)
        XCTAssertTrue(partial.history.message?.contains("configured Codex log directory is unavailable") == true)
        XCTAssertTrue(partial.history.message?.contains("retains the last same-source daily reading") == true)
    }

    func testChangedSourceDoesNotBorrowHighCacheDuringAnIncompleteRefresh() async throws {
        let fixture = try fixture()
        try replaceSession(record("response", input: 900_000), at: fixture.session)
        let initial = await collect(fixture)
        XCTAssertEqual(initial.history.value?.totals.totalTokens, 900_002)
        let otherHome = fixture.root.appendingPathComponent("other-home", isDirectory: true)
        let otherFile = otherHome.appendingPathComponent("sessions/other.jsonl")
        try FileManager.default.createDirectory(at: otherFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try record("other-response", input: 10).write(to: otherFile, atomically: true, encoding: .utf8)

        let changed = await collect(fixture, previous: initial.history,
                                    configuration: .init(homes: [otherHome.path, fixture.root.appendingPathComponent("missing-home").path],
                                                         message: nil))

        XCTAssertEqual(changed.history.status, .stale)
        XCTAssertNotEqual(changed.history.value?.sourceID, initial.history.value?.sourceID)
        XCTAssertEqual(changed.history.value?.totals.totalTokens, 12)
        XCTAssertTrue(changed.history.message?.contains("configured Codex log directory is unavailable") == true)
        XCTAssertFalse(changed.history.message?.contains("retains the last same-source daily reading") == true)
    }

    func testChangedTimeZoneDoesNotBorrowHighCacheEvenWhenLocalDayBoundariesMatch() async throws {
        let fixture = try fixture()
        let secondHome = fixture.root.appendingPathComponent("second-home", isDirectory: true)
        try FileManager.default.createDirectory(at: secondHome, withIntermediateDirectories: true)
        let configuration = CodexAccountConfiguration(homes: [fixture.home.path, secondHome.path], message: nil)
        try replaceSession(record("response", input: 900_000), at: fixture.session)
        let initial = await collect(fixture, configuration: configuration)
        var changedCalendar = calendar
        changedCalendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        XCTAssertEqual(changedCalendar.startOfDay(for: now), calendar.startOfDay(for: now))
        try FileManager.default.removeItem(at: secondHome)
        try replaceSession(record("response", input: 10), at: fixture.session)

        let changed = await collect(fixture, previous: initial.history,
                                    configuration: configuration,
                                    calendar: changedCalendar)

        XCTAssertEqual(changed.history.status, .stale)
        XCTAssertEqual(changed.history.value?.sourceID, initial.history.value?.sourceID)
        XCTAssertEqual(changed.history.value?.timeZoneIdentifier, "Europe/Paris")
        XCTAssertEqual(changed.history.value?.totals.totalTokens, 12)
        XCTAssertTrue(changed.history.message?.contains("configured Codex log directory is unavailable") == true)
        XCTAssertFalse(changed.history.message?.contains("retains the last same-source daily reading") == true)
    }

    func testLocalMidnightRetainsOnlyTheMatchingDayAndKeepsSevenCalendarDates() async throws {
        let fixture = try fixture()
        let secondHome = fixture.root.appendingPathComponent("second-home", isDirectory: true)
        try FileManager.default.createDirectory(at: secondHome, withIntermediateDirectories: true)
        let configuration = CodexAccountConfiguration(homes: [fixture.home.path, secondHome.path], message: nil)
        let beforeMidnight = ISO8601DateFormatter().date(from: "2026-10-01T21:59:00Z")!
        let afterMidnight = ISO8601DateFormatter().date(from: "2026-10-01T22:01:00Z")!
        try replaceSession(record("yesterday", date: "2026-10-01T21:58:00Z", input: 900_000)
                           + String(repeating: " ", count: 1_024) + "\n", at: fixture.session)
        let initial = await collect(fixture, configuration: configuration, now: beforeMidnight)
        XCTAssertEqual(initial.history.status, .ready)
        XCTAssertEqual(initial.history.value?.days.last?.totals.totalTokens, 900_002)
        try FileManager.default.removeItem(at: secondHome)
        try replaceSession(record("yesterday", date: "2026-10-01T21:58:00Z", input: 10)
                           + record("today", date: "2026-10-01T22:00:30Z", input: 20), at: fixture.session)

        let rolled = await collect(fixture, previous: initial.history,
                                   configuration: configuration,
                                   now: afterMidnight)
        let history = try XCTUnwrap(rolled.history.value)

        XCTAssertEqual(rolled.history.status, .stale)
        XCTAssertEqual(history.days.map { TokenHistoryCollector.dateKey($0.date, calendar: calendar) },
                       ["2026-09-26", "2026-09-27", "2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02"])
        XCTAssertEqual(history.days[5].totals.totalTokens, 900_002)
        XCTAssertEqual(history.days[6].totals.totalTokens, 22)
        XCTAssertEqual(history.totals.totalTokens, 900_024)
        XCTAssertTrue(rolled.history.message?.contains("retains the last same-source daily reading") == true)
    }
    func testDailyAggregationMatchesExistingCountersAcrossDSTAndDistinctSessions() throws {
        let reference = ISO8601DateFormatter().date(from: "2026-10-26T12:00:00Z")!
        let days = try TokenHistoryCollector.dates(now: reference, calendar: calendar)
        var records: [String: CodexResponseUsage] = [:]
        for (index, day) in days.enumerated() {
            for offset in 0..<3 {
                let date = calendar.date(byAdding: .hour, value: 2 + offset, to: day)!
                records["\(index)-\(offset)"] = CodexResponseUsage(inputTokens: 10 + offset,
                    cachedInputTokens: offset, outputTokens: 2, reasoningTokens: 1,
                    sessionHash: offset == 2 ? "another-session" : "same-session", timestamp: date)
            }
        }
        records["undated"] = CodexResponseUsage(inputTokens: 90_000, cachedInputTokens: 0,
            outputTokens: 0, reasoningTokens: 0, sessionHash: "undated")
        records["outside-window"] = CodexResponseUsage(inputTokens: 80_000, cachedInputTokens: 0,
            outputTokens: 0, reasoningTokens: 0, sessionHash: "old", timestamp: days[0].addingTimeInterval(-1))
        let actual = try TokenHistoryCollector.dailyTotals(records, days: days, calendar: calendar)
        for (index, day) in days.enumerated() {
            let matches = records.filter { $0.value.timestamp.map { calendar.isDate($0, inSameDayAs: day) } == true }
            let expected = try CodexUsageRecordScanner.totals(for: matches, sessionHashes: Set(matches.values.map(\.sessionHash)))
            XCTAssertEqual(actual[index], expected)
            XCTAssertEqual(actual[index].sessionCount, 2)
        }
        XCTAssertEqual(days[6].timeIntervalSince(days[5]), 25 * 3600, "Calendar days must retain the DST fallback day")
    }

    func testDailyAggregationRejectsCounterOverflow() throws {
        let records = [
            "large": CodexResponseUsage(inputTokens: Int.max, cachedInputTokens: 0, outputTokens: 0,
                reasoningTokens: 0, sessionHash: "one", timestamp: now),
            "overflow": CodexResponseUsage(inputTokens: 1, cachedInputTokens: 0, outputTokens: 0,
                reasoningTokens: 0, sessionHash: "two", timestamp: now),
        ]
        XCTAssertThrowsError(try TokenHistoryCollector.dailyTotals(records,
            days: TokenHistoryCollector.dates(now: now, calendar: calendar), calendar: calendar))
    }

    func testGlobalHistorySharesSmallUnknownScopeSummaryAndKeepsModernCompletenessIndependent() async throws {
        let fixture = try fixture()
        try replaceSession(record("response", input: 100), at: fixture.session)
        let reading = await collect(fixture)
        let summary = try XCTUnwrap(reading.workspaceSummary)
        XCTAssertEqual((summary.modernTotals.last ?? nil)?.totalTokens, 102)
        XCTAssertTrue(summary.scopedTotals.isEmpty)
        XCTAssertTrue(summary.hasUnattributedRecords)
        XCTAssertEqual(summary.unattributedDays, [6])
        XCTAssertTrue(summary.complete)

        // Legacy coverage is global-only; it must not masquerade as a failed modern
        // scan and make an old workspace attribution eligible for cached fallback.
        try Data("invalid-synthetic-legacy-fixture".utf8).write(to: fixture.legacy)
        let partial = await collect(fixture, previous: reading.history)
        XCTAssertEqual(partial.history.status, .stale)
        XCTAssertTrue(try XCTUnwrap(partial.workspaceSummary).complete)
        XCTAssertEqual(partial.history.value?.totals.totalTokens, reading.history.value?.totals.totalTokens)
    }
}
