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
            claudeResetCards: snapshot.claudeResetCards,
            antigravityQuota: snapshot.antigravityQuota, antigravityTokens: snapshot.antigravityTokens
        )
    }
}
