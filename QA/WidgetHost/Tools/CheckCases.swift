import CryptoKit
import Darwin
import Foundation

/// Standalone contract checker; deliberately outside both application targets.
@main
enum CheckWidgetQACases {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("Widget QA contract: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let paths = Array(CommandLine.arguments.dropFirst())
        if paths.first == "--manifest", paths.count == 2 || paths.count == 4 && paths[2] == "--report" {
            let reportURL = paths.count == 4 ? URL(fileURLWithPath: paths[3]) : nil
            try checkManifest(at: URL(fileURLWithPath: paths[1]), reportURL: reportURL)
            return
        }
        guard !paths.isEmpty else { throw WidgetQAStore.Failure("Pass synthetic case JSON files to check.") }
        for path in paths {
            _ = try WidgetQAStore.load(from: URL(fileURLWithPath: path))
        }
        print("Validated \(paths.count) synthetic Widget QA cases.")
    }

    private struct Manifest: Decodable {
        struct Case: Decodable {
            let caseID: String
            let file: String
            let sha256: String
            let applicableFamilies: [String]
            let expectationsByFamily: [String: Expectation]
        }
        struct Expectation: Decodable {
            let enabledProviders: [String]
            let visibleCardCount: Int
            let visibleItemIDs: [String]
            let visibleNames: [String]
            let selectedSlotIDs: [String]
            let overflowWorkspaceCount: Int
            let maximumVisibleCards: Int
            let isMultiWorkspace: Bool
            let activityVisible: Bool
            let tokenHistoryVisible: Bool
            let activityModuleIDs: [String]
            let historyModuleIDs: [String]
            let codexActivityPolicy: String
            let globalFooterVisible: Bool
            let hiddenWidgetFields: [String]
            let items: [Item]
        }
        struct Item: Decodable {
            let id: String
            let provider: String
            let planName: String?
            let primaryNumericValue: Double?
            let primaryResetAt: String?
            let primaryPeriod: String
            let secondaryNumericValue: Double?
            let secondaryResetAt: String?
            let expectedSeverity: String
            let expectedUnavailable: Bool
            let expectedStatusIconVisible: Bool
            let activity: Activity?
        }
        struct Activity: Decodable {
            let numericValue: Double?
            let caption: String
            let expectedSeverity: String
            let aggregationNote: String?
            let historyValues: [Int?]?
            let historyExpectedSeverity: String?
            let historyTimeZoneIdentifier: String?
            let fetchedAtVisible: Bool?
        }
        let schemaVersion: Int
        let syntheticOnly: Bool
        let caseCount: Int
        let referenceDate: String
        let cases: [Case]
    }

    private static func checkManifest(at url: URL, reportURL: URL?) throws {
        let manifestData = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.schemaVersion == 1, manifest.syntheticOnly,
              manifest.caseCount == manifest.cases.count,
              Set(manifest.cases.map(\.caseID)).count == manifest.cases.count,
              let referenceDate = ISO8601DateFormatter().date(from: manifest.referenceDate) else {
            throw WidgetQAStore.Failure("Manifest identity, count, provenance or reference date is invalid.")
        }
        let sizes: [String: ProviderWidgetSize] = ["small": .small, "medium": .medium,
                                                  "large": .large, "extra-large": .extraLarge]
        var checked = 0
        var records: [[String: Any]] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        for record in manifest.cases {
            let caseURL = url.deletingLastPathComponent().appendingPathComponent(record.file).standardizedFileURL
            let casesDirectory = url.deletingLastPathComponent().appendingPathComponent("cases").standardizedFileURL
            guard caseURL.path.hasPrefix(casesDirectory.path + "/"),
                  Set(record.expectationsByFamily.keys) == Set(sizes.keys),
                  !record.applicableFamilies.isEmpty,
                  Set(record.applicableFamilies).count == record.applicableFamilies.count else {
                throw WidgetQAStore.Failure("Fixture path or family coverage is invalid: \(record.caseID).")
            }
            let caseData = try Data(contentsOf: caseURL)
            guard digest(caseData) == record.sha256 else {
                throw WidgetQAStore.Failure("Fixture SHA256 differs from the manifest: \(record.caseID).")
            }
            let fixture = try WidgetQAStore.decode(caseData)
            guard fixture.caseID == record.caseID, fixture.referenceDate == referenceDate else {
                throw WidgetQAStore.Failure("Case identity or frozen date differs from the manifest: \(record.caseID).")
            }
            let providers = fixture.settings.visibleProviders(in: fixture.snapshot)
            for name in record.applicableFamilies {
                guard let size = sizes[name], let expected = record.expectationsByFamily[name] else {
                    throw WidgetQAStore.Failure("Unknown or missing family in \(record.caseID).")
                }
                let composition = WidgetComposition(snapshot: fixture.snapshot, providers: providers, size: size,
                                                     referenceDate: fixture.referenceDate, calendar: calendar,
                                                     selectedModuleIDs: fixture.selectedModuleIDs)
                let selected = fixture.selectedModuleIDs
                    ?? WidgetModuleCatalog.defaults(snapshot: fixture.snapshot, providers: providers)
                guard providers.map(\.rawValue) == expected.enabledProviders,
                      composition.items.count == expected.visibleCardCount,
                      composition.items.map(\.id) == expected.visibleItemIDs,
                      composition.items.map({ $0.workspaceName ?? $0.provider.displayName }) == expected.visibleNames,
                      Array(selected.prefix(WidgetComposition.capacity(for: size))) == expected.selectedSlotIDs,
                      composition.overflowWorkspaceCount == expected.overflowWorkspaceCount,
                      WidgetComposition.capacity(for: size) == expected.maximumVisibleCards,
                      composition.isMultiWorkspace == expected.isMultiWorkspace else {
                    throw WidgetQAStore.Failure("Swift composition differs from manifest: \(record.caseID) / \(name).")
                }
                try checkItems(composition.items, expected: expected.items, fixture: fixture, family: name)
                let showsActivity = (size == .large || size == .extraLarge) && !composition.items.isEmpty
                // Follow the real family budget: compact sizes never build an activity projection.
                let activity = showsActivity ? WidgetActivityPresentation(snapshot: fixture.snapshot,
                    composition: composition,
                    referenceDate: fixture.referenceDate, calendar: calendar).items : []
                let activityModuleIDs = activity.compactMap(\.moduleID)
                let allowsHistory = WidgetContentPlan.showsActivityHistory(size: size, providerCount: composition.items.count)
                let historyModuleIDs = allowsHistory
                    ? activity.filter { $0.history != nil }.compactMap(\.moduleID) : []
                let showsHistory = allowsHistory && activity.contains { $0.history != nil }
                let hiddenFields = ["resetCards", "resetCardExpiry", "cursorUsed", "cursorLimit", "automaticOverflow"]
                    + ((size == .small || size == .medium) ? ["dailyTokens"] : [])
                    + (allowsHistory ? [] : ["tokenHistory"])
                guard expected.activityVisible == showsActivity,
                      expected.tokenHistoryVisible == showsHistory,
                      expected.activityModuleIDs == activityModuleIDs,
                      expected.historyModuleIDs == historyModuleIDs,
                      expected.codexActivityPolicy == "workspace-only-no-global-fallback",
                      !expected.globalFooterVisible,
                      expected.hiddenWidgetFields == hiddenFields,
                      activity.allSatisfy({ $0.aggregationNote == nil }) else {
                    throw WidgetQAStore.Failure("Activity family budget or workspace scope differs: \(record.caseID) / \(name).")
                }
                try checkActivity(activity, expected: expected.items, fixture: fixture, family: name)
                records.append([
                    "caseID": record.caseID, "family": name, "fixtureSHA256": record.sha256,
                    "visibleItemIDs": composition.items.map(\.id), "overflowWorkspaceCount": composition.overflowWorkspaceCount,
                    "selectedSlotIDs": Array(selected.prefix(WidgetComposition.capacity(for: size))),
                    "activityVisible": showsActivity, "tokenHistoryVisible": showsHistory,
                    "activityModuleIDs": activityModuleIDs, "historyModuleIDs": historyModuleIDs,
                    "globalFooterVisible": false,
                    "hiddenWidgetFields": hiddenFields,
                    "modules": composition.items.map { item -> [String: Any] in
                        ["id": item.id, "provider": item.provider.rawValue,
                         "name": item.workspaceName ?? item.provider.displayName,
                         "value": item.presentation.value, "period": item.presentation.period,
                         "planName": item.presentation.planName as Any? ?? NSNull(),
                         "severity": String(describing: item.presentation.status.severity),
                         "secondaryValues": item.presentation.windows.map(\.percent)]
                    },
                    "activity": activity.map { item -> [String: Any] in
                        var details: [String: Any] = ["moduleID": item.moduleID as Any? ?? NSNull(),
                            "provider": item.provider.rawValue, "value": item.value,
                            "compactValue": item.compactValue,
                            "caption": item.caption, "severity": String(describing: item.status.severity),
                            "aggregationNote": item.aggregationNote as Any? ?? NSNull()]
                        if showsHistory, let history = item.history {
                            details["historyTimeZoneIdentifier"] = item.historyTimeZoneIdentifier as Any? ?? NSNull()
                            details["history"] = history.map { day -> [String: Any] in
                                ["date": day.date.ISO8601Format(), "value": day.value as Any? ?? NSNull()]
                            }
                        }
                        return details
                    }
                ])
                checked += 1
            }
        }
        if let reportURL {
            let report: [String: Any] = ["schemaVersion": 1, "kind": "offline-synthetic-model-contract",
                "desktopEvidence": false, "manifestSHA256": digest(manifestData), "referenceDate": manifest.referenceDate,
                "caseCount": manifest.cases.count, "familyCount": checked, "records": records]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try AtomicFileWriter.write(data, to: reportURL)
        }
        print("Validated \(manifest.cases.count) synthetic cases and \(checked) Swift family compositions.")
    }

    private static func checkActivity(_ activity: [WidgetActivityItem], expected: [Manifest.Item],
                                      fixture: WidgetQACase, family: String) throws {
        let modules = expected.filter { $0.activity != nil }
        guard activity.count == modules.count else {
            throw WidgetQAStore.Failure("Activity module count differs: \(fixture.caseID) / \(family).")
        }
        for (item, module) in zip(activity, modules) {
            guard let expectation = module.activity else { continue }
            let value = item.provider == .cursor
                ? UsageFormatting.usd(expectation.numericValue, minimumDigits: 2, maximumDigits: 2)
                : UsageFormatting.tokens(expectation.numericValue.map { Int($0) })
            guard item.moduleID == module.id, item.provider.rawValue == module.provider,
                  item.value == value, item.caption == expectation.caption,
                  String(describing: item.status.severity) == expectation.expectedSeverity,
                  item.aggregationNote == expectation.aggregationNote,
                  item.history?.map(\.value) == expectation.historyValues,
                  item.historyTimeZoneIdentifier == expectation.historyTimeZoneIdentifier,
                  item.historyStatus.map({ String(describing: $0.severity) }) == expectation.historyExpectedSeverity,
                  (item.fetchedAtLabel != nil) == (expectation.fetchedAtVisible ?? false),
                  !item.accessibilityText.contains("All workspaces") else {
                throw WidgetQAStore.Failure("Workspace activity value, history or status differs: \(fixture.caseID) / \(family) / \(module.id).")
            }
        }
    }

    private static func checkItems(_ items: [WidgetDisplayItem], expected: [Manifest.Item],
                                   fixture: WidgetQACase, family: String) throws {
        guard items.count == expected.count else { throw WidgetQAStore.Failure("Module expectation count differs.") }
        let dates = ISO8601DateFormatter()
        func percent(_ number: Double?) -> String {
            number.map { "\(Int(min(100, max(0, $0)).rounded()))%" } ?? "—"
        }
        func countdown(_ text: String?) -> String? {
            text.flatMap { dates.date(from: $0) }.map { UsageFormatting.resetCountdown($0, relativeTo: fixture.referenceDate) }
        }
        for (item, expectation) in zip(items, expected) {
            let presentation = item.presentation
            let primary: String
            if item.provider == .cursor || item.provider == .deepseek {
                let currency = item.provider == .cursor ? "USD" : fixture.snapshot.deepseekUsage.value?.balances.first?.currency
                primary = UsageFormatting.money(expectation.primaryNumericValue.flatMap { amount in
                    currency.map { DeepSeekMoney(currency: $0, amount: amount) }
                })
            } else {
                primary = percent(expectation.primaryNumericValue)
            }
            let reset = countdown(expectation.primaryResetAt)
            let secondaryMatches = presentation.windows.first.map {
                $0.percent == percent(expectation.secondaryNumericValue)
                    && $0.reset == (countdown(expectation.secondaryResetAt) ?? "Reset unavailable")
            } ?? (expectation.secondaryNumericValue == nil && expectation.secondaryResetAt == nil)
            guard item.id == expectation.id, item.provider.rawValue == expectation.provider,
                  presentation.planName == expectation.planName,
                  presentation.value == primary, presentation.period == expectation.primaryPeriod,
                  presentation.reset == reset, secondaryMatches,
                  String(describing: presentation.status.severity) == expectation.expectedSeverity,
                  (presentation.status.severity != .normal) == expectation.expectedStatusIconVisible,
                  !expectation.expectedUnavailable || (presentation.planName == nil && presentation.value == "—") else {
                throw WidgetQAStore.Failure("Module quota, plan, reset or state differs: \(fixture.caseID) / \(family) / \(item.id).")
            }
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
