import Foundation
import XCTest

final class BrandAppearanceTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    private func date(_ iso8601: String) -> Date {
        ISO8601DateFormatter().date(from: iso8601)!
    }

    private func variant(_ localDay: String) -> BrandVariant {
        HolidayLogoResolver.variant(at: date("\(localDay)T12:00:00+08:00"), timeZone: shanghai)
    }

    func testGregorianHolidayBoundariesAndRecovery() {
        let expectations: [(String, BrandVariant)] = [
            ("2023-12-31", .standard), ("2024-01-01", .newYear), ("2024-01-02", .standard),
            ("2024-09-30", .standard), ("2024-10-01", .standard),
            ("2024-10-07", .standard), ("2024-10-08", .standard),
            ("2024-10-23", .standard), ("2024-10-24", .programmerDay), ("2024-10-25", .standard),
            ("2024-10-30", .standard), ("2024-10-31", .halloween), ("2024-11-01", .standard),
            ("2024-12-23", .standard), ("2024-12-24", .christmas),
            ("2024-12-26", .christmas), ("2024-12-27", .standard)
        ]
        for (day, expected) in expectations {
            XCTAssertEqual(variant(day), expected, day)
        }
    }

    func testLunarNewYearIncludesBothKindsOfEveAndEndsAfterSeventhDay() {
        let expectations: [(String, BrandVariant)] = [
            ("2024-02-08", .standard), ("2024-02-09", .lunarNewYear), // Lunar 12/30
            ("2024-02-10", .lunarNewYear), ("2024-02-16", .lunarNewYear),
            ("2024-02-17", .standard),
            ("2025-01-27", .standard), ("2025-01-28", .lunarNewYear), // Lunar 12/29
            ("2025-01-29", .lunarNewYear), ("2025-02-04", .lunarNewYear),
            ("2025-02-05", .standard)
        ]
        for (day, expected) in expectations {
            XCTAssertEqual(variant(day), expected, day)
        }
    }

    func testSingleDayLunarHolidaysAndRecovery() {
        let expectations: [(String, BrandVariant)] = [
            ("2024-02-23", .standard), ("2024-02-24", .lanternFestival), ("2024-02-25", .standard),
            ("2024-06-09", .standard), ("2024-06-10", .dragonBoat), ("2024-06-11", .standard),
            ("2024-09-16", .standard), ("2024-09-17", .midAutumn), ("2024-09-18", .standard)
        ]
        for (day, expected) in expectations {
            XCTAssertEqual(variant(day), expected, day)
        }
    }

    func testLeapMonthsDoNotRepeatLunarHolidays() {
        XCTAssertEqual(variant("2009-05-28"), .dragonBoat)
        XCTAssertEqual(variant("2009-06-27"), .standard) // Leap fifth month, day five
        XCTAssertEqual(variant("1995-09-09"), .midAutumn)
        XCTAssertEqual(variant("1995-10-09"), .standard) // Leap eighth month, day fifteen
    }

    func testMidAutumnInOctoberAndRetiredHolidayDates() {
        XCTAssertEqual(variant("2020-10-01"), .midAutumn)
        XCTAssertEqual(variant("2020-10-02"), .standard)
        XCTAssertEqual(variant("2025-10-05"), .standard)
        XCTAssertEqual(variant("2025-10-06"), .midAutumn)
        XCTAssertEqual(variant("2025-10-07"), .standard)
        XCTAssertEqual(variant("2025-10-08"), .standard)
    }

    func testLocalTimeZoneControlsHolidayAtSameInstant() {
        let programmerMidnight = date("2024-10-23T16:30:00Z")
        XCTAssertEqual(HolidayLogoResolver.variant(at: programmerMidnight, timeZone: shanghai), .programmerDay)
        XCTAssertEqual(HolidayLogoResolver.variant(at: programmerMidnight, timeZone: TimeZone(secondsFromGMT: 0)!), .standard)
        let instant = date("2024-12-31T23:30:00Z")
        XCTAssertEqual(HolidayLogoResolver.variant(at: instant, timeZone: shanghai), .newYear)
        XCTAssertEqual(HolidayLogoResolver.variant(at: instant, timeZone: TimeZone(identifier: "America/Los_Angeles")!), .standard)

        let lanternMidnight = date("2024-02-23T16:00:00Z")
        XCTAssertEqual(HolidayLogoResolver.variant(at: lanternMidnight, timeZone: shanghai), .lanternFestival)
        XCTAssertEqual(HolidayLogoResolver.variant(at: lanternMidnight, timeZone: TimeZone(secondsFromGMT: 0)!), .standard)
    }

    func testExactMidnightStartsAndEndsFestival() {
        XCTAssertEqual(HolidayLogoResolver.variant(at: date("2024-10-23T23:59:59+08:00"), timeZone: shanghai), .standard)
        XCTAssertEqual(HolidayLogoResolver.variant(at: date("2024-10-24T00:00:00+08:00"), timeZone: shanghai), .programmerDay)
        XCTAssertEqual(HolidayLogoResolver.variant(at: date("2024-10-24T23:59:59+08:00"), timeZone: shanghai), .programmerDay)
        XCTAssertEqual(HolidayLogoResolver.variant(at: date("2024-10-25T00:00:00+08:00"), timeZone: shanghai), .standard)
        XCTAssertEqual(HolidayLogoResolver.variant(at: date("2024-10-30T23:59:59+08:00"), timeZone: shanghai), .standard)
        XCTAssertEqual(HolidayLogoResolver.variant(at: date("2024-10-31T00:00:00+08:00"), timeZone: shanghai), .halloween)
        XCTAssertEqual(HolidayLogoResolver.variant(at: date("2024-10-31T23:59:59+08:00"), timeZone: shanghai), .halloween)
        XCTAssertEqual(HolidayLogoResolver.variant(at: date("2024-11-01T00:00:00+08:00"), timeZone: shanghai), .standard)
    }

    func testFutureMidnightsRespectDaylightSavingAndCrossYear() {
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        XCTAssertEqual(HolidayLogoResolver.futureMidnights(after: date("2026-03-28T12:00:00+01:00"), timeZone: berlin), [
            date("2026-03-29T00:00:00+01:00"), date("2026-03-30T00:00:00+02:00")
        ])
        XCTAssertEqual(HolidayLogoResolver.futureMidnights(after: date("2026-10-24T12:00:00+02:00"), timeZone: berlin), [
            date("2026-10-25T00:00:00+02:00"), date("2026-10-26T00:00:00+01:00")
        ])
        XCTAssertEqual(HolidayLogoResolver.futureMidnights(after: date("2024-12-31T23:59:59+08:00"), timeZone: shanghai), [
            date("2025-01-01T00:00:00+08:00"), date("2025-01-02T00:00:00+08:00")
        ])
    }

    func testFutureMidnightsAreStrictlyFutureAndCountIsHonored() {
        let midnight = date("2024-01-01T00:00:00+08:00")
        XCTAssertEqual(HolidayLogoResolver.futureMidnights(after: midnight, timeZone: shanghai, count: 1), [
            date("2024-01-02T00:00:00+08:00")
        ])
        XCTAssertTrue(HolidayLogoResolver.futureMidnights(after: midnight, timeZone: shanghai, count: 0).isEmpty)
        XCTAssertTrue(HolidayLogoResolver.futureMidnights(after: midnight, timeZone: shanghai, count: -1).isEmpty)
    }

    func testAutomaticAndEveryManualChoice() {
        let holiday = date("2024-12-25T12:00:00+08:00")
        let ordinaryDay = date("2024-07-12T12:00:00+08:00")
        XCTAssertNil(AppearanceSelection.automatic.fixedVariant)
        XCTAssertEqual(AppearanceSettings.default.resolvedVariant(at: holiday, timeZone: shanghai), .christmas)
        XCTAssertEqual(AppearanceSettings.default.resolvedVariant(at: ordinaryDay, timeZone: shanghai), .standard)
        for selection in AppearanceSelection.allCases where selection != .automatic {
            let settings = AppearanceSettings(selection: selection)
            XCTAssertEqual(settings.resolvedVariant(at: holiday, timeZone: shanghai), selection.fixedVariant)
            XCTAssertEqual(settings.resolvedVariant(at: ordinaryDay, timeZone: shanghai), selection.fixedVariant)
        }
    }

    func testSettingsRoundTripSeparateFileAndFallbacks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-\(UUID())")
        let url = directory.appendingPathComponent("settings.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(AppearanceSettings.load(from: url), .default)
        for selection in AppearanceSelection.allCases {
            let settings = AppearanceSettings(selection: selection)
            try settings.save(to: url)
            XCTAssertEqual(AppearanceSettings.load(from: url), settings)
        }
        for invalidJSON in ["not json", "{}", "{\"selection\":null}", "{\"selection\":\"futureFestival\"}"] {
            try Data(invalidJSON.utf8).write(to: url)
            XCTAssertEqual(AppearanceSettings.load(from: url), .default)
        }
        XCTAssertEqual(AppearanceSettings.settingsURL.lastPathComponent, "beaver-meter-appearance.json")
        XCTAssertEqual(AppearanceSettings.settingsURL.deletingLastPathComponent(), UsageSnapshot.snapshotURL.deletingLastPathComponent())
        XCTAssertNotEqual(AppearanceSettings.settingsURL, ProviderSettings.settingsURL)
    }

    func testRetiredFixedOutfitLoadsAndSavesAsProgrammerDay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-outfit-\(UUID())")
        let url = directory.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"selection\":\"nationalDay\"}".utf8).write(to: url)
        let settings = AppearanceSettings.load(from: url)
        XCTAssertEqual(settings.selection, .programmerDay)
        XCTAssertEqual(settings.resolvedVariant(at: date("2024-07-12T12:00:00+08:00"), timeZone: shanghai), .programmerDay)
        try settings.save(to: url)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String]
        XCTAssertEqual(saved?["selection"], "programmerDay")
        XCTAssertEqual(BrandVariant.allCases.count, 9)
        XCTAssertFalse(AppearanceSelection.allCases.map(\.rawValue).contains("nationalDay"))
    }
}
