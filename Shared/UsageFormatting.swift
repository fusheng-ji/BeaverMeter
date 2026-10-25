import Foundation

enum UsageFormatting {
    static let locale = Locale(identifier: "en_US")
    private static let formatters = FormatterCache()
    static func tokens(_ value: Int?) -> String {
        guard let value else { return "—" }
        if value >= 1_000_000_000 {
            return String(format: value >= 10_000_000_000 ? "%.0fB" : "%.1fB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: value >= 10_000_000 ? "%.0fM" : "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: value >= 100_000 ? "%.0fK" : "%.1fK", Double(value) / 1_000)
        }
        return value.formatted(.number.locale(locale))
    }

    static func usd(_ value: Double?, minimumDigits: Int = 2, maximumDigits: Int = 4) -> String {
        guard let value else { return "—" }
        return formatters.number(value, key: "usd:\(minimumDigits):\(maximumDigits)") { formatter in
            formatter.numberStyle = .currency
            formatter.currencyCode = "USD"
            formatter.currencySymbol = "$"
            formatter.minimumFractionDigits = minimumDigits
            formatter.maximumFractionDigits = maximumDigits
        } ?? String(format: "$%.2f", value)
    }

    static func usdCode(_ value: Double) -> String {
        let minimumDigits = value.rounded() == value ? 0 : 2
        let amount = formatters.number(value, key: "usdCode:\(minimumDigits)") { formatter in
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = minimumDigits
            formatter.maximumFractionDigits = 2
            formatter.groupingSeparator = ","
        }
        return "US$" + (amount ?? String(format: "%.2f", value))
    }

    static func money(_ value: DeepSeekMoney?) -> String {
        guard let value else { return "—" }
        return formatters.number(value.amount, key: "money:\(value.currency)") { formatter in
            formatter.numberStyle = .currency
            formatter.currencyCode = value.currency
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 4
        }
            ?? "\(value.currency) \(String(format: "%.2f", value.amount))"
    }

    static func moneyList(_ values: [DeepSeekMoney]) -> String {
        values.isEmpty ? "—" : values.map(money).joined(separator: " · ")
    }

    static func firstValidMoney(_ values: [DeepSeekMoney]) -> DeepSeekMoney? {
        values.first { !$0.currency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.amount.isFinite }
    }

    static func clampedPercent(_ value: Double?) -> Double? {
        value.map { min(max($0, 0), 100) }
    }

    static func relativeAge(_ date: Date?, relativeTo now: Date = .now) -> String {
        guard let date else { return "never updated" }
        return formatters.relative(date, relativeTo: now)
    }

    static func reset(_ date: Date?) -> String? {
        guard let date else { return nil }
        if date <= .now { return "reset pending" }
        return "resets " + formatters.relative(date, relativeTo: .now)
    }

    static func resetCountdown(_ date: Date?, relativeTo now: Date = .now) -> String {
        guard let date else { return "Reset unavailable" }
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "Reset pending" }

        let totalMinutes = max(0, Int(interval / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 { return "Resets in \(days)d \(hours)h" }
        if hours > 0 { return "Resets in \(hours)h \(minutes)m" }
        if minutes > 0 { return "Resets in \(minutes)m" }
        return "Resets in <1m"
    }

    static func cacheAge(_ date: Date?, relativeTo now: Date = .now) -> String? {
        guard let date else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "Stale · <1m old" }
        if seconds < 3_600 { return "Stale · \(seconds / 60)m old" }
        if seconds < 86_400 { return "Stale · \(seconds / 3_600)h old" }
        return "Stale · \(seconds / 86_400)d old"
    }

    static func source(_ source: UsageDataSource) -> String {
        switch source {
        case .codexBarLocal: "Local logs"
        case .cursorDashboard: "Cursor Dashboard"
        case .accountAPI: "Account API"
        case .deepSeekPlatform: "DeepSeek Platform"
        case .cache: "Cached"
        case .preview: "Preview"
        case .none: "No data"
        }
    }

    static func status(_ status: UsageDataStatus) -> String {
        switch status {
        case .ready: "Live"
        case .stale: "Stale"
        case .unavailable: "No data"
        case .unauthenticated: "Sign in"
        case .error: "Error"
        }
    }

    /// Formatting and initial configuration share the lock, so cached mutable
    /// Foundation objects are never used or reconfigured concurrently.
    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private let numbers = NSCache<NSString, NumberFormatter>()
        private var relativeFormatter: RelativeDateTimeFormatter?
        private var relativeCalendar: Calendar?

        init() {
            // Currency codes and precision are caller supplied; keep their cache bounded.
            numbers.countLimit = 32
        }

        func number(_ value: Double, key: String, configure: (NumberFormatter) -> Void) -> String? {
            lock.lock()
            defer { lock.unlock() }
            let cacheKey = key as NSString
            let formatter: NumberFormatter
            if let cached = numbers.object(forKey: cacheKey) {
                formatter = cached
            } else {
                formatter = NumberFormatter()
                formatter.locale = UsageFormatting.locale
                configure(formatter)
                numbers.setObject(formatter, forKey: cacheKey)
            }
            return formatter.string(from: NSNumber(value: value))
        }

        func relative(_ date: Date, relativeTo now: Date) -> String {
            lock.lock()
            defer { lock.unlock() }
            let calendar = Calendar.current
            if relativeFormatter == nil || relativeCalendar != calendar {
                let formatter = RelativeDateTimeFormatter()
                formatter.locale = UsageFormatting.locale
                formatter.unitsStyle = .abbreviated
                relativeFormatter = formatter
                relativeCalendar = calendar
            }
            return relativeFormatter!.localizedString(for: date, relativeTo: now)
        }
    }
}
