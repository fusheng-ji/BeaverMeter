import Foundation

/// A service BeaverMeter can show. Named to avoid CodexBarCore's `UsageProvider`.
enum MeterProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case codex, claude, cursor, deepseek

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .deepseek: "DeepSeek"
        }
    }
}

enum ProviderVisibility: String, Codable, CaseIterable, Hashable, Sendable {
    /// Shown once the service has produced any value on this Mac.
    case auto
    case shown
    case hidden
}

/// User switches shared by the App, Widget and collector through a file next to
/// the snapshot, which the sandboxed Widget can already read.
struct ProviderSettings: Codable, Hashable, Sendable {
    private var visibility: [String: ProviderVisibility] = [:]

    static let `default` = ProviderSettings()

    subscript(provider: MeterProvider) -> ProviderVisibility {
        get { visibility[provider.rawValue] ?? .auto }
        set { visibility[provider.rawValue] = newValue == .auto ? nil : newValue }
    }

    /// Hidden services are neither collected nor displayed.
    func collects(_ provider: MeterProvider) -> Bool {
        self[provider] != .hidden
    }

    /// Visible services in display order. A snapshot where nothing is detected
    /// still shows every non-hidden service so a fresh install is not blank.
    func visibleProviders(in snapshot: UsageSnapshot) -> [MeterProvider] {
        let candidates = MeterProvider.allCases.filter(collects)
        let visible = candidates.filter { self[$0] == .shown || snapshot.isDetected($0) }
        return visible.isEmpty && !MeterProvider.allCases.contains(where: snapshot.isDetected) ? candidates : visible
    }

    static var settingsURL: URL {
        UsageSnapshot.snapshotURL.deletingLastPathComponent().appendingPathComponent("beaver-meter-settings.json")
    }

    static func load(from url: URL = settingsURL) -> ProviderSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(ProviderSettings.self, from: data)
        else { return .default }
        return settings
    }

    func save(to url: URL = Self.settingsURL) throws {
        try AtomicFileWriter.writeJSON(self, to: url, prettyPrinted: true)
    }
}

extension UsageSnapshot {
    /// A service is present once any of its values exists, even a stale one.
    func isDetected(_ provider: MeterProvider) -> Bool {
        switch provider {
        case .codex: codexTokens.value != nil || codexQuota.value != nil || codexHistory.value != nil
            || (codexAccounts.value?.count ?? 0) > 1
            || codexAccounts.value?.contains(where: {
                $0.quota.value != nil || $0.resetCards.value != nil || $0.tokens?.value != nil || $0.history?.value != nil
                    || $0.tokenActivity?.value != nil
            }) == true
        case .claude: claudeTokens.value != nil || claudeQuota.value != nil || claudeHistory.value != nil || claudeResetCards.value != nil
        case .cursor: cursorCosts.value != nil || cursorQuota.value != nil
        case .deepseek: deepseekUsage.value != nil
        }
    }
}

enum ProviderGridLayout {
    /// Rows of two; an odd service out takes a full-width row at the bottom.
    static func rows(_ providers: [MeterProvider]) -> [[MeterProvider]] {
        stride(from: 0, to: providers.count, by: 2).map { Array(providers[$0..<min($0 + 2, providers.count)]) }
    }

    static func rows(_ providers: [MeterProvider], size: ProviderWidgetSize) -> [[MeterProvider]] {
        if size == .small || (size == .large && providers.count < 4) {
            return providers.map { [$0] }
        }
        return providers.count < 4 ? (providers.isEmpty ? [] : [providers]) : rows(providers)
    }
}

enum ProviderWidgetSize: CaseIterable { case small, medium, large, extraLarge }

/// Card shape is independent of its typography and padding density.
enum ProviderPanelLayout {
    case vertical, horizontal, horizontalExpanded, column, expanded

    var isHorizontal: Bool { self == .horizontal || self == .horizontalExpanded }
    var expandsWindows: Bool { self == .expanded || self == .horizontalExpanded }
}
