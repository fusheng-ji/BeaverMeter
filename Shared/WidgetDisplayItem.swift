import Foundation

struct WidgetDisplayItem: Identifiable {
    let id: String
    let provider: MeterProvider
    let presentation: WidgetProviderPresentation
    let workspaceName: String?
    let fullWorkspaceName: String?
    let isCodexWorkspace: Bool
}

/// Explicit ordered modules; selection never expands a service into sibling workspaces.
struct WidgetComposition {
    let items: [WidgetDisplayItem]
    let isMultiWorkspace: Bool
    /// Module selection has no automatic workspace overflow badge.
    let overflowWorkspaceCount = 0

    init(snapshot: UsageSnapshot, providers: [MeterProvider], size: ProviderWidgetSize,
         referenceDate: Date, calendar: Calendar = .current, selectedModuleIDs: [String]? = nil) {
        let visible = Set(providers)
        let accounts = WidgetModuleCatalog.accounts(in: snapshot)
        let names = WidgetModuleCatalog.workspaceNames(accounts)
        let indices = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { ($0.element.id, $0.offset) })
        let selection = selectedModuleIDs ?? WidgetModuleCatalog.defaults(snapshot: snapshot, providers: providers)
        var seen: Set<String> = []
        // Capacity applies to slot positions. Empty/duplicate/hidden slots never pull later slots forward.
        let candidates = selection.prefix(Self.capacity(for: size)).compactMap { id -> WidgetDisplayItem? in
            guard id != WidgetModuleCatalog.noneID, seen.insert(id).inserted else { return nil }
            if id.hasPrefix(WidgetModuleCatalog.workspacePrefix) {
                let accountID = String(id.dropFirst(WidgetModuleCatalog.workspacePrefix.count))
                guard visible.contains(.codex), !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                if let index = indices[accountID] {
                    return WidgetDisplayItem(id: id, provider: .codex,
                        presentation: WidgetProviderPresentation(codexAccount: accounts[index], referenceDate: referenceDate, calendar: calendar),
                        workspaceName: names[index].short, fullWorkspaceName: names[index].full, isCodexWorkspace: true)
                }
                let missing = CodexAccountUsage(id: accountID, homeID: accountID, displayName: "Unavailable workspace",
                    quota: .unavailable("This selected Codex workspace is no longer available. Edit the widget to choose another module."),
                    resetCards: .unavailable("No inventory for a missing workspace."))
                return WidgetDisplayItem(id: id, provider: .codex,
                    presentation: WidgetProviderPresentation(codexAccount: missing, referenceDate: referenceDate, calendar: calendar),
                    workspaceName: "Unavailable", fullWorkspaceName: "Unavailable Codex workspace", isCodexWorkspace: true)
            }
            guard let provider = MeterProvider.allCases.first(where: { id == "service:\($0.rawValue)" }),
                  visible.contains(provider) else { return nil }
            if provider == .codex, !accounts.isEmpty {
                let legacy = CodexAccountUsage(id: id, homeID: id, displayName: "Unavailable Codex module",
                    quota: .unavailable("Codex workspaces are now available. Edit the widget to choose a workspace module."),
                    resetCards: .unavailable("No inventory for an unavailable module."))
                return WidgetDisplayItem(id: id, provider: .codex,
                    presentation: WidgetProviderPresentation(codexAccount: legacy, referenceDate: referenceDate, calendar: calendar),
                    workspaceName: "Unavailable", fullWorkspaceName: "Unavailable Codex module", isCodexWorkspace: false)
            }
            return WidgetDisplayItem(id: id, provider: provider,
                presentation: WidgetProviderPresentation(snapshot: snapshot, provider: provider,
                                                         referenceDate: referenceDate, calendar: calendar),
                workspaceName: nil, fullWorkspaceName: nil, isCodexWorkspace: false)
        }
        items = Array(candidates.prefix(Self.capacity(for: size)))
        isMultiWorkspace = items.filter(\.isCodexWorkspace).count > 1
    }

    static func capacity(for size: ProviderWidgetSize) -> Int {
        switch size {
        case .small: 2
        case .medium: 4
        case .large, .extraLarge: 6
        }
    }

    static func rows(cardCount: Int, size: ProviderWidgetSize) -> [[Int]] {
        let count = min(max(0, cardCount), capacity(for: size))
        guard count > 0 else { return [] }
        let indices = Array(0..<count)
        let columns: Int
        switch size {
        case .small: columns = 1
        case .medium: columns = count <= 3 ? count : 2
        case .large: columns = count <= 4 ? 1 : 2
        case .extraLarge: columns = count <= 3 ? count : count == 4 ? 2 : 3
        }
        return stride(from: 0, to: count, by: columns).map { start in
            Array(indices[start..<min(start + columns, count)])
        }
    }
}
