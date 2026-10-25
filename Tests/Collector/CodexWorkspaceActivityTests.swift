import Foundation
import XCTest

final class CodexWorkspaceActivityTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func fixture() throws -> (root: URL, home: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-activity-tests-\(UUID())")
        let home = root.appendingPathComponent("home")
        let file = home.appendingPathComponent("sessions/synthetic.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, home, file)
    }

    private func append(_ object: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object) + Data([10])
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }

    private func metadata(_ scope: String, session: String) -> [String: Any] {
        ["type": "session_meta", "timestamp": "2026-10-01T09:00:00Z",
         "payload": ["id": session, "session_id": session, "creator_account_id": scope,
                     "creator_user_id": "must-not-be-cached", "instructions": "must-not-be-cached"]]
    }

    private func usage(_ response: String, session: String, tokens: Int, thread: String? = nil) -> [String: Any] {
        ["type": "token_usage_record", "timestamp": "2026-10-01T10:00:00Z",
         "payload": ["response_id": response, "session_id": session, "thread_id": thread ?? session,
                     "usage": ["input_tokens": tokens, "cached_input_tokens": 0,
                               "output_tokens": 0, "reasoning_output_tokens": 0]]]
    }

    private func reading<T: Codable & Hashable & Sendable>(_ value: T?, status: UsageDataStatus = .ready) -> UsageValue<T> {
        UsageValue(status: status, source: .codexBarLocal, measuredAt: now, lastAttemptAt: now, message: nil, value: value)
    }

    private func account(_ id: String, scope: String?) -> CodexAccountUsage {
        var value = CodexAccountUsage(id: id, homeID: "same-home", displayName: id,
            quota: .unavailable("Quota is independent"), resetCards: .unavailable("No inventory"))
        value.workspaceAccountIDHash = scope.map(CodexUsageSupport.hash)
        return value
    }

    private func aggregate(_ configuration: CodexAccountConfiguration, extraToday: Int = 0,
                           remote: CodexRemoteUsageCollector.Result? = nil) throws -> UsageValue<TokenHistory<CodexTokenTotals>> {
        var records: [String: CodexResponseUsage] = [:]
        for home in configuration.homes {
            let scan = try CodexUsageRecordScanner.collect(codexHomePath: home, now: now, calendar: calendar, historyDays: 7)
            for (id, usage) in scan.usageByResponseHash { records[id] = records[id].map { $0.mergingWorkspaceScope(usage) } ?? usage }
        }
        for (id, usage) in remote?.usageByResponseHash ?? [:] { records[id] = records[id].map { $0.mergingWorkspaceScope(usage) } ?? usage }
        let days = try TokenHistoryCollector.dates(now: now, calendar: calendar).map { day -> TokenHistoryDay<CodexTokenTotals> in
            let matches = records.filter { $0.value.timestamp.map { calendar.isDate($0, inSameDayAs: day) } == true }
            var value = try CodexUsageRecordScanner.totals(for: matches, sessionHashes: Set(matches.values.map(\.sessionHash))) ?? .zero
            if calendar.isDate(day, inSameDayAs: now), extraToday > 0 {
                value = try CodexTokenAggregation.adding(value, CodexTokenTotals(totalTokens: extraToday,
                    inputTokens: extraToday, cachedInputTokens: 0, outputTokens: 0, reasoningTokens: 0, sessionCount: 0))
            }
            return TokenHistoryDay(date: day, totals: value)
        }
        let total = try days.reduce(CodexTokenTotals.zero) { try CodexTokenAggregation.adding($0, $1.totals) }
        return reading(TokenHistory(sourceID: "global", timeZoneIdentifier: calendar.timeZone.identifier, days: days, totals: total))
    }

    private func collect(_ accounts: [CodexAccountUsage], fixture: (root: URL, home: URL, file: URL),
                         previous: [CodexAccountUsage] = [], configuration: CodexAccountConfiguration? = nil,
                         extraToday: Int = 0, remote: CodexRemoteUsageCollector.Result? = nil,
                         referenceDate: Date? = nil) async throws -> UsageValue<[CodexAccountUsage]> {
        let config = configuration ?? CodexAccountConfiguration(homes: [fixture.home.path], message: nil)
        return await CodexWorkspaceActivityCollector.collect(accounts: reading(accounts), previous: reading(previous),
            configuration: config, aggregateHistory: try aggregate(config, extraToday: extraToday, remote: remote),
            remoteHistory: remote, now: referenceDate ?? now, directory: fixture.root, environment: [:], calendar: calendar)
    }

    // Typed evidence is constructed only to test the attribution boundary. Current rollout and
    // remote protocols do not contain this request-account proof and cannot produce it.
    private func verifiedRequest(_ scope: String, tokens: Int, session: String = "request-session",
                                 creator: String? = nil) -> CodexResponseUsage {
        CodexResponseUsage(inputTokens: tokens, cachedInputTokens: 0, outputTokens: 0, reasoningTokens: 0,
            sessionHash: CodexUsageSupport.hash(session), timestamp: now,
            workspaceHash: CodexUsageSupport.hash(scope), workspaceScopeEvidence: .requestAccount,
            creatorWorkspaceHash: creator.map(CodexUsageSupport.hash))
    }

    private func typedRecords(_ records: [String: CodexResponseUsage], complete: Bool = true) -> CodexRemoteUsageCollector.Result {
        .init(configured: true, complete: complete,
              usageByResponseHash: Dictionary(uniqueKeysWithValues: records.map { (CodexUsageSupport.hash($0.key), $0.value) }), message: nil)
    }

    func testScannerJoinsEachSessionInsteadOfAssigningLastMetadataToCopiedParent() throws {
        let f = try fixture()
        try append(metadata(" WORKSPACE-A ", session: "parent"), to: f.file)
        try append(usage("a", session: "parent", tokens: 100), to: f.file)
        try append(metadata("workspace-b", session: "child"), to: f.file)
        try append(usage("b", session: "child", tokens: 200), to: f.file)
        try append(usage("copied-parent", session: "parent", tokens: 50), to: f.file)
        let cache = f.root.appendingPathComponent("scan.json")
        let scan = try CodexUsageRecordScanner.collect(codexHomePath: f.home.path, now: now, calendar: calendar, cacheURL: cache)
        XCTAssertEqual(scan.totals?.totalTokens, 350)
        XCTAssertEqual(scan.usageByResponseHash[CodexUsageSupport.hash("a")]?.creatorWorkspaceHash, CodexUsageSupport.hash("workspace-a"))
        XCTAssertEqual(scan.usageByResponseHash[CodexUsageSupport.hash("b")]?.creatorWorkspaceHash, CodexUsageSupport.hash("workspace-b"))
        XCTAssertEqual(scan.usageByResponseHash[CodexUsageSupport.hash("copied-parent")]?.creatorWorkspaceHash, CodexUsageSupport.hash("workspace-a"))
        XCTAssertTrue(scan.usageByResponseHash.values.allSatisfy { $0.workspaceHash == nil && $0.verifiedWorkspaceHash == nil })
        let persisted = try String(contentsOf: cache, encoding: .utf8)
        for secret in ["WORKSPACE-A", "workspace-b", "must-not-be-cached", "creator_account_id"] {
            XCTAssertFalse(persisted.contains(secret))
        }
    }

    func testScannerMissingMismatchedAndConflictingIdentitiesStayUnknown() throws {
        let f = try fixture()
        try append(metadata("workspace-a", session: "a"), to: f.file)
        try append(usage("unmatched", session: "unknown", tokens: 1), to: f.file)
        try append(usage("mismatch", session: "a", tokens: 2, thread: "unknown"), to: f.file)
        try append(usage("conflicted", session: "a", tokens: 3), to: f.file)
        try append(metadata("workspace-b", session: "a"), to: f.file)
        let result = try CodexUsageRecordScanner.collect(codexHomePath: f.home.path, now: now, calendar: calendar)
        XCTAssertEqual(result.totals?.totalTokens, 6)
        XCTAssertTrue(result.usageByResponseHash.values.allSatisfy { $0.creatorWorkspaceHash == nil && $0.verifiedWorkspaceHash == nil })
    }

    func testScannerAppendKeepsCreatorDiagnosticsAndOldAttributionCacheIsRescanned() throws {
        let f = try fixture()
        try append(metadata("workspace-a", session: "a"), to: f.file)
        try append(usage("first", session: "a", tokens: 100), to: f.file)
        let cache = f.root.appendingPathComponent("scan.json")
        _ = try CodexUsageRecordScanner.collect(codexHomePath: f.home.path, now: now, calendar: calendar, cacheURL: cache)
        try append(usage("second", session: "a", tokens: 20), to: f.file)
        let appended = try CodexUsageRecordScanner.collect(codexHomePath: f.home.path, now: now, calendar: calendar, cacheURL: cache)
        XCTAssertEqual(appended.totals?.totalTokens, 120)
        XCTAssertTrue(appended.usageByResponseHash.values.allSatisfy { $0.creatorWorkspaceHash == CodexUsageSupport.hash("workspace-a") })
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
        old["schemaVersion"] = 4
        var files = try XCTUnwrap(old["files"] as? [String: [String: Any]])
        for (file, state) in files {
            var state = state
            var records = try XCTUnwrap(state["records"] as? [String: [String: Any]])
            for (response, record) in records {
                var record = record
                record["workspaceHash"] = CodexUsageSupport.hash("workspace-b")
                record["workspaceScopeEvidence"] = "requestAccount"
                records[response] = record
            }
            state["records"] = records
            files[file] = state
        }
        old["files"] = files
        try JSONSerialization.data(withJSONObject: old).write(to: cache)
        let rescanned = try CodexUsageRecordScanner.collect(codexHomePath: f.home.path, now: now, calendar: calendar, cacheURL: cache)
        XCTAssertEqual(rescanned.totals?.totalTokens, 120)
        XCTAssertTrue(rescanned.usageByResponseHash.values.allSatisfy { $0.creatorWorkspaceHash == CodexUsageSupport.hash("workspace-a")
            && $0.workspaceHash == nil && $0.workspaceScopeEvidence == nil })
        let upgraded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
        XCTAssertEqual(upgraded["schemaVersion"] as? Int, 5)
    }

    func testDuplicateResponseConflictsLoseScopeWithoutChangingGlobalDedupTotals() throws {
        let f = try fixture()
        let second = f.file.deletingLastPathComponent().appendingPathComponent("copy.jsonl")
        try append(metadata("workspace-a", session: "a"), to: f.file)
        try append(usage("same-response", session: "a", tokens: 100), to: f.file)
        try append(metadata("workspace-b", session: "b"), to: second)
        try append(usage("same-response", session: "b", tokens: 100), to: second)
        let result = try CodexUsageRecordScanner.collect(codexHomePath: f.home.path, now: now, calendar: calendar)
        XCTAssertEqual(result.totals?.totalTokens, 100)
        XCTAssertEqual(result.usageByResponseHash.count, 1)
        XCTAssertNil(result.usageByResponseHash.values.first?.creatorWorkspaceHash)
        XCTAssertNil(result.usageByResponseHash.values.first?.verifiedWorkspaceHash)
    }

    func testCreatorOnlyRecordsNeverBecomeWorkspaceUsageEvenInSharedHome() async throws {
        let f = try fixture()
        try append(metadata("workspace-a", session: "a"), to: f.file)
        try append(usage("a", session: "a", tokens: 100), to: f.file)
        try append(metadata("workspace-b", session: "b"), to: f.file)
        try append(usage("b", session: "b", tokens: 200), to: f.file)
        let config = CodexAccountConfiguration(homes: [f.home.path], message: nil)
        let global = try aggregate(config)
        XCTAssertEqual(global.value?.totals.totalTokens, 300)
        let result = try await collect([account("a", scope: "workspace-a"), account("b", scope: "workspace-b")], fixture: f)
        XCTAssertTrue(result.value!.allSatisfy { $0.tokens?.value == nil && $0.history?.value == nil })
        XCTAssertTrue(result.value!.allSatisfy { $0.tokens?.status == .unavailable })
        XCTAssertEqual(result.value?.map { $0.quota.status }, [.unavailable, .unavailable])
    }

    func testSyntheticVerifiedRequestScopesKeepDifferentTodayAndHistoryReadings() async throws {
        let f = try fixture()
        let records = typedRecords(["a": verifiedRequest("workspace-a", tokens: 100, session: "a"),
                                    "b": verifiedRequest("workspace-b", tokens: 200, session: "b")])
        let result = try await collect([account("a", scope: "workspace-a"), account("b", scope: "workspace-b")], fixture: f, remote: records)
        XCTAssertEqual(result.value?.map { $0.tokens?.value?.totalTokens }, [100, 200])
        XCTAssertEqual(result.value?.map { $0.history?.value?.totals.totalTokens }, [100, 200])
        XCTAssertEqual(result.value?.map { $0.tokens?.status }, [.ready, .ready])
        XCTAssertNotEqual(result.value?[0].history?.value?.sourceID, result.value?[1].history?.value?.sourceID)
        let updatedRecords = typedRecords(["a": verifiedRequest("workspace-a", tokens: 100, session: "a"),
                                           "b": verifiedRequest("workspace-b", tokens: 200, session: "b"),
                                           "b-next": verifiedRequest("workspace-b", tokens: 70, session: "b")])
        let updated = try await collect(result.value!, fixture: f, previous: result.value!, remote: updatedRecords)
        XCTAssertEqual(updated.value?.map { $0.tokens?.value?.totalTokens }, [100, 270])
    }

    func testRequestEvidenceOverridesDifferentCreatorWithoutAllocatingToCreator() async throws {
        let f = try fixture()
        let record = verifiedRequest("workspace-b", tokens: 100, creator: "workspace-a")
        let result = try await collect([account("a", scope: "workspace-a"), account("b", scope: "workspace-b")],
                                       fixture: f, remote: typedRecords(["request": record]))
        XCTAssertNil(result.value?[0].tokens?.value)
        XCTAssertNil(result.value?[0].history?.value)
        XCTAssertEqual(result.value?[1].tokens?.value?.totalTokens, 100)
        XCTAssertEqual(result.value?[1].tokens?.status, .ready)
    }

    func testTypedWorkspaceHashRequiresProofAndValidCanonicalHash() async throws {
        let f = try fixture()
        var noProof = verifiedRequest("workspace-a", tokens: 100)
        noProof.workspaceScopeEvidence = nil
        var invalidProof = verifiedRequest("workspace-b", tokens: 200)
        invalidProof.workspaceHash = "not-a-sha256"
        XCTAssertNil(noProof.verifiedWorkspaceHash)
        XCTAssertNil(invalidProof.verifiedWorkspaceHash)
        let decoded = try JSONDecoder().decode(CodexResponseUsage.self, from: JSONEncoder().encode(noProof))
        XCTAssertNil(decoded.verifiedWorkspaceHash)
        let result = try await collect([account("a", scope: "workspace-a"), account("b", scope: "workspace-b")],
                                       fixture: f, remote: typedRecords(["legacy-hash": decoded, "invalid-proof": invalidProof]))
        XCTAssertTrue(result.value!.allSatisfy { $0.tokens?.value == nil && $0.history?.value == nil })
        var unknownEvidence = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(noProof)) as? [String: Any])
        unknownEvidence["workspaceScopeEvidence"] = "sessionCreator"
        XCTAssertThrowsError(try JSONDecoder().decode(CodexResponseUsage.self, from: JSONSerialization.data(withJSONObject: unknownEvidence)))
    }

    func testUnknownCreatorOnlyAndLegacyRemaindersNeverGetAddedToVerifiedRequests() async throws {
        let f = try fixture()
        let own = [account("a", scope: "workspace-a"), account("b", scope: "workspace-b")]
        let request = typedRecords(["a": verifiedRequest("workspace-a", tokens: 100)])
        let legacy = try await collect(own, fixture: f, extraToday: 900, remote: request)
        XCTAssertEqual(legacy.value?[0].tokens?.value?.totalTokens, 100)
        XCTAssertEqual(legacy.value?[0].tokens?.status, .stale)
        XCTAssertEqual(legacy.value?[0].tokens?.source, .codexBarLocal)
        XCTAssertNil(legacy.value?[1].tokens?.value)
        try append(metadata("workspace-b", session: "creator-b"), to: f.file)
        try append(usage("creator-only", session: "creator-b", tokens: 900), to: f.file)
        let unknown = try await collect(own, fixture: f, remote: request)
        XCTAssertEqual(unknown.value?[0].tokens?.value?.totalTokens, 100)
        XCTAssertEqual(unknown.value?[0].tokens?.status, .stale)
        XCTAssertNil(unknown.value?[1].history?.value)
    }

    func testAuthOnlyAndCreatorOnlyZeroStayUnknownButVerifiedZeroIsRealZero() async throws {
        let f = try fixture()
        let accounts = [account("a", scope: "workspace-a"), account("b", scope: "workspace-b")]
        let empty = try await collect(accounts, fixture: f)
        XCTAssertTrue(empty.value!.allSatisfy { $0.tokens?.value == nil && $0.history?.value == nil })
        try append(metadata("workspace-a", session: "a"), to: f.file)
        try append(usage("creator-zero", session: "a", tokens: 0), to: f.file)
        let creatorZero = try await collect(accounts, fixture: f)
        XCTAssertTrue(creatorZero.value!.allSatisfy { $0.tokens?.value == nil && $0.history?.value == nil })
        let clean = try fixture()
        let zero = try await collect(accounts, fixture: clean, remote: typedRecords(["zero": verifiedRequest("workspace-a", tokens: 0)]))
        XCTAssertEqual(zero.value?[0].tokens?.value?.totalTokens, 0)
        XCTAssertEqual(zero.value?[0].tokens?.status, .ready)
        XCTAssertNil(zero.value?[1].tokens?.value)
    }

    func testConflictingRequestEvidenceClearsCacheEvenWhenAnotherSourceIsIncomplete() async throws {
        let f = try fixture()
        let a = verifiedRequest("workspace-a", tokens: 100)
        let first = try await collect([account("a", scope: "workspace-a")], fixture: f, remote: typedRecords(["same": a]))
        let conflict = a.mergingWorkspaceScope(verifiedRequest("workspace-b", tokens: 100))
        XCTAssertNil(conflict.verifiedWorkspaceHash)
        XCTAssertNil(conflict.workspaceScopeEvidence)
        XCTAssertEqual(conflict.inputTokens, 100)
        for message in [nil, "Synthetic source discovery failure"] as [String?] {
            let config = CodexAccountConfiguration(homes: [f.home.path], message: message)
            let result = try await collect(first.value!, fixture: f, previous: first.value!, configuration: config,
                                           remote: typedRecords(["same": conflict]))
            XCTAssertNil(result.value?[0].tokens?.value)
            XCTAssertNil(result.value?[0].history?.value)
        }
        var unprovedDuplicate = a
        unprovedDuplicate.workspaceScopeEvidence = nil
        XCTAssertNil(a.mergingWorkspaceScope(unprovedDuplicate).verifiedWorkspaceHash)
    }

    func testRequestCacheRetentionRequiresMatchingScopeSourceAndDay() async throws {
        let f = try fixture()
        let first = try await collect([account("a", scope: "workspace-a")], fixture: f,
                                       remote: typedRecords(["a": verifiedRequest("workspace-a", tokens: 100)]))
        let lower = typedRecords(["a": verifiedRequest("workspace-a", tokens: 1)])
        let partial = CodexAccountConfiguration(homes: [f.home.path], message: "Synthetic source recovery")
        let retained = try await collect(first.value!, fixture: f, previous: first.value!, configuration: partial, remote: lower)
        XCTAssertEqual(retained.value?[0].tokens?.value?.totalTokens, 100)
        XCTAssertEqual(retained.value?[0].tokens?.status, .stale)
        XCTAssertEqual(retained.value?[0].tokens?.source, .cache)
        let differentScope = try await collect([account("a", scope: "workspace-b")], fixture: f,
                                              previous: first.value!, configuration: partial, remote: lower)
        XCTAssertNil(differentScope.value?[0].tokens?.value)
        let otherDay = try await collect(first.value!, fixture: f, previous: first.value!, configuration: partial,
                                         remote: lower, referenceDate: now.addingTimeInterval(86_400))
        XCTAssertNil(otherDay.value?[0].tokens?.value)
        let other = f.root.appendingPathComponent("other-home")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let differentSource = try await collect(first.value!, fixture: f, previous: first.value!,
            configuration: .init(homes: [other.path], message: "Synthetic source recovery"), remote: lower)
        XCTAssertEqual(differentSource.value?[0].tokens?.value?.totalTokens, 1)
        XCTAssertEqual(differentSource.value?[0].tokens?.source, .codexBarLocal)
    }

    func testOldCreatorBasedSnapshotHistoryNeverReturnsThroughStaleFallback() async throws {
        let f = try fixture()
        let scope = CodexUsageSupport.hash("workspace-a")
        var old = account("a", scope: "workspace-a")
        let totals = CodexTokenTotals(totalTokens: 100, inputTokens: 100, cachedInputTokens: 0,
                                     outputTokens: 0, reasoningTokens: 0, sessionCount: 1)
        let oldSource = CodexUsageSupport.hash((["workspace-records-v1", scope, f.home.path, "", "", "", calendar.timeZone.identifier]).joined(separator: "\u{0}"))
        old.tokens = reading(totals)
        old.history = reading(TokenHistory(sourceID: oldSource, timeZoneIdentifier: calendar.timeZone.identifier,
            days: [TokenHistoryDay(date: calendar.startOfDay(for: now), totals: totals)], totals: totals))
        let config = CodexAccountConfiguration(homes: [f.home.path], message: "Synthetic source unavailable")
        let result = try await collect([old], fixture: f, previous: [old], configuration: config)
        XCTAssertNil(result.value?[0].tokens?.value)
        XCTAssertNil(result.value?[0].history?.value)
    }

    func testRemoteWireCreatorAndLegacyWorkspaceHashNeverProduceRequestProof() throws {
        let f = try fixture()
        let response = f.root.appendingPathComponent("remote.json")
        let cache = f.root.appendingPathComponent("remote-cache.json")
        let fileID = CodexUsageSupport.hash("file")
        let record: [String: Any] = ["responseHash": CodexUsageSupport.hash("response"),
            "sessionHash": CodexUsageSupport.hash("session"), "timestamp": now.timeIntervalSince1970,
            "inputTokens": 100, "cachedInputTokens": 0, "outputTokens": 0, "reasoningTokens": 0,
            "creatorWorkspaceHash": CodexUsageSupport.hash("workspace-a"),
            "workspaceHash": CodexUsageSupport.hash("workspace-b"), "workspaceScopeEvidence": "requestAccount"]
        try JSONSerialization.data(withJSONObject: ["complete": true, "failedFiles": [], "activeFiles": [fileID],
            "files": [fileID: ["offset": 100, "reset": false, "records": [record]]]]).write(to: response)
        var env = ["CODEX_REMOTE_SSH_HOST": "synthetic-host", "CODEX_REMOTE_ROOT": "/synthetic/codex",
                   "CODEX_REMOTE_PYTHON": "/usr/bin/python3", "CODEX_REMOTE_RESPONSE_FIXTURE": response.path]
        let result = CodexRemoteUsageCollector.collect(environment: env, now: now, calendar: calendar, cacheURL: cache)
        XCTAssertEqual(result.usageByResponseHash.values.first?.inputTokens, 100)
        XCTAssertEqual(result.usageByResponseHash.values.first?.creatorWorkspaceHash, CodexUsageSupport.hash("workspace-a"))
        XCTAssertNil(result.usageByResponseHash.values.first?.workspaceHash)
        XCTAssertNil(result.usageByResponseHash.values.first?.workspaceScopeEvidence)
        var oldCache = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
        oldCache["schemaVersion"] = 4
        try JSONSerialization.data(withJSONObject: oldCache).write(to: cache)
        env["CODEX_REMOTE_RESPONSE_FIXTURE"] = f.root.appendingPathComponent("offline").path
        let migrated = CodexRemoteUsageCollector.collect(environment: env, now: now, calendar: calendar, cacheURL: cache)
        XCTAssertEqual(migrated.usageByResponseHash.values.first?.inputTokens, 100)
        XCTAssertNil(migrated.usageByResponseHash.values.first?.verifiedWorkspaceHash)
        XCTAssertNil(migrated.usageByResponseHash.values.first?.creatorWorkspaceHash)
    }

    func testOuterQuotaStatusAndUnauthenticatedScopeStayIndependent() async throws {
        let f = try fixture()
        let outer = reading([account("no-identity", scope: nil)], status: .error)
        let result = await CodexWorkspaceActivityCollector.collect(accounts: outer, previous: .unavailable("none"),
            configuration: .init(homes: [f.home.path], message: nil), aggregateHistory: try aggregate(.init(homes: [f.home.path], message: nil)),
            now: now, directory: f.root, environment: [:], calendar: calendar)
        XCTAssertEqual(result.status, outer.status)
        XCTAssertEqual(result.source, outer.source)
        XCTAssertEqual(result.measuredAt, outer.measuredAt)
        XCTAssertNil(result.value?[0].tokens?.value)
        XCTAssertEqual(result.value?[0].quota, outer.value?[0].quota)
    }

    func testProviderWideFixturesNeverScanOrAllocateGlobalTotalsToWorkspaces() async throws {
        for key in ["CODEX_TOKEN_FIXTURE", "CODEX_HISTORY_FIXTURE"] {
            let f = try fixture()
            try append(metadata("workspace-a", session: "session-a"), to: f.file)
            try append(usage("real-synthetic-record", session: "session-a", tokens: 100), to: f.file)
            let outer = reading([account("a", scope: "workspace-a")], status: .error)
            let aggregate = reading(TokenHistory<CodexTokenTotals>(sourceID: "provider-fixture", timeZoneIdentifier: calendar.timeZone.identifier,
                days: [TokenHistoryDay(date: calendar.startOfDay(for: now), totals: .zero)], totals: .zero))
            let result = await CodexWorkspaceActivityCollector.collect(accounts: outer, previous: outer,
                configuration: .init(homes: [f.home.path, f.root.appendingPathComponent("missing-source").path], message: nil),
                aggregateHistory: aggregate, now: now, directory: f.root, environment: [key: "synthetic-fixture.json"], calendar: calendar)
            XCTAssertNil(result.value?[0].tokens?.value, key)
            XCTAssertNil(result.value?[0].history?.value, key)
            XCTAssertEqual(result.value?[0].tokens?.status, .unavailable, key)
            XCTAssertEqual(result.status, outer.status, key)
            XCTAssertEqual(result.value?[0].quota, outer.value?[0].quota, key)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path), ["home"], key)
        }
    }

    func testAccountsWithoutTrustedScopeSkipLogScanAndCacheCreation() async throws {
        let f = try fixture()
        try append(metadata("workspace-a", session: "session-a"), to: f.file)
        try append(usage("real-synthetic-record", session: "session-a", tokens: 100), to: f.file)
        var invalid = account("invalid", scope: nil)
        invalid.workspaceAccountIDHash = "invalid-hash"
        let result = await CodexWorkspaceActivityCollector.collect(accounts: reading([account("unknown", scope: nil), invalid]),
            previous: .unavailable("none"), configuration: .init(homes: [f.home.path], message: nil),
            aggregateHistory: .unavailable("No global provenance"), now: now, directory: f.root, environment: [:], calendar: calendar)
        XCTAssertTrue(result.value?.allSatisfy { $0.tokens?.value == nil && $0.history?.value == nil } == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path), ["home"])
    }

    func testSharedSummaryRetainsIndependentProofWithoutReopeningLogSources() async throws {
        let f = try fixture()
        let configuration = CodexAccountConfiguration(homes: [f.home.path], message: nil)
        let remote = typedRecords(["a": verifiedRequest("workspace-a", tokens: 100),
                                   "b": verifiedRequest("workspace-b", tokens: 200)])
        let history = try aggregate(configuration, remote: remote)
        let summary = try CodexWorkspaceActivityCollector.summarize(records: remote.usageByResponseHash,
            complete: true, configuration: configuration, environment: [:], now: now, calendar: calendar)
        let rows = [account("a", scope: "workspace-a"), account("b", scope: "workspace-b")]
        let standalone = try await collect(rows, fixture: f, remote: remote)
        // Removing the synthetic source would make another scan incomplete. Reuse must
        // consume the frozen summary only, without creating or decoding another cache.
        try FileManager.default.removeItem(at: f.home)
        let filesBeforeReuse = try FileManager.default.contentsOfDirectory(atPath: f.root.path)
        let bytesBeforeReuse = try filesBeforeReuse.map { try Data(contentsOf: f.root.appendingPathComponent($0)) }
        let result = await CodexWorkspaceActivityCollector.collect(accounts: reading(rows), previous: .unavailable("none"),
            configuration: configuration, aggregateHistory: history, scanSummary: summary,
            now: now, directory: f.root, environment: [:], calendar: calendar)
        XCTAssertEqual(result, standalone)
        XCTAssertEqual(result.value?.map { $0.tokens?.value?.totalTokens }, [100, 200])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path), filesBeforeReuse)
        XCTAssertEqual(try filesBeforeReuse.map { try Data(contentsOf: f.root.appendingPathComponent($0)) }, bytesBeforeReuse)
    }

    func testSharedSummaryRejectsAnotherSourceOrReferenceDate() async throws {
        let f = try fixture()
        let configuration = CodexAccountConfiguration(homes: [f.home.path], message: nil)
        let records = typedRecords(["a": verifiedRequest("workspace-a", tokens: 100)])
        let history = try aggregate(configuration, remote: records)
        let summary = try CodexWorkspaceActivityCollector.summarize(records: records.usageByResponseHash,
            complete: true, configuration: configuration, environment: [:], now: now, calendar: calendar)
        for changedSource in [false, true] {
            let result = await CodexWorkspaceActivityCollector.collect(accounts: reading([account("a", scope: "workspace-a")]),
                previous: .unavailable("none"), configuration: configuration, aggregateHistory: history,
                scanSummary: summary, now: changedSource ? now : now.addingTimeInterval(60), directory: f.root,
                environment: changedSource ? ["CODEX_REMOTE_SSH_HOST": "not-contacted-synthetic-host"] : [:], calendar: calendar)
            XCTAssertNil(result.value?[0].tokens?.value)
            XCTAssertNil(result.value?[0].history?.value)
        }
    }

    func testSharedSummaryPreservesUnknownConflictsAndIncompleteCacheRules() async throws {
        let f = try fixture()
        let configuration = CodexAccountConfiguration(homes: [f.home.path], message: nil)
        let rows = [account("a", scope: "workspace-a"), account("b", scope: "workspace-b")]
        let first = try await collect(rows, fixture: f, remote: typedRecords([
            "a": verifiedRequest("workspace-a", tokens: 100), "b": verifiedRequest("workspace-b", tokens: 200)]))
        for includeUnknown in [false, true] {
            var records = ["a": verifiedRequest("workspace-a", tokens: 1)]
            if includeUnknown {
                records["unattributed"] = CodexResponseUsage(inputTokens: 5, cachedInputTokens: 0,
                    outputTokens: 0, reasoningTokens: 0, sessionHash: "unknown", timestamp: now)
            }
            let remote = typedRecords(records, complete: false)
            let history = try aggregate(configuration, remote: remote)
            let standalone = try await collect(rows, fixture: f, previous: first.value!, remote: remote)
            let summary = try CodexWorkspaceActivityCollector.summarize(records: remote.usageByResponseHash,
                complete: false, configuration: configuration, environment: [:], now: now, calendar: calendar)
            let shared = await CodexWorkspaceActivityCollector.collect(accounts: reading(rows), previous: first,
                configuration: configuration, aggregateHistory: history, scanSummary: summary,
                now: now, directory: f.root, environment: [:], calendar: calendar)
            XCTAssertEqual(shared, standalone, "unknown evidence: \(includeUnknown)")
            XCTAssertEqual(shared.value?[0].tokens?.value?.totalTokens, includeUnknown ? 1 : 100)
        }
    }
}
