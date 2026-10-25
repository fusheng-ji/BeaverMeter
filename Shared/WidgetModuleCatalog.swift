import Foundation

struct WidgetModuleOption: Identifiable {
    let id: String
    let provider: MeterProvider
    let title: String
    let workspaceID: String?
}

/// Stable selectable modules. A Codex account keeps its ID when it is the only workspace.
enum WidgetModuleCatalog {
    static let noneID = "none"
    static let workspacePrefix = "codex-workspace:"

    static func available(snapshot: UsageSnapshot, providers: [MeterProvider]) -> [WidgetModuleOption] {
        let accounts = accounts(in: snapshot)
        let names = workspaceNames(accounts)
        var seen: Set<MeterProvider> = []
        return providers.filter { seen.insert($0).inserted }.flatMap { provider in
            if provider == .codex, !accounts.isEmpty {
                return accounts.enumerated().map { index, account in
                    WidgetModuleOption(id: workspacePrefix + account.id, provider: .codex,
                                       title: names[index].short, workspaceID: account.id)
                }
            }
            return [WidgetModuleOption(id: "service:\(provider.rawValue)", provider: provider,
                                       title: provider.displayName, workspaceID: nil)]
        }
    }

    /// Each service gets its first module before extra workspaces use remaining slots.
    static func defaults(snapshot: UsageSnapshot, providers: [MeterProvider]) -> [String] {
        let options = available(snapshot: snapshot, providers: providers)
        var seen: Set<MeterProvider> = []
        let first = options.filter { seen.insert($0.provider).inserted }
        let firstIDs = Set(first.map(\.id))
        return Array((first + options.filter { !firstIDs.contains($0.id) }).prefix(6)).map(\.id)
    }

    static func accounts(in snapshot: UsageSnapshot) -> [CodexAccountUsage] {
        var seen: Set<String> = []
        return (snapshot.codexAccounts.value ?? []).filter {
            !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.id).inserted
        }
    }

    static func workspaceNames(_ accounts: [CodexAccountUsage]) -> [(short: String, full: String)] {
        func nonempty(_ text: String?) -> String? {
            text.flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        let baseNames = accounts.enumerated().map { index, account in
            nonempty(account.workspaceName) ?? nonempty(account.displayName) ?? "Workspace \(index + 1)"
        }
        let totals = Dictionary(grouping: baseNames, by: { $0.lowercased() }).mapValues(\.count)
        var occurrences: [String: Int] = [:]
        return accounts.enumerated().map { index, account in
            let base = baseNames[index], key = base.lowercased()
            occurrences[key, default: 0] += 1
            let short = totals[key, default: 0] > 1 ? "\(occurrences[key]!) · \(base)" : base
            let identity = nonempty(account.accountName)
                ?? nonempty(account.displayName).flatMap { $0 == base ? nil : $0 }
            return (short, identity.map { "\(short) · \($0)" } ?? short)
        }
    }
}
