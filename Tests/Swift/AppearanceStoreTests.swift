import Foundation
import XCTest

@MainActor
final class AppearanceStoreTests: XCTestCase {
    private let christmas = ISO8601DateFormatter().date(from: "2024-12-25T12:00:00Z")!
    private let utc = TimeZone(secondsFromGMT: 0)!

    func testFrozenPreviewUsesReferenceDateAndChangesOnlyInMemory() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-appearance-\(UUID()).json")
        let store = AppearanceStore(settings: .default, observesChanges: false,
                                    referenceDate: christmas, timeZone: utc, settingsURL: url)
        XCTAssertEqual(store.variant, .christmas)
        store.select(.standard)
        XCTAssertEqual(store.settings.selection, .standard)
        XCTAssertEqual(store.variant, .standard)
        store.select(.automatic)
        XCTAssertEqual(store.variant, .christmas)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFrozenPreviewDoesNotReadOrOverwriteExistingSettings() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-appearance-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let existing = AppearanceSettings(selection: .halloween)
        try existing.save(to: url)
        let store = AppearanceStore(settings: AppearanceSettings(selection: .newYear), observesChanges: false,
                                    referenceDate: christmas, timeZone: utc, settingsURL: url)
        XCTAssertEqual(store.variant, .newYear)
        store.select(.midAutumn)
        XCTAssertEqual(store.variant, .midAutumn)
        XCTAssertEqual(AppearanceSettings.load(from: url), existing)
    }

    func testFailedSavePreservesCurrentSelectionAndReportsError() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("blocked-appearance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("Not a directory".utf8).write(to: file)
        let store = AppearanceStore(settings: .default, observesChanges: true,
                                    referenceDate: christmas, timeZone: utc,
                                    settingsURL: file.appendingPathComponent("settings.json"))
        store.select(.standard)
        XCTAssertEqual(store.settings, .default)
        XCTAssertEqual(store.variant, .christmas)
        XCTAssertNotNil(store.errorMessage)
    }

    func testLiveSelectionPersistsAndReturningToAutomaticResolvesCalendar() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-appearance-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AppearanceStore(settings: .default, observesChanges: true,
                                    referenceDate: christmas, timeZone: utc, settingsURL: url)
        store.select(.standard)
        XCTAssertEqual(store.settings.selection, .standard)
        XCTAssertEqual(store.variant, .standard)
        XCTAssertEqual(AppearanceSettings.load(from: url), store.settings)
        store.select(.automatic)
        XCTAssertEqual(store.variant, .christmas)
        XCTAssertEqual(AppearanceSettings.load(from: url), .default)
        XCTAssertNil(store.errorMessage)
    }
}
