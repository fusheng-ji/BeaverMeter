import Foundation
import XCTest

final class ProviderSettingsTests: XCTestCase {
    func testAutoShowsDetectedServicesAndSwitchesOverride() {
        let snapshot = UsagePreviewScenario.signedOut.snapshot  // DeepSeek has no value
        var settings = ProviderSettings.default
        XCTAssertEqual(settings.visibleProviders(in: snapshot), [.codex, .claude, .cursor])

        settings[.deepseek] = .shown
        settings[.cursor] = .hidden
        XCTAssertEqual(settings.visibleProviders(in: snapshot), [.codex, .claude, .deepseek])
        XCTAssertFalse(settings.collects(.cursor))
    }

    func testNothingDetectedStillShowsEnabledServices() {
        var settings = ProviderSettings.default
        settings[.cursor] = .hidden
        let snapshot = UsagePreviewScenario.unavailable.snapshot
        XCTAssertEqual(settings.visibleProviders(in: snapshot), [.codex, .claude, .deepseek])
    }

    func testMultipleConfiguredFailedCodexWorkspacesAreDetectedAndStillHonorHiddenSetting() {
        var snapshot = UsagePreviewScenario.unavailable.snapshot
        let accounts = ["personal", "work"].map { id in
            CodexAccountUsage(id: id, homeID: id, displayName: id,
                              quota: .unavailable("Sign in"), resetCards: .unavailable("Cards unknown"))
        }
        snapshot.codexAccounts = UsageValue(status: .ready, source: .accountAPI,
                                            measuredAt: snapshot.generatedAt, lastAttemptAt: snapshot.generatedAt,
                                            message: nil, value: accounts)
        var settings = ProviderSettings.default
        XCTAssertTrue(snapshot.isDetected(.codex))
        XCTAssertEqual(settings.visibleProviders(in: snapshot), [.codex])
        settings[.claude] = .shown
        settings[.codex] = .hidden
        XCTAssertEqual(settings.visibleProviders(in: snapshot), [.claude])
    }

    func testSettingsRoundTripAndAutoIsNotStored() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var settings = ProviderSettings.default
        settings[.cursor] = .hidden
        settings[.claude] = .auto
        try settings.save(to: url)
        XCTAssertEqual(ProviderSettings.load(from: url), settings)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("claude"))
        XCTAssertEqual(ProviderSettings.load(from: url.appendingPathExtension("missing")), .default)
    }

    func testWorkspaceActivityDetectsCodexWithoutBorrowingProviderTotals() {
        var snapshot = UsagePreviewScenario.unavailable.snapshot
        let account = CodexAccountUsage(id: "workspace", homeID: "home", displayName: "Personal",
            quota: .unavailable("No quota"), resetCards: .unavailable("No inventory"),
            tokens: UsageSnapshot.preview.codexTokens)
        snapshot.codexAccounts = UsageValue(status: .ready, source: .accountAPI,
            measuredAt: snapshot.generatedAt, lastAttemptAt: snapshot.generatedAt, message: nil, value: [account])
        XCTAssertTrue(snapshot.isDetected(.codex))
        var settings = ProviderSettings.default
        XCTAssertEqual(settings.visibleProviders(in: snapshot), [.codex])
        settings[.codex] = .hidden
        XCTAssertFalse(settings.visibleProviders(in: snapshot).contains(.codex))
    }

    func testGridRowsPairServicesAndLeaveOddOneFullWidth() {
        XCTAssertEqual(ProviderGridLayout.rows([.codex]), [[.codex]])
        XCTAssertEqual(ProviderGridLayout.rows([.codex, .claude, .deepseek]), [[.codex, .claude], [.deepseek]])
        XCTAssertEqual(ProviderGridLayout.rows(MeterProvider.allCases).count, 2)
    }

    func testAdaptiveLayoutsKeepEveryServiceEqualAndInOrder() {
        for mask in 0..<16 {
            let providers = MeterProvider.allCases.enumerated().compactMap { index, provider in
                mask & (1 << index) != 0 ? provider : nil
            }
            for size in ProviderWidgetSize.allCases {
                let rows = ProviderGridLayout.rows(providers, size: size)
                XCTAssertEqual(rows.flatMap { $0 }, providers)
                XCTAssertEqual(Set(rows.map(\.count)).count, rows.isEmpty ? 0 : 1)
                if providers.count == 3 {
                    XCTAssertEqual(rows.count, size == .small || size == .large ? 3 : 1)
                }
            }
        }
    }
}
