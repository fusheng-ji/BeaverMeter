import SwiftUI

/// Safety insets stay fixed; optional detail yields before essential quota.
struct AdaptiveProviderCard: View {
    let presentation: WidgetProviderPresentation
    let size: ProviderWidgetSize
    let providerCount: Int
    var workspaceName: String?
    var fullWorkspaceName: String?
    var activity: WidgetActivityItem? = nil

    private var title: String { workspaceName ?? presentation.provider.displayName }
    private var fullTitle: String { fullWorkspaceName ?? title }
    private var accessibilityTitle: String {
        #if WIDGET_QA
        let spacing = WidgetSpacingPolicy(size: size, cardCount: providerCount)
        return "\(fullTitle); safeInsets: \(spacing.horizontalPadding),\(spacing.verticalPadding); detailLevel: adaptive"
        #else
        return fullTitle
        #endif
    }
    private var window: WidgetQuotaWindow? { presentation.windows.first }
    private var isMoney: Bool { presentation.provider == .cursor || presentation.provider == .deepseek }

    var body: some View {
        GeometryReader { geometry in
            let plan = WidgetContentPlan(provider: presentation.provider, size: size,
                providerCount: providerCount, cardSize: geometry.size,
                hasSubscription: presentation.planName != nil)
            let centered = size == .extraLarge && providerCount <= 3 && plan.layout == .tile
                && presentation.provider == .antigravity && activity == nil
            let alignment: Alignment = centered ? .leading
                : plan.layout == .tile || plan.layout == .column || plan.layout == .compact ? .topLeading : .leading
            fittedContent(plan)
                .frame(width: plan.contentWidth, height: plan.contentHeight, alignment: alignment)
                .padding(.horizontal, plan.horizontalPadding)
                .padding(.vertical, plan.verticalPadding)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .modifier(WidgetCardSurface(provider: presentation.provider, cornerRadius: plan.cornerRadius))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle)
        .help("\(fullTitle) · \(presentation.valueDescription)")
    }

    private func fittedContent(_ plan: WidgetContentPlan) -> some View {
        ViewThatFits(in: [.horizontal, .vertical]) {
            variant(plan, .full)
            variant(plan, .withoutActivityDetails)
            variant(plan, .withoutActivity)
            variant(plan, .withoutWindowReset)
            variant(plan, .withoutSubscription)
            variant(plan, .primaryOnly)
        }
    }

    private func variant(_ plan: WidgetContentPlan, _ level: WidgetCardDetailLevel) -> some View {
        content(plan, level).fixedSize(horizontal: false, vertical: true)
            .modifier(WidgetFitChoiceQA(level: level))
    }

    @ViewBuilder private func content(_ plan: WidgetContentPlan, _ level: WidgetCardDetailLevel) -> some View {
        switch plan.layout {
        case .wideRow: wideRow(plan, level)
        case .compact: identityAndQuotaRow(plan, level, prominentSecondary: false)
        case .tile:
            VStack(alignment: .leading, spacing: plan.spacing) {
                identityAndQuotaRow(plan, level, prominentSecondary: true)
                moduleActivity(level)
            }
        case .dashboard: dashboard(plan, level)
        case .hero, .column: stacked(plan, level)
        }
    }

    private func wideRow(_ plan: WidgetContentPlan, _ level: WidgetCardDetailLevel) -> some View {
        HStack(spacing: plan.columnSpacing) {
            header(plan, level).frame(width: plan.identityColumnWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: plan.columnSpacing) {
                    primaryMetric(plan, level)
                        .frame(width: isMoney ? plan.mergedMetricWidth : plan.metricColumnWidth, alignment: .leading)
                    if let window, !isMoney, level.showsSecondaryWindow {
                        metric(value: window.percent, compactValue: window.percent,
                               period: shortPeriod(window.label), reset: level.showsWindowReset ? window.reset : nil,
                               valueSize: plan.secondaryValueSize, detailSize: plan.detailSize,
                               accessibilityReset: window.reset, inlineReset: level == .primaryOnly)
                            .frame(width: plan.metricColumnWidth, alignment: .leading)
                    }
                }
                if size == .large, level.showsActivity, let activity {
                    WidgetActivitySummary(item: activity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stacked(_ plan: WidgetContentPlan, _ level: WidgetCardDetailLevel) -> some View {
        VStack(alignment: .leading, spacing: plan.spacing) {
            header(plan, level)
            if size == .extraLarge {
                HStack(alignment: .firstTextBaseline, spacing: plan.columnSpacing) {
                    primaryMetric(plan, level, inlineReset: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let window, !isMoney, level.showsSecondaryWindow {
                        metric(value: window.percent, compactValue: window.percent,
                               period: shortPeriod(window.label), reset: level.showsWindowReset ? window.reset : nil,
                               valueSize: plan.secondaryValueSize, detailSize: plan.detailSize,
                               accessibilityReset: window.reset, inlineReset: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                primaryMetric(plan, level)
                if let window, level.showsSecondaryWindow {
                    secondaryWindow(window, plan: plan, level: level, valueSize: plan.secondaryValueSize)
                }
            }
            moduleActivity(level)
        }
    }

    private func dashboard(_ plan: WidgetContentPlan, _ level: WidgetCardDetailLevel) -> some View {
        VStack(alignment: .leading, spacing: level.showsActivity && activity != nil ? 10 : 0) {
            HStack(alignment: .top, spacing: plan.dashboardColumnSpacing) {
                header(plan, level).frame(width: plan.dashboardIdentityWidth, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: plan.dashboardColumnSpacing) {
                    primaryMetric(plan, level)
                    if let window, !isMoney, level.showsSecondaryWindow {
                        metric(value: window.percent, compactValue: window.percent,
                               period: shortPeriod(window.label), reset: level.showsWindowReset ? window.reset : nil,
                               valueSize: plan.secondaryValueSize, detailSize: plan.detailSize,
                               accessibilityReset: window.reset)
                    }
                }
                .frame(width: plan.dashboardMetricWidth, alignment: .leading)
            }
            if level.showsActivity, let activity {
                VStack(alignment: .leading, spacing: 8) {
                    Divider().opacity(0.4)
                    WidgetActivitySummary(item: activity, layout: .footer)
                }
            }
        }
    }

    private func identityAndQuotaRow(_ plan: WidgetContentPlan, _ level: WidgetCardDetailLevel,
                                     prominentSecondary: Bool) -> some View {
        HStack(alignment: .top, spacing: plan.sideColumnSpacing) {
            header(plan, level).frame(width: plan.sideIdentityColumnWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: plan.spacing) {
                primaryValue(plan)
                periodReset(presentation.period == "Weekly" ? "Wk" : presentation.period,
                            reset: presentation.reset, size: plan.detailSize, inline: level == .primaryOnly)
                    .modifier(WidgetMetricAccessibility(label:
                        [presentation.period, presentation.reset].compactMap { $0 }.joined(separator: ", ")))
                if let window, level.showsSecondaryWindow {
                    secondaryWindow(window, plan: plan, level: level,
                                    valueSize: prominentSecondary ? plan.secondaryValueSize : nil)
                }
            }
            .frame(width: plan.sideMetricColumnWidth, alignment: .leading)
        }
    }

    @ViewBuilder private func moduleActivity(_ level: WidgetCardDetailLevel) -> some View {
        if (size == .large || size == .extraLarge), level.showsActivity, let activity {
            WidgetActivitySummary(item: activity,
                showsHistory: level.showsActivityDetails && WidgetContentPlan.showsActivityHistory(size: size, providerCount: providerCount),
                showsDetails: level.showsActivityDetails && size == .extraLarge)
        }
    }

    private func header(_ plan: WidgetContentPlan, _ level: WidgetCardDetailLevel) -> some View {
        let subscription = level.showsSubscription ? presentation.planName : nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                ProviderLogoView(provider: presentation.provider, size: plan.logoSize)
                    .modifier(WidgetLeafQAIdentity(kind: "logo", detailLevel: level))
                if presentation.status.severity != .normal {
                    WidgetStatusIcon(status: presentation.status, size: 8)
                        .modifier(WidgetLeafQAIdentity(kind: "status"))
                }
            }
            secondary(title, size: plan.titleSize)
                .help(fullTitle).accessibilityLabel(fullTitle)
            if let subscription {
                secondary(subscription, size: plan.subscriptionSize)
                    .help("Subscription plan: \(subscription)")
                    .accessibilityLabel("Subscription plan: \(subscription)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: plan.identityHeaderHeight(showsSubscription: subscription != nil), alignment: .topLeading)
    }

    private func primaryValue(_ plan: WidgetContentPlan) -> some View {
        WidgetPrimaryValue(full: presentation.value, compact: presentation.compactValue, size: plan.valueSize,
                           moneyCurrencyCode: presentation.moneyCurrencyCode,
                           compactMoneyAmount: presentation.compactMoneyAmount, currencySize: plan.detailSize)
    }

    private func primaryMetric(_ plan: WidgetContentPlan, _ level: WidgetCardDetailLevel,
                               inlineReset: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            primaryValue(plan)
            periodReset(presentation.period, reset: presentation.reset, size: plan.detailSize,
                        inline: inlineReset || level == .primaryOnly)
        }
        .modifier(WidgetMetricAccessibility(label:
            ["\(presentation.period), \(presentation.value) \(isMoney && presentation.provider == .deepseek ? "balance" : "remaining")",
             presentation.reset].compactMap { $0 }.joined(separator: ", ")))
    }

    private func metric(value: String, compactValue: String, period: String, reset: String?,
                        valueSize: CGFloat, detailSize: CGFloat, accessibilityReset: String? = nil,
                        inlineReset: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            WidgetPrimaryValue(full: value, compact: compactValue, size: valueSize)
            periodReset(period, reset: reset, size: detailSize, inline: inlineReset)
        }
        .modifier(WidgetMetricAccessibility(label:
            ["\(period), \(value) remaining", accessibilityReset ?? reset].compactMap { $0 }.joined(separator: ", ")))
    }

    @ViewBuilder private func periodReset(_ period: String, reset: String?, size: CGFloat,
                                          inline: Bool = false) -> some View {
        if inline {
            secondary(periodText(period, reset: reset), size: size)
        } else {
            ViewThatFits(in: .horizontal) {
                secondary(periodText(period, reset: reset), size: size).fixedSize()
                VStack(alignment: .leading, spacing: 0) {
                    secondary(shortPeriod(period), size: size)
                    if let reset { secondary(compactReset(reset), size: size) }
                }
            }
        }
    }

    private func secondaryWindow(_ window: WidgetQuotaWindow, plan: WidgetContentPlan,
                                 level: WidgetCardDetailLevel, valueSize: CGFloat? = nil) -> some View {
        ViewThatFits(in: .horizontal) {
            if plan.showsWindowResets && level.showsWindowReset {
                windowText(window, size: plan.detailSize, includesReset: true, valueSize: valueSize).fixedSize()
                VStack(alignment: .leading, spacing: 1) {
                    windowText(window, size: plan.detailSize, includesReset: false, valueSize: valueSize)
                    secondary(compactReset(window.reset), size: plan.detailSize)
                }.fixedSize()
            }
            windowText(window, size: plan.detailSize, includesReset: false, valueSize: valueSize)
        }
        .help("\(window.label), \(window.percent) remaining, \(window.reset)")
        .modifier(WidgetMetricAccessibility(label: "\(window.label), \(window.percent) remaining, \(window.reset)"))
    }

    private func windowText(_ window: WidgetQuotaWindow, size: CGFloat, includesReset: Bool,
                            valueSize: CGFloat?) -> some View {
        (Text("\(window.label == "Weekly" ? "Wk" : shortPeriod(window.label)) ")
         + Text(window.percent).font(.system(size: valueSize ?? size, weight: .semibold, design: .rounded))
         + Text(includesReset ? " · \(compactReset(window.reset))" : ""))
            .font(.system(size: size, weight: .medium, design: .rounded))
            .monospacedDigit().modifier(WidgetSecondaryText()).lineLimit(1)
    }

    private func shortPeriod(_ text: String) -> String { text == "5-hour" ? "5h" : text }
    private func periodText(_ period: String, reset: String?) -> String {
        shortPeriod(period) + (reset.map { " · \(compactReset($0))" } ?? "")
    }
    private func compactReset(_ text: String) -> String {
        if text == "Reset unavailable" { return "↻ —" }
        if text == "Reset pending" { return "↻ pending" }
        return text.hasPrefix("Resets in ") ? "↻ \(text.dropFirst("Resets in ".count).replacingOccurrences(of: " ", with: ""))" : text
    }
    private func secondary(_ text: String, size: CGFloat, lines: Int = 1) -> some View {
        Text(text).font(.system(size: size, weight: .medium, design: .rounded))
            .modifier(WidgetSecondaryText()).lineLimit(lines)
    }
}
