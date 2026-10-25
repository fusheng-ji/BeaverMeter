import SwiftUI

/// Palette for documentation artwork, independent of the existing product UI.
enum BrandStyle {
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.095, green: 0.103, blue: 0.106)
            : Color(red: 0.965, green: 0.951, blue: 0.925)
    }

    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.145, green: 0.151, blue: 0.153)
            : Color(red: 0.998, green: 0.990, blue: 0.970)
    }

    static func text(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.960, green: 0.948, blue: 0.915)
            : Color(red: 0.175, green: 0.165, blue: 0.150)
    }

    static func secondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.685, green: 0.700, blue: 0.680)
            : Color(red: 0.405, green: 0.410, blue: 0.380)
    }

    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.18) : Color.white.opacity(0.65)
    }

    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.89, green: 0.73, blue: 0.49)
            : Color(red: 0.46, green: 0.31, blue: 0.15)
    }

    static func provider(_ provider: MeterProvider, _ scheme: ColorScheme) -> Color {
        switch (provider, scheme) {
        case (.codex, .light): Color(red: 0.02, green: 0.47, blue: 0.40)
        case (.codex, _): Color(red: 0.20, green: 0.88, blue: 0.75)
        case (.claude, .light): Color(red: 0.70, green: 0.32, blue: 0.20)
        case (.claude, _): Color(red: 0.93, green: 0.51, blue: 0.36)
        case (.cursor, .light): Color(red: 0.38, green: 0.32, blue: 0.80)
        case (.cursor, _): Color(red: 0.65, green: 0.60, blue: 1.00)
        case (.deepseek, .light): Color(red: 0.12, green: 0.40, blue: 0.77)
        case (.deepseek, _): Color(red: 0.35, green: 0.65, blue: 1.00)
        }
    }
}

// Used only by documentation specimen sheets, never by the app or Widget UI.
struct BrandSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        content.background(BrandStyle.surface(colorScheme), in: RoundedRectangle(cornerRadius: radius))
    }
}
