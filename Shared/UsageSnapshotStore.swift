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
        guard let snapshot = try? decoder.decode(UsageSnapshot.self, from: data),
              (5...Self.currentSchemaVersion).contains(snapshot.schemaVersion) else { return nil }
        return UsageSnapshot(
            schemaVersion: Self.currentSchemaVersion, generatedAt: snapshot.generatedAt,
            codexTokens: snapshot.codexTokens, cursorCosts: snapshot.cursorCosts,
            cursorQuota: snapshot.cursorQuota, codexQuota: snapshot.codexQuota,
            claudeTokens: snapshot.claudeTokens, claudeQuota: snapshot.claudeQuota,
            deepseekUsage: snapshot.deepseekUsage, codexAccounts: snapshot.codexAccounts,
            codexHistory: snapshot.codexHistory, claudeHistory: snapshot.claudeHistory,
            claudeResetCards: snapshot.claudeResetCards
        )
    }
}

extension UsageSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try c.decode(Int.self, forKey: .schemaVersion),
            generatedAt: try c.decode(Date.self, forKey: .generatedAt),
            codexTokens: try c.decode(UsageValue<CodexTokenTotals>.self, forKey: .codexTokens),
            cursorCosts: try c.decode(UsageValue<CursorCostTotals>.self, forKey: .cursorCosts),
            cursorQuota: try c.decode(UsageValue<CompactQuota>.self, forKey: .cursorQuota),
            codexQuota: try c.decode(UsageValue<CompactQuota>.self, forKey: .codexQuota),
            claudeTokens: try c.decodeIfPresent(UsageValue<ClaudeTokenTotals>.self, forKey: .claudeTokens)
                ?? Self.unavailable.claudeTokens,
            claudeQuota: try c.decodeIfPresent(UsageValue<CompactQuota>.self, forKey: .claudeQuota)
                ?? Self.unavailable.claudeQuota,
            deepseekUsage: try c.decode(UsageValue<DeepSeekUsageTotals>.self, forKey: .deepseekUsage),
            codexAccounts: try c.decodeIfPresent(UsageValue<[CodexAccountUsage]>.self, forKey: .codexAccounts)
                ?? Self.unavailable.codexAccounts,
            codexHistory: try c.decodeIfPresent(UsageValue<TokenHistory<CodexTokenTotals>>.self, forKey: .codexHistory)
                ?? Self.unavailable.codexHistory,
            claudeHistory: try c.decodeIfPresent(UsageValue<TokenHistory<ClaudeTokenTotals>>.self, forKey: .claudeHistory)
                ?? Self.unavailable.claudeHistory,
            claudeResetCards: try c.decodeIfPresent(UsageValue<ResetCardInventory>.self, forKey: .claudeResetCards)
                ?? Self.unavailable.claudeResetCards
        )
    }
}
