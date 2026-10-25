import SwiftUI
import WidgetKit

struct WidgetQAEntry: TimelineEntry {
    let date: Date
    let fixture: WidgetQACase?
    let failure: String?

    static func load() -> Self {
        do { return Self(date: .now, fixture: try WidgetQAStore.load(), failure: nil) }
        catch { return Self(date: .now, fixture: nil, failure: error.localizedDescription) }
    }
}

struct WidgetQAProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetQAEntry { .load() }
    func getSnapshot(in context: Context, completion: @escaping (WidgetQAEntry) -> Void) { completion(.load()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetQAEntry>) -> Void) {
        completion(Timeline(entries: [.load()], policy: .after(Date.now.addingTimeInterval(60))))
    }
}

struct WidgetQAView: View {
    let entry: WidgetQAEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let fixture = entry.fixture {
                // Give the host a named group even when production content is
                // a single Text (empty services) or one provider card. A value
                // on the production view alone can be flattened by SwiftUI.
                VStack(spacing: 0) {
                    QuotaWidgetContent(snapshot: fixture.snapshot, family: family,
                                       providers: fixture.settings.visibleProviders(in: fixture.snapshot),
                                           referenceDate: fixture.referenceDate,
                                           selectedModuleIDs: fixture.selectedModuleIDs)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("QA caseID: \(fixture.caseID)")
                .accessibilityIdentifier("WidgetQA.case.\(fixture.caseID)")
                .accessibilityValue("QA caseID: \(fixture.caseID)")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("QA load failed").font(.headline)
                    Text(entry.failure ?? "No synthetic case is available.").font(.caption)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .accessibilityLabel("BeaverMeter QA load failed")
            }
        }
        .containerBackground(for: .widget) { QuotaWidgetBackground() }
        .widgetURL(AppNavigation.codexWorkspacesURL)
        .environment(\.locale, UsageFormatting.locale)
        .environment(\.timeZone, TimeZone(identifier: "Europe/Berlin")!)
    }
}

@main
struct BeaverMeterWidgetQA: Widget {
    let kind = WidgetQAStore.kind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WidgetQAProvider()) { WidgetQAView(entry: $0) }
            .configurationDisplayName("BeaverMeter QA")
            .description("Synthetic desktop layout validation. No live account data.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
            .contentMarginsDisabled()
    }
}
