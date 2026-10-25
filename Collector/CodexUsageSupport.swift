import CryptoKit
import Foundation

/// Only an upstream request-account attribution contract can produce this evidence.
/// Session creators and the currently authenticated account do not prove who paid for a request.
enum CodexWorkspaceScopeEvidence: String, Codable, Hashable, Sendable {
    case requestAccount
}

/// One response's counters. Cached input and reasoning are subsets, not extra tokens.
struct CodexResponseUsage: Codable, Hashable, Sendable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let sessionHash: String
    var timestamp: Date? = nil
    /// A potential request-account hash is usable only together with explicit evidence below.
    var workspaceHash: String? = nil
    var workspaceScopeEvidence: CodexWorkspaceScopeEvidence? = nil
    /// Diagnostic provenance only. A resumed thread may use a different request account.
    var creatorWorkspaceHash: String? = nil

    var verifiedWorkspaceHash: String? {
        guard workspaceScopeEvidence == .requestAccount,
              let workspaceHash, CodexUsageSupport.isSHA256(workspaceHash) else { return nil }
        return workspaceHash
    }

    /// Preserve the first counters/global dedup semantics; inconsistent evidence is unknown.
    func mergingWorkspaceScope(_ other: Self) -> Self {
        var result = self
        if let scope = verifiedWorkspaceHash, scope == other.verifiedWorkspaceHash {
            result.workspaceHash = scope
            result.workspaceScopeEvidence = .requestAccount
        } else {
            result.workspaceHash = nil
            result.workspaceScopeEvidence = nil
        }
        if creatorWorkspaceHash != other.creatorWorkspaceHash { result.creatorWorkspaceHash = nil }
        return result
    }
}

struct CodexDayWindow: Sendable {
    let start: Date
    let end: Date
    let cutoff: Date

    init(now: Date, calendar: Calendar, historyDays: Int = 1) throws {
        let today = calendar.startOfDay(for: now)
        guard let firstDay = calendar.date(byAdding: .day, value: 1 - historyDays, to: today),
              let nextDay = calendar.date(byAdding: .day, value: 1, to: today) else {
            throw CocoaError(.coderReadCorrupt)
        }
        start = firstDay
        end = nextDay
        cutoff = now
    }

    func contains(_ timestamp: Date) -> Bool {
        timestamp >= start && timestamp < end && timestamp <= cutoff
    }
}

enum CodexUsageSupport {
    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    static func homeURL(_ configuredPath: String?) -> URL {
        if let path = nonempty(configuredPath) {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    static func load<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func adding(_ lhs: Int, _ rhs: Int) throws -> Int {
        let sum = lhs.addingReportingOverflow(rhs)
        guard !sum.overflow else { throw CocoaError(.coderReadCorrupt) }
        return sum.partialValue
    }
}

struct CodexCacheLocations {
    let directory: URL

    init(snapshotURL: URL) {
        directory = snapshotURL.deletingLastPathComponent()
    }

    var local: URL { directory.appendingPathComponent("beaver-meter-codex-scan-v2.json") }
    var remote: URL { directory.appendingPathComponent("beaver-meter-codex-remote-scan-v2.json") }
    var remoteV1: URL { directory.appendingPathComponent("beaver-meter-codex-remote-scan-v1.json") }
    var legacy: URL { directory.appendingPathComponent("beaver-meter-codex-legacy-v1.json") }
    var measurement: URL { directory.appendingPathComponent("beaver-meter-codex-measurement-v1.json") }
}

extension CodexTokenTotals {
    static let zero = CodexTokenTotals(
        totalTokens: 0, inputTokens: 0, cachedInputTokens: 0,
        outputTokens: 0, reasoningTokens: 0, sessionCount: 0
    )
}
