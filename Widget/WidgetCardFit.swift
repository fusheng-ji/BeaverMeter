import SwiftUI

/// Cumulative reductions preserve quota and safety insets before optional detail.
enum WidgetCardDetailLevel: Int, CaseIterable {
    case full, withoutActivityDetails, withoutActivity, withoutWindowReset, withoutSubscription, primaryOnly

    var showsActivityDetails: Bool { self == .full }
    var showsActivity: Bool { rawValue < Self.withoutActivity.rawValue }
    var showsWindowReset: Bool { rawValue < Self.withoutWindowReset.rawValue }
    var showsSubscription: Bool { rawValue < Self.withoutSubscription.rawValue }
    var showsSecondaryWindow: Bool { self != .primaryOnly }
}

/// QA exposes the chosen visible leaves; production retains concise VoiceOver groups.
struct WidgetMetricAccessibility: ViewModifier {
    let label: String
    func body(content: Content) -> some View {
        #if WIDGET_QA
        content.accessibilityElement(children: .contain).accessibilityLabel(label)
        #else
        content.accessibilityElement(children: .ignore).accessibilityLabel(label)
        #endif
    }
}

struct WidgetCardQAIdentity: ViewModifier {
    let moduleID: String
    func body(content: Content) -> some View {
        #if WIDGET_QA
        content.accessibilityIdentifier("WidgetQA.card.\(moduleID)")
        #else
        content
        #endif
    }
}

struct WidgetFitChoiceQA: ViewModifier {
    let level: WidgetCardDetailLevel
    func body(content: Content) -> some View {
        #if WIDGET_QA
        content.accessibilityElement(children: .contain)
            .accessibilityIdentifier("WidgetQA.fit.\(level.rawValue)")
            .accessibilityLabel("detailLevel: \(String(describing: level))")
            .accessibilityValue("detailLevel: \(String(describing: level))")
        #else
        content
        #endif
    }
}

struct WidgetLeafQAIdentity: ViewModifier {
    let kind: String
    var detailLevel: WidgetCardDetailLevel? = nil
    func body(content: Content) -> some View {
        #if WIDGET_QA
        content.accessibilityElement(children: .ignore)
            .accessibilityLabel("QA \(kind)" + (detailLevel.map { "; detailLevel: \(String(describing: $0))" } ?? ""))
            .accessibilityIdentifier("WidgetQA.leaf.\(kind)")
            .accessibilityHidden(false)
        #else
        content.accessibilityHidden(kind == "logo")
        #endif
    }
}
