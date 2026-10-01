import SwiftUI

enum QuotaProviderKind {
    case codex
    case claude
    case cursor

    var name: String {
        switch self {
        case .codex: "CODEX"
        case .claude: "CLAUDE"
        case .cursor: "CURSOR"
        }
    }

    var icon: String {
        switch self {
        case .codex: "sparkles"
        case .claude: "asterisk"
        case .cursor: "cursorarrow"
        }
    }

    var accent: Color {
        switch self {
        case .codex: Color(red: 0.20, green: 0.88, blue: 0.75)
        case .claude: Color(red: 0.93, green: 0.51, blue: 0.36)
        case .cursor: Color(red: 0.48, green: 0.42, blue: 1.00)
        }
    }

}

enum QuotaPanelDensity {
    case strip
    case compact
    case regular
    /// A service with a tile or full row to itself.
    case hero

    var padding: CGFloat {
        switch self {
        case .strip: 6
        case .compact: 6
        case .regular: 12
        case .hero: 16
        }
    }

    var spacing: CGFloat {
        switch self {
        case .strip: 2
        case .compact: 2
        case .regular: 6
        case .hero: 8
        }
    }

    var valueSize: CGFloat {
        switch self {
        case .strip: 17
        case .compact: 20
        case .regular: 30
        case .hero: 52
        }
    }
}

struct QuotaProviderPanel: View {
    let provider: QuotaProviderKind
    let data: UsageValue<CompactQuota>
    let density: QuotaPanelDensity
    var dailyTokens: DailyTokenSummary?
    var referenceDate: Date = .now

    private var quota: CompactQuota? { data.value }
    private var cornerRadius: CGFloat { density == .strip || density == .compact ? 13 : 18 }
    private var remainingPercent: Double? {
        UsageFormatting.clampedPercent(quota?.remainingPercent)
    }

    private var progressColor: Color {
        guard let remainingPercent else { return provider.accent }
        if remainingPercent < 20 { return Color(red: 1.00, green: 0.31, blue: 0.31) }
        if remainingPercent < 50 { return Color(red: 1.00, green: 0.68, blue: 0.20) }
        return provider.accent
    }

    private var valueText: String {
        switch provider {
        case .codex, .claude:
            guard let remainingPercent else { return "—" }
            return "\(Int(remainingPercent.rounded()))%"
        case .cursor:
            return UsageFormatting.usd(quota?.remaining, minimumDigits: 2, maximumDigits: 2)
        }
    }

    private var detailText: String {
        guard let quota else { return data.message ?? UsageFormatting.status(data.status) }
        switch provider {
        case .codex:
            return quotaPeriod(windowSeconds: quota.windowSeconds)
        case .claude:
            let period = quotaPeriod(windowSeconds: quota.windowSeconds)
            return modelScope.map { "\($0) \(period.lowercased())" } ?? period
        case .cursor:
            if let used = quota.used, let limit = quota.limit {
                return "\(UsageFormatting.usdCode(used)) / \(UsageFormatting.usdCode(limit))"
            }
            return quota.detail.isEmpty ? "Monthly quota" : quota.detail
        }
    }

    /// Claude's model-scoped weekly lanes share the 7-day window with the overall lane.
    private var modelScope: String? { quota?.modelScope }

    private var otherWindows: [CompactQuota] { quota?.otherWindows ?? [] }

    /// Names the headline window when the detail line is about the others.
    private var valueSuffix: String {
        otherWindows.isEmpty ? "remaining" : "\(quota?.shortWindowName ?? "") left"
    }

    /// "Weekly 88% · Fable 95%", falling back to "Wk" where space is short.
    private func windowsSummary(short: Bool) -> String {
        quota?.otherWindowsSummary(short: short) ?? ""
    }

    private var status: UsageStatusPresentation { UsageStatusPresentation(data, relativeTo: referenceDate) }

    var body: some View {
        Group {
            if density == .strip {
                stripBody
            } else {
                standardBody
            }
        }
        .padding(density.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(panelBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .help(status.detail)
    }

    /// Built in separate steps: one long `+` chain exceeds the compiler's type-check budget.
    private var accessibilityDescription: String {
        let reset = UsageFormatting.resetCountdown(quota?.resetAt, relativeTo: referenceDate)
        var label = "\(provider.name), \(valueText) remaining, \(detailText), "
        label += "\(reset), \(status.detail)"
        for window in otherWindows {
            label += ", \(window.windowTitle) \(window.percentLeftText) remaining"
        }
        if let dailyTokens {
            label += ", " + dailyTokens.accessibilityText
        }
        return label
    }

    private var stripBody: some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            HStack(spacing: 5) {
                Image(systemName: provider.icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(provider.accent)
                Text(provider.name)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.86))
                Spacer(minLength: 3)
                Text(valueText)
                    .font(.system(size: density.valueSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            HStack(spacing: 4) {
                Image(systemName: stripStatus.icon)
                ViewThatFits(in: .horizontal) {
                    if !otherWindows.isEmpty, status.severity == .normal {
                        Text(windowsSummary(short: false)).lineLimit(1)
                        Text(windowsSummary(short: true)).lineLimit(1)
                    }
                    Text(stripDetailText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                Spacer(minLength: 2)
                QuotaProgressBar(percent: remainingPercent, tint: progressColor)
                    .frame(width: 42, height: 3)
            }
            .font(.system(size: 7, weight: .semibold, design: .rounded))
            .foregroundStyle(stripStatus.widgetColor)
        }
    }

    /// Strips fold today's tokens into the detail line so four providers fit a Small widget.
    private var stripStatus: UsageStatusPresentation {
        if status.severity == .normal, let dailyTokens, dailyTokens.status.severity != .normal {
            return dailyTokens.status
        }
        return status
    }

    private var stripDetailText: String {
        guard status.severity == .normal else { return status.label }
        guard let dailyTokens else { return detailText }
        guard dailyTokens.status.severity == .normal else {
            return "\(dailyTokens.value) tok · \(dailyTokens.warningLabel)"
        }
        let period = switch quota?.windowSeconds {
        case 18_000: "5h"
        case 604_800: modelScope.map { "\($0) week" } ?? "Week"
        default: detailText
        }
        return "\(period) · \(dailyTokens.value) tok today"
    }

    private var standardBody: some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            header
            value

            if density != .compact {
                ViewThatFits(in: .horizontal) {
                    // With several windows the value is the five-hour one and this line
                    // carries the rest, for example "Weekly 88% · Fable 95%".
                    if otherWindows.isEmpty {
                        detailLine(detailText)
                    } else {
                        detailLine(windowsSummary(short: false))
                        detailLine(windowsSummary(short: true))
                    }
                }
            }

            if density == .compact {
                HStack(spacing: 4) {
                    resetLine
                    Spacer(minLength: 0)
                    QuotaProgressBar(percent: remainingPercent, tint: progressColor)
                        .frame(width: 30, height: 3)
                }
            } else {
                resetLine
                QuotaProgressBar(percent: remainingPercent, tint: progressColor)
                    .frame(height: 4)
            }
            // Keeps today's tokens at the bottom when the panel has spare height.
            Spacer(minLength: 0)
            dailyTokenLine
        }
    }


    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: provider.icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(provider.accent)
            Text(provider.name)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.88))
            Spacer(minLength: 4)
            Label(status.label, systemImage: status.icon)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(status.widgetColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var value: some View {
        // Drops the "remaining" suffix rather than truncating when space runs out.
        ViewThatFits(in: .horizontal) {
            // Medium panels have no detail line, so the other windows sit beside the value.
            if density == .compact, !otherWindows.isEmpty, status.severity == .normal {
                valueRow(suffix: windowsSummary(short: false))
                valueRow(suffix: windowsSummary(short: true))
            }
            if density != .regular || !otherWindows.isEmpty {
                valueRow(suffix: valueSuffix)
            }
            valueRow(suffix: nil)
        }
    }

    private func valueRow(suffix: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(valueText)
                .font(.system(size: density.valueSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let suffix {
                Text(suffix)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
    }


    private func detailLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.62))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var resetLine: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock")
                .foregroundStyle(provider.accent.opacity(0.88))
            Text(UsageFormatting.resetCountdown(quota?.resetAt, relativeTo: referenceDate))
                .lineLimit(1)
        }
        .font(.system(size: 8, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.70))
    }

    @ViewBuilder
    private var dailyTokenLine: some View {
        if let presentation = dailyTokens {
            HStack(spacing: 3) {
                Text("Today")
                Text("\(presentation.value) tok").fontWeight(.semibold).monospacedDigit()
                Spacer(minLength: 0)
                if presentation.status.severity != .normal {
                    Image(systemName: presentation.status.icon)
                        .foregroundStyle(presentation.status.widgetColor)
                    Text(presentation.warningLabel).foregroundStyle(presentation.status.widgetColor)
                }
            }
            .font(.system(size: density == .strip ? 8 : 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .help(presentation.status.detail)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityText)
        }
    }

    private var panelBackground: some ShapeStyle {
        provider.accent.opacity(0.08)
    }

    private func quotaPeriod(windowSeconds: Int?) -> String {
        guard let windowSeconds else { return quota?.label ?? "Quota window" }
        switch windowSeconds {
        case 604_800: return "Weekly quota"
        case 18_000: return "5-hour quota"
        default:
            if windowSeconds.isMultiple(of: 86_400) {
                return "\(windowSeconds / 86_400)-day quota"
            }
            return quota?.label ?? "Quota window"
        }
    }
}

struct QuotaProgressBar: View {
    let percent: Double?
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.10))
                if let percent {
                    Capsule()
                        .fill(tint)
                        .frame(width: fillWidth(total: proxy.size.width, percent: percent))
                } else {
                    Capsule()
                        .fill(.white.opacity(0.16))
                        .frame(width: proxy.size.width * 0.24)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func fillWidth(total: CGFloat, percent: Double) -> CGFloat {
        guard percent > 0 else { return 0 }
        return min(total, max(4, total * percent / 100))
    }
}

extension UsageStatusPresentation {
    var widgetColor: Color {
        switch severity {
        case .normal: .white.opacity(0.68)
        case .warning: Color(red: 1.00, green: 0.74, blue: 0.32)
        case .critical: Color(red: 1.00, green: 0.44, blue: 0.42)
        }
    }
}
