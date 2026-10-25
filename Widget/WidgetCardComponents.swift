import SwiftUI

struct WidgetPrimaryValue: View {
    let full: String
    let compact: String
    let size: CGFloat

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(full).fixedSize(horizontal: true, vertical: true)
            Text(compact).fixedSize(horizontal: true, vertical: true)
            Text(compact).minimumScaleFactor(0.85)
        }
        .font(.system(size: size, weight: .bold, design: .rounded))
        .monospacedDigit()
        .modifier(WidgetPrimaryText())
        .lineLimit(1)
        .accessibilityLabel(full)
        .help(full)
    }
}
