import SwiftUI
import WidgetKit

struct BeaverMeterEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
    var settings: ProviderSettings = .default
    var selectedModuleIDs: [String]? = nil

    var providers: [MeterProvider] { settings.visibleProviders(in: snapshot) }
}

struct BeaverMeterProvider: AppIntentTimelineProvider {
    typealias Intent = WidgetModuleIntent
    private var usesDemoData: Bool {
        Bundle.main.object(forInfoDictionaryKey: "BeaverMeterInteractionDemo") as? Bool == true
    }

    func recommendations() -> [AppIntentRecommendation<WidgetModuleIntent>] {
        let snapshot: UsageSnapshot = usesDemoData ? .preview : .load()
        let settings: ProviderSettings = usesDemoData ? .default : .load()
        let configuration = WidgetModuleIntent.defaultConfiguration(
            snapshot: snapshot, providers: settings.visibleProviders(in: snapshot))
        return [AppIntentRecommendation(intent: configuration, description: "Services and workspaces")]
    }

    func placeholder(in context: Context) -> BeaverMeterEntry {
        BeaverMeterEntry(date: UsageSnapshot.previewDate, snapshot: .preview)
    }

    func snapshot(for configuration: WidgetModuleIntent, in context: Context) async -> BeaverMeterEntry {
        let demo = context.isPreview || usesDemoData
        return BeaverMeterEntry(date: demo ? UsageSnapshot.previewDate : .now,
                                snapshot: demo ? .preview : .load(),
                                settings: demo ? .default : .load(),
                                selectedModuleIDs: configuration.selectedModuleIDs(for: context.family))
    }

    func timeline(for configuration: WidgetModuleIntent, in context: Context) async -> Timeline<BeaverMeterEntry> {
        let now = usesDemoData ? UsageSnapshot.previewDate : .now
        let snapshot: UsageSnapshot = usesDemoData ? .preview : .load()
        let settings: ProviderSettings = usesDemoData ? .default : .load()
        let expirations = settings.visibleProviders(in: snapshot).contains(.claude)
            ? ClaudeQuotaVisibility.expirationDates(quota: snapshot.claudeQuota, cards: snapshot.claudeResetCards, after: now)
            : []
        let selection = configuration.selectedModuleIDs(for: context.family)
        let entries = ([now] + expirations).map {
            BeaverMeterEntry(date: $0, snapshot: snapshot, settings: settings, selectedModuleIDs: selection)
        }
        return Timeline(entries: entries, policy: .after(Date.now.addingTimeInterval(5 * 60)))
    }
}

@main
struct BeaverMeterWidget: Widget {
    let kind = "BeaverMeterWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: WidgetModuleIntent.self, provider: BeaverMeterProvider()) { entry in
            BeaverMeterWidgetView(entry: entry)
                .environment(\.locale, UsageFormatting.locale)
        }
        .configurationDisplayName(Bundle.main.object(forInfoDictionaryKey: "BeaverMeterInteractionDemo") as? Bool == true
                                  ? "BeaverMeter QA" : "BeaverMeter")
        .description("Choose services and workspaces in the order you want.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}
