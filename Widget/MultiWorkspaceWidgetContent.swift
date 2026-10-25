import SwiftUI

/// Selected modules keep their configured order and share one grid.
struct WidgetCompositionContent: View {
    let composition: WidgetComposition
    let size: ProviderWidgetSize
    var activityItems: [WidgetActivityItem] = []
    private var cardSpacing: CGFloat { size == .small ? 3 : size == .medium ? 6 : 8 }

    var body: some View {
        GeometryReader { geometry in
            let count = composition.items.count
            let rows = WidgetComposition.rows(cardCount: count, size: size)
            let columns = max(1, rows.map(\.count).max() ?? 1)
            let height = max(0, (geometry.size.height - cardSpacing * CGFloat(max(0, rows.count - 1))) / CGFloat(max(1, rows.count)))
            let width = max(0, (geometry.size.width - cardSpacing * CGFloat(columns - 1)) / CGFloat(columns))
            VStack(spacing: cardSpacing) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: cardSpacing) {
                        ForEach(row.map { composition.items[$0] }) { item in
                            AdaptiveProviderCard(presentation: item.presentation, size: size, providerCount: count,
                                                 workspaceName: item.workspaceName,
                                                 fullWorkspaceName: item.fullWorkspaceName,
                                                 activity: activityItems.first(where: { $0.moduleID == item.id }))
                                .frame(width: width, height: height)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: height)
                }
            }
        }
    }
}
