import SwiftUI

struct WidgetStatusIcon: View {
    let status: WidgetCardStatus
    var size: CGFloat = 11
    private var legibility = WidgetLegibility()

    init(status: WidgetCardStatus, size: CGFloat = 11) {
        self.status = status
        self.size = size
    }

    private var color: Color {
        switch status.severity {
        case .normal: legibility.secondary
        case .warning: legibility.usesReducedColor ? legibility.primary : .orange
        case .critical: legibility.usesReducedColor ? legibility.primary : .red
        }
    }

    var body: some View {
        Image(systemName: status.icon)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size + 2, height: size + 2)
            .fixedSize()
            .accessibilityLabel(status.detail)
            .help(status.detail)
    }
}
