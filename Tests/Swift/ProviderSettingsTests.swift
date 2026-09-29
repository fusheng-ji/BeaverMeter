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

    func testGridRowsPairServicesAndLeaveOddOneFullWidth() {
        XCTAssertEqual(ProviderGridLayout.rows([.codex]), [[.codex]])
        XCTAssertEqual(ProviderGridLayout.rows([.codex, .claude, .deepseek]), [[.codex, .claude], [.deepseek]])
        XCTAssertEqual(ProviderGridLayout.rows(MeterProvider.allCases).count, 2)
    }
}
