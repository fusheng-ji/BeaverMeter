import Darwin
import Foundation

extension UsageSnapshot {
    static var snapshotURL: URL {
        let home: URL = {
            guard let entry = getpwuid(getuid()) else {
                return FileManager.default.homeDirectoryForCurrentUser
            }
            return URL(fileURLWithPath: String(cString: entry.pointee.pw_dir), isDirectory: true)
        }()
        return home.appendingPathComponent("Library/Application Support/BeaverMeter/beaver-meter-snapshot.json")
    }

    static func load() -> UsageSnapshot {
        load(from: snapshotURL)
    }

    static func load(from url: URL) -> UsageSnapshot {
        guard let data = try? Data(contentsOf: url) else { return .unavailable }
        return decode(data) ?? .unavailable
    }

    static func decode(_ data: Data) -> UsageSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let snapshot = try? decoder.decode(UsageSnapshot.self, from: data),
           snapshot.schemaVersion == Self.currentSchemaVersion {
            return snapshot
        }
        // Version 5 had no Claude fields; keep its provider values as the
        // stale fallback for the first refresh after an upgrade.
        if let legacy = try? decoder.decode(SchemaV5.self, from: data), legacy.schemaVersion == 5 {
            return UsageSnapshot(
                schemaVersion: Self.currentSchemaVersion,
                generatedAt: legacy.generatedAt,
                codexTokens: legacy.codexTokens,
                cursorCosts: legacy.cursorCosts,
                cursorQuota: legacy.cursorQuota,
                codexQuota: legacy.codexQuota,
                claudeTokens: Self.unavailable.claudeTokens,
                claudeQuota: Self.unavailable.claudeQuota,
                deepseekUsage: legacy.deepseekUsage
            )
        }
        return nil
    }

    private struct SchemaV5: Decodable {
        let schemaVersion: Int
        let generatedAt: Date
        let codexTokens: UsageValue<CodexTokenTotals>
        let cursorCosts: UsageValue<CursorCostTotals>
        let cursorQuota: UsageValue<CompactQuota>
        let codexQuota: UsageValue<CompactQuota>
        let deepseekUsage: UsageValue<DeepSeekUsageTotals>
    }
}
