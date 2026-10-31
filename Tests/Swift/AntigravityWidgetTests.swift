import Foundation
import XCTest

final class AntigravityWidgetTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!

    private func window(_ percent: Double?, label: String, seconds: Int,
                        resetAt: Date? = nil, resetDescription: String? = nil) -> CompactQuota {
        var window = CompactQuota(label: label, used: nil, limit: nil, remaining: nil,
                                  remainingPercent: percent, resetAt: resetAt, windowSeconds: seconds,
                                  detail: "Server quota")
        window.resetDescription = resetDescription
        return window
    }

    private func reading(_ groups: [AntigravityQuotaGroup], status: UsageDataStatus = .ready,
                         age: TimeInterval = 0, source: UsageDataSource = .antigravityLocal) -> UsageValue<AntigravityQuotaSnapshot> {
        UsageValue(status: status, source: source, measuredAt: now.addingTimeInterval(-age),
                   lastAttemptAt: now, message: nil,
                   value: AntigravityQuotaSnapshot(groups: groups, planName: "Google AI Ultra"))
    }

    private func snapshot(_ reading: UsageValue<AntigravityQuotaSnapshot>) -> UsageSnapshot {
        var snapshot = UsageSnapshot.preview
        snapshot.antigravityQuota = reading
        return snapshot
    }

    private func present(_ id: AntigravityQuotaGroupID, _ reading: UsageValue<AntigravityQuotaSnapshot>,
                         referenceDate: Date? = nil) -> WidgetProviderPresentation {
        WidgetProviderPresentation(antigravityGroup: id, quota: reading, referenceDate: referenceDate ?? now)
    }

    func testCatalogOffersTwoStableIndependentGroupModules() {
        let options = WidgetModuleCatalog.available(snapshot: .preview, providers: [.antigravity, .antigravity])
        XCTAssertEqual(options.map(\.id), ["antigravity-group:gemini", "antigravity-group:claude-gpt"])
        XCTAssertEqual(options.map(\.title), ["Antigravity · Gemini", "Antigravity · Claude/GPT"])
        XCTAssertTrue(options.allSatisfy { $0.workspaceID == nil && $0.provider == .antigravity })
        XCTAssertEqual(WidgetModuleCatalog.defaults(snapshot: .preview, providers: [.antigravity]), options.map(\.id))
    }

    func testSelectedGroupsPreserveUserOrderAndKeepTheirOwnQuotas() {
        let source = snapshot(reading([
            AntigravityQuotaGroup(id: .gemini, windows: [window(70, label: "Gemini Weekly", seconds: 604_800)]),
            AntigravityQuotaGroup(id: .claudeGPT, windows: [window(0, label: "Claude/GPT 5h", seconds: 18_000)])
        ]))
        let selected = ["antigravity-group:claude-gpt", "antigravity-group:gemini"]
        let model = WidgetComposition(snapshot: source, providers: [.antigravity], size: .small,
                                      referenceDate: now, selectedModuleIDs: selected)
        XCTAssertEqual(model.items.map(\.id), selected)
        XCTAssertEqual(model.items.map { $0.presentation.value }, ["0%", "70%"])
        XCTAssertEqual(model.items.map { $0.presentation.period }, ["5h", "Weekly"])
        XCTAssertEqual(model.items.map(\.workspaceName), ["Claude/GPT", "Gemini"])
        XCTAssertEqual(model.items.map(\.fullWorkspaceName), ["Antigravity · Claude/GPT", "Antigravity · Gemini"])
        XCTAssertTrue(model.items.allSatisfy { !$0.isCodexWorkspace })
        XCTAssertFalse(model.isMultiWorkspace)
    }

    func testMissingGroupOccupiesItsSelectedSlotWithoutBorrowingOtherPool() {
        let source = snapshot(reading([
            AntigravityQuotaGroup(id: .gemini, windows: [window(17, label: "Gemini Weekly", seconds: 604_800)])
        ]))
        let model = WidgetComposition(snapshot: source, providers: [.antigravity, .cursor], size: .small,
            referenceDate: now, selectedModuleIDs: ["antigravity-group:claude-gpt", "antigravity-group:gemini", "service:cursor"])
        XCTAssertEqual(model.items.map(\.id), ["antigravity-group:claude-gpt", "antigravity-group:gemini"])
        XCTAssertEqual(model.items[0].presentation.value, "—")
        XCTAssertEqual(model.items[0].presentation.status.severity, .warning)
        XCTAssertFalse(model.items[0].presentation.valueDescription.contains("17%"))
        XCTAssertEqual(model.items[1].presentation.value, "17%")
    }

    func testHiddenAntigravityGroupsStayExcludedWithoutBackfillingSlots() {
        let model = WidgetComposition(snapshot: .preview, providers: [.cursor], size: .small, referenceDate: now,
            selectedModuleIDs: ["antigravity-group:gemini", "antigravity-group:claude-gpt", "service:cursor"])
        XCTAssertTrue(model.items.isEmpty)
    }

    func testGroupShowsTightestWindowAndWeeklyWinsTies() {
        let windows = [window(20, label: "Gemini 5h", seconds: 18_000),
                       window(20, label: "Gemini Weekly", seconds: 604_800)]
        let model = present(.gemini, reading([AntigravityQuotaGroup(id: .gemini, windows: windows)]))
        XCTAssertEqual(model.value, "20%")
        XCTAssertEqual(model.period, "Weekly")
        XCTAssertEqual(model.windows.map(\.label), ["5-hour"])
        XCTAssertEqual(model.windows.map(\.percent), ["20%"])
        XCTAssertTrue(model.valueDescription.contains("Gemini"))
        XCTAssertTrue(model.valueDescription.contains("Google AI Ultra"))
    }

    func testUnknownWindowsNeverBecomeFullOrEmptyAllowance() {
        let unknown = reading([AntigravityQuotaGroup(id: .gemini, windows: [
            window(nil, label: "Gemini 5h", seconds: 18_000),
            window(.nan, label: "Gemini Weekly", seconds: 604_800)
        ])])
        let model = present(.gemini, unknown)
        XCTAssertEqual(model.value, "—")
        XCTAssertTrue(model.windows.isEmpty)
        XCTAssertEqual(model.status.severity, .warning)
        XCTAssertFalse(model.valueDescription.contains("100%"))
        XCTAssertFalse(model.valueDescription.contains("0%"))
    }

    func testResetProseIsPreservedForBothWindowsWhenDatesAreUnavailable() {
        let model = present(.gemini, reading([AntigravityQuotaGroup(id: .gemini, windows: [
            window(10, label: "Gemini 5h", seconds: 18_000, resetDescription: "Refills in about two hours"),
            window(50, label: "Gemini Weekly", seconds: 604_800, resetDescription: "Weekly refresh pending")
        ])]))
        XCTAssertEqual(model.reset, "Refills in about two hours")
        XCTAssertEqual(model.windows.first?.reset, "Weekly refresh pending")
        XCTAssertTrue(model.valueDescription.contains("Refills in about two hours"))
        XCTAssertTrue(model.valueDescription.contains("Weekly refresh pending"))
    }

    func testKnownResetDateTakesPrecedenceOverProseAndExpiresItsWindow() {
        let date = now.addingTimeInterval(600)
        let quota = reading([AntigravityQuotaGroup(id: .gemini, windows: [
            window(10, label: "Gemini 5h", seconds: 18_000, resetAt: date, resetDescription: "Old prose"),
            window(50, label: "Gemini Weekly", seconds: 604_800, resetAt: now.addingTimeInterval(86_400))
        ])])
        XCTAssertEqual(present(.gemini, quota).reset, "Resets in 10m")
        XCTAssertFalse(present(.gemini, quota).valueDescription.contains("Old prose"))
        let afterReset = present(.gemini, quota, referenceDate: date)
        XCTAssertEqual(afterReset.period, "Weekly")
        XCTAssertEqual(afterReset.value, "50%")
        XCTAssertTrue(afterReset.windows.isEmpty)
    }

    func testQuotaCacheExpiresFromMeasurementRatherThanLatestAttempt() {
        let quota = reading([AntigravityQuotaGroup(id: .claudeGPT, windows: [
            window(0, label: "Claude/GPT Weekly", seconds: 604_800)
        ])], status: .stale, age: 1_799, source: .cache)
        XCTAssertEqual(present(.claudeGPT, quota).value, "0%")
        XCTAssertEqual(present(.claudeGPT, quota).status.severity, .warning)
        let expired = present(.claudeGPT, quota, referenceDate: now.addingTimeInterval(1))
        XCTAssertEqual(expired.value, "—")
        XCTAssertTrue(expired.windows.isEmpty)
    }

    func testAuthenticationFailureCannotExposeCachedAllowance() {
        let quota = reading([AntigravityQuotaGroup(id: .gemini, windows: [
            window(80, label: "Gemini Weekly", seconds: 604_800)
        ])], status: .unauthenticated, source: .cache)
        let model = present(.gemini, quota)
        XCTAssertEqual(model.value, "—")
        XCTAssertTrue(model.windows.isEmpty)
        XCTAssertTrue(model.status.detail.contains("Sign in"))
        XCTAssertFalse(model.valueDescription.contains("80%"))
    }

    func testLocalTokenErrorsCannotPolluteQuotaOrGenerateWidgetActivity() {
        var source = snapshot(reading([AntigravityQuotaGroup(id: .gemini, windows: [
            window(60, label: "Gemini Weekly", seconds: 604_800)
        ])]))
        source.antigravityTokens = UsageValue(status: .error, source: .codexBarLocal,
            measuredAt: now, lastAttemptAt: now, message: "private local token marker", value: nil)
        let composition = WidgetComposition(snapshot: source, providers: [.antigravity], size: .large,
            referenceDate: now, selectedModuleIDs: ["antigravity-group:gemini", "antigravity-group:claude-gpt"])
        XCTAssertEqual(composition.items.first?.presentation.status.severity, .normal)
        XCTAssertFalse(composition.items[0].presentation.valueDescription.contains("private local token marker"))
        XCTAssertTrue(WidgetActivityPresentation(snapshot: source, composition: composition, referenceDate: now).items.isEmpty)
        XCTAssertTrue(WidgetActivityPresentation(snapshot: source, providers: [.antigravity], referenceDate: now).items.isEmpty)
        XCTAssertFalse(composition.items[0].presentation.valueDescription.contains("Today"))
    }
}
