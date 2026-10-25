import AppKit
import CryptoKit
import SwiftUI
import WidgetKit

private struct PreviewOptions {
    enum Mode { case screenshots, canonical, widgets, widgetAppearances, serviceMatrix, workspaceMatrix, holidays, interactive, interactiveDemo }
    var mode: Mode = .screenshots
    var path: String?
    var referenceDate = UsageSnapshot.previewDate
    var timeZone = TimeZone(secondsFromGMT: 0)!
    var selection = AppearanceSelection.automatic
    var schemes: [ColorScheme] = [.dark, .light]
    var checkAssets = false
    var updateVersion: String?
    var refreshingDemo = false
    var help = false

    static let usage = """
    BeaverMeterPreviewRenderer [output-directory] [options]
      --canonical DIRECTORY     README/guide images only; frozen synthetic data
      --widgets DIRECTORY       Every provider combination and state
      --widget-appearances DIRECTORY
                                 24 design previews: three rendering modes,
                                 dark/light and all four widget sizes;
                                 does not simulate WidgetKit host compositing
      --service-matrix DIRECTORY Four Widget sizes, menus and local gallery
      --workspace-matrix DIRECTORY
                                 Explicit ordered module/identity/failure fixtures,
                                 capacities 2/4/6/6; no workspace expansion or +N;
                                 PNGs, JSON manifest and offline contact sheets
      --holidays DIRECTORY      Nine logos, four widget sizes and logo specimens
      --interactive SNAPSHOT    Local test snapshot with explicit login/refresh
      --interactive-demo        In-memory demo; no collection or settings writes
      --date YYYY-MM-DD         Frozen date in the selected time zone
      --time-zone IANA           Time zone, for example Europe/Berlin (default GMT)
      --logo NAME                automatic, standard, newYear, lunarNewYear,
                                 lanternFestival, dragonBoat, midAutumn,
                                 programmerDay, halloween, christmas
      --appearance MODE          light, dark or both (default both)
      --check-assets             Validate all bundled logo files before rendering;
                                 alone, validate and exit
      --update-version VERSION  Show an in-memory Update button (no network/settings)
      --refreshing              Show the preview's refresh indicator
      --help                     Print this help
    """

    init(arguments: [String]) throws {
        var index = 0
        var dateText: String?
        var modeWasSet = false
        func requireValue(_ flag: String) throws -> String {
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw PreviewFailure("Missing value for \(flag).")
            }
            index += 1
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--canonical", "--widgets", "--widget-appearances", "--service-matrix", "--workspace-matrix", "--holidays", "--interactive", "--interactive-demo":
                guard !modeWasSet, path == nil else { throw PreviewFailure("Choose one rendering mode.") }
                modeWasSet = true
                switch argument {
                case "--canonical": mode = .canonical
                case "--widgets": mode = .widgets
                case "--widget-appearances": mode = .widgetAppearances
                case "--service-matrix": mode = .serviceMatrix
                case "--workspace-matrix": mode = .workspaceMatrix
                case "--holidays": mode = .holidays
                case "--interactive": mode = .interactive
                default: mode = .interactiveDemo
                }
                if mode != .interactiveDemo { path = try requireValue(argument) }
            case "--date": dateText = try requireValue(argument)
            case "--time-zone":
                let identifier = try requireValue(argument)
                guard let zone = TimeZone(identifier: identifier) else {
                    throw PreviewFailure("Unknown time zone '\(identifier)'. Use an IANA name such as Europe/Berlin.")
                }
                timeZone = zone
            case "--logo":
                let value = try requireValue(argument)
                guard let choice = AppearanceSelection(rawValue: value) else {
                    throw PreviewFailure("Unknown logo '\(value)'. Valid names: \(AppearanceSelection.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                selection = choice
            case "--appearance":
                switch try requireValue(argument) {
                case "light": schemes = [.light]
                case "dark": schemes = [.dark]
                case "both": schemes = [.dark, .light]
                default: throw PreviewFailure("Appearance must be light, dark or both.")
                }
            case "--check-assets": checkAssets = true
            case "--update-version": updateVersion = try requireValue(argument)
            case "--refreshing": refreshingDemo = true
            case "--help", "-h": help = true
            default:
                guard !argument.hasPrefix("-"), path == nil, !modeWasSet else {
                    throw PreviewFailure("Unexpected argument '\(argument)'.")
                }
                path = argument
            }
            index += 1
        }
        if let dateText {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let date = formatter.date(from: dateText), formatter.string(from: date) == dateText else {
                throw PreviewFailure("Invalid date '\(dateText)'. Use a valid YYYY-MM-DD date.")
            }
            referenceDate = date
        }
        if (mode == .serviceMatrix || mode == .canonical), selection == .automatic { selection = .standard }
    }

    var settings: AppearanceSettings { AppearanceSettings(selection: selection) }
    var variant: BrandVariant { settings.resolvedVariant(at: referenceDate, timeZone: timeZone) }
    var directory: URL { URL(fileURLWithPath: path ?? "screenshots", isDirectory: true) }
    func suffix(for scheme: ColorScheme) -> String { scheme == .dark ? "" : "-light" }
}

private struct PreviewFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct NativeWidgetRender: Codable {
    let snapshot: UsageSnapshot
    let family: Int
    let size: CGSize
    let providers: [MeterProvider]
    let selectedModuleIDs: [String]?
    let referenceDate: Date
    let timeZone: String
    let destination: URL
}

/// Independent synthetic workspace readings; never split or borrow provider totals.
private enum PreviewWorkspaceActivity {
    static func identityHash(_ id: String) -> String {
        SHA256.hash(data: Data("synthetic-workspace:\(id)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func totals(_ total: Int) -> CodexTokenTotals {
        let output = total / 5
        return CodexTokenTotals(totalTokens: total, inputTokens: total - output,
                                cachedInputTokens: total / 10, outputTokens: output,
                                reasoningTokens: output / 4, sessionCount: total == 0 ? 0 : 2)
    }

    static func history(_ values: [Int], id: String, referenceDate: Date) -> TokenHistory<CodexTokenTotals> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: referenceDate)
        let days = values.enumerated().map { index, value in
            TokenHistoryDay(date: calendar.date(byAdding: .day, value: index - values.count + 1, to: today)!,
                            totals: totals(value))
        }
        return TokenHistory(sourceID: "synthetic-workspace-\(id)", timeZoneIdentifier: "GMT",
                            days: days, totals: totals(values.reduce(0, +)))
    }

    static func accountActivity(_ values: [Int], id: String, referenceDate: Date) -> CodexAccountTokenActivity {
        let calendar = CodexAccountTokenDay.labelCalendar
        let serviceDay = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: referenceDate))!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let days = values.enumerated().map { index, value in
            CodexAccountTokenDay(
                date: formatter.string(from: calendar.date(byAdding: .day, value: index - values.count + 1, to: serviceDay)!),
                tokens: value)
        }
        return CodexAccountTokenActivity(workspaceAccountIDHash: identityHash(id), dailyUsage: days,
                                          lifetimeTokens: nil, statsAsOf: formatter.string(from: serviceDay))
    }
}

/// Frozen synthetic reproduction of the four-card desktop layout. No live usage is read.
private enum FourRowWidgetPreview {
    static let providers: [MeterProvider] = [.codex, .claude, .cursor]
    static let selectedModuleIDs = ["codex-workspace:four-rows-personal", "codex-workspace:four-rows-plus",
                                    "service:claude", "service:cursor"]

    static func snapshot(referenceDate now: Date) -> UsageSnapshot {
        let base = UsageSnapshot.monitoringPreview
        func ready<T>(_ value: T) -> UsageValue<T> {
            UsageValue(status: .ready, source: .preview, measuredAt: now, lastAttemptAt: now, message: nil, value: value)
        }
        func weekly(_ label: String, percent: Double, resetAfter: TimeInterval,
                    fiveHourResetAfter: TimeInterval? = nil) -> CompactQuota {
            var quota = CompactQuota(label: "\(label) Week", used: nil, limit: nil, remaining: nil,
                                     remainingPercent: percent, resetAt: now.addingTimeInterval(resetAfter),
                                     windowSeconds: 604_800, detail: "\(Int(percent.rounded()))% left")
            if let fiveHourResetAfter {
                let fiveHour = CompactQuota(label: "\(label) 5h", used: nil, limit: nil, remaining: nil,
                                            remainingPercent: 99, resetAt: now.addingTimeInterval(fiveHourResetAfter),
                                            windowSeconds: 18_000, detail: "99% left")
                quota.windows = [fiveHour, quota]
            }
            return quota
        }
        let personal = weekly("Codex", percent: 76, resetAfter: 6 * 86_400 + 2 * 3_600)
        let plus = weekly("Codex", percent: 81, resetAfter: 6 * 86_400 + 4 * 3_600,
                          fiveHourResetAfter: 4 * 3_600 + 23 * 60)
        var claude = weekly("Claude", percent: 74, resetAfter: 3 * 86_400 + 22 * 3_600,
                            fiveHourResetAfter: 3 * 3_600 + 30 * 60)
        // Synthetic known metadata matches the credential-derived plan format.
        claude.planName = "Claude Max 20x"
        // Enterprise mirrors cursor-summary-v3.json membership metadata; amounts remain synthetic.
        let cursor = CompactQuota(planName: "Enterprise", label: "Cursor Monthly", used: 667.94, limit: 790, remaining: 122.06,
                                  remainingPercent: nil, resetAt: now.addingTimeInterval(8 * 86_400 + 8 * 3_600),
                                  windowSeconds: 31 * 86_400, detail: "$122.06 left")
        let accounts = [
            CodexAccountUsage(id: "four-rows-personal", homeID: "four-rows-home-personal",
                              displayName: "demo@example.test · Personal", quota: ready(personal),
                              resetCards: ready(ResetCardInventory(availableCount: 1, observedAt: now, batches: [])),
                              workspaceName: "Personal", accountName: "demo@example.test", planName: "Pro",
                              workspaceAccountIDHash: PreviewWorkspaceActivity.identityHash("personal"),
                              tokens: ready(PreviewWorkspaceActivity.totals(42_800)),
                              history: ready(PreviewWorkspaceActivity.history([12_000, 0, 31_500, 18_200, 55_900, 9_400, 42_800],
                                  id: "personal", referenceDate: now)),
                              tokenActivity: ready(PreviewWorkspaceActivity.accountActivity(
                                  [12_000, 0, 31_500, 18_200, 55_900, 9_400, 42_800], id: "personal", referenceDate: now))),
            CodexAccountUsage(id: "four-rows-plus", homeID: "four-rows-home-plus",
                              displayName: "demo@example.test · Plus", quota: ready(plus),
                              resetCards: ready(ResetCardInventory(availableCount: 2, observedAt: now, batches: [])),
                              workspaceName: "Plus", accountName: "demo@example.test", planName: "Plus",
                              workspaceAccountIDHash: PreviewWorkspaceActivity.identityHash("plus"),
                              tokens: ready(PreviewWorkspaceActivity.totals(137_600)),
                              history: ready(PreviewWorkspaceActivity.history([93_000, 117_500, 0, 84_200, 156_900, 61_400, 137_600],
                                  id: "plus", referenceDate: now)),
                              tokenActivity: ready(PreviewWorkspaceActivity.accountActivity(
                                  [93_000, 117_500, 0, 84_200, 156_900, 61_400, 137_600], id: "plus", referenceDate: now)))
        ]
        return UsageSnapshot(schemaVersion: base.schemaVersion, generatedAt: now,
                             codexTokens: base.codexTokens, cursorCosts: base.cursorCosts,
                             cursorQuota: ready(cursor), codexQuota: ready(personal),
                             claudeTokens: base.claudeTokens, claudeQuota: ready(claude),
                             deepseekUsage: base.deepseekUsage, codexAccounts: ready(accounts),
                             codexHistory: base.codexHistory, claudeHistory: base.claudeHistory,
                             claudeResetCards: base.claudeResetCards)
    }
}

/// Synthetic workspace records only. No production settings or credentials are read.
private struct WorkspacePreviewCase {
    enum Kind { case boundary, sameNames, longNames, quotaStates, cardStates, failedQuota, unknownQuota, legacySingleFallback }
    let name: String
    let workspaceCount: Int
    let kind: Kind

    static func cases(availableSlots: Int) -> [Self] {
        // Counts describe available source records, not automatic module expansion.
        let counts = Set([max(1, availableSlots - 1), availableSlots, availableSlots + 1, availableSlots + 4]).sorted()
        return counts.map { Self(name: String(format: "boundary-w%02d", $0), workspaceCount: $0, kind: .boundary) } + [
            Self(name: "same-names", workspaceCount: 3, kind: .sameNames),
            Self(name: "long-names", workspaceCount: 3, kind: .longNames),
            Self(name: "quota-states", workspaceCount: 3, kind: .quotaStates),
            Self(name: "card-states", workspaceCount: 4, kind: .cardStates),
            Self(name: "quota-failed-cards-valid", workspaceCount: 2, kind: .failedQuota),
            Self(name: "quota-unknown-cards-valid", workspaceCount: 1, kind: .unknownQuota),
            Self(name: "legacy-single-workspace-fallback", workspaceCount: 1, kind: .legacySingleFallback)
        ]
    }

    func snapshot(referenceDate now: Date) -> UsageSnapshot {
        let base = UsageSnapshot.monitoringPreview
        func ready<T>(_ value: T) -> UsageValue<T> {
            UsageValue(status: .ready, source: .preview, measuredAt: now, lastAttemptAt: now, message: nil, value: value)
        }
        let accounts = (0..<workspaceCount).map { index -> CodexAccountUsage in
            let number = index + 1
            let id = String(format: "demo-workspace-%02d", number)
            let workspaceName: String
            switch kind {
            case .sameNames: workspaceName = "Research"
            case .longNames:
                workspaceName = "Research workspace \(number) · Robotics, representation learning and long-running distributed experiments"
            default: workspaceName = "Workspace \(number)"
            }
            let accountName = kind == .sameNames ? "shared@example.test" : "member-\(number)@example.test"
            let percent: Double? = kind == .unknownQuota || kind == .quotaStates && index == 1 ? nil
                : kind == .quotaStates && index == 0 ? 0 : Double(100 - (number * 13) % 101)
            let quota = CompactQuota(label: "Codex Week", used: nil, limit: nil, remaining: nil,
                                     remainingPercent: percent, resetAt: now.addingTimeInterval(Double(number + 1) * 86_400),
                                     windowSeconds: 604_800, detail: "Synthetic workspace \(number) weekly allowance", windows: [
                                        CompactQuota(label: "Codex 5h", used: nil, limit: nil, remaining: nil,
                                                     remainingPercent: Double(max(0, 95 - number * 7)),
                                                     resetAt: now.addingTimeInterval(Double(number + 1) * 3_600),
                                                     windowSeconds: 18_000, detail: "Synthetic five-hour window"),
                                        CompactQuota(label: "Codex Week", used: nil, limit: nil, remaining: nil,
                                                     remainingPercent: percent,
                                                     resetAt: now.addingTimeInterval(Double(number + 1) * 86_400),
                                                     windowSeconds: 604_800, detail: "Synthetic weekly window")
                                     ])
            let quotaData: UsageValue<CompactQuota>
            if kind == .failedQuota || kind == .legacySingleFallback || kind == .quotaStates && index == 2 {
                quotaData = UsageValue(status: .error, source: .none, measuredAt: nil, lastAttemptAt: now,
                                       message: "Synthetic quota request failed; this workspace's cards remain valid.", value: nil)
            } else {
                quotaData = ready(quota)
            }
            let count = kind == .cardStates && index == 0 ? 0 : number % 3 + 1
            let expiry = kind == .cardStates && index == 3 ? nil : now.addingTimeInterval(Double(number + 5) * 3_600)
            let inventory = ResetCardInventory(availableCount: count, observedAt: now,
                batches: count == 0 ? [] : [ResetCardBatch(id: "\(id)-cards", count: count,
                                                         startsAt: now.addingTimeInterval(-3_600), expiresAt: expiry)])
            let cards: UsageValue<ResetCardInventory>
            if kind == .cardStates && index == 1 {
                cards = UsageValue(status: .unavailable, source: .none, measuredAt: nil, lastAttemptAt: now,
                                   message: "Synthetic card inventory has not been read.", value: nil)
            } else if kind == .cardStates && index == 2 {
                cards = UsageValue(status: .stale, source: .cache, measuredAt: now.addingTimeInterval(-600),
                                   lastAttemptAt: now, message: "Synthetic card refresh failed; valid cached cards remain.", value: inventory)
            } else {
                cards = ready(inventory)
            }
            return CodexAccountUsage(id: id, homeID: "demo-home-\(number)",
                                     displayName: "\(accountName) · \(workspaceName)", quota: quotaData,
                                     resetCards: cards, workspaceName: workspaceName, accountName: accountName,
                                     planName: number.isMultiple(of: 2) ? "Business" : "Pro",
                                     workspaceAccountIDHash: PreviewWorkspaceActivity.identityHash(id),
                                     tokens: ready(PreviewWorkspaceActivity.totals(17_350 * number)),
                                     history: ready(PreviewWorkspaceActivity.history(
                                        [9_100, 15_600, 0, 12_300, 21_800, 6_200, 17_350].map { $0 * number },
                                        id: id, referenceDate: now)),
                                     tokenActivity: ready(PreviewWorkspaceActivity.accountActivity(
                                        [9_100, 15_600, 0, 12_300, 21_800, 6_200, 17_350].map { $0 * number },
                                        id: id, referenceDate: now)))
        }
        return UsageSnapshot(schemaVersion: base.schemaVersion, generatedAt: now,
                                     codexTokens: base.codexTokens, cursorCosts: base.cursorCosts,
                                     cursorQuota: base.cursorQuota, codexQuota: base.codexQuota,
                                     claudeTokens: base.claudeTokens, claudeQuota: base.claudeQuota,
                                     deepseekUsage: base.deepseekUsage, codexAccounts: ready(accounts),
                                     codexHistory: base.codexHistory, claudeHistory: base.claudeHistory,
                                     claudeResetCards: base.claudeResetCards)
    }
}

private struct WorkspacePreviewRecord: Codable {
    let family: String
    let appearance: String
    let configuration: String
    let scenario: String
    let maximumVisibleCards: Int
    let workspaceCount: Int
    let expectedVisibleCardCount: Int
    let expectedOverflowCount: Int
    let expectedVisibleWorkspaceIDs: [String]
    let selectedModuleIDs: [String]
    let expectedVisibleItemIDs: [String]
    let expectationNote: String
    let enabledProviders: [String]
    let image: String
    let fixture: String
}

private struct WorkspacePreviewManifest: Codable {
    let previewOnly: Bool
    let note: String
    let widgetContentContract: String
    let hiddenFixtureData: [String]
    let referenceDate: Date
    let timeZone: String
    let records: [WorkspacePreviewRecord]
}

@main
struct PreviewRenderer {
    @MainActor private static var nativeJobs: [NativeWidgetRender] = []
    @MainActor private static var aliases: [(URL, URL)] = []
    private static let widgetSizes: [(WidgetFamily, CGSize, String)] = [
        (.systemSmall, CGSize(width: 174, height: 174), "small"),
        (.systemMedium, CGSize(width: 352, height: 174), "medium"),
        (.systemLarge, CGSize(width: 352, height: 352), "large"),
        (.systemExtraLarge, CGSize(width: 710, height: 352), "extra-large")
    ]

    @MainActor
    static func main() {
        do {
            if ProcessInfo.processInfo.environment["BEAVERMETER_PREVIEW_NATIVE_BATCH"] == "1" {
                let jobs = try JSONDecoder().decode([NativeWidgetRender].self,
                                                   from: FileHandle.standardInput.readDataToEndOfFile())
                for job in jobs {
                    guard let family = WidgetFamily(rawValue: job.family) else { throw PreviewFailure("Invalid widget family") }
                    var options = try PreviewOptions(arguments: ["--time-zone", job.timeZone])
                    options.referenceDate = job.referenceDate
                    let content = widget(job.snapshot, family: family, providers: job.providers, options: options,
                                         selectedModuleIDs: job.selectedModuleIDs)
                        .frame(width: job.size.width, height: job.size.height)
                        .environment(\.colorScheme, .dark)
                        .environment(\.isRenderingUsagePreview, true)
                        .environment(\.locale, Locale(identifier: "en_US"))
                        .environment(\.timeZone, options.timeZone)
                    renderNativeMaterial(content, size: job.size, appearance: NSAppearance(named: .darkAqua)!, to: job.destination)
                }
                return
            }
            let options = try PreviewOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.help { print(PreviewOptions.usage); return }
            if options.checkAssets {
                try checkAssets()
                if options.path == nil, options.mode == .screenshots { return }
            }
            switch options.mode {
            case .canonical: try renderCanonical(options: options)
            case .widgets: try renderWidgetMatrix(options: options)
            case .widgetAppearances: try renderWidgetAppearances(options: options)
            case .serviceMatrix: try renderServiceMatrix(options: options)
            case .workspaceMatrix: try renderWorkspaceMatrix(options: options)
            case .holidays: try renderHolidays(options: options)
            case .interactive:
                showInteractivePreview(snapshotURL: URL(fileURLWithPath: options.path!), options: options)
            case .interactiveDemo: showInteractivePreview(snapshotURL: nil, options: options)
            case .screenshots: try renderScreenshots(options: options)
            }
            if !nativeJobs.isEmpty {
                guard let executable = Bundle.main.executableURL else { throw PreviewFailure("Missing renderer executable") }
                let result = try SubprocessRunner.run(executable: executable, arguments: [],
                    standardInput: JSONEncoder().encode(nativeJobs), timeout: 60,
                    environment: ["BEAVERMETER_PREVIEW_NATIVE_BATCH": "1"])
                guard result.status == 0, !result.timedOut else {
                    throw PreviewFailure("Native material export failed: \(String(decoding: result.standardError, as: UTF8.self))")
                }
                FileHandle.standardOutput.write(result.standardOutput)
                nativeJobs.removeAll()
            }
            for (source, destination) in aliases {
                try Data(contentsOf: source).write(to: destination, options: .atomic)
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n\n\(PreviewOptions.usage)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func appearance(_ options: PreviewOptions, variant: BrandVariant? = nil) -> AppearanceStore {
        let settings = variant.map { AppearanceSettings(selection: AppearanceSelection(rawValue: $0.rawValue)!) }
            ?? options.settings
        return AppearanceStore(settings: settings, observesChanges: false,
                               referenceDate: options.referenceDate, timeZone: options.timeZone)
    }

    @MainActor
    private static func updates(_ options: PreviewOptions) -> UpdateStore {
        let available = options.updateVersion.map {
            AvailableUpdate(version: $0, releaseURL: URL(string: "\(GitHubRelease.repositoryURL)/releases")!)
        }
        return UpdateStore(previewUpdate: available)
    }

    @MainActor
    private static func renderCanonical(options: PreviewOptions) throws {
        let directory = options.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = FourRowWidgetPreview.snapshot(referenceDate: options.referenceDate)
        var settings = ProviderSettings.default
        settings[.cursor] = .hidden
        settings[.deepseek] = .hidden
        func makeMenu(_ updateStore: UpdateStore) -> UsageMenuView {
            UsageMenuView(
                store: UsageStore(snapshot: snapshot, providerSettings: settings, observesSnapshotChanges: false),
                appearance: appearance(options), updates: updateStore, automaticRefresh: false, scrollsContent: false,
                updatedDescriptionOverride: "from demo data", viewHeight: 730, referenceDate: options.referenceDate,
                historyExpanded: false, accountsExpanded: false, resetCardsExpanded: false, appearanceExpanded: false)
        }
        let menu = makeMenu(UpdateStore(previewUpdate: nil))
        for scheme in options.schemes {
            if options.updateVersion != nil {
                render(makeMenu(updates(options)).background(Color(nsColor: .windowBackgroundColor)),
                    size: CGSize(width: 410, height: 730), scheme: scheme, options: options, naturalHeight: true,
                    to: directory.appendingPathComponent("menu-update-\(scheme == .dark ? "dark" : "light").png"))
            }
            render(menu.background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 410, height: 730),
                   scheme: scheme, options: options, naturalHeight: true,
                   to: directory.appendingPathComponent("menu-monitoring-collapsed-\(scheme == .dark ? "dark" : "light").png"))
            for (family, size, name) in widgetSizes {
                renderWidget(snapshot, family: family, providers: FourRowWidgetPreview.providers, size: size,
                    scheme: scheme, options: options, selectedModuleIDs: FourRowWidgetPreview.selectedModuleIDs,
                    to: directory.appendingPathComponent("widget-\(name)\(options.suffix(for: scheme)).png"))
            }
        }
        let boundary = WorkspacePreviewCase(name: "six-modules", workspaceCount: 3, kind: .boundary)
            .snapshot(referenceDate: options.referenceDate)
        let six = ["codex-workspace:demo-workspace-01", "codex-workspace:demo-workspace-02", "service:claude",
                   "service:cursor", "service:deepseek", "codex-workspace:demo-workspace-03"]
        for (family, size, name) in widgetSizes where family == .systemLarge || family == .systemExtraLarge {
            for scheme in options.schemes {
                renderWidget(boundary, family: family, providers: MeterProvider.allCases, size: size,
                    scheme: scheme, options: options, selectedModuleIDs: six,
                    to: directory.appendingPathComponent("widget-\(name)-six-modules\(options.suffix(for: scheme)).png"))
            }
        }
        let overview = HStack(alignment: .center, spacing: 54) {
            VStack(alignment: .leading, spacing: 25) {
                HStack(spacing: 16) {
                    BrandLogoView(variant: .standard, size: 76)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("BeaverMeter").font(.system(size: 43, weight: .bold, design: .rounded))
                        Text("Your AI usage, at a glance.").font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Remaining allowance.\nWorkspace usage. One quiet place.")
                    .font(.system(size: 26, weight: .medium)).lineSpacing(6)
                HStack(alignment: .top, spacing: 16) {
                    widget(snapshot, family: .systemSmall, providers: FourRowWidgetPreview.providers,
                           options: options, selectedModuleIDs: FourRowWidgetPreview.selectedModuleIDs)
                        .frame(width: 174, height: 174)
                    widget(snapshot, family: .systemMedium, providers: FourRowWidgetPreview.providers,
                           options: options, selectedModuleIDs: FourRowWidgetPreview.selectedModuleIDs)
                        .frame(width: 352, height: 174)
                }
                HStack(spacing: 24) {
                    Label("Native macOS", systemImage: "macwindow")
                    Label("Local credentials", systemImage: "lock")
                    Label("Choose your modules", systemImage: "square.grid.2x2")
                }.font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Text("DEMO DATA · FOUR WIDGET SIZES · LIGHT & DARK")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            }.frame(width: 650, alignment: .leading)
            menu.background(Color.white).clipShape(RoundedRectangle(cornerRadius: 22))
                .frame(width: 410).scaleEffect(0.86)
        }
        .padding(64).frame(width: 1280, height: 800)
        .background(Color(red: 0.966, green: 0.96, blue: 0.94))
        render(overview, size: CGSize(width: 1280, height: 800), scheme: .light, options: options,
               to: directory.appendingPathComponent("brand-overview.png"))
    }

    @MainActor
    private static func renderScreenshots(options: PreviewOptions) throws {
        let directory = options.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in options.schemes {
            let mark = BrandLogoView(variant: options.variant, size: 18, template: true)
            .foregroundStyle(scheme == .dark ? Color.white : Color.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
            render(mark, size: CGSize(width: 24, height: 24), scheme: scheme, options: options,
                   to: directory.appendingPathComponent("menu-bar-mark\(options.suffix(for: scheme)).png"))
        }
        var monitoringSettings = ProviderSettings.default
        monitoringSettings[.cursor] = .hidden
        monitoringSettings[.deepseek] = .hidden
        for expanded in [false, true] {
            let height = UsageMenuView.fittedHeight(
                for: [.codex, .claude], maxHeight: expanded ? 1250 : 650,
                claudeWindowCount: UsageSnapshot.monitoringPreview.claudeQuota.value?.windows?.count ?? 0,
                expandedMonitoringHeight: expanded ? 800 : 0
            )
            let menu = UsageMenuView(
                store: UsageStore(snapshot: .monitoringPreview, providerSettings: monitoringSettings, observesSnapshotChanges: false),
                appearance: appearance(options), updates: updates(options),
                refreshingOverride: options.refreshingDemo, automaticRefresh: false, scrollsContent: false,
                updatedDescriptionOverride: "from demo data", viewHeight: height, referenceDate: options.referenceDate,
                historyExpanded: expanded, accountsExpanded: expanded, resetCardsExpanded: expanded
            )
            for scheme in options.schemes {
                render(menu.background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 410, height: height), scheme: scheme, options: options, naturalHeight: true,
                       to: directory.appendingPathComponent("menu-monitoring-\(expanded ? "expanded" : "collapsed")-\(scheme == .dark ? "dark" : "light").png"))
            }
        }

        let servicesSnapshot = UsageSnapshot.monitoringPreview
        for showsAppearance in [false, true] {
            let height = UsageMenuView.fittedHeight(
                for: MeterProvider.allCases, maxHeight: 1_300, servicesExpanded: !showsAppearance,
                claudeWindowCount: servicesSnapshot.claudeQuota.value?.windows?.count ?? 0,
                expandedMonitoringHeight: showsAppearance ? 95 : 0
            )
            let menu = UsageMenuView(
                store: UsageStore(snapshot: servicesSnapshot, providerSettings: .default, observesSnapshotChanges: false),
                appearance: appearance(options), automaticRefresh: false, scrollsContent: false,
                updatedDescriptionOverride: "from demo data", viewHeight: height, referenceDate: options.referenceDate,
                servicesExpanded: !showsAppearance, appearanceExpanded: showsAppearance
            )
            for scheme in options.schemes {
                render(menu.background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 410, height: height), scheme: scheme, options: options, naturalHeight: true,
                       to: directory.appendingPathComponent("menu-popover-\(showsAppearance ? "appearance" : "services")\(options.suffix(for: scheme)).png"))
            }
        }

        for scenario in UsagePreviewScenario.allCases {
            let suffix = scenario == .normal ? "" : "-\(scenario.rawValue)"
            let snapshot = scenario.snapshot
            let providers = scenario.providerSettings.visibleProviders(in: snapshot)
            let height = UsageMenuView.fittedHeight(
                for: providers, maxHeight: scenario == .longList ? 1_950 : scenario == .refreshError ? 1_360 : 1_220,
                claudeWindowCount: snapshot.claudeQuota.value?.windows?.count ?? 0
            )
            for scheme in options.schemes {
                let menu = UsageMenuView(
                    store: UsageStore(snapshot: snapshot, providerSettings: scenario.providerSettings, observesSnapshotChanges: false),
                    appearance: appearance(options), automaticRefresh: false, scrollsContent: false,
                    updatedDescriptionOverride: "from demo data", viewHeight: height, referenceDate: options.referenceDate,
                    refreshErrorOverride: scenario == .refreshError ? "Refresh failed; the previous data was preserved." : nil
                )
                render(menu.background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 410, height: height), scheme: scheme, options: options, naturalHeight: true,
                       to: directory.appendingPathComponent("menu-popover\(suffix)\(options.suffix(for: scheme)).png"))
                for (family, size, name) in widgetSizes {
                    let destination = directory.appendingPathComponent("widget-\(name)\(suffix)\(options.suffix(for: scheme)).png")
                    renderWidget(snapshot, family: family, providers: providers, size: size,
                                 scheme: scheme, options: options, to: destination)
                    if [.oneService, .codexClaudeOnly, .withoutCursor].contains(scenario) {
                        let count = providers.count
                        let alias = directory.appendingPathComponent("widget-\(name)-\(count)-service\(count == 1 ? "" : "s")\(options.suffix(for: scheme)).png")
                        aliases.append((destination, alias))
                    }
                    if scenario == .remoteUnavailable {
                        let alias = directory.appendingPathComponent("widget-\(name)-remote-unavailable\(options.suffix(for: scheme)).png")
                        aliases.append((destination, alias))
                    }
                }
            }
        }
        let fourRows = FourRowWidgetPreview.snapshot(referenceDate: options.referenceDate)
        for (family, size, name) in widgetSizes {
            for scheme in options.schemes {
                renderWidget(fourRows, family: family, providers: FourRowWidgetPreview.providers, size: size,
                             scheme: scheme, options: options, selectedModuleIDs: FourRowWidgetPreview.selectedModuleIDs,
                             to: directory.appendingPathComponent("widget-\(name)-four-rows\(options.suffix(for: scheme)).png"))
            }
        }
        render(overview(options: options), size: CGSize(width: 1280, height: 800), scheme: .light,
               options: options, to: directory.appendingPathComponent("brand-overview.png"))
    }

    /// Every service combination, including empty, across all widget families.
    @MainActor
    private static func renderWidgetMatrix(options: PreviewOptions) throws {
        let directory = options.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scenario in [UsagePreviewScenario.normal, .zero, .stale, .unavailable, .signedOut, .error,
                         .largeValues, .remoteUnavailable, .rateLimited, .longWindows,
                         .missingHistory, .previousDay, .longList] {
            for mask in 0..<16 {
                let providers = MeterProvider.allCases.enumerated().compactMap { index, provider in
                    mask & (1 << index) != 0 ? provider : nil
                }
                let services = providers.isEmpty ? "none" : providers.map(\.rawValue).joined(separator: "-")
                for (family, size, name) in widgetSizes {
                    for scheme in options.schemes {
                        renderWidget(scenario.snapshot, family: family, providers: providers, size: size,
                               scheme: scheme, options: options,
                               to: directory.appendingPathComponent("\(name)-\(services)-\(scenario.rawValue)\(options.suffix(for: scheme)).png"))
                    }
                }
            }
        }
    }

    /// Exercises the view's rendering-mode branches with a legible preview
    /// background. WidgetKit's host compositing is not reproduced here.
    @MainActor
    private static func renderWidgetAppearances(options: PreviewOptions) throws {
        let directory = options.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let modes: [(WidgetRenderingMode, String)] = [
            (.fullColor, "full-color"),
            (.vibrant, "vibrant-design"),
            (.accented, "accented-design")
        ]
        let snapshot = FourRowWidgetPreview.snapshot(referenceDate: options.referenceDate)
        for (mode, modeName) in modes {
            for scheme in [ColorScheme.dark, .light] {
                let schemeName = scheme == .dark ? "dark" : "light"
                for (family, size, sizeName) in widgetSizes {
                    // Reduced-color previews show the foreground design on a
                    // dark proofing canvas. Wallpaper adaptation belongs to the host.
                    let content = QuotaWidgetContent(snapshot: snapshot, family: family,
                                                     providers: FourRowWidgetPreview.providers,
                                                     referenceDate: options.referenceDate,
                                                     selectedModuleIDs: FourRowWidgetPreview.selectedModuleIDs)
                        .background(QuotaWidgetBackground().environment(\.colorScheme,
                            mode == .fullColor ? scheme : .dark))
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .environment(\.widgetRenderingMode, mode)
                    render(content, size: size, scheme: scheme, options: options,
                           to: directory.appendingPathComponent("widget-\(sizeName)-\(modeName)-\(schemeName).png"))
                }
            }
        }
        print("Rendered 24 widget design previews; WidgetKit host compositing is not simulated.")
    }

    /// Offline layout proofs only: ImageRenderer does not exercise WidgetKit
    /// registration, timelines, host compositing or the installed application.
    @MainActor
    private static func renderWorkspaceMatrix(options: PreviewOptions) throws {
        let directory = options.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let configurations: [(String, [MeterProvider])] = [("codex-only", [.codex]), ("all-services", MeterProvider.allCases)]
        let moduleSizes: [ProviderWidgetSize] = [.small, .medium, .large, .extraLarge]
        var records: [WorkspacePreviewRecord] = []
        for (index, widgetSize) in widgetSizes.enumerated() {
            let (family, size, familyName) = widgetSize
            let moduleSize = moduleSizes[index]
            let cap = WidgetComposition.capacity(for: moduleSize)
            for (configuration, providers) in configurations {
                for scenario in WorkspacePreviewCase.cases(availableSlots: cap) {
                    let snapshot = scenario.snapshot(referenceDate: options.referenceDate)
                    let selectedModuleIDs = WidgetModuleCatalog.defaults(snapshot: snapshot, providers: providers)
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = options.timeZone
                    let composition = WidgetComposition(snapshot: snapshot, providers: providers, size: moduleSize,
                                                        referenceDate: options.referenceDate, calendar: calendar,
                                                        selectedModuleIDs: selectedModuleIDs)
                    let relativeDirectory = "\(familyName)/\(configuration)/\(scenario.name)"
                    let destination = directory.appendingPathComponent(relativeDirectory, isDirectory: true)
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    let fixture = "\(relativeDirectory)/snapshot.json"
                    try encoder.encode(snapshot).write(to: directory.appendingPathComponent(fixture), options: .atomic)
                    for scheme in options.schemes {
                        let appearance = scheme == .dark ? "dark" : "light"
                        let imageName = "\(relativeDirectory)/\(appearance).png"
                        render(widget(snapshot, family: family, providers: providers, options: options,
                                      selectedModuleIDs: selectedModuleIDs), size: size,
                               scheme: scheme, options: options, to: directory.appendingPathComponent(imageName))
                        records.append(WorkspacePreviewRecord(
                            family: familyName, appearance: appearance, configuration: configuration,
                            scenario: scenario.name, maximumVisibleCards: cap, workspaceCount: scenario.workspaceCount,
                            expectedVisibleCardCount: composition.items.count,
                            expectedOverflowCount: composition.overflowWorkspaceCount,
                            expectedVisibleWorkspaceIDs: composition.items.filter(\.isCodexWorkspace).map {
                                String($0.id.dropFirst(WidgetModuleCatalog.workspacePrefix.count))
                            },
                            selectedModuleIDs: selectedModuleIDs,
                            expectedVisibleItemIDs: composition.items.map(\.id),
                            expectationNote: scenario.kind == .legacySingleFallback
                                ? "Historical case name: the explicitly selected failed workspace remains unavailable and never borrows ambient quota. No automatic expansion or +N."
                                : "Selected slot order is authoritative, with caps 2/4/6/6. Source workspaces do not auto-expand. Each Codex module keeps its own quota, plan, tokens and history; missing workspace activity never borrows provider-wide totals. Extra Large with exactly four visible modules in 2x2 omits seven-day statistics/trends while keeping quota/current usage; other Extra Large counts retain available history.",
                            enabledProviders: providers.map(\.rawValue), image: imageName, fixture: fixture))
                    }
                }
            }
        }
        let note = "Offline design previews only; not installed WidgetKit screenshots or runtime verification. Selected slot order, caps 2/4/6/6; enabled services do not imply every module is visible."
        let manifest = WorkspacePreviewManifest(previewOnly: true, note: note,
                                               widgetContentContract: "One module is one service or workspace with both principal windows. Ordered slots, caps 2/4/6/6, no automatic expansion or +N. Small primary reset; Medium window details; Large module usage. Extra Large with exactly four visible modules in 2x2 keeps quota/current usage without seven-day statistics/trends; other Extra Large counts retain available module history. Codex tokens/history come only from that selected workspace account; legacy or missing readings remain unknown even when provider-wide totals exist. No global footer.",
                                               hiddenFixtureData: ["tokenBreakdowns", "cursorRecentCalls", "resetCards",
                                                                   "resetCardExpiry", "cursorUsed", "cursorLimit"],
                                               referenceDate: options.referenceDate,
                                               timeZone: options.timeZone.identifier, records: records)
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        try workspaceGallery(records: records, note: note)
            .write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        for (_, _, familyName) in widgetSizes {
            for scheme in options.schemes {
                let appearance = scheme == .dark ? "dark" : "light"
                let boundaries = records.filter { $0.family == familyName && $0.appearance == appearance && $0.scenario.hasPrefix("boundary-") }
                try renderWorkspaceContactSheet(boundaries, directory: directory, family: familyName, appearance: appearance)
            }
        }
        print("Rendered \(records.count) selected-module design previews, synthetic snapshots, manifest and contact sheets.")
    }

    private static func workspaceGallery(records: [WorkspacePreviewRecord], note: String) -> String {
        let figures = records.map { record in
            """
            <figure><figcaption>\(record.family) · \(record.configuration) · \(record.scenario) · \(record.appearance)</figcaption>
            <p>\(record.workspaceCount) source workspaces · \(record.expectedVisibleCardCount)/\(record.maximumVisibleCards) selected modules</p><p>Slots: \(record.selectedModuleIDs.joined(separator: ", "))</p>
            <p>\(record.expectationNote)</p>
            <a href="\(record.image)"><img src="\(record.image)" alt="\(record.scenario) offline selected-module widget preview" loading="lazy"></a>
            <a href="\(record.fixture)">Synthetic snapshot JSON</a></figure>
            """
        }.joined(separator: "\n")
        return """
        <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Workspace quota widget design previews</title><style>
        body{margin:24px;background:#18191b;color:#eee;font:14px/1.5 system-ui}h1{font-size:24px}
        main{display:grid;grid-template-columns:repeat(auto-fit,minmax(330px,1fr));gap:20px}
        figure{margin:0;padding:16px;background:#242529;border-radius:12px}figcaption{font-weight:600}
        p{color:#bbb}a{color:#aad1ff}img{display:block;max-width:100%;max-height:370px;margin:12px auto;object-fit:contain}
        </style><h1>Workspace quota widget design previews</h1><p>\(note)</p>
        <p>Small 2 · Medium 4 · Large 6 · Extra Large 6 modules. One module is one service or workspace with both windows. Selected slot order is authoritative; no automatic workspace expansion or +N.</p>
        <p>Small shows quota summaries and the primary reset; Medium adds window details. Large adds usage inside the selected module. Extra Large with exactly four visible modules in 2x2 keeps quota/current usage without seven-day statistics/trends; other Extra Large counts retain available module history. Each Codex workspace has independent synthetic token/history readings; provider-wide totals never fill a missing workspace reading. There is no global footer.</p>
        <p>Large uses full-width rows for two to four modules, then two columns for five or six. Extra source workspaces test isolation rather than overflow. Inventory/expiry, monthly budget used/limit, token breakdowns and individual calls remain menu-only; hidden inventory errors never affect quota status.</p>
        <main>\(figures)</main></html>
        """
    }

    @MainActor
    private static func renderWorkspaceContactSheet(_ records: [WorkspacePreviewRecord], directory: URL,
                                                    family: String, appearance: String) throws {
        let columns = family == "extra-large" ? 2 : 4
        let rows = Int(ceil(Double(records.count) / Double(columns)))
        let cellWidth: CGFloat = family == "extra-large" ? 700 : 350
        let gap: CGFloat = 18, margin: CGFloat = 24, header: CGFloat = 82
        let imageHeight: CGFloat = family == "small" ? 280 : family == "large" || family == "extra-large" ? 347 : 175
        let labelHeight: CGFloat = 44
        let cellHeight = labelHeight + imageHeight
        let width = Int(margin * 2 + cellWidth * CGFloat(columns) + gap * CGFloat(columns - 1))
        let height = Int(margin * 2 + header + cellHeight * CGFloat(rows) + gap * CGFloat(max(0, rows - 1)))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw PreviewFailure("Cannot allocate workspace contact sheet.")
        }
        bitmap.size = NSSize(width: CGFloat(width), height: CGFloat(height))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let dark = appearance == "dark"
        (dark ? NSColor(calibratedWhite: 0.08, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
        let textColor = dark ? NSColor.white : NSColor.black
        func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat) {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
                                                             .foregroundColor: textColor]
            (value as NSString).draw(in: NSRect(x: x, y: y, width: width, height: 24), withAttributes: attributes)
        }
        text("\(family) · \(appearance) · selected module boundaries", x: margin, y: CGFloat(height) - margin - 25,
             width: CGFloat(width) - 2 * margin, size: 21)
        text("Offline design previews · not WidgetKit host verification", x: margin, y: CGFloat(height) - margin - 51,
             width: CGFloat(width) - 2 * margin, size: 13)
        for (index, record) in records.enumerated() {
            let column = index % columns, row = index / columns
            let x = margin + CGFloat(column) * (cellWidth + gap)
            let top = CGFloat(height) - margin - header - CGFloat(row) * (cellHeight + gap)
            text("\(record.configuration) · \(record.workspaceCount) workspaces", x: x, y: top - 20, width: cellWidth, size: 13)
            text("\(record.expectedVisibleCardCount)/\(record.maximumVisibleCards) selected modules",
                 x: x, y: top - 40, width: cellWidth, size: 12)
            guard let image = NSImage(contentsOf: directory.appendingPathComponent(record.image)),
                  image.size.width > 0, image.size.height > 0 else {
                throw PreviewFailure("Unreadable workspace preview: \(record.image)")
            }
            let scale = min(cellWidth / image.size.width, imageHeight / image.size.height)
            let fitted = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: x + (cellWidth - fitted.width) / 2, y: top - labelHeight - fitted.height,
                                  width: fitted.width, height: fitted.height),
                       from: NSRect(origin: .zero, size: image.size), operation: .sourceOver, fraction: 1)
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewFailure("Cannot encode workspace contact sheet.")
        }
        let output = directory.appendingPathComponent("workspace-\(family)-\(appearance)-boundaries.png")
        try png.write(to: output, options: .atomic)
        print("Rendered \(output.path)")
    }

    /// Shared, explicit switches keep the menu and Widget in the same configuration.
    @MainActor
    private static func renderServiceMatrix(options: PreviewOptions) throws {
        let snapshot = UsageSnapshot.monitoringPreview
        let directory = options.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for mask in 0..<(1 << MeterProvider.allCases.count) {
            var settings = ProviderSettings.default
            for (index, provider) in MeterProvider.allCases.enumerated() {
                settings[provider] = mask & (1 << index) != 0 ? .shown : .hidden
            }
            let providers = settings.visibleProviders(in: snapshot)
            let name = providers.isEmpty ? "none" : providers.map(\.rawValue).joined(separator: "-")
            let height = UsageMenuView.fittedHeight(
                for: providers, maxHeight: 2_000, servicesExpanded: true,
                claudeWindowCount: snapshot.claudeQuota.value?.windows?.count ?? 0
            )
            for scheme in options.schemes {
                let destination = directory.appendingPathComponent(name)
                    .appendingPathComponent(scheme == .light ? "light" : "dark")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                for (family, size, sizeName) in widgetSizes {
                    renderWidget(snapshot, family: family, providers: providers, size: size,
                           scheme: scheme, options: options,
                           to: destination.appendingPathComponent("widget-\(sizeName).png"))
                }
                let menu = UsageMenuView(
                    store: UsageStore(snapshot: snapshot, providerSettings: settings, observesSnapshotChanges: false,
                                      collectorScript: nil),
                    appearance: appearance(options), automaticRefresh: false, scrollsContent: false,
                    updatedDescriptionOverride: "from demo data", viewHeight: height,
                    referenceDate: options.referenceDate, servicesExpanded: true
                )
                render(menu.background(Color(nsColor: .windowBackgroundColor)),
                       size: CGSize(width: 410, height: height), scheme: scheme, options: options, naturalHeight: true,
                       to: destination.appendingPathComponent("menu.png"))
            }
        }
        try ServiceMatrixGallery.html(schemes: options.schemes.map { $0 == .light ? "light" : "dark" })
            .write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        print("Rendered service matrix: \(16 * options.schemes.count * 5) PNGs and index.html")
    }

    @MainActor
    private static func widget(_ snapshot: UsageSnapshot, family: WidgetFamily, providers: [MeterProvider],
                               options: PreviewOptions, selectedModuleIDs: [String]? = nil) -> some View {
        QuotaWidgetContent(snapshot: snapshot, family: family, providers: providers,
                           referenceDate: options.referenceDate, selectedModuleIDs: selectedModuleIDs)
            .background(QuotaWidgetBackground())
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @MainActor
    private static func renderWidget(_ snapshot: UsageSnapshot, family: WidgetFamily, providers: [MeterProvider],
                                     size: CGSize, scheme: ColorScheme, options: PreviewOptions,
                                     selectedModuleIDs: [String]? = nil, to destination: URL) {
        if scheme == .dark, ProcessInfo.processInfo.environment["BEAVERMETER_PREVIEW_RASTER_ONLY"] != "1" {
            nativeJobs.append(NativeWidgetRender(snapshot: snapshot, family: family.rawValue, size: size,
                providers: providers, selectedModuleIDs: selectedModuleIDs,
                referenceDate: options.referenceDate, timeZone: options.timeZone.identifier,
                destination: destination))
        } else {
            render(widget(snapshot, family: family, providers: providers, options: options,
                          selectedModuleIDs: selectedModuleIDs), size: size,
                   scheme: scheme, options: options, to: destination)
        }
    }

    @MainActor
    private static func renderHolidays(options: PreviewOptions) throws {
        let directory = options.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for variant in BrandVariant.allCases {
            for (family, size, name) in widgetSizes {
                for scheme in options.schemes {
                    renderWidget(.preview, family: family, providers: MeterProvider.allCases,
                                 size: size, scheme: scheme, options: options,
                           to: directory.appendingPathComponent("widget-\(name)-\(variant.rawValue)\(options.suffix(for: scheme)).png"))
                }
            }
        }
        for scheme in options.schemes {
            let sheet = VStack(alignment: .leading, spacing: 20) {
                Text("BeaverMeter · The seasonal collection")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                Text("One familiar face. Nine ways to greet the year.")
                    .font(.system(size: 14)).foregroundStyle(BrandStyle.secondary(scheme))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 14) {
                    ForEach(BrandVariant.allCases, id: \.self) { variant in
                        VStack(spacing: 10) {
                            BrandLogoView(variant: variant, size: 92)
                            Text(variant.displayName).font(.system(size: 12, weight: .semibold))
                            HStack(spacing: 14) {
                                ForEach([14, 18, 24, 32], id: \.self) { size in
                                    BrandLogoView(variant: variant, size: CGFloat(size), template: true)
                                        .foregroundStyle(BrandStyle.text(scheme))
                                }
                            }.frame(height: 32)
                        }
                        .frame(maxWidth: .infinity).padding(16).modifier(BrandSurface())
                    }
                }
            }
            .padding(28).foregroundStyle(BrandStyle.text(scheme)).background(BrandStyle.background(scheme))
            render(sheet, size: CGSize(width: 840, height: 740), scheme: scheme, options: options,
                   to: directory.appendingPathComponent("logo-collection\(options.suffix(for: scheme)).png"))
        }
    }

    @MainActor
    private static func overview(options: PreviewOptions) -> some View {
        var settings = ProviderSettings.default
        settings[.claude] = .hidden
        settings[.cursor] = .hidden
        settings[.deepseek] = .hidden
        return HStack(alignment: .center, spacing: 72) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 18) {
                    BrandLogoView(variant: options.variant, size: 82)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("BeaverMeter").font(.system(size: 48, weight: .semibold, design: .rounded))
                        Text("A little clarity for your AI day.")
                            .font(.system(size: 20, weight: .medium, design: .rounded))
                            .foregroundStyle(BrandStyle.secondary(.light))
                    }
                }
                Text("Tokens, quotas, costs and balance.\nQuietly at home on your Mac.")
                    .font(.system(size: 25, weight: .regular, design: .rounded))
                    .lineSpacing(5)
                HStack(spacing: 14) {
                    widget(.preview, family: .systemSmall, providers: [.codex], options: options)
                        .frame(width: 174, height: 174)
                    widget(.preview, family: .systemMedium, providers: MeterProvider.allCases, options: options)
                        .frame(width: 352, height: 174)
                }
                HStack(spacing: 20) {
                    Label("Native macOS", systemImage: "macwindow")
                    Label("Local credentials", systemImage: "lock")
                    Label("Seasonal logos", systemImage: "sparkles")
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(BrandStyle.secondary(.light))
                Text("DEMO DATA · LIGHT & DARK · FOUR WIDGET SIZES")
                    .font(.system(size: 9, weight: .medium)).tracking(1.4)
                    .foregroundStyle(BrandStyle.secondary(.light))
            }.frame(width: 600, alignment: .leading)
            UsageMenuView(
                store: UsageStore(snapshot: .monitoringPreview, providerSettings: settings, observesSnapshotChanges: false),
                appearance: appearance(options), automaticRefresh: false, scrollsContent: false,
                updatedDescriptionOverride: "from demo data", viewHeight: 530,
                referenceDate: options.referenceDate, appearanceExpanded: true
            )
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(BrandStyle.border(.light), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.12), radius: 28, x: 0, y: 12)
        }
        .padding(56)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(BrandStyle.text(.light)).background(BrandStyle.background(.light))
    }

    @MainActor
    private static func checkAssets() throws {
        let roots = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for provider in MeterProvider.allCases {
            for scheme in [ColorScheme.light, .dark] {
                guard let image = ProviderLogoAssets.image(for: provider, scheme: scheme),
                      image.size.width == 256, image.size.height == 256,
                      image.isTemplate == (scheme == .dark) else {
                    throw PreviewFailure("Missing or invalid provider logo: \(provider.rawValue), \(scheme).")
                }
                print("Validated service logo: \(provider.rawValue), \(scheme)")
            }
        }
        for variant in BrandVariant.allCases {
            for template in [false, true] {
                let filename = variant.assetName + (template ? "-template" : "") + ".png"
                let urls = roots.map { $0.appendingPathComponent("BrandAssets").appendingPathComponent(filename) }
                guard let url = urls.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                      let direct = NSImage(contentsOf: url), direct.size.width > 0, direct.size.height > 0 else {
                    throw PreviewFailure("Missing or unreadable bundled logo: BrandAssets/\(filename).")
                }
                guard let loaded = BrandLogoAssets.image(for: variant, template: template), loaded.isTemplate == template else {
                    throw PreviewFailure("Wrong NSImage template mode for \(filename).")
                }
                print("Validated \(filename) · \(Int(direct.size.width))×\(Int(direct.size.height)) · template=\(template)")
            }
        }
    }

    /// Test snapshots retain explicit refresh/login. The demo keeps every change in memory.
    @MainActor
    private static func showInteractivePreview(snapshotURL: URL?, options: PreviewOptions) {
        let snapshot = snapshotURL.map { UsageSnapshot.load(from: $0) } ?? .monitoringPreview
        let settings = snapshotURL.map {
            ProviderSettings.load(from: $0.deletingLastPathComponent().appendingPathComponent("beaver-meter-settings.json"))
        } ?? .default
        let app = NSApplication.shared
        let delegate = InteractivePreviewDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        let script = snapshotURL.map { _ in URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/collect_beaver_meter.sh") }
        let store = UsageStore(snapshot: snapshot, providerSettings: settings, observesSnapshotChanges: false,
                               snapshotURL: snapshotURL ?? FileManager.default.temporaryDirectory
                                .appendingPathComponent("beavermeter-interactive-demo/usage.json"),
                               allowsWorkspaceLogin: snapshotURL != nil, collectorScript: script)
        let view = UsageMenuView(
            store: store, appearance: appearance(options), automaticRefresh: false,
            updatedDescriptionOverride: snapshotURL == nil ? "from demo data" : "from local test data",
            viewHeight: 700, referenceDate: options.referenceDate
        )
        .environment(\.timeZone, options.timeZone)
        .environment(\.colorScheme, options.schemes.first ?? .light)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = snapshotURL == nil ? "BeaverMeter — Visual Demo" : "BeaverMeter — Local Test"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime((window, delegate)) { app.run() }
    }

    @MainActor
    private static func render<Content: View>(
        _ content: Content, size: CGSize, scheme: ColorScheme, options: PreviewOptions,
        naturalHeight: Bool = false, to destination: URL
    ) {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            let styledContent = content
                .frame(width: size.width, height: naturalHeight ? nil : size.height)
                .environment(\.colorScheme, scheme)
                .environment(\.isRenderingUsagePreview, true)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.timeZone, options.timeZone)
            // AppKit's indeterminate spinner cannot be captured by ImageRenderer.
            if options.refreshingDemo && naturalHeight {
                let hosting = NSHostingView(rootView: styledContent)
                renderNativeMaterial(styledContent,
                                     size: CGSize(width: size.width, height: hosting.fittingSize.height),
                                     appearance: appearance, to: destination)
                return
            }
            let renderer = ImageRenderer(content: styledContent)
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(width: size.width, height: naturalHeight ? nil : size.height)
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                fatalError("Could not render \(destination.lastPathComponent)")
            }
            do {
                try png.write(to: destination, options: .atomic)
                print("Rendered \(destination.path)")
            } catch { fatalError("Could not write \(destination.path): \(error.localizedDescription)") }
        }
    }

    /// ImageRenderer produces material texture artifacts. Cache an offscreen
    /// hosting view instead; no screen or wallpaper is captured and no window is shown.
    @MainActor
    private static func renderNativeMaterial<Content: View>(
        _ content: Content, size: CGSize, appearance: NSAppearance, to destination: URL
    ) {
        autoreleasepool {
            NSApplication.shared.setActivationPolicy(.accessory)
            let hosting = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.backgroundColor = .clear
            window.isOpaque = false
            window.contentView = hosting
            defer { window.contentView = nil; window.close() }
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                fatalError("Could not allocate material screenshot")
            }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let output: NSBitmapImageRep
            if bitmap.pixelsWide == Int(size.width * 2), bitmap.pixelsHigh == Int(size.height * 2) {
                guard let image = bitmap.cgImage else { fatalError("Could not read material screenshot") }
                // Drop AppKit cache-display metadata; keep standard PNG pixel sizing.
                output = NSBitmapImageRep(cgImage: image)
            } else {
                // External non-Retina displays still export the promised 2× PNG.
                guard let source = bitmap.cgImage,
                      let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    fatalError("Could not scale material screenshot")
                }
                context.interpolationQuality = .high
                context.draw(source, in: CGRect(origin: .zero, size: CGSize(width: size.width * 2, height: size.height * 2)))
                guard let image = context.makeImage() else { fatalError("Could not scale material screenshot") }
                output = NSBitmapImageRep(cgImage: image)
            }
            guard let png = output.representation(using: .png, properties: [:]) else {
                fatalError("Could not render \(destination.lastPathComponent)")
            }
            do {
                try png.write(to: destination, options: .atomic)
                print("Rendered \(destination.path)")
            } catch { fatalError("Could not write \(destination.path): \(error.localizedDescription)") }
        }
    }
}

private final class InteractivePreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
