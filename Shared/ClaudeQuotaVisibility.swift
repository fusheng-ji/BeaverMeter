import Foundation

/// A stopped collector must not leave an old Claude allowance looking current.
/// Authentication failures never retain values; transient failures get a short,
/// measured-time cache, independent of how often another refresh is attempted.
enum ClaudeQuotaVisibility {
    static let maximumAge: TimeInterval = 30 * 60

    /// Future entries expire a displayed value even if WidgetKit postpones its
    /// next collector refresh. The same projection supplies each future entry.
    static func expirationDates(quota: UsageValue<CompactQuota>, cards: UsageValue<ResetCardInventory>,
                                after now: Date) -> [Date] {
        var dates: [Date] = []
        if quota.source != .preview, quota.status != .unauthenticated, let value = quota.value,
           let measuredAt = quota.measuredAt {
            let deadline = measuredAt.addingTimeInterval(maximumAge)
            dates.append(deadline)
            dates.append(contentsOf: ([value] + (value.windows ?? [])).compactMap(\.resetAt).filter { $0 < deadline })
        }
        if cards.source != .preview, cards.status != .unauthenticated, cards.value != nil,
           let measuredAt = cards.measuredAt {
            dates.append(measuredAt.addingTimeInterval(maximumAge))
        }
        return Array(Set(dates.filter { $0 > now })).sorted()
    }

    static func quota(_ data: UsageValue<CompactQuota>, relativeTo now: Date) -> UsageValue<CompactQuota> {
        if data.status == .unauthenticated { return hidden(data, status: .unauthenticated, message: data.message) }
        guard let value = data.value else { return data }
        if data.source == .preview { return data }
        guard let measuredAt = data.measuredAt, now.timeIntervalSince(measuredAt) < maximumAge else {
            return hidden(data, message: "Claude quota is out of date. Verify your login to refresh it.")
        }
        let isCurrent: (CompactQuota) -> Bool = { $0.resetAt.map { $0 > now } ?? true }
        var windows = value.windows ?? []
        if !windows.contains(where: { $0.label == value.label }) {
            var primary = value
            primary.windows = nil
            windows.insert(primary, at: 0)
        }
        let current = windows.filter(isCurrent)
        guard var visible = isCurrent(value) ? value : current.first else {
            return hidden(data, message: "Claude quota has reset. Waiting for a fresh reading.")
        }
        visible.windows = value.windows == nil && current.count == 1 ? nil : current
        return UsageValue(status: data.status, source: data.source, measuredAt: data.measuredAt,
                          lastAttemptAt: data.lastAttemptAt, message: data.message, value: visible)
    }

    static func resetCards(_ data: UsageValue<ResetCardInventory>, relativeTo now: Date) -> UsageValue<ResetCardInventory> {
        if data.status == .unauthenticated { return hidden(data, status: .unauthenticated, message: data.message) }
        guard data.value != nil, data.source != .preview else { return data }
        guard let measuredAt = data.measuredAt, now.timeIntervalSince(measuredAt) < maximumAge else {
            return hidden(data, message: "Claude reset cards are out of date. Verify your login to refresh them.")
        }
        return data
    }

    private static func hidden<Value>(_ data: UsageValue<Value>, status: UsageDataStatus = .unavailable,
                                      message: String?) -> UsageValue<Value> {
        UsageValue(status: status, source: .none, measuredAt: nil,
                   lastAttemptAt: data.lastAttemptAt, message: message, value: nil)
    }
}
