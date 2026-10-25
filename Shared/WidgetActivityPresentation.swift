import Foundation

struct WidgetActivityDay: Identifiable {
    let date: Date
    let value: Int?
    var id: Date { date }
}

struct WidgetActivityItem: Identifiable {
    let provider: MeterProvider
    var moduleID: String? = nil
    let value: String
    let compactValue: String
    let caption: String
    let detail: String?
    let aggregationNote: String?
    let status: WidgetCardStatus
    let history: [WidgetActivityDay]?
    let historyLabel: String?
    let historyTimeZoneIdentifier: String?
    let historyStatus: WidgetCardStatus?
    let accessibilityText: String
    var fetchedAtLabel: String? = nil
    var id: String { moduleID ?? provider.rawValue }
}

/// Composition projections keep workspace activity with its selected quota module.
struct WidgetActivityPresentation {
    let items: [WidgetActivityItem]

    /// Compatibility summary for callers that explicitly request provider-wide activity.
    /// Widget cards use the composition initializer to keep workspace attribution strict.
    init(snapshot: UsageSnapshot, providers: [MeterProvider], referenceDate: Date, calendar: Calendar = .current) {
        var seen: Set<MeterProvider> = []
        items = providers.filter { seen.insert($0).inserted }.map { provider in
            switch provider {
            case .codex:
                Self.tokens(snapshot.codexTokens, history: snapshot.codexHistory, provider: provider,
                            referenceDate: referenceDate, calendar: calendar, aggregationNote: "All workspaces")
            case .claude:
                Self.tokens(snapshot.claudeTokens, history: snapshot.claudeHistory, provider: provider,
                            referenceDate: referenceDate, calendar: calendar)
            case .cursor:
                Self.cursor(snapshot.cursorCosts, referenceDate: referenceDate, calendar: calendar)
            case .deepseek:
                Self.deepseek(snapshot.deepseekUsage, referenceDate: referenceDate, calendar: calendar)
            }
        }
    }

    /// Widget modules never infer workspace activity from provider-wide totals.
    init(snapshot: UsageSnapshot, composition: WidgetComposition, referenceDate: Date, calendar: Calendar = .current) {
        let accounts = WidgetModuleCatalog.accounts(in: snapshot)
        items = composition.items.map { module in
            var item: WidgetActivityItem
            switch module.provider {
            case .codex:
                let accountID = module.isCodexWorkspace
                    ? String(module.id.dropFirst(WidgetModuleCatalog.workspacePrefix.count)) : nil
                let account = accountID.flatMap { id in accounts.first(where: { $0.id == id }) }
                let scopeLabel = module.fullWorkspaceName ?? module.workspaceName ?? "Unselected workspace"
                if let activity = account?.tokenActivity {
                    item = Self.accountTokens(activity, expectedScope: account?.workspaceAccountIDHash,
                                              scopeLabel: scopeLabel, referenceDate: referenceDate, calendar: calendar)
                } else {
                    item = Self.tokens(
                        account?.tokens ?? .unavailable("Today's token usage has not been attributed to this workspace."),
                        history: account?.history ?? .unavailable("Token history has not been attributed to this workspace."),
                        provider: .codex, referenceDate: referenceDate, calendar: calendar, scopeLabel: scopeLabel)
                }
            case .claude:
                item = Self.tokens(snapshot.claudeTokens, history: snapshot.claudeHistory, provider: .claude,
                                   referenceDate: referenceDate, calendar: calendar)
            case .cursor:
                item = Self.cursor(snapshot.cursorCosts, referenceDate: referenceDate, calendar: calendar)
            case .deepseek:
                item = Self.deepseek(snapshot.deepseekUsage, referenceDate: referenceDate, calendar: calendar)
            }
            item.moduleID = module.id
            return item
        }
    }

    private static func accountTokens(_ reading: UsageValue<CodexAccountTokenActivity>, expectedScope: String?,
                                      scopeLabel: String, referenceDate: Date, calendar: Calendar) -> WidgetActivityItem {
        let presentation = CodexAccountTokenPresentation(reading, expectedScope: expectedScope,
                                                        relativeTo: referenceDate, calendar: calendar)
        let status = WidgetCardStatus(presentation.status)
        return WidgetActivityItem(provider: .codex, value: presentation.value, compactValue: presentation.value,
            caption: presentation.caption, detail: presentation.status.severity == .normal ? nil : presentation.status.label,
            aggregationNote: nil, status: status, history: presentation.history,
            historyLabel: presentation.historyLabel,
            // The chart's default calendar preserves date labels; the service supplies no source time zone.
            historyTimeZoneIdentifier: nil,
            historyStatus: presentation.history == nil ? nil : status,
            accessibilityText: ["Codex", scopeLabel, presentation.countDescription,
                                presentation.timingDescription, presentation.status.detail]
                .filter { !$0.isEmpty }.joined(separator: " · "),
            fetchedAtLabel: presentation.fetchedAtLabel)
    }

    private static func tokens<T: DailyTokenTotals>(
        _ reading: UsageValue<T>, history: UsageValue<TokenHistory<T>>, provider: MeterProvider,
        referenceDate: Date, calendar: Calendar, aggregationNote: String? = nil, scopeLabel: String? = nil
    ) -> WidgetActivityItem {
        let data: UsageValue<T>
        if (reading.value?.totalTokens ?? 0) < 0 {
            data = hidden(reading, message: "Today's token count is unavailable.")
        } else {
            data = datedDailyReading(reading, referenceDate: referenceDate, calendar: calendar)
        }
        let daily = DailyTokenPresentation(data, relativeTo: referenceDate, calendar: calendar)
        let trend = tokenHistory(history, referenceDate: referenceDate, calendar: calendar)
        let count = daily.data.value.map { "\($0.totalTokens.formatted(.number.locale(UsageFormatting.locale))) tokens today" }
            ?? "Today's tokens unavailable"
        let description = [provider.displayName, scopeLabel, aggregationNote, count, daily.status.detail]
            .compactMap { $0 }.joined(separator: " · ")
        return WidgetActivityItem(provider: provider, value: daily.value, compactValue: daily.value, caption: "tokens today",
                                  detail: daily.status.severity == .normal ? nil : daily.status.label,
                                  aggregationNote: aggregationNote, status: WidgetCardStatus(daily.status),
                                  history: trend.days, historyLabel: "Last 7 days",
                                  historyTimeZoneIdentifier: trend.calendar.timeZone.identifier,
                                  historyStatus: WidgetCardStatus(trend.status), accessibilityText: description)
    }

    private static func cursor(_ reading: UsageValue<CursorCostTotals>, referenceDate: Date,
                               calendar: Calendar) -> WidgetActivityItem {
        var data = datedDailyReading(reading, referenceDate: referenceDate, calendar: calendar)
        let amount = data.value?.todayCostUSD
        if data.value != nil, amount.map({ $0.isFinite && $0 >= 0 }) != true {
            data = hidden(data, message: "Today's actual charge is unavailable.")
        }
        let status = UsageStatusPresentation(data, relativeTo: referenceDate)
        let value = UsageFormatting.usd(data.value?.todayCostUSD, minimumDigits: 2, maximumDigits: 2)
        let exactValue = UsageFormatting.usd(data.value?.todayCostUSD, minimumDigits: 2, maximumDigits: 4)
        return WidgetActivityItem(provider: .cursor, value: value, compactValue: compactUSD(data.value?.todayCostUSD),
                                  caption: "actual charge today",
                                  detail: status.severity == .normal ? nil : status.label,
                                  aggregationNote: nil, status: WidgetCardStatus(status), history: nil,
                                  historyLabel: nil, historyTimeZoneIdentifier: nil, historyStatus: nil,
                                  accessibilityText: "Cursor · \(exactValue) actual charge today · \(status.detail)")
    }

    private static func deepseek(_ reading: UsageValue<DeepSeekUsageTotals>, referenceDate: Date,
                                 calendar: Calendar) -> WidgetActivityItem {
        var data = reading
        if reading.value == nil, reading.status == .ready {
            data = hidden(reading, message: "This month's activity is unavailable.")
        }
        if reading.source != .preview, reading.value != nil,
           reading.measuredAt.map({ $0 <= referenceDate && calendar.isDate($0, equalTo: referenceDate, toGranularity: .month) }) != true {
            data = hidden(reading, message: "This month's activity is awaiting refresh.")
        }
        let tokens = data.value?.monthTokens.flatMap { $0 >= 0 ? $0 : nil }
        let calls = data.value?.monthRequests.flatMap { $0 >= 0 ? $0 : nil }
        if data.value != nil, tokens == nil, calls == nil {
            data = hidden(data, message: "This month's activity is unavailable.")
        }
        let status = UsageStatusPresentation(data, relativeTo: referenceDate)
        let value = UsageFormatting.tokens(tokens ?? calls)
        let caption = tokens != nil ? "tokens this month" : calls != nil ? "calls this month" : "activity this month"
        let detail = tokens != nil ? calls.map { "\(UsageFormatting.tokens($0)) calls this month" } : nil
        let description = ["DeepSeek", "\(value) \(caption)", detail, status.detail].compactMap { $0 }.joined(separator: " · ")
        return WidgetActivityItem(provider: .deepseek, value: value, compactValue: value, caption: caption, detail: detail,
                                  aggregationNote: nil, status: WidgetCardStatus(status), history: nil,
                                  historyLabel: nil, historyTimeZoneIdentifier: nil, historyStatus: nil,
                                  accessibilityText: description)
    }

    private static func datedDailyReading<T>(
        _ data: UsageValue<T>, referenceDate: Date, calendar: Calendar
    ) -> UsageValue<T> {
        if data.value == nil, data.status == .ready { return hidden(data, message: "Today's usage is unavailable.") }
        guard data.source != .preview, data.value != nil else { return data }
        guard let measuredAt = data.measuredAt, measuredAt <= referenceDate,
              calendar.isDate(measuredAt, inSameDayAs: referenceDate) else {
            return hidden(data, message: "Today's usage is awaiting refresh.")
        }
        return data
    }

    private struct HistoryProjection {
        let days: [WidgetActivityDay]
        let calendar: Calendar
        let status: UsageStatusPresentation
    }

    private static func tokenHistory<T: DailyTokenTotals>(
        _ reading: UsageValue<TokenHistory<T>>, referenceDate: Date, calendar: Calendar
    ) -> HistoryProjection {
        var historyCalendar = calendar
        let validTimeZone = reading.value.flatMap { TimeZone(identifier: $0.timeZoneIdentifier) }
        if let validTimeZone { historyCalendar.timeZone = validTimeZone }
        let today = historyCalendar.startOfDay(for: referenceDate)
        let dates = (-6...0).compactMap { historyCalendar.date(byAdding: .day, value: $0, to: today) }
        var data = reading
        let validMeasurement = reading.source == .preview
            || reading.measuredAt.map { $0 <= referenceDate } == true
        let canUseHistory = reading.value != nil && validTimeZone != nil && validMeasurement
            && reading.status != .unavailable && reading.status != .unauthenticated
        if !canUseHistory, reading.value != nil {
            data = hidden(reading, message: validTimeZone == nil ? "History time zone is unavailable." : "History is awaiting refresh.")
        } else if !canUseHistory, reading.status == .ready {
            data = hidden(reading, message: "History is unavailable.")
        } else if reading.source != .preview, let measuredAt = reading.measuredAt,
                  !historyCalendar.isDate(measuredAt, inSameDayAs: referenceDate), !reading.isStale {
            data = UsageValue(status: .stale, source: .cache, measuredAt: measuredAt,
                              lastAttemptAt: reading.lastAttemptAt, message: "History is awaiting today's refresh.", value: reading.value)
        }
        let historyDays = canUseHistory ? reading.value?.days ?? [] : []
        let grouped = Dictionary(grouping: historyDays.filter { $0.date <= referenceDate }) {
            historyCalendar.startOfDay(for: $0.date)
        }
        let days = dates.map { date -> WidgetActivityDay in
            let values = grouped[date]?.map { $0.totals.totalTokens } ?? []
            let known = Set(values.filter { $0 >= 0 })
            // Conflicting/invalid duplicate readings are unknown, never added together.
            let value = known.count == 1 && values.allSatisfy({ $0 >= 0 }) ? known.first : nil
            return WidgetActivityDay(date: date, value: value)
        }
        if days.allSatisfy({ $0.value == nil }), data.status == .ready {
            data = hidden(data, message: "No known token readings in the last seven days.")
        }
        return HistoryProjection(days: days, calendar: historyCalendar,
                                 status: UsageStatusPresentation(data, relativeTo: referenceDate))
    }

    private static func hidden<T>(_ data: UsageValue<T>, message: String) -> UsageValue<T> {
        UsageValue(status: .unavailable, source: .none, measuredAt: nil,
                   lastAttemptAt: data.lastAttemptAt, message: message, value: nil)
    }

    private static func compactUSD(_ amount: Double?) -> String {
        guard let amount, amount.isFinite, amount >= 0 else { return "—" }
        let scale: Double
        let suffix: String
        switch amount {
        case 1_000_000_000...: scale = 1_000_000_000; suffix = "B"
        case 1_000_000...: scale = 1_000_000; suffix = "M"
        case 1_000...: scale = 1_000; suffix = "K"
        default: return UsageFormatting.usd(amount, minimumDigits: 2, maximumDigits: 2)
        }
        return UsageFormatting.usd(amount / scale, minimumDigits: 0, maximumDigits: 1) + suffix
    }
}
