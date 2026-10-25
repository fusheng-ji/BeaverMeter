import SwiftUI
import WidgetKit

/// Previews can exercise accessibility without changing the Mac's preferences.
struct WidgetAccessibilityOptions: Sendable {
    var reduceTransparency = false
    var increaseContrast = false
}

private struct WidgetAccessibilityOverrideKey: EnvironmentKey {
    static let defaultValue: WidgetAccessibilityOptions? = nil
}

extension EnvironmentValues {
    var widgetAccessibilityOverride: WidgetAccessibilityOptions? {
        get { self[WidgetAccessibilityOverrideKey.self] }
        set { self[WidgetAccessibilityOverrideKey.self] = newValue }
    }
}

struct WidgetAccessibility: DynamicProperty {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.widgetAccessibilityOverride) private var override

    var options: WidgetAccessibilityOptions {
        override ?? WidgetAccessibilityOptions(reduceTransparency: reduceTransparency,
                                               increaseContrast: contrast == .increased)
    }
}

/// Explicit foreground colors keep text legible when the system changes widget appearance.
struct WidgetLegibility: DynamicProperty {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    private var accessibility = WidgetAccessibility()

    var usesReducedColor: Bool { renderingMode != .fullColor }

    var primary: Color {
        colorScheme == .dark || usesReducedColor ? .white : .primary
    }

    var secondary: Color {
        if accessibility.options.increaseContrast { return primary }
        return colorScheme == .dark || usesReducedColor ? Color(white: 0.78) : .secondary
    }
}

/// Opaque surfaces preserve contrast; WidgetKit owns the container's vibrant treatment.
struct WidgetSurfaceBackground: View {
    var provider: MeterProvider?
    var cornerRadius: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    init(provider: MeterProvider? = nil, cornerRadius: CGFloat = 0) {
        self.provider = provider
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius).fill(solidFill)
    }

    private var solidFill: Color {
        // Card backgrounds are foreground content to WidgetKit. In reduced-color modes
        // they would become gray blocks, so let the container provide the surface.
        if provider != nil, renderingMode != .fullColor { return .clear }
        if colorScheme == .dark {
            return provider == nil ? Color(red: 0.065, green: 0.07, blue: 0.085) : Color(white: 0.12)
        }
        if let provider { return BrandStyle.provider(provider, .light).opacity(0.08) }
        return Color(red: 0.965, green: 0.970, blue: 0.980)
    }
}

struct WidgetCardSurface: ViewModifier {
    let provider: MeterProvider
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    private var legibility = WidgetLegibility()
    private var accessibility = WidgetAccessibility()

    init(provider: MeterProvider, cornerRadius: CGFloat) {
        self.provider = provider
        self.cornerRadius = cornerRadius
    }

    func body(content: Content) -> some View {
        content
            .background(WidgetSurfaceBackground(provider: provider, cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(border, lineWidth: 1))
    }

    private var border: Color {
        if legibility.usesReducedColor { return .clear }
        if colorScheme == .dark { return .white.opacity(accessibility.options.increaseContrast ? 0.36 : 0.14) }
        return .primary.opacity(accessibility.options.increaseContrast ? 0.22 : 0.08)
    }
}

struct WidgetPrimaryText: ViewModifier {
    private var legibility = WidgetLegibility()
    func body(content: Content) -> some View {
        content.foregroundStyle(legibility.primary)
    }
}

struct WidgetSecondaryText: ViewModifier {
    private var legibility = WidgetLegibility()
    func body(content: Content) -> some View {
        content.foregroundStyle(legibility.secondary)
    }
}
