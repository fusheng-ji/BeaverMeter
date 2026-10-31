import CryptoKit
import Darwin
import Foundation

/// Offline decoding/composition checks, separate from native WidgetKit observations.
@main
enum CheckAntigravityQACases {
    struct Manifest: Decodable {
        struct Record: Decodable {
            struct ExpectedGroup: Decodable {
                let id: String
                let name: String
                let primaryPercent: Double?
                let period: String
                let resetDescription: String?
            }
            let caseID: String
            let file: String
            let sha256: String
            let selectedModuleIDs: [String]
            let expectedGroups: [ExpectedGroup]
        }
        let syntheticOnly: Bool
        let snapshotSchemaVersion: Int
        let caseCount: Int
        let cases: [Record]
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("Antigravity QA contract: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 1 else { throw WidgetQAStore.Failure("Pass the Antigravity QA manifest path.") }
        let url = URL(fileURLWithPath: arguments[0])
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard manifest.syntheticOnly, manifest.snapshotSchemaVersion == UsageSnapshot.currentSchemaVersion,
              manifest.caseCount == 5, manifest.cases.count == 5 else {
            throw WidgetQAStore.Failure("Expected five isolated schema-8 cases.")
        }
        let sizes: [ProviderWidgetSize] = [.small, .medium, .large, .extraLarge]
        for record in manifest.cases {
            let data = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(record.file))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let fixture = try WidgetQAStore.decode(data)
            guard digest == record.sha256, fixture.caseID == record.caseID,
                  fixture.selectedModuleIDs == record.selectedModuleIDs,
                  MeterProvider.allCases.allSatisfy({ fixture.settings[$0] != .auto }) else {
                throw WidgetQAStore.Failure("Fixture identity, selection, hash or explicit provider settings differ.")
            }
            let providers = fixture.settings.visibleProviders(in: fixture.snapshot)
            if record.caseID == "antigravity-spacing-stress" {
                guard providers.count == MeterProvider.allCases.count,
                      fixture.selectedModuleIDs?.count == 6,
                      let account = fixture.snapshot.codexAccounts.value?.first,
                      (account.workspaceName?.count ?? 0) > 60,
                      account.quota.value?.remainingPercent == nil,
                      fixture.snapshot.cursorQuota.value?.remaining ?? 0 > 9_000_000_000,
                      let balance = fixture.snapshot.deepseekUsage.value?.balances.first,
                      balance.currency == "CNY", balance.amount > 9_000_000_000 else {
                    throw WidgetQAStore.Failure("Synthetic spacing-stress edge values are missing.")
                }
            }
            for size in sizes {
                let composition = WidgetComposition(snapshot: fixture.snapshot, providers: providers, size: size,
                    referenceDate: fixture.referenceDate, selectedModuleIDs: fixture.selectedModuleIDs)
                guard composition.items.map(\.id) == Array(record.selectedModuleIDs.prefix(WidgetComposition.capacity(for: size))) else {
                    throw WidgetQAStore.Failure("Module order or capacity differs in \(fixture.caseID).")
                }
                let groups = composition.items.filter { $0.provider == .antigravity }
                guard groups.count == 2 else { throw WidgetQAStore.Failure("An Antigravity group lost its card.") }
                for (item, expected) in zip(groups, record.expectedGroups) {
                    let value = expected.primaryPercent.map { "\(Int(min(max($0, 0), 100).rounded()))%" } ?? "—"
                    guard item.id == expected.id, item.workspaceName == expected.name,
                          item.presentation.value == value, item.presentation.period == expected.period,
                          expected.resetDescription == nil || item.presentation.reset == expected.resetDescription else {
                        throw WidgetQAStore.Failure("Independent group quota, identity or reset text differs in \(fixture.caseID).")
                    }
                }
                let activity = WidgetActivityPresentation(snapshot: fixture.snapshot, composition: composition,
                                                         referenceDate: fixture.referenceDate)
                guard !activity.items.contains(where: { $0.provider == .antigravity }) else {
                    throw WidgetQAStore.Failure("Antigravity quota-only modules gained activity content.")
                }
                if record.caseID == "antigravity-spacing-stress", size == .large || size == .extraLarge {
                    guard composition.items.first(where: { $0.provider == .codex })?.presentation.value == "—",
                          composition.items.first(where: { $0.provider == .claude })?.presentation.value == "100%",
                          composition.items.first(where: { $0.provider == .deepseek })?.presentation.moneyCurrencyCode == "CNY",
                          composition.items.first(where: { $0.provider == .deepseek })?.presentation.compactMoneyAmount == "9.9B" else {
                        throw WidgetQAStore.Failure("Spacing-stress projection lost unknown, full, or large CNY values.")
                    }
                }
            }
        }
        print("Validated five Antigravity cases / 20 family compositions offline. Native observations remain pending.")
    }
}
