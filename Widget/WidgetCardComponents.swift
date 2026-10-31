import SwiftUI

struct WidgetPrimaryValue: View {
    let full: String
    let compact: String
    let size: CGFloat
    var moneyCurrencyCode: String? = nil
    var compactMoneyAmount: String? = nil
    var currencySize: CGFloat = 8

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(full).fixedSize(horizontal: true, vertical: true)
            Text(compact).fixedSize(horizontal: true, vertical: true)
            if let moneyCurrencyCode, let compactMoneyAmount {
                VStack(alignment: .leading, spacing: 1) {
                    Text(compactMoneyAmount)
                    Text(moneyCurrencyCode)
                        .font(.system(size: currencySize, weight: .medium, design: .rounded))
                        .modifier(WidgetSecondaryText())
                }
                .fixedSize(horizontal: true, vertical: true)
            }
            Text(compact).minimumScaleFactor(0.85)
        }
        .font(.system(size: size, weight: .bold, design: .rounded))
        .monospacedDigit()
        .modifier(WidgetPrimaryText())
        .lineLimit(1)
        .modifier(WidgetMetricAccessibility(label: full))
        .help(full)
    }
}
