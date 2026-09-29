import Foundation

/// Shared presentation policy; collectors and snapshot serialization remain independent of UI.
struct UsageStatusPresentation: Equatable {
    enum Severity: Equatable {
        case normal
        case warning
        case critical
    }

    let label: String
    let icon: String
    let severity: Severity
    let detail: String

    init<Value>(_ data: UsageValue<Value>, relativeTo now: Date = .now) {
        if data.isStale {
            let isOld = (data.age(at: now) ?? 0) >= 3 * 60 * 60
            label = isOld ? "Old cache" : "Stale"
            icon = "clock.badge.exclamationmark.fill"
            severity = isOld ? .critical : .warning
        } else {
            switch data.status {
            case .ready:
                label = data.source == .preview ? "Demo" : "Live"
                icon = "checkmark.circle.fill"
                severity = .normal
            case .stale:
                label = "Stale"
                icon = "clock.badge.exclamationmark.fill"
                severity = .warning
            case .unauthenticated:
                label = "Sign in"
                icon = "person.crop.circle.badge.exclamationmark"
                severity = .warning
            case .unavailable:
                label = "No data"
                icon = "minus.circle.fill"
                severity = .warning
            case .error:
                label = "Error"
                icon = "exclamationmark.triangle.fill"
                severity = .critical
            }
        }
        detail = [
            label,
            UsageFormatting.source(data.source),
            "updated \(UsageFormatting.relativeAge(data.measuredAt, relativeTo: now))",
            data.message
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

typealias CodexDailyTokenPresentation = DailyTokenPresentation<CodexTokenTotals>
typealias ClaudeDailyTokenPresentation = DailyTokenPresentation<ClaudeTokenTotals>

/// Today's token total, with values measured on a previous day hidden.
struct DailyTokenPresentation<Totals: DailyTokenTotals> {
    let data: UsageValue<Totals>
    let value: String
    let accessibilityText: String
    let status: UsageStatusPresentation
    let warningLabel: String

    init(_ original: UsageValue<Totals>, relativeTo now: Date = .now, calendar: Calendar = .current) {
        if original.source != .preview,
           let measuredAt = original.measuredAt,
           !calendar.isDate(measuredAt, inSameDayAs: now) {
            data = UsageValue(status: .unavailable, source: .none, measuredAt: nil,
                              lastAttemptAt: original.lastAttemptAt,
                              message: "Today's usage is awaiting refresh.", value: nil)
        } else {
            data = original
        }
        value = UsageFormatting.tokens(data.value?.totalTokens)
        status = UsageStatusPresentation(data, relativeTo: now)
        warningLabel = data.message?.localizedCaseInsensitiveContains("remote") == true
            ? "Remote" : status.label
        let count = data.value.map { "\($0.totalTokens.formatted()) tokens" } ?? "unavailable"
        accessibilityText = "\(Totals.providerName) today, \(count), \(status.detail)"
    }

    var summary: DailyTokenSummary {
        DailyTokenSummary(value: value, accessibilityText: accessibilityText,
                          status: status, warningLabel: warningLabel)
    }
}

/// Provider-independent daily token line for compact widget panels.
struct DailyTokenSummary: Equatable {
    let value: String
    let accessibilityText: String
    let status: UsageStatusPresentation
    let warningLabel: String
}

extension CompactQuota {
    /// "Fable" for "Claude Fable Week"; nil for all-model and single-scope windows.
    var modelScope: String? {
        guard label.hasPrefix("Claude "), label.hasSuffix(" Week") else { return nil }
        let name = label.dropFirst("Claude ".count).dropLast(" Week".count)
        return name.isEmpty ? nil : String(name)
    }

    /// Row title such as "5-hour", "Weekly" or "Fable weekly".
    var windowTitle: String {
        switch windowSeconds {
        case 18_000: "5-hour"
        case 604_800: modelScope.map { "\($0) weekly" } ?? "Weekly"
        default: label
        }
    }

    /// Terse name for strips: "5h", "Wk" or the model name.
    var shortWindowName: String {
        switch windowSeconds {
        case 18_000: "5h"
        case 604_800: modelScope ?? "Wk"
        default: label
        }
    }

    var percentLeftText: String {
        remainingPercent.map { "\(Int(UsageFormatting.clampedPercent($0)!.rounded()))%" } ?? "—"
    }

    /// The windows other than this summary one, in display order.
    var otherWindows: [CompactQuota] {
        (windows ?? []).filter { $0.label != label }
    }
}
