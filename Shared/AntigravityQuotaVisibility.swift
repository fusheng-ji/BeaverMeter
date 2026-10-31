import Foundation

/// The same measurement deadline applies to the menu and future Widget entries.
enum AntigravityQuotaVisibility {
    static let maximumAge: TimeInterval = 30 * 60

    static func quota(_ data: UsageValue<AntigravityQuotaSnapshot>, relativeTo now: Date) -> UsageValue<AntigravityQuotaSnapshot> {
        if data.status == .unauthenticated { return hidden(data, status: .unauthenticated, message: data.message) }
        guard let value = data.value else { return data }
        if data.source == .preview { return data }
        guard let measuredAt = data.measuredAt, now.timeIntervalSince(measuredAt) < maximumAge else {
            return hidden(data, message: "Antigravity quota is out of date. Waiting for a fresh reading.")
        }
        let groups = value.groups.map { group in
            AntigravityQuotaGroup(id: group.id, windows: group.windows.filter {
                $0.resetAt.map { $0 > now } ?? true
            })
        }
        guard groups.contains(where: { $0.windows.contains(where: isKnown) }) else {
            return hidden(data, message: "Antigravity quota is awaiting a fresh reading.")
        }
        return UsageValue(status: data.status, source: data.source, measuredAt: data.measuredAt,
                          lastAttemptAt: data.lastAttemptAt, message: data.message,
                          value: AntigravityQuotaSnapshot(groups: groups, planName: value.planName, accountID: value.accountID))
    }

    static func group(_ id: AntigravityQuotaGroupID, in data: UsageValue<AntigravityQuotaSnapshot>,
                      relativeTo now: Date) -> UsageValue<CompactQuota> {
        let visible = quota(data, relativeTo: now)
        let windows = visible.value?.groups.first(where: { $0.id == id })?.windows ?? []
        return project(visible, windows: windows, label: "\(id.title) quota is unavailable.")
    }

    static func summary(_ data: UsageValue<AntigravityQuotaSnapshot>, relativeTo now: Date) -> UsageValue<CompactQuota> {
        let visible = quota(data, relativeTo: now)
        return project(visible, windows: visible.value?.groups.flatMap(\.windows) ?? [],
                       label: "Antigravity quota is unavailable.")
    }

    static func expirationDates(quota: UsageValue<AntigravityQuotaSnapshot>, after now: Date) -> [Date] {
        guard quota.source != .preview, quota.status != .unauthenticated,
              let value = quota.value, let measuredAt = quota.measuredAt else { return [] }
        let deadline = measuredAt.addingTimeInterval(maximumAge)
        return Array(Set(([deadline] + value.groups.flatMap(\.windows).compactMap(\.resetAt))
            .filter { $0 > now && $0 <= deadline })).sorted()
    }

    private static func isKnown(_ window: CompactQuota) -> Bool {
        window.remainingPercent?.isFinite == true
    }

    private static func project(_ data: UsageValue<AntigravityQuotaSnapshot>, windows: [CompactQuota],
                                label: String) -> UsageValue<CompactQuota> {
        let known = windows.filter(isKnown)
        var selected = known.sorted {
            if $0.remainingPercent != $1.remainingPercent { return $0.remainingPercent! < $1.remainingPercent! }
            if ($0.windowSeconds == 604_800) != ($1.windowSeconds == 604_800) { return $0.windowSeconds == 604_800 }
            return $0.label < $1.label
        }.first
        selected?.planName = data.value?.planName
        selected?.windows = known.count > 1 ? known : nil
        return UsageValue(status: selected == nil && data.status == .ready ? .unavailable : data.status,
                          source: data.source, measuredAt: data.measuredAt, lastAttemptAt: data.lastAttemptAt,
                          message: selected == nil ? (data.message ?? label) : data.message, value: selected)
    }

    private static func hidden(_ data: UsageValue<AntigravityQuotaSnapshot>, status: UsageDataStatus = .unavailable,
                               message: String?) -> UsageValue<AntigravityQuotaSnapshot> {
        UsageValue(status: status, source: .none, measuredAt: nil, lastAttemptAt: data.lastAttemptAt,
                   message: message, value: nil)
    }
}
