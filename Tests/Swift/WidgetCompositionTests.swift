import Foundation
import XCTest

final class WidgetCompositionTests: XCTestCase {
    private let now = UsageSnapshot.previewDate
    private func reading<T: Codable & Hashable & Sendable>(_ value: T?, status: UsageDataStatus = .ready) -> UsageValue<T> {
        UsageValue(status: status, source: .accountAPI, measuredAt: now, lastAttemptAt: now, message: nil, value: value)
    }
    private func account(_ id: String, name: String? = nil, percent: Double = 50,
                         secondary: Double? = nil, plan: String? = "Pro", status: UsageDataStatus = .ready,
                         hasQuota: Bool = true) -> CodexAccountUsage {
        var quota = CompactQuota(planName: nil, label: "Codex 5h", used: nil, limit: nil, remaining: nil,
                                 remainingPercent: percent, resetAt: now.addingTimeInterval(3_600),
                                 windowSeconds: 18_000, detail: "Own quota")
        if let secondary {
            quota.windows = [quota, CompactQuota(label: "Codex Week", used: nil, limit: nil, remaining: nil,
                remainingPercent: secondary, resetAt: now.addingTimeInterval(86_400), windowSeconds: 604_800, detail: "Own week")]
        }
        return CodexAccountUsage(id: id, homeID: "home-\(id)", displayName: "\(id) display",
            quota: reading(hasQuota ? quota : nil, status: status), resetCards: .unavailable("Hidden inventory"),
            workspaceName: name ?? "Workspace \(id)", accountName: "\(id)@example.test", planName: plan)
    }
    private func snapshot(_ accounts: [CodexAccountUsage]) -> UsageSnapshot {
        let base = UsageSnapshot.preview
        let ambient = CompactQuota(planName: "Ambient", label: "Codex 5h", used: nil, limit: nil, remaining: nil,
            remainingPercent: 99, resetAt: now.addingTimeInterval(600), windowSeconds: 18_000, detail: "Ambient quota")
        return UsageSnapshot(schemaVersion: UsageSnapshot.currentSchemaVersion, generatedAt: now,
            codexTokens: base.codexTokens, cursorCosts: base.cursorCosts, cursorQuota: base.cursorQuota,
            codexQuota: reading(ambient), claudeTokens: base.claudeTokens, claudeQuota: base.claudeQuota,
            deepseekUsage: base.deepseekUsage, codexAccounts: reading(accounts))
    }
    private func composition(_ accounts: [CodexAccountUsage], providers: [MeterProvider] = MeterProvider.allCases,
                             size: ProviderWidgetSize = .large, selected: [String]? = nil) -> WidgetComposition {
        WidgetComposition(snapshot: snapshot(accounts), providers: providers, size: size,
                          referenceDate: now, selectedModuleIDs: selected)
    }

    func testFamilyCapsAreTwoFourSixSixAndRowsClampExcessInput() {
        XCTAssertEqual(ProviderWidgetSize.allCases.map(WidgetComposition.capacity), [2, 4, 6, 6])
        for size in ProviderWidgetSize.allCases {
            XCTAssertTrue(WidgetComposition.rows(cardCount: -1, size: size).isEmpty)
            for count in 0...20 {
                let rows = WidgetComposition.rows(cardCount: count, size: size)
                XCTAssertEqual(rows.flatMap { $0 }, Array(0..<min(count, WidgetComposition.capacity(for: size))))
            }
        }
    }

    func testApprovedFamilyArrangements() {
        XCTAssertEqual(WidgetComposition.rows(cardCount: 2, size: .small), [[0], [1]])
        XCTAssertEqual(WidgetComposition.rows(cardCount: 3, size: .medium), [[0, 1, 2]])
        XCTAssertEqual(WidgetComposition.rows(cardCount: 4, size: .medium), [[0, 1], [2, 3]])
        XCTAssertEqual(WidgetComposition.rows(cardCount: 4, size: .large), [[0], [1], [2], [3]])
        XCTAssertEqual(WidgetComposition.rows(cardCount: 6, size: .large), [[0, 1], [2, 3], [4, 5]])
        XCTAssertEqual(WidgetComposition.rows(cardCount: 3, size: .extraLarge), [[0, 1, 2]])
        XCTAssertEqual(WidgetComposition.rows(cardCount: 4, size: .extraLarge), [[0, 1], [2, 3]])
        XCTAssertEqual(WidgetComposition.rows(cardCount: 6, size: .extraLarge), [[0, 1, 2], [3, 4, 5]])
    }

    func testDefaultSelectionKeepsOtherServicesBeforeExtraWorkspaces() {
        let accounts = (1...20).map { account("\($0)") }
        let expected = ["codex-workspace:1", "service:claude", "service:cursor", "service:deepseek",
                        "codex-workspace:2", "codex-workspace:3"]
        for size in ProviderWidgetSize.allCases {
            let model = composition(accounts, size: size)
            XCTAssertEqual(model.items.map(\.id), Array(expected.prefix(WidgetComposition.capacity(for: size))))
            XCTAssertLessThanOrEqual(model.items.count, 6)
            XCTAssertEqual(model.overflowWorkspaceCount, 0)
        }
    }

    func testSelectedSlotsPreserveUserOrderAndDoNotExpandCodex() {
        let model = composition([account("a"), account("b"), account("c")],
            selected: ["service:cursor", "codex-workspace:c", "service:claude"])
        XCTAssertEqual(model.items.map(\.id), ["service:cursor", "codex-workspace:c", "service:claude"])
        XCTAssertEqual(model.items.filter(\.isCodexWorkspace).count, 1)
        XCTAssertFalse(model.isMultiWorkspace)
    }

    func testExplicitEmptyAndNoneSlotsDoNotFallBackToDefaults() {
        let accounts = [account("a"), account("b")]
        XCTAssertFalse(composition(accounts).items.isEmpty)
        XCTAssertTrue(composition(accounts, selected: []).items.isEmpty)
        XCTAssertTrue(composition(accounts, selected: [WidgetModuleCatalog.noneID, WidgetModuleCatalog.noneID]).items.isEmpty)
        XCTAssertEqual(composition(accounts, selected: ["none", "service:claude", "none"]).items.map(\.id), ["service:claude"])
    }

    func testInvalidHiddenAndDuplicateSlotsDoNotBackfillFamilySlots() {
        let model = composition([account("a"), account("b")], providers: [.codex, .cursor], size: .small,
            selected: ["service:unknown", "service:claude", "none", "codex-workspace:",
                       "codex-workspace:a", "codex-workspace:a", "service:cursor", "codex-workspace:b"])
        XCTAssertTrue(model.items.isEmpty)
    }

    func testNoneAndDuplicateSlotsDoNotPullLaterSlotsIntoSmallFamily() {
        let accounts = [account("personal")]
        let emptyFirst = composition(accounts, size: .small,
            selected: ["none", "codex-workspace:personal", "service:claude"])
        XCTAssertEqual(emptyFirst.items.map(\.id), ["codex-workspace:personal"])
        let repeatedFirst = composition(accounts, size: .small,
            selected: ["codex-workspace:personal", "codex-workspace:personal", "service:claude"])
        XCTAssertEqual(repeatedFirst.items.map(\.id), ["codex-workspace:personal"])
        let hiddenFirst = composition(accounts, providers: [.codex, .claude], size: .small,
            selected: ["service:cursor", "codex-workspace:personal", "service:claude"])
        XCTAssertEqual(hiddenFirst.items.map(\.id), ["codex-workspace:personal"])
    }

    func testSelectedWorkspaceIdSurvivesOneToManyWorkspaceTransition() {
        let one = composition([account("a")], providers: [.codex])
        let many = composition([account("a"), account("b")], providers: [.codex], selected: one.items.map(\.id))
        XCTAssertEqual(one.items.map(\.id), ["codex-workspace:a"])
        XCTAssertEqual(many.items.map(\.id), one.items.map(\.id))
        XCTAssertEqual(many.items[0].presentation.value, "50%")
    }

    func testMissingSelectedWorkspaceRemainsUnavailableAndOccupiesItsSlot() {
        let model = composition([account("sibling-identity-marker", percent: 91, plan: "SiblingPlanUnique")], size: .small,
            selected: ["codex-workspace:deleted", "service:claude", "service:cursor"])
        XCTAssertEqual(model.items.map(\.id), ["codex-workspace:deleted", "service:claude"])
        let missing = model.items[0]
        XCTAssertEqual(missing.workspaceName, "Unavailable")
        XCTAssertEqual(missing.presentation.value, "—")
        XCTAssertNil(missing.presentation.planName)
        XCTAssertTrue(missing.presentation.windows.isEmpty)
        XCTAssertEqual(missing.presentation.status.severity, .warning)
        XCTAssertFalse(missing.presentation.valueDescription.contains("Ambient"))
        XCTAssertFalse(missing.presentation.valueDescription.contains("sibling-identity-marker"))
        XCTAssertFalse(missing.presentation.valueDescription.contains("SiblingPlanUnique"))
        XCTAssertFalse(missing.presentation.valueDescription.contains("91%"))
        XCTAssertFalse(missing.presentation.valueDescription.contains("99%"))
    }

    func testMissingWorkspaceReturnsToSameSelectionWhenItsRecordReturns() {
        let selected = ["codex-workspace:restored"]
        let missing = composition([], selected: selected)
        let restored = composition([account("restored", percent: 17, plan: "Business")], selected: selected)
        XCTAssertEqual(missing.items.map(\.id), restored.items.map(\.id))
        XCTAssertEqual(restored.items[0].presentation.value, "17%")
        XCTAssertEqual(restored.items[0].presentation.planName, "Business")
    }

    func testExplicitFailedWorkspaceCannotBorrowAmbientOrSiblingQuotaAndPlan() {
        let accounts = [account("failed", plan: nil, status: .error, hasQuota: false),
                        account("healthy", percent: 91, plan: "Sibling")]
        let model = composition(accounts, selected: ["codex-workspace:failed"])
        XCTAssertEqual(model.items[0].presentation.value, "—")
        XCTAssertNil(model.items[0].presentation.planName)
        XCTAssertEqual(model.items[0].presentation.status.severity, .critical)
        XCTAssertFalse(model.items[0].presentation.valueDescription.contains("Ambient"))
        XCTAssertFalse(model.items[0].presentation.valueDescription.contains("Sibling"))
    }

    func testEachWorkspaceKeepsIndependentWindowPlanAndStatus() {
        let model = composition([account("a", percent: 0, secondary: 30, plan: "Pro", status: .stale),
                                 account("b", percent: 70, secondary: 90, plan: "Business")],
            selected: ["codex-workspace:b", "codex-workspace:a"])
        XCTAssertEqual(model.items.map { $0.presentation.value }, ["70%", "0%"])
        XCTAssertEqual(model.items.map { $0.presentation.windows.first?.percent }, ["90%", "30%"])
        XCTAssertEqual(model.items.map { $0.presentation.planName }, ["Business", "Pro"])
        XCTAssertEqual(model.items.map { $0.presentation.status.severity }, [.normal, .warning])
        XCTAssertTrue(model.isMultiWorkspace)
    }

    func testDuplicateNamesKeepStableOrdinalsRegardlessOfSelectionOrder() {
        let accounts = [account("a", name: "Team"), account("b", name: "Team"), account("c", name: " Team ")]
        let model = composition(accounts, selected: ["codex-workspace:c", "codex-workspace:a"])
        XCTAssertEqual(model.items.map(\.workspaceName), ["3 · Team", "1 · Team"])
        XCTAssertEqual(model.items[0].fullWorkspaceName, "3 · Team · c@example.test")
    }

    func testNoWorkspaceUsesLegacyServiceQuotaWithoutInventingWorkspace() {
        let model = composition([], providers: [.codex])
        XCTAssertEqual(model.items.map(\.id), ["service:codex"])
        XCTAssertEqual(model.items[0].presentation.value, "99%")
        XCTAssertEqual(model.items[0].presentation.planName, "Ambient")
        XCTAssertFalse(model.items[0].isCodexWorkspace)
    }

    func testSelectedLegacyServiceBecomesUnavailableWhenWorkspacesAppear() {
        let selected = ["service:codex"]
        let original = composition([], providers: [.codex], selected: selected)
        XCTAssertEqual(original.items[0].presentation.value, "99%")
        let accounts = [account("new", percent: 17, plan: "Business")]
        let configured = composition(accounts, providers: [.codex], selected: selected)
        XCTAssertEqual(configured.items.map(\.id), selected)
        XCTAssertEqual(configured.items[0].workspaceName, "Unavailable")
        XCTAssertEqual(configured.items[0].presentation.value, "—")
        XCTAssertNil(configured.items[0].presentation.planName)
        XCTAssertEqual(configured.items[0].presentation.status.severity, .warning)
        XCTAssertTrue(configured.items[0].presentation.status.detail.contains("Edit the widget"))
        XCTAssertFalse(configured.items[0].presentation.valueDescription.contains("Ambient"))
        XCTAssertFalse(configured.items[0].presentation.valueDescription.contains("Business"))
        XCTAssertEqual(composition(accounts, providers: [.codex]).items.map(\.id), ["codex-workspace:new"])
    }

    func testHiddenProviderSelectionRemainsExcludedWithoutChangingVisibleOrder() {
        let selected = ["service:cursor", "codex-workspace:a", "service:claude"]
        let hidden = composition([account("a")], providers: [.cursor, .claude], selected: selected)
        XCTAssertEqual(hidden.items.map(\.id), ["service:cursor", "service:claude"])
        let shown = composition([account("a")], selected: selected)
        XCTAssertEqual(shown.items.map(\.id), selected)
        XCTAssertTrue(composition([account("a")], providers: [], selected: selected).items.isEmpty)
    }
}
