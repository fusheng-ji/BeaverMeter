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
}
