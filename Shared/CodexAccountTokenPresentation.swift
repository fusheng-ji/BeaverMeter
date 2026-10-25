import Foundation

/// Compact account API activity; source periods and clocks remain available in timing details.
struct CodexAccountTokenPresentation {
    let data: UsageValue<CodexAccountTokenActivity>
    let value: String
    let caption: String
    let countDescription: String
    let history: [WidgetActivityDay]?
    let historyLabel: String?
    let status: UsageStatusPresentation
    let fetchedAtLabel: String?
    let timingDescription: String

    init(_ original: UsageValue<CodexAccountTokenActivity>, expectedScope: String?, relativeTo now: Date,
         calendar: Calendar = .current) {
        var reading = original
        var indexedDays: [Date: Int] = [:]
        var latest: (date: Date, sourceDate: String, tokens: Int)?
        if let activity = original.value {
            let days = activity.dailyUsage ?? []
            var invalid = expectedScope == nil || activity.workspaceAccountIDHash != expectedScope
                || activity.lifetimeTokens.map { $0 < 0 } == true
                || (activity.lifetimeTokens == nil && days.isEmpty)
                || original.measuredAt.map { $0 > now } != false
                || (original.source != .accountAPI && original.source != .cache && original.source != .preview)
            if !invalid {
                indexedDays.reserveCapacity(days.count)
                for day in days {
                    guard day.tokens >= 0, let date = day.calendarDate,
                          indexedDays[date].map({ $0 == day.tokens }) ?? true else {
                        invalid = true
                        break
                    }
                    indexedDays[date] = day.tokens
                    if latest == nil || date > latest!.date { latest = (date, day.date, day.tokens) }
                }
            }
            if invalid || original.status == .unauthenticated || original.status == .unavailable {
                reading = UsageValue(status: .unavailable, source: .none, measuredAt: nil,
                    lastAttemptAt: original.lastAttemptAt,
                    message: "Verified workspace token activity is unavailable.", value: nil)
                indexedDays.removeAll(keepingCapacity: false)
                latest = nil
            }
        } else if original.status == .ready {
            reading = UsageValue(status: .unavailable, source: .none, measuredAt: nil,
                lastAttemptAt: original.lastAttemptAt, message: "Workspace token activity is unavailable.", value: nil)
        }
        if reading.value != nil, reading.status == .ready,
           reading.measuredAt.map({ now.timeIntervalSince($0) > 3 * 60 * 60 }) == true {
            reading = UsageValue(status: .stale, source: .cache, measuredAt: reading.measuredAt,
                lastAttemptAt: reading.lastAttemptAt,
                message: "Last workspace token reading; awaiting refresh.", value: reading.value)
        }
        data = reading
        status = UsageStatusPresentation(reading, relativeTo: now)
        var timing: [String] = []
        if let latest { timing.append("Service bucket date \(latest.sourceDate)") }
        if let asOf = reading.value?.statsAsOf { timing.append("Service report date \(asOf)") }
        if let fetchedAt = reading.measuredAt {
            let clock = Self.clockLabels(fetchedAt, calendar: calendar)
            fetchedAtLabel = reading.value == nil ? nil
                : "Fetched \(calendar.isDate(fetchedAt, inSameDayAs: now) ? clock.time : clock.datedTime)"
            timing.append("Fetched \(clock.preciseTime)")
        } else { fetchedAtLabel = nil }
        if let generatedAt = reading.value?.serviceGeneratedAt {
            timing.append("Response generated \(Self.clockLabels(generatedAt, calendar: calendar).preciseTime)")
        }
        timingDescription = timing.joined(separator: " · ")
        if let latest {
            let calendar = CodexAccountTokenDay.labelCalendar
            let label = CodexAccountTokenDay.label(latest.date,
                includeYear: calendar.component(.year, from: latest.date) != calendar.component(.year, from: now))
            value = UsageFormatting.tokens(latest.tokens)
            caption = "tokens today"
            countDescription = "\(latest.tokens.formatted(.number.locale(UsageFormatting.locale))) tokens today"
            history = (-6...0).map { offset in
                let date = latest.date.addingTimeInterval(Double(offset) * 86_400)
                return WidgetActivityDay(date: date, value: indexedDays[date])
            }
            historyLabel = "7 days through \(label)"
        } else if let count = reading.value?.lifetimeTokens {
            value = UsageFormatting.tokens(count)
            caption = "tokens total"
            countDescription = "\(count.formatted(.number.locale(UsageFormatting.locale))) lifetime tokens"
            history = nil
            historyLabel = nil
        } else {
            value = "—"
            caption = "tokens"
            countDescription = "Workspace tokens unavailable"
            history = nil
            historyLabel = nil
        }
    }

    private static let clockLocale = Locale(identifier: "en_US_POSIX")

    private static func clockLabels(_ date: Date, calendar: Calendar) -> (time: String, datedTime: String, preciseTime: String) {
        if calendar.identifier != .gregorian && calendar.identifier != .iso8601 {
            // Preserve less common user calendars without maintaining a formatter cache.
            let formatter = DateFormatter()
            formatter.locale = clockLocale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "HH:mm zzz"
            let time = formatter.string(from: date)
            formatter.dateFormat = "MMM d HH:mm zzz"
            let datedTime = formatter.string(from: date)
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
            return (time, datedTime, formatter.string(from: date))
        }
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let zone = calendar.timeZone
        let name = zone.localizedName(for: zone.isDaylightSavingTime(for: date) ? .shortDaylightSaving : .shortStandard,
                                      locale: clockLocale) ?? zone.abbreviation(for: date) ?? zone.identifier
        let time = "\(padded(parts.hour ?? 0)):\(padded(parts.minute ?? 0))"
        let day = "\(CodexAccountTokenDay.abbreviatedMonth(parts.month ?? 1)) \(parts.day ?? 1)"
        let fullDay = "\(padded(parts.year ?? 1, width: 4))-\(padded(parts.month ?? 1))-\(padded(parts.day ?? 1))"
        return ("\(time) \(name)", "\(day) \(time) \(name)", "\(fullDay) \(time):\(padded(parts.second ?? 0)) \(name)")
    }

    private static func padded(_ value: Int, width: Int = 2) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}
