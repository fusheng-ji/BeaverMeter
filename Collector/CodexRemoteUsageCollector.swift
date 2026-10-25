import Foundation

enum CodexRemoteUsageCollector {
    struct Result {
        let configured: Bool
        let complete: Bool
        let usageByResponseHash: [String: CodexUsageRecordScanner.AccumulatedUsage]
        let message: String?
    }

    private static let cacheSchemaVersion = 5

    private struct Cache: Codable {
        let schemaVersion: Int
        let dayStart: Date
        let sourceHash: String
        var roots: [String: RootState]
    }

    private struct OldCache: Codable {
        let schemaVersion: Int
        let dayStart: Date
        let sourceHash: String
        var files: [String: FileState]
    }

    private struct RootState: Codable {
        var files: [String: FileState]
    }

    private struct FileState: Codable, Equatable {
        var offset: Int64
        var records: [String: CodexUsageRecordScanner.AccumulatedUsage]
        var sessionScopes: [String: String]? = nil
        var conflictedSessions: Set<String>? = nil
        var responseSessions: [String: [String]]? = nil

        static let empty = FileState(offset: 0, records: [:])
    }

    private struct RemoteResponse: Decodable {
        let schemaVersion: Int?
        let configuredRootHash: String?
        let activeRootHashes: [String]?
        let discoveryComplete: Bool?
        let roots: [String: RootResponse]?
        // Existing isolated SSH fixtures use the original single-root protocol.
        let complete: Bool?
        let failedFiles: [String]?
        let activeFiles: [String]?
        let files: [String: FileDelta]?
    }

    private struct RootResponse: Decodable {
        let complete: Bool
        let failedFiles: [String]
        let activeFiles: [String]
        let files: [String: FileDelta]
    }

    private struct FileDelta: Decodable {
        let offset: Int64
        let reset: Bool
        let records: [RemoteRecord]
        let sessionScopes: [String: String]?
        let conflictedSessions: [String]?
    }

    private struct RemoteRecord: Decodable {
        let responseHash: String
        let sessionHash: String
        let timestamp: Double
        let inputTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int
        let reasoningTokens: Int
        // The current protocol transports only creator diagnostics, never request-account evidence.
        // Old `workspaceHash` and any unrecognized proof fields are deliberately ignored.
        let creatorWorkspaceHash: String?
        let scopeSessionHashes: [String]?
    }

    private struct ScopeContext: Encodable {
        let sessionScopes: [String: String]
        let conflictedSessions: Set<String>
    }

    private struct RootRequest: Encodable {
        let files: [String: Int64]
        let scopeContexts: [String: ScopeContext]
    }

    static func collect(
        environment: [String: String],
        now: Date,
        calendar: Calendar,
        cacheURL: URL,
        timeout: TimeInterval = 30,
        historyDays: Int = 1
    ) -> Result {
        guard let host = nonempty(environment["CODEX_REMOTE_SSH_HOST"]) else {
            return Result(
                configured: false,
                complete: true,
                usageByResponseHash: [:],
                message: nil
            )
        }
        guard let root = nonempty(environment["CODEX_REMOTE_ROOT"]),
              let python = nonempty(environment["CODEX_REMOTE_PYTHON"]),
              let window = try? CodexDayWindow(now: now, calendar: calendar, historyDays: historyDays)
        else {
            return Result(
                configured: true, complete: false,
                usageByResponseHash: [:],
                message: "Remote Codex configuration is incomplete; specify a root and Python executable."
            )
        }
        let sourceHash = hash("\(host)\u{0}\(root)\u{0}\(python)")
        let dayStart = window.start

        let loaded = loadCache(from: cacheURL)
        let cacheIsCurrent = loaded?.schemaVersion == cacheSchemaVersion
            && loaded?.dayStart == dayStart
            && loaded?.sourceHash == sourceHash
        var cache = if cacheIsCurrent, let loaded {
            loaded
        } else if let loaded, [3, 4].contains(loaded.schemaVersion), loaded.dayStart == dayStart, loaded.sourceHash == sourceHash {
            Cache(schemaVersion: cacheSchemaVersion, dayStart: dayStart, sourceHash: sourceHash,
                  roots: rescanning(loaded.roots))
        } else if let old = loadOldCache(from: cacheURL.deletingLastPathComponent()
            .appendingPathComponent("beaver-meter-codex-remote-scan-v1.json")),
                  historyDays == 1, old.schemaVersion == 1, old.dayStart == dayStart, old.sourceHash == sourceHash {
            Cache(schemaVersion: cacheSchemaVersion, dayStart: dayStart, sourceHash: sourceHash,
                  roots: rescanning([hash(root): RootState(files: old.files)]))
        } else {
            Cache(
                schemaVersion: cacheSchemaVersion,
                dayStart: dayStart,
                sourceHash: sourceHash,
                roots: [:]
            )
        }
        let resetCache = !cacheIsCurrent

        do {
            let responseData: Data
            if let fixture = nonempty(environment["CODEX_REMOTE_RESPONSE_FIXTURE"]) {
                responseData = try Data(contentsOf: URL(fileURLWithPath: fixture))
            } else {
                responseData = try fetch(
                    host: host,
                    root: root,
                    python: python,
                    window: window,
                    cache: cache,
                    environment: environment,
                    timeout: timeout
                )
            }
            let response = try JSONDecoder().decode(RemoteResponse.self, from: responseData)
            let configuredHash = hash(root)
            let rootResponses: [String: RootResponse]
            if let roots = response.roots, response.schemaVersion == 2 {
                guard response.configuredRootHash == configuredHash else {
                    throw CocoaError(.coderReadCorrupt)
                }
                rootResponses = roots
            } else if let complete = response.complete,
                      let failedFiles = response.failedFiles,
                      let activeFiles = response.activeFiles,
                      let files = response.files {
                rootResponses = [configuredHash: RootResponse(
                    complete: complete, failedFiles: failedFiles,
                    activeFiles: activeFiles, files: files
                )]
            } else {
                throw CocoaError(.coderReadCorrupt)
            }
            var cacheChanged = resetCache
            let activeRoots = response.activeRootHashes ?? []
            var complete = (response.discoveryComplete ?? true) && activeRoots.count <= 1
            // Counts already observed today remain valid if logs are removed,
            // archived or temporarily inaccessible. Day/source changes reset them.
            for (rootHash, rootResponse) in rootResponses {
                guard isSHA256(rootHash) else { complete = false; continue }
                if !rootResponse.complete || !rootResponse.failedFiles.isEmpty { complete = false }
                var rootState = cache.roots[rootHash] ?? RootState(files: [:])
                let activeFiles = Set(rootResponse.activeFiles)
                for (identity, delta) in rootResponse.files {
                    guard activeFiles.contains(identity), delta.offset >= 0 else {
                        complete = false
                        continue
                    }
                    var state = delta.reset ? .empty : (rootState.files[identity] ?? .empty)
                    let priorState = state
                    guard delta.reset || delta.offset >= state.offset else {
                        complete = false
                        continue
                    }
                    cacheChanged = cacheChanged || state.offset != delta.offset || delta.reset
                    if let scopes = delta.sessionScopes {
                        state.sessionScopes = scopes.filter { isSHA256($0.key) && isSHA256($0.value) }
                        if state.sessionScopes?.count != scopes.count { complete = false }
                    }
                    if let conflicts = delta.conflictedSessions {
                        state.conflictedSessions = Set(conflicts.filter(isSHA256))
                        if state.conflictedSessions?.count != conflicts.count { complete = false }
                    }
                    for record in delta.records {
                        guard window.contains(Date(timeIntervalSince1970: record.timestamp)),
                              isSHA256(record.responseHash),
                              isSHA256(record.sessionHash),
                              record.inputTokens >= 0,
                              record.cachedInputTokens >= 0,
                              record.outputTokens >= 0,
                              record.reasoningTokens >= 0
                        else { complete = false; continue }
                        let creatorScope = record.creatorWorkspaceHash.flatMap { isSHA256($0) ? $0 : nil }
                        if record.creatorWorkspaceHash != nil && creatorScope == nil { complete = false }
                        let oldBinding = state.responseSessions?[record.responseHash]
                        if let identities = record.scopeSessionHashes {
                            if identities.allSatisfy(isSHA256) {
                                if state.responseSessions == nil { state.responseSessions = [:] }
                                state.responseSessions?[record.responseHash] = oldBinding.map { $0 == identities ? identities : [] } ?? identities
                            } else { complete = false }
                        }
                        let usage = CodexUsageRecordScanner.AccumulatedUsage(
                                inputTokens: record.inputTokens,
                                cachedInputTokens: record.cachedInputTokens,
                                outputTokens: record.outputTokens,
                                reasoningTokens: record.reasoningTokens,
                                sessionHash: record.sessionHash,
                                timestamp: Date(timeIntervalSince1970: record.timestamp), creatorWorkspaceHash: creatorScope
                            )
                        if let old = state.records[record.responseHash] {
                            if oldBinding == nil, record.scopeSessionHashes != nil {
                                // A fresh rescan can restore creator diagnostics, but never request-account proof.
                                var upgraded = old
                                upgraded.workspaceHash = nil
                                upgraded.workspaceScopeEvidence = nil
                                upgraded.creatorWorkspaceHash = creatorScope
                                state.records[record.responseHash] = upgraded
                            } else { state.records[record.responseHash] = old.mergingWorkspaceScope(usage) }
                        } else { state.records[record.responseHash] = usage }
                    }
                    for (response, identities) in state.responseSessions ?? [:] {
                        guard var usage = state.records[response] else { continue }
                        let scopes = identities.compactMap { state.sessionScopes?[$0] }
                        usage.creatorWorkspaceHash = !identities.isEmpty && scopes.count == identities.count
                            && identities.allSatisfy({ !(state.conflictedSessions ?? []).contains($0) })
                            && Set(scopes).count == 1 ? scopes.first : nil
                        usage.workspaceHash = nil
                        usage.workspaceScopeEvidence = nil
                        state.records[response] = usage
                    }
                    state.offset = delta.offset
                    cacheChanged = cacheChanged || state != priorState
                    rootState.files[identity] = state
                }
                cache.roots[rootHash] = rootState
            }
            if cacheChanged { try AtomicFileWriter.writeJSON(cache, to: cacheURL) }
            let records = mergedRecords(in: cache)
            return Result(
                configured: true,
                complete: complete,
                usageByResponseHash: records,
                message: complete ? nil : (activeRoots.count > 1
                    ? "Multiple active remote Codex homes were found; today's total may be incomplete."
                    : "Some remote Codex records could not be refreshed; today's total includes cached remote usage.")
            )
        } catch {
            let records = mergedRecords(in: cache)
            return Result(
                configured: true,
                complete: false,
                usageByResponseHash: records,
                message: records.isEmpty
                    ? "Remote Codex usage is unavailable; today's total includes local usage only."
                    : "Remote Codex refresh failed; today's total includes the last remote reading."
            )
        }
    }

    private static func fetch(
        host: String,
        root: String,
        python: String,
        window: CodexDayWindow,
        cache: Cache,
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> Data {
        guard isSafeHost(host), root.hasPrefix("/"), python.hasPrefix("/"),
              !root.contains("\n"), !python.contains("\n")
        else { throw CocoaError(.fileReadInvalidFileName) }
        guard let scriptURL = resolvedScriptURL(environment: environment),
              let scriptData = try? Data(contentsOf: scriptURL),
              !scriptData.isEmpty
        else { throw CocoaError(.fileNoSuchFile) }

        let code = "import base64;exec(base64.b64decode(\"\(scriptData.base64EncodedString())\"))"
        let command = [
            shellQuote(python), "-c", shellQuote(code), shellQuote(root),
            String(window.start.timeIntervalSince1970), String(window.end.timeIntervalSince1970),
            String(window.cutoff.timeIntervalSince1970),
        ].joined(separator: " ")
        let request = try JSONEncoder().encode(["roots": cache.roots.mapValues { root in
            RootRequest(files: root.files.mapValues(\.offset), scopeContexts: root.files.mapValues {
                ScopeContext(sessionScopes: $0.sessionScopes ?? [:], conflictedSessions: $0.conflictedSessions ?? [])
            })
        }])
        let ssh = nonempty(environment["BEAVERMETER_SSH"]) ?? "/usr/bin/ssh"
        let result = try SubprocessRunner.run(
            executable: URL(fileURLWithPath: ssh),
            arguments: [
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
                "--", host, command,
            ],
            standardInput: request,
            timeout: timeout,
            environment: environment
        )
        guard result.status == 0, !result.timedOut, !result.cancelled else {
            throw CocoaError(.fileReadUnknown)
        }
        return result.standardOutput
    }

    private static func resolvedScriptURL(environment: [String: String]) -> URL? {
        if let configured = nonempty(environment["BEAVERMETER_REMOTE_SCRIPT"]) {
            return URL(fileURLWithPath: configured)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        return executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/remote_codex_usage.py")
    }

    private static func mergedRecords(in cache: Cache) -> [String: CodexUsageRecordScanner.AccumulatedUsage] {
        var records: [String: CodexUsageRecordScanner.AccumulatedUsage] = [:]
        for root in cache.roots.values {
            for state in root.files.values {
                for (hash, var usage) in state.records {
                    // No current remote wire record can establish request-account evidence.
                    usage.workspaceHash = nil
                    usage.workspaceScopeEvidence = nil
                    records[hash] = records[hash].map { $0.mergingWorkspaceScope(usage) } ?? usage
                }
            }
        }
        return records
    }

    private static func rescanning(_ roots: [String: RootState]) -> [String: RootState] {
        roots.mapValues { root in
            RootState(files: root.files.mapValues { state in
                var state = state
                state.offset = 0
                state.sessionScopes = nil
                state.conflictedSessions = nil
                state.responseSessions = nil
                state.records = state.records.mapValues { usage in
                    var usage = usage
                    usage.workspaceHash = nil
                    usage.workspaceScopeEvidence = nil
                    usage.creatorWorkspaceHash = nil
                    return usage
                }
                return state
            })
        }
    }

    private static func loadCache(from url: URL) -> Cache? {
        CodexUsageSupport.load(Cache.self, from: url)
    }

    private static func loadOldCache(from url: URL) -> OldCache? {
        CodexUsageSupport.load(OldCache.self, from: url)
    }

    private static func nonempty(_ value: String?) -> String? {
        CodexUsageSupport.nonempty(value)
    }

    private static func isSafeHost(_ host: String) -> Bool {
        !host.isEmpty && host.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || ".-_@".unicodeScalars.contains($0)
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        CodexUsageSupport.isSHA256(value)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func hash(_ value: String) -> String {
        CodexUsageSupport.hash(value)
    }
}
