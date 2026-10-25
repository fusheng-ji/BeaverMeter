import Foundation

/// Artwork used by the menu bar and popover; Widgets use provider logos.
enum BrandVariant: String, Codable, CaseIterable, Hashable, Sendable {
    case standard, newYear, lunarNewYear, lanternFestival, dragonBoat
    case midAutumn, programmerDay, halloween, christmas

    var displayName: String {
        switch self {
        case .standard: "Classic Beaver"
        case .newYear: "New Year"
        case .lunarNewYear: "Lunar New Year"
        case .lanternFestival: "Lantern Festival"
        case .dragonBoat: "Dragon Boat Festival"
        case .midAutumn: "Mid-Autumn Festival"
        case .programmerDay: "Programmers' Day"
        case .halloween: "Halloween"
        case .christmas: "Christmas"
        }
    }

    var assetName: String { "beaver-\(rawValue)" }
}

enum AppearanceSelection: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic, standard, newYear, lunarNewYear, lanternFestival, dragonBoat
    case midAutumn, programmerDay, halloween, christmas

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let stored = try container.decode(String.self)
        // Keep an existing fixed selection when replacing the retired outfit.
        let value = stored == "nationalDay" ? "programmerDay" : stored
        guard let selection = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown appearance selection")
        }
        self = selection
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var fixedVariant: BrandVariant? { BrandVariant(rawValue: rawValue) }
    var displayName: String { fixedVariant?.displayName ?? "Automatic · Local Calendar" }
}

/// Stored separately from usage so changing a logo never requires collecting data.
struct AppearanceSettings: Codable, Equatable, Sendable {
    var selection: AppearanceSelection = .automatic

    static let `default` = AppearanceSettings()

    static var settingsURL: URL {
        UsageSnapshot.snapshotURL.deletingLastPathComponent()
            .appendingPathComponent("beaver-meter-appearance.json")
    }

    static func load(from url: URL = settingsURL) -> AppearanceSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(Self.self, from: data)
        else { return .default }
        return settings
    }

    func save(to url: URL = Self.settingsURL) throws {
        try AtomicFileWriter.writeJSON(self, to: url, prettyPrinted: true)
    }

    func resolvedVariant(at date: Date, timeZone: TimeZone) -> BrandVariant {
        selection.fixedVariant ?? HolidayLogoResolver.variant(at: date, timeZone: timeZone)
    }
}

/// Calendar-only rules; deliberately independent of locale, network and usage data.
enum HolidayLogoResolver {
    static func variant(at date: Date, timeZone: TimeZone) -> BrandVariant {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        var chinese = Calendar(identifier: .chinese)
        chinese.timeZone = timeZone

        let lunar = chinese.dateComponents([.month, .day, .isLeapMonth], from: date)
        if lunar.isLeapMonth == false, let month = lunar.month, let day = lunar.day {
            switch (month, day) {
            case (1, 1...7): return .lunarNewYear
            case (1, 15): return .lanternFestival
            case (5, 5): return .dragonBoat
            case (8, 15): return .midAutumn
            default: break
            }
        }

        // A lunar year can end on day 29 or day 30. Identify its eve by tomorrow.
        if let tomorrow = gregorian.date(byAdding: .day, value: 1, to: gregorian.startOfDay(for: date)) {
            let nextLunar = chinese.dateComponents([.month, .day, .isLeapMonth], from: tomorrow)
            if nextLunar.month == 1, nextLunar.day == 1, nextLunar.isLeapMonth == false {
                return .lunarNewYear
            }
        }

        let solar = gregorian.dateComponents([.month, .day], from: date)
        switch (solar.month ?? 0, solar.day ?? 0) {
        case (1, 1): return .newYear
        case (10, 24): return .programmerDay
        case (10, 31): return .halloween
        case (12, 24...26): return .christmas
        default: return .standard
        }
    }

    /// Uses calendar days rather than 24-hour intervals to survive DST changes.
    static func futureMidnights(after date: Date, timeZone: TimeZone, count: Int = 2) -> [Date] {
        guard count > 0 else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var midnight = calendar.startOfDay(for: date)
        var dates: [Date] = []
        for _ in 0..<count {
            guard let next = calendar.date(byAdding: .day, value: 1, to: midnight) else { break }
            midnight = calendar.startOfDay(for: next)
            dates.append(midnight)
        }
        return dates
    }
}
