import SwiftUI
import WidgetKit

struct QuotaWidgetContent: View {
    let snapshot: UsageSnapshot
    let family: WidgetFamily
    var providers: [MeterProvider] = MeterProvider.allCases
    var referenceDate: Date = .now
    var selectedModuleIDs: [String]? = nil
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        let composition = self.composition
        Group {
            if composition.items.isEmpty {
                Text(providers.isEmpty ? "No services are switched on. Choose Services in the BeaverMeter menu."
                     : "Choose the modules to show in Edit Widget.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .modifier(WidgetSecondaryText())
                    .multilineTextAlignment(.center)
            } else if family == .systemLarge || family == .systemExtraLarge {
                WidgetCompositionContent(composition: composition, size: widgetSize,
                                         activityItems: activityPresentation(for: composition).items)
            } else {
                WidgetCompositionContent(composition: composition, size: widgetSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(outerPadding)
    }
    private func activityPresentation(for composition: WidgetComposition) -> WidgetActivityPresentation {
        WidgetActivityPresentation(snapshot: snapshot, composition: composition,
                                   referenceDate: referenceDate, calendar: calendar)
    }
    private var widgetSize: ProviderWidgetSize {
        switch family {
        case .systemSmall: .small
        case .systemMedium: .medium
        case .systemLarge: .large
        default: .extraLarge
        }
    }
    private var composition: WidgetComposition {
        WidgetComposition(snapshot: snapshot, providers: providers, size: widgetSize,
                          referenceDate: referenceDate, calendar: calendar, selectedModuleIDs: selectedModuleIDs)
    }
    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return calendar
    }
    private var outerPadding: CGFloat {
        switch family {
        case .systemSmall: 8
        case .systemMedium: 10
        default: 14
        }
    }
}

struct QuotaWidgetBackground: View {
    var body: some View { WidgetSurfaceBackground() }
}
