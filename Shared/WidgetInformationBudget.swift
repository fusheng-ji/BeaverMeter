import Foundation

/// Family controls detail depth; geometry preserves core values within that budget.
struct WidgetContentPlan {
    enum Layout { case compact, column, wideRow, hero, tile, dashboard }

    let provider: MeterProvider
    let size: ProviderWidgetSize
    let providerCount: Int
    let cardSize: CGSize
    var hasSubscription = false

    static func showsActivityHistory(size: ProviderWidgetSize, providerCount: Int) -> Bool {
        size == .extraLarge && providerCount != 4
    }

    var layout: Layout {
        return switch size {
        case .small: providerCount == 1 ? .hero : .compact
        case .medium: providerCount == 1 ? .wideRow : providerCount >= 4 ? .compact : .column
        case .large: providerCount == 1 ? .hero : providerCount <= 4 ? .wideRow : .tile
        case .extraLarge: providerCount == 1 ? .hero : providerCount == 4 ? .dashboard : .tile
        }
    }
    var valueSize: CGFloat {
        let base: CGFloat = switch size {
        case .small: providerCount == 1 ? 36 : 22
        case .medium: [32, 26, 22, 22][min(3, max(0, providerCount - 1))]
        case .large: providerCount == 1 ? 48 : providerCount == 2 ? 32 : providerCount == 3 ? 28
            : providerCount == 4 ? 26 : 24
        case .extraLarge: providerCount == 1 ? 48 : providerCount <= 4 ? 32 : 26
        }
        return hasSubscription && layout == .compact ? min(base, 20) : base
    }
    var secondaryValueSize: CGFloat { layout == .dashboard ? 26 : max(12, (valueSize * 0.7).rounded()) }
    var horizontalPadding: CGFloat {
        if layout == .dashboard { return 12 }
        if size == .small { return providerCount == 1 ? 10 : 8 }
        if layout == .wideRow { return 12 }
        if providerCount >= 5 { return 6 }
        return providerCount == 1 ? 16 : size == .medium && providerCount == 4 ? 8 : 10
    }
    var verticalPadding: CGFloat {
        if layout == .dashboard { return 12 }
        if layout == .compact { return 6 }
        if size == .small && layout == .hero { return 6 }
        if layout == .column { return 8 }
        if layout == .tile && providerCount >= 4 { return 4 }
        if layout == .compact || providerCount >= 5 { return 4 }
        return layout == .wideRow ? 8 : 12
    }
    var spacing: CGFloat {
        if hasSubscription && layout == .compact { return 1 }
        if size == .small && layout == .hero { return 2 }
        if layout == .column { return 3 }
        if layout == .compact || layout == .tile && providerCount >= 4 { return 2 }
        return 4
    }
    var detailSize: CGFloat {
        if layout == .dashboard { return 11 }
        if size == .small || size == .medium && providerCount >= 4 { return 8 }
        if providerCount >= 5 { return 9 }
        return size == .large && providerCount <= 2 ? 11 : 10
    }
    var titleSize: CGFloat { max(9, detailSize + 1) }
    var subscriptionSize: CGFloat { max(8, detailSize - 1) }
    var logoSize: CGFloat {
        switch layout {
        case .compact: 28
        case .wideRow: providerCount == 1 ? 32 : 28
        case .hero: size == .small ? 32 : 44
        case .column: providerCount == 2 ? 32 : 28
        case .tile: size == .extraLarge ? 36 : 28
        case .dashboard: 36
        }
    }
    /// Reserve name and plan lines so identity and quota baselines stay aligned.
    var identityHeaderHeight: CGFloat {
        layout == .dashboard ? dashboardQuotaHeight : logoSize + (titleSize + subscriptionSize) * 1.25 + 4
    }
    var cornerRadius: CGFloat { layout == .compact || layout == .wideRow ? 13 : 18 }
    var contentWidth: CGFloat { max(0, cardSize.width - horizontalPadding * 2) }
    var columnSpacing: CGFloat { min(8, contentWidth / 2) }
    var identityColumnWidth: CGFloat { max(0, contentWidth - columnSpacing * 2) * 0.28 }
    var metricColumnWidth: CGFloat { max(0, contentWidth - columnSpacing * 2 - identityColumnWidth) / 2 }
    var mergedMetricWidth: CGFloat { metricColumnWidth * 2 + columnSpacing }
    var sideColumnSpacing: CGFloat { min(6, contentWidth / 2) }
    var sideIdentityColumnWidth: CGFloat {
        min(max(0, contentWidth - sideColumnSpacing), min(84, max(70, contentWidth * 0.34)))
    }
    var sideMetricColumnWidth: CGFloat { max(0, contentWidth - sideIdentityColumnWidth - sideColumnSpacing) }
    var dashboardIdentityWidth: CGFloat { min(84, contentWidth * 0.28) }
    var dashboardColumnSpacing: CGFloat { min(12, contentWidth / 4) }
    var dashboardMetricWidth: CGFloat {
        max(0, contentWidth - dashboardIdentityWidth - dashboardColumnSpacing)
    }
    var dashboardFooterHeight: CGFloat { 33 }
    var dashboardSectionSpacing: CGFloat { 10 }
    var dashboardQuotaHeight: CGFloat {
        max(0, cardSize.height - verticalPadding * 2 - dashboardFooterHeight - dashboardSectionSpacing)
    }
    var showsPrimaryReset: Bool { true }
    var windowLimit: Int { provider == .codex || provider == .claude ? 1 : 0 }
    var showsWindowResets: Bool { size != .small }
}
