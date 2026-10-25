import Foundation

struct TokenHistoryDay<Totals: DailyTokenTotals>: Codable, Hashable, Sendable, Identifiable {
    var id: Date { date }
    let date: Date
    let totals: Totals
}

struct TokenHistory<Totals: DailyTokenTotals>: Codable, Hashable, Sendable {
    /// Identifies the configured log sources, never an authentication token.
    let sourceID: String
    let timeZoneIdentifier: String
    let days: [TokenHistoryDay<Totals>]
    let totals: Totals

    func coversToday(at now: Date, calendar: Calendar = .current) -> Bool {
        timeZoneIdentifier == calendar.timeZone.identifier
            && days.last.map { calendar.isDate($0.date, inSameDayAs: now) } == true
    }
}

struct ResetCardBatch: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let count: Int
    let startsAt: Date?
    let expiresAt: Date?
    var paused = false
    var requiresLimit = false
}

struct ResetCardInventory: Codable, Hashable, Sendable {
    let availableCount: Int
    let observedAt: Date
    let batches: [ResetCardBatch]

    func availableBatches(at now: Date) -> [ResetCardBatch] {
        batches.filter { $0.count > 0 && ($0.expiresAt.map { $0 > now } ?? true) }
            .sorted {
                if $0.expiresAt != $1.expiresAt {
                    return ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture)
                }
                return $0.id < $1.id
            }
    }

    /// Only subtract expirations occurring after the last authoritative reading.
    /// Missing details remain unknown rather than implying zero cards.
    func count(at now: Date) -> Int {
        let expired = batches.filter {
            $0.expiresAt.map { $0 > observedAt && $0 <= now } ?? false
        }.reduce(0) { $0 + min(max(0, availableCount - $0), max(0, $1.count)) }
        return max(0, availableCount - expired)
    }
}

struct CodexAccountUsage: Codable, Hashable, Sendable, Identifiable {
    /// Hash of source home + provider/workspace identity, isolating cached values.
    let id: String
    let homeID: String
    let displayName: String
    let quota: UsageValue<CompactQuota>
    let resetCards: UsageValue<ResetCardInventory>
    var workspaceName: String? = nil
    var accountName: String? = nil
    var planName: String? = nil
    var loginProfileID: UUID? = nil
    /// Hash of a verified workspace account identity, never a credential.
    var workspaceAccountIDHash: String? = nil
    /// Nil on legacy snapshots or when records cannot be attributed to this workspace.
    var tokens: UsageValue<CodexTokenTotals>? = nil
    var history: UsageValue<TokenHistory<CodexTokenTotals>>? = nil
    /// Official account-profile ledger, separate from request-attributed local records.
    var tokenActivity: UsageValue<CodexAccountTokenActivity>? = nil
}

/// Service calendar dates are labels: the endpoint does not declare their time zone.
struct CodexAccountTokenDay: Codable, Hashable, Sendable {
    let date: String
    let tokens: Int

    var calendarDate: Date? { Self.parseCalendarDate(date) }

    static let labelCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    static func parseCalendarDate(_ text: String) -> Date? {
        guard text.utf8.count == 10 else { return nil }
        var year = 0, month = 0, day = 0
        for (index, byte) in text.utf8.enumerated() {
            if index == 4 || index == 7 {
                guard byte == 45 else { return nil }
            } else {
                guard (48...57).contains(byte) else { return nil }
                let digit = Int(byte - 48)
                if index < 4 { year = year * 10 + digit }
                else if index < 7 { month = month * 10 + digit }
                else { day = day * 10 + digit }
            }
        }
        guard year > 0, (1...12).contains(month), (1...31).contains(day) else { return nil }
        if year < 1600 {
            // Preserve Foundation's historical Gregorian cutover behavior outside modern ledgers.
            guard let date = labelCalendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
            let components = labelCalendar.dateComponents([.year, .month, .day], from: date)
            return components.year == year && components.month == month && components.day == day ? date : nil
        }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let daysInMonth = month == 2 ? (leap ? 29 : 28) : ([4, 6, 9, 11].contains(month) ? 30 : 31)
        guard day <= daysInMonth else { return nil }
        // Convert a validated Gregorian civil date to an integer UTC day without Calendar allocation.
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let shiftedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let days = era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719_468
        return Date(timeIntervalSince1970: Double(days) * 86_400)
    }

    static func label(_ date: Date, includeYear: Bool = false) -> String {
        let parts = labelCalendar.dateComponents([.year, .month, .day], from: date)
        let label = "\(abbreviatedMonth(parts.month ?? 1)) \(parts.day ?? 1)"
        return includeYear ? "\(label), \(parts.year ?? 1)" : label
    }

    static func abbreviatedMonth(_ month: Int) -> String { months[month - 1] }
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}

struct CodexAccountTokenActivity: Codable, Hashable, Sendable {
    let workspaceAccountIDHash: String
    /// Missing days remain unknown. No token breakdown is supplied by this API.
    let dailyUsage: [CodexAccountTokenDay]?
    let lifetimeTokens: Int?
    /// Retained as returned, since this may be a calendar date rather than a timestamp.
    let statsAsOf: String?
    /// Response generation time, not the time the underlying statistics were updated.
    var serviceGeneratedAt: Date? = nil
}
