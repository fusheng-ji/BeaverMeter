import Foundation
import XCTest

final class CodexWorkspaceActivityModelTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-26T12:00:00Z")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return value
    }

    private func totals(_ count: Int) -> CodexTokenTotals {
        CodexTokenTotals(totalTokens: count, inputTokens: count, cachedInputTokens: 0,
                         outputTokens: 0, reasoningTokens: 0, sessionCount: count == 0 ? 0 : 1)
    }

    private func reading<T>(_ value: T, status: UsageDataStatus = .ready) -> UsageValue<T> {
        UsageValue(status: status, source: status == .stale ? .cache : .codexBarLocal,
                   measuredAt: now, lastAttemptAt: now, message: status == .stale ? "Workspace reading retained." : nil,
                   value: value)
    }

    private func history(_ count: Int, sourceID: String) -> TokenHistory<CodexTokenTotals> {
        TokenHistory(sourceID: sourceID, timeZoneIdentifier: calendar.timeZone.identifier,
                     days: [TokenHistoryDay(date: calendar.startOfDay(for: now), totals: totals(count))],
                     totals: totals(count))
    }

    private func account(_ id: String, count: Int? = nil, historyCount: Int? = nil,
                         tokenStatus: UsageDataStatus = .ready, historyStatus: UsageDataStatus = .ready) -> CodexAccountUsage {
        CodexAccountUsage(id: id, homeID: "same-source-home", displayName: "Workspace \(id)",
            quota: .unavailable("Quota-only failure must not affect activity."), resetCards: .unavailable("No inventory"),
            workspaceName: "Workspace \(id)", workspaceAccountIDHash: "synthetic-hash-\(id)",
            tokens: count.map { reading(totals($0), status: tokenStatus) },
            history: historyCount.map { reading(history($0, sourceID: "workspace-\(id)"), status: historyStatus) })
    }

    private func snapshot(_ accounts: [CodexAccountUsage]) -> UsageSnapshot {
        let base = UsageSnapshot.preview
        return UsageSnapshot(schemaVersion: 7, generatedAt: now,
            codexTokens: reading(totals(9_999_999)), cursorCosts: base.cursorCosts, cursorQuota: base.cursorQuota,
            codexQuota: base.codexQuota, claudeTokens: base.claudeTokens, claudeQuota: base.claudeQuota,
            deepseekUsage: base.deepseekUsage, codexAccounts: reading(accounts),
            codexHistory: reading(history(8_888_888, sourceID: "all-sources")))
    }

    private func activity(_ snapshot: UsageSnapshot, selected: [String],
                          providers: [MeterProvider] = [.codex]) -> [WidgetActivityItem] {
        let composition = WidgetComposition(snapshot: snapshot, providers: providers, size: .extraLarge,
                                            referenceDate: now, calendar: calendar, selectedModuleIDs: selected)
        return WidgetActivityPresentation(snapshot: snapshot, composition: composition,
                                           referenceDate: now, calendar: calendar).items
    }

    func testLegacySchemaSevenAccountsDecodeMissingActivityAsUnknown() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(UsageSnapshot.monitoringPreview)) as? [String: Any])
        var accounts = try XCTUnwrap(object["codexAccounts"] as? [String: Any])
        var values = try XCTUnwrap(accounts["value"] as? [[String: Any]])
        for index in values.indices {
            for field in ["workspaceAccountIDHash", "tokens", "history"] { values[index][field] = nil }
        }
        accounts["value"] = values
        object["codexAccounts"] = accounts
        let decoded = try XCTUnwrap(UsageSnapshot.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(decoded.schemaVersion, 7)
        XCTAssertEqual(decoded.codexTokens.value?.totalTokens, 100_000)
        for account in try XCTUnwrap(decoded.codexAccounts.value) {
            XCTAssertNil(account.workspaceAccountIDHash)
            XCTAssertNil(account.tokens)
            XCTAssertNil(account.history)
            let result = try XCTUnwrap(activity(decoded, selected: ["codex-workspace:\(account.id)"]).first)
            XCTAssertEqual(result.value, "—")
            XCTAssertTrue(result.history!.allSatisfy { $0.value == nil })
        }
    }

    func testWorkspaceActivityFieldsRoundTripAndPreviewValuesAreIndependent() throws {
        let source = UsageSnapshot.monitoringPreview
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(source)
        let decoded = try XCTUnwrap(UsageSnapshot.decode(data))
        let accounts = try XCTUnwrap(decoded.codexAccounts.value)
        for (actual, expected) in zip(accounts, try XCTUnwrap(source.codexAccounts.value)) {
            XCTAssertEqual(actual.id, expected.id)
            XCTAssertEqual(actual.workspaceAccountIDHash, expected.workspaceAccountIDHash)
            XCTAssertEqual(actual.tokens, expected.tokens)
            XCTAssertEqual(actual.history, expected.history)
        }
        XCTAssertEqual(accounts.map { $0.tokens?.value?.totalTokens }, [48_200, 17_650])
        XCTAssertEqual(accounts.map { $0.history?.value?.days.last?.totals.totalTokens }, [48_200, 17_650])
        XCTAssertNotEqual(accounts[0].workspaceAccountIDHash, accounts[1].workspaceAccountIDHash)
        XCTAssertNotEqual(accounts[0].history?.value?.sourceID, accounts[1].history?.value?.sourceID)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("access_token"))
        XCTAssertFalse(text.contains("refresh_token"))
    }

    func testSelectedWorkspacesKeepDistinctDailyUsageHistoryAndModuleIdentity() {
        let source = snapshot([account("a", count: 111, historyCount: 11), account("b", count: 222, historyCount: 22)])
        let result = activity(source, selected: ["codex-workspace:b", "codex-workspace:a"])
        XCTAssertEqual(result.map(\.id), ["codex-workspace:b", "codex-workspace:a"])
        XCTAssertEqual(result.map(\.moduleID), ["codex-workspace:b", "codex-workspace:a"])
        XCTAssertEqual(result.map(\.value), ["222", "111"])
        XCTAssertEqual(result.map { $0.history?.last?.value }, [22, 11])
        XCTAssertTrue(result.allSatisfy { $0.aggregationNote == nil })
        XCTAssertTrue(result[0].accessibilityText.contains("Workspace b"))
        XCTAssertFalse(result[0].accessibilityText.contains("Workspace a"))
        XCTAssertFalse(result[0].accessibilityText.contains("All workspaces"))
        XCTAssertFalse(result[0].accessibilityText.contains("9,999,999"))
    }

    func testSingleLegacyWorkspaceNeverBorrowsProviderTotalsOrHistory() throws {
        let source = snapshot([account("a")])
        let result = try XCTUnwrap(activity(source, selected: ["codex-workspace:a"]).first)
        XCTAssertEqual(result.value, "—")
        XCTAssertNotEqual(result.status.severity, .normal)
        XCTAssertTrue(result.history!.allSatisfy { $0.value == nil })
        XCTAssertNil(result.aggregationNote)
    }

    func testMissingWorkspaceAndLegacyServiceNeverBorrowSiblingActivity() throws {
        let source = snapshot([account("a", count: 111, historyCount: 11)])
        for selection in ["codex-workspace:removed", "service:codex"] {
            let result = try XCTUnwrap(activity(source, selected: [selection]).first)
            XCTAssertEqual(result.id, selection)
            XCTAssertEqual(result.value, "—")
            XCTAssertTrue(result.history!.allSatisfy { $0.value == nil })
            XCTAssertNil(result.aggregationNote)
        }
        let noAccounts = try XCTUnwrap(activity(snapshot([]), selected: ["service:codex"]).first)
        XCTAssertEqual(noAccounts.value, "—")
        XCTAssertTrue(noAccounts.history!.allSatisfy { $0.value == nil })
    }

    func testKnownWorkspaceZeroAndUnknownRemainDistinct() {
        let source = snapshot([account("zero", count: 0, historyCount: 0), account("unknown")])
        let result = activity(source, selected: ["codex-workspace:zero", "codex-workspace:unknown"])
        XCTAssertEqual(result[0].value, "0")
        XCTAssertEqual(result[0].status.severity, .normal)
        XCTAssertEqual(result[0].history?.last?.value, 0)
        XCTAssertEqual(result[1].value, "—")
        XCTAssertNotEqual(result[1].status.severity, .normal)
        XCTAssertTrue(result[1].history!.allSatisfy { $0.value == nil })
    }

    func testWorkspaceCurrentAndHistoryStatusesRemainIndependent() {
        let source = snapshot([
            account("a", count: 111, historyCount: 11, tokenStatus: .stale),
            account("b", count: 222, historyCount: 22, historyStatus: .stale)
        ])
        let result = activity(source, selected: ["codex-workspace:a", "codex-workspace:b"])
        XCTAssertEqual(result[0].status.severity, .warning)
        XCTAssertEqual(result[0].historyStatus?.severity, .normal)
        XCTAssertEqual(result[1].status.severity, .normal)
        XCTAssertEqual(result[1].historyStatus?.severity, .warning)
        XCTAssertFalse(result[1].accessibilityText.contains("Quota-only"))
        XCTAssertFalse(result[1].accessibilityText.contains("history"))
    }

    func testSourceReorderingDoesNotMoveActivityBetweenSelectedWorkspaces() {
        let a = account("a", count: 111, historyCount: 11)
        let b = account("b", count: 222, historyCount: 22)
        let selection = ["codex-workspace:a", "codex-workspace:b"]
        let before = activity(snapshot([a, b]), selected: selection)
        let after = activity(snapshot([b, a]), selected: selection)
        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertEqual(before.map(\.value), after.map(\.value))
        XCTAssertEqual(before.map { $0.history?.last?.value }, after.map { $0.history?.last?.value })
    }

    func testOtherProvidersRetainOwnSourcesWithStableModuleIDs() {
        let source = snapshot([])
        let providers: [MeterProvider] = [.cursor, .claude, .deepseek]
        let result = activity(source, selected: providers.map { "service:\($0.rawValue)" }, providers: providers)
        let legacy = WidgetActivityPresentation(snapshot: source, providers: providers, referenceDate: now, calendar: calendar)
        XCTAssertEqual(result.map(\.id), ["service:cursor", "service:claude", "service:deepseek"])
        XCTAssertEqual(result.map(\.provider), providers)
        XCTAssertEqual(result.map(\.value), legacy.items.map(\.value))
    }
}
