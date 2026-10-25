import Foundation
import XCTest

final class WidgetModuleCatalogTests: XCTestCase {
    private func snapshot(_ ids: [String], name: String? = nil) -> UsageSnapshot {
        var snapshot = UsageSnapshot.preview
        snapshot.codexAccounts = UsageValue(status: .ready, source: .preview,
            measuredAt: snapshot.generatedAt, lastAttemptAt: snapshot.generatedAt, message: nil,
            value: ids.map { id in
                CodexAccountUsage(id: id, homeID: "home-\(id)", displayName: "\(id) display",
                    quota: snapshot.codexQuota, resetCards: .unavailable("No inventory"),
                    workspaceName: name ?? "Workspace \(id)", planName: "Pro")
            })
        return snapshot
    }

    func testWorkspaceOptionsUseStableAccountIdsForSingleAndMultipleAccounts() {
        let single = WidgetModuleCatalog.available(snapshot: snapshot(["a"]), providers: [.codex])
        let multiple = WidgetModuleCatalog.available(snapshot: snapshot(["a", "b"]), providers: [.codex])
        XCTAssertEqual(single.map(\.id), ["codex-workspace:a"])
        XCTAssertEqual(single.first?.id, multiple.first?.id)
        XCTAssertEqual(single.first?.workspaceID, "a")
        XCTAssertEqual(single.first?.provider, .codex)
    }

    func testCatalogOffersEveryWorkspaceButDefaultsNeverExceedSixModules() {
        let source = snapshot((1...20).map(String.init))
        let available = WidgetModuleCatalog.available(snapshot: source, providers: MeterProvider.allCases)
        XCTAssertEqual(available.count, 23)
        XCTAssertEqual(WidgetModuleCatalog.defaults(snapshot: source, providers: MeterProvider.allCases),
            ["codex-workspace:1", "service:claude", "service:cursor", "service:deepseek", "codex-workspace:2", "codex-workspace:3"])
        XCTAssertEqual(WidgetModuleCatalog.defaults(snapshot: source, providers: [.codex]).count, 6)
    }

    func testDefaultServiceOrderPrecedesAdditionalWorkspaceOptions() {
        let defaults = WidgetModuleCatalog.defaults(snapshot: snapshot(["a", "b", "c"]), providers: [.cursor, .codex, .claude])
        XCTAssertEqual(defaults, ["service:cursor", "codex-workspace:a", "service:claude", "codex-workspace:b", "codex-workspace:c"])
    }

    func testNoAccountsOfferOnlyLegacyCodexServiceOption() {
        let options = WidgetModuleCatalog.available(snapshot: snapshot([]), providers: [.codex])
        XCTAssertEqual(options.map(\.id), ["service:codex"])
        XCTAssertNil(options.first?.workspaceID)
        XCTAssertEqual(options.first?.title, "Codex")
    }

    func testHiddenAndDuplicateProvidersDoNotCreateExtraOptions() {
        let options = WidgetModuleCatalog.available(snapshot: snapshot(["a", "b"]), providers: [.claude, .claude, .cursor])
        XCTAssertEqual(options.map(\.id), ["service:claude", "service:cursor"])
        XCTAssertTrue(WidgetModuleCatalog.available(snapshot: snapshot(["a"]), providers: []).isEmpty)
        XCTAssertTrue(WidgetModuleCatalog.defaults(snapshot: snapshot(["a"]), providers: []).isEmpty)
    }

    func testSameNamesHaveDistinctLabelsAndStableIdsAfterRename() {
        let old = WidgetModuleCatalog.available(snapshot: snapshot(["a", "b"], name: "Team"), providers: [.codex])
        let renamed = WidgetModuleCatalog.available(snapshot: snapshot(["a", "b"], name: "Renamed"), providers: [.codex])
        XCTAssertEqual(old.map(\.title), ["1 · Team", "2 · Team"])
        XCTAssertEqual(old.map(\.id), renamed.map(\.id))
    }

    func testDuplicateAccountIdsCannotCreateDuplicatePickerIdentity() {
        let options = WidgetModuleCatalog.available(snapshot: snapshot(["a", "a", "b"]), providers: [.codex])
        XCTAssertEqual(options.map(\.id), ["codex-workspace:a", "codex-workspace:b"])
    }

    func testNoneIsExplicitAndNeverAnAutomaticDefaultOrProviderOption() {
        let source = snapshot(["a"])
        XCTAssertFalse(WidgetModuleCatalog.available(snapshot: source, providers: MeterProvider.allCases).contains { $0.id == WidgetModuleCatalog.noneID })
        XCTAssertFalse(WidgetModuleCatalog.defaults(snapshot: source, providers: MeterProvider.allCases).contains(WidgetModuleCatalog.noneID))
    }
}
