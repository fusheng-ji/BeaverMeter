import Foundation

struct WidgetQuotaWindow: Identifiable {
    let id: String
    let label: String
    let percent: String
    let reset: String
}

/// A quota-only projection. Every account keeps its own allowance windows and status.
struct WidgetProviderPresentation {
    let provider: MeterProvider
    let status: WidgetCardStatus
    let value: String
    let compactValue: String
    let valueDescription: String
    let planName: String?
    let period: String
    let reset: String?
    let windows: [WidgetQuotaWindow]

    init(snapshot: UsageSnapshot, provider: MeterProvider, referenceDate: Date, calendar: Calendar = .current) {
        switch provider {
        case .codex:
            let firstAccount = snapshot.codexAccounts.value?.first
            // Ordinary service cards preserve the existing quota fallback. Explicit workspace cards below never fall back.
            let selectedAccount = firstAccount?.quota.value != nil ? firstAccount : nil
            self.init(provider: provider, quota: selectedAccount?.quota ?? snapshot.codexQuota,
                      accountName: selectedAccount?.displayName, planName: firstAccount?.planName,
                      referenceDate: referenceDate)
        case .claude:
            self.init(provider: provider,
                      quota: ClaudeQuotaVisibility.quota(snapshot.claudeQuota, relativeTo: referenceDate),
                      referenceDate: referenceDate)
        case .cursor:
            self.init(provider: provider, quota: snapshot.cursorQuota, referenceDate: referenceDate)
        case .deepseek:
            self.init(balance: snapshot.deepseekUsage, referenceDate: referenceDate)
        }
    }

    /// Explicit workspace cards never inherit the default quota or any sibling account data.
    init(codexAccount account: CodexAccountUsage, referenceDate: Date, calendar: Calendar = .current) {
        self.init(provider: .codex, quota: account.quota,
                  accountName: account.displayName, planName: account.planName, referenceDate: referenceDate)
    }

    private init(balance data: UsageValue<DeepSeekUsageTotals>, referenceDate: Date) {
        let primaryBalance = data.value?.balances.first {
            Self.nonempty($0.currency) != nil && $0.amount.isFinite
        }
        let status = WidgetCardStatus(UsageStatusPresentation(data, relativeTo: referenceDate))
        let value = UsageFormatting.money(primaryBalance)
        self.provider = .deepseek
        self.status = status
        self.value = value
        self.compactValue = Self.compactMoney(primaryBalance)
        self.valueDescription = ["DeepSeek", "\(value) balance", status.detail].joined(separator: " · ")
        self.planName = nil
        self.period = "Balance"
        self.reset = nil
        self.windows = []
    }

    private init(provider: MeterProvider, quota data: UsageValue<CompactQuota>,
                 accountName: String? = nil, planName: String? = nil, referenceDate: Date) {
        let quota = provider == .claude ? data.value?.claudeWidgetQuota : data.value
        let planName = Self.normalizedPlan(planName) ?? Self.normalizedPlan(quota?.planName)
            ?? Self.normalizedPlan(data.value?.planName)
        let status = WidgetCardStatus(UsageStatusPresentation(data, relativeTo: referenceDate))
        let value: String
        let compactValue: String
        let period: String
        if provider == .cursor {
            let balance = Self.finite(quota?.remaining).map { DeepSeekMoney(currency: "USD", amount: $0) }
            value = UsageFormatting.money(balance)
            compactValue = Self.compactMoney(balance)
            period = "Monthly"
        } else {
            value = Self.percent(quota?.remainingPercent)
            compactValue = value
            switch quota?.windowSeconds {
            case 18_000: period = "5h"
            case 604_800: period = "Weekly"
            default: period = quota?.label ?? "Quota"
            }
        }
        let reset = quota?.resetAt.map { UsageFormatting.resetCountdown($0, relativeTo: referenceDate) }
        let windows = provider == .cursor ? [] : Self.keyWindows(quota, referenceDate: referenceDate)
        self.provider = provider
        self.status = status
        self.value = value
        self.compactValue = compactValue
        self.valueDescription = ([provider.displayName, Self.nonempty(accountName), planName, "\(value) remaining", period,
                                  reset, status.detail].compactMap { $0 }
            + windows.map { "\($0.label): \($0.percent) remaining · \($0.reset)" }).joined(separator: " · ")
        self.period = period
        self.planName = planName
        self.reset = reset
        self.windows = windows
    }

    /// Keep only the other principal limit: five hours or the all-model weekly window.
    private static func keyWindows(_ quota: CompactQuota?, referenceDate: Date) -> [WidgetQuotaWindow] {
        guard let quota, let window = quota.otherWindows.first(where: {
            ($0.windowSeconds == 18_000 || $0.windowSeconds == 604_800)
                && $0.windowSeconds != quota.windowSeconds && $0.modelScope == nil
        }) else { return [] }
        return [WidgetQuotaWindow(id: window.label, label: window.windowTitle,
                                  percent: percent(window.remainingPercent),
                                  reset: UsageFormatting.resetCountdown(window.resetAt, relativeTo: referenceDate))]
    }

    private static func percent(_ value: Double?) -> String {
        guard let value = finite(value) else { return "—" }
        return "\(Int(min(max(value, 0), 100).rounded()))%"
    }

    private static func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
    private static func normalizedPlan(_ value: String?) -> String? {
        nonempty(value?.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private static func nonempty(_ value: String?) -> String? {
        value.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    private static func compactMoney(_ money: DeepSeekMoney?) -> String {
        guard let money, money.amount.isFinite, nonempty(money.currency) != nil else { return "—" }
        let magnitude = abs(money.amount)
        let unit: (divisor: Double, suffix: String)
        switch magnitude {
        case 1_000_000_000...: unit = (1_000_000_000, "B")
        case 1_000_000...: unit = (1_000_000, "M")
        case 1_000...: unit = (1_000, "K")
        default:
            guard magnitude >= 1 else { return UsageFormatting.money(money) }
            let formatter = NumberFormatter()
            formatter.locale = UsageFormatting.locale
            formatter.numberStyle = .currency
            formatter.currencyCode = money.currency
            formatter.usesSignificantDigits = true
            formatter.minimumSignificantDigits = 1
            formatter.maximumSignificantDigits = 3
            formatter.usesGroupingSeparator = false
            return formatter.string(from: NSNumber(value: money.amount)) ?? UsageFormatting.money(money)
        }
        let formatter = NumberFormatter()
        formatter.locale = UsageFormatting.locale
        formatter.numberStyle = .currency
        formatter.currencyCode = money.currency
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        formatter.usesGroupingSeparator = false
        guard let scaled = formatter.string(from: NSNumber(value: money.amount / unit.divisor)) else {
            return UsageFormatting.money(money)
        }
        return scaled + unit.suffix
    }
}
