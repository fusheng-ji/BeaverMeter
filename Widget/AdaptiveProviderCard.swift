import SwiftUI

/// Identity, remaining allowance and the corresponding reset stay together at every density.
struct AdaptiveProviderCard: View {
    let presentation: WidgetProviderPresentation
    let size: ProviderWidgetSize
    let providerCount: Int
    var workspaceName: String?
    var fullWorkspaceName: String?
    var activity: WidgetActivityItem? = nil

    private var title: String { workspaceName ?? presentation.provider.displayName }
    private var fullTitle: String { fullWorkspaceName ?? title }
    private var window: WidgetQuotaWindow? { presentation.windows.first }
    private var isMoney: Bool { presentation.provider == .cursor || presentation.provider == .deepseek }

    var body: some View {
        GeometryReader { geometry in
            let plan = WidgetContentPlan(provider: presentation.provider, size: size,
                                         providerCount: providerCount, cardSize: geometry.size,
                                         hasSubscription: presentation.planName != nil)
            content(plan)
                .padding(.horizontal, plan.horizontalPadding)
                .padding(.vertical, plan.verticalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: plan.layout == .tile || plan.layout == .column || plan.layout == .compact
                           ? .topLeading : .leading)
                .modifier(WidgetCardSurface(provider: presentation.provider, cornerRadius: plan.cornerRadius))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(fullTitle)
        .help("\(fullTitle) · \(presentation.valueDescription)")
    }

    @ViewBuilder
    private func content(_ plan: WidgetContentPlan) -> some View {
        switch plan.layout {
        case .wideRow: wideRow(plan)
        case .compact: compact(plan)
        case .tile: tile(plan)
        case .dashboard: dashboard(plan)
        case .hero, .column: stacked(plan)
        }
    }

    private func wideRow(_ plan: WidgetContentPlan) -> some View {
        HStack(spacing: plan.columnSpacing) {
            header(plan).frame(width: plan.identityColumnWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: plan.columnSpacing) {
                    metric(value: presentation.value, compactValue: presentation.compactValue,
                           period: presentation.period, reset: presentation.reset,
                           valueSize: plan.valueSize, detailSize: plan.detailSize)
                        .frame(width: isMoney ? plan.mergedMetricWidth : plan.metricColumnWidth, alignment: .leading)
                    if let window, !isMoney {
                        metric(value: window.percent, compactValue: window.percent, period: shortPeriod(window.label),
                               reset: window.reset, valueSize: plan.secondaryValueSize, detailSize: plan.detailSize)
                            .frame(width: plan.metricColumnWidth, alignment: .leading)
                    }
                }
                if size == .large {
                    Group {
                        if let activity { WidgetActivitySummary(item: activity) }
                        else { Color.clear.accessibilityHidden(true) }
                    }
                    .frame(height: 14, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stacked(_ plan: WidgetContentPlan) -> some View {
        VStack(alignment: .leading, spacing: plan.spacing) {
            header(plan)
            if size == .extraLarge {
                pairedMetrics(plan)
            } else {
                metric(value: presentation.value, compactValue: presentation.compactValue,
                       period: presentation.period, reset: presentation.reset,
                       valueSize: plan.valueSize, detailSize: plan.detailSize)
                if let window {
                    if plan.cardSize.height >= 180 {
                        metric(value: window.percent, compactValue: window.percent,
                               period: shortPeriod(window.label), reset: plan.showsWindowResets ? window.reset : nil,
                               valueSize: plan.secondaryValueSize, detailSize: plan.detailSize,
                               accessibilityReset: window.reset)
                            .padding(.top, plan.spacing)
                    } else {
                        secondaryWindow(window, plan: plan, valueSize: plan.secondaryValueSize)
                    }
                }
            }
            moduleActivity
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func compact(_ plan: WidgetContentPlan) -> some View {
        identityAndQuotaRow(plan, prominentSecondary: false)
    }

    private func dashboard(_ plan: WidgetContentPlan) -> some View {
        VStack(alignment: .leading, spacing: plan.dashboardSectionSpacing) {
            HStack(alignment: .top, spacing: plan.dashboardColumnSpacing) {
                header(plan).frame(width: plan.dashboardIdentityWidth, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: plan.dashboardColumnSpacing) {
                    dashboardMetric(value: presentation.value, compactValue: presentation.compactValue,
                                    period: presentation.period, reset: presentation.reset,
                                    valueSize: plan.valueSize, detailSize: plan.detailSize)
                    if let window, !isMoney {
                        dashboardMetric(value: window.percent, compactValue: window.percent,
                                        period: shortPeriod(window.label), reset: window.reset,
                                        valueSize: plan.secondaryValueSize, detailSize: plan.detailSize)
                    }
                }
                .frame(width: plan.dashboardMetricWidth, alignment: .leading)
            }
            .frame(height: plan.dashboardQuotaHeight, alignment: .top)

            VStack(alignment: .leading, spacing: 8) {
                Divider().opacity(0.4)
                if let activity {
                    WidgetActivitySummary(item: activity, layout: .footer)
                        .frame(height: 24, alignment: .center)
                } else {
                    Color.clear.frame(height: 24).accessibilityHidden(true)
                }
            }
            .frame(height: plan.dashboardFooterHeight, alignment: .bottom)
        }
    }

    private func dashboardMetric(value: String, compactValue: String, period: String,
                                 reset: String?, valueSize: CGFloat, detailSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            WidgetPrimaryValue(full: value, compact: compactValue, size: valueSize)
            secondary(period, size: detailSize)
            if let reset { secondary(compactReset(reset), size: detailSize) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((["\(period), \(value) \(isMoney && presentation.provider == .deepseek ? "balance" : "remaining")", reset]
            .compactMap { $0 }).joined(separator: ", "))
    }

    private func tile(_ plan: WidgetContentPlan) -> some View {
        VStack(alignment: .leading, spacing: plan.spacing) {
            identityAndQuotaRow(plan, prominentSecondary: true)
            moduleActivity
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func identityAndQuotaRow(_ plan: WidgetContentPlan, prominentSecondary: Bool) -> some View {
        HStack(alignment: .top, spacing: plan.sideColumnSpacing) {
            header(plan)
                .frame(width: plan.sideIdentityColumnWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: plan.spacing) {
                primaryValue(plan)
                periodReset(presentation.period == "Weekly" ? "Wk" : presentation.period,
                            reset: presentation.reset, size: plan.detailSize)
                    .accessibilityLabel([presentation.period, presentation.reset].compactMap { $0 }.joined(separator: ", "))
                if let window {
                    secondaryWindow(window, plan: plan,
                                    valueSize: prominentSecondary ? plan.secondaryValueSize : nil)
                }
            }
            .frame(width: plan.sideMetricColumnWidth, alignment: .leading)
        }
    }

    private func pairedMetrics(_ plan: WidgetContentPlan) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: plan.columnSpacing) {
            metric(value: presentation.value, compactValue: presentation.compactValue,
                   period: presentation.period, reset: presentation.reset,
                   valueSize: plan.valueSize, detailSize: plan.detailSize, compactPeriod: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let window, !isMoney {
                metric(value: window.percent, compactValue: window.percent,
                       period: shortPeriod(window.label), reset: window.reset,
                       valueSize: plan.secondaryValueSize, detailSize: plan.detailSize, compactPeriod: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var moduleActivity: some View {
        if size == .large || size == .extraLarge, let activity {
            WidgetActivitySummary(item: activity, showsHistory:
                WidgetContentPlan.showsActivityHistory(size: size, providerCount: providerCount),
                showsDetails: size == .extraLarge)
        }
    }

    private func header(_ plan: WidgetContentPlan) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                ProviderLogoView(provider: presentation.provider, size: plan.logoSize).accessibilityHidden(true)
                if presentation.status.severity != .normal {
                    WidgetStatusIcon(status: presentation.status, size: 8)
                }
            }
            if let workspaceName {
                secondary(workspaceName, size: plan.titleSize, lines: plan.layout == .dashboard ? 2 : 1)
                    .help(fullTitle).accessibilityLabel(fullTitle)
            }
            if let subscription = presentation.planName {
                secondary(subscription, size: plan.subscriptionSize,
                          lines: plan.layout == .dashboard && workspaceName == nil ? 2 : 1)
                    .help("Subscription plan: \(subscription)")
                    .accessibilityLabel("Subscription plan: \(subscription)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: plan.identityHeaderHeight, alignment: .topLeading)
    }

    private func primaryValue(_ plan: WidgetContentPlan) -> some View {
        WidgetPrimaryValue(full: presentation.value, compact: presentation.compactValue, size: plan.valueSize)
    }

    private func metric(value: String, compactValue: String, period: String, reset: String?,
                        valueSize: CGFloat, detailSize: CGFloat, accessibilityReset: String? = nil,
                        compactPeriod: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            WidgetPrimaryValue(full: value, compact: compactValue, size: valueSize)
            if compactPeriod {
                secondary(periodText(period == "Weekly" ? "Wk" : period, reset: reset), size: detailSize)
            } else {
                periodReset(period, reset: reset, size: detailSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((["\(period), \(value) \(isMoney && presentation.provider == .deepseek ? "balance" : "remaining")", accessibilityReset ?? reset]
            .compactMap { $0 }).joined(separator: ", "))
    }

    private func periodReset(_ period: String, reset: String?, size: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            secondary(periodText(period, reset: reset), size: size).fixedSize()
            VStack(alignment: .leading, spacing: 0) {
                secondary(shortPeriod(period), size: size)
                if let reset { secondary(compactReset(reset), size: size).fixedSize() }
            }
        }
    }

    private func secondaryWindow(_ window: WidgetQuotaWindow, plan: WidgetContentPlan,
                                 valueSize: CGFloat? = nil) -> some View {
        ViewThatFits(in: .horizontal) {
            if plan.showsWindowResets {
                windowText(window, size: plan.detailSize, includesReset: true, valueSize: valueSize).fixedSize()
                VStack(alignment: .leading, spacing: 1) {
                    windowText(window, size: plan.detailSize, includesReset: false, valueSize: valueSize)
                    secondary(compactReset(window.reset), size: plan.detailSize)
                }
                .fixedSize()
            }
            windowText(window, size: plan.detailSize, includesReset: false, valueSize: valueSize).fixedSize()
        }
        .help("\(window.label), \(window.percent) remaining, \(window.reset)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label), \(window.percent) remaining, \(window.reset)")
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
