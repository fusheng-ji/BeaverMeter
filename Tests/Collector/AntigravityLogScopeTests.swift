import CodexBarCore
import Foundation
import SQLite3
import XCTest

final class AntigravityLogScopeTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let home: URL
        let cache: URL
        var app: URL { home.appendingPathComponent(".gemini/antigravity") }
        var conversations: URL { app.appendingPathComponent("conversations") }
        var cli: URL { home.appendingPathComponent(".gemini/antigravity-cli/conversations") }
        var environment: [String: String] { ["HOME": home.path] }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beavermeter-antigravity-log-scope-\(UUID())", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let result = Fixture(root: root, home: home, cache: root.appendingPathComponent("cache"))
        try FileManager.default.createDirectory(at: result.conversations, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return result
    }

    @discardableResult
    private func database(_ path: URL, sql: String, keepOpen: Bool = false) throws -> OpaquePointer? {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle else { throw TestError.database }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw TestError.database
        }
        if keepOpen { return handle }
        sqlite3_close(handle)
        return nil
    }

    private func summary(_ fixture: Fixture, extra: String = "") throws {
        try database(fixture.app.appendingPathComponent("conversation_summaries.db"), sql: """
            CREATE TABLE conversation_summaries(conversation_id TEXT, title TEXT, preview TEXT, raw_summary BLOB);
            CREATE TABLE search_schema_version(version INTEGER);
            \(extra)
            """)
    }

    private func emptyConversation(_ path: URL) throws {
        try database(path, sql: "CREATE TABLE gen_metadata(idx INTEGER, data BLOB, size INTEGER);")
    }

    private func scopedApp(_ scope: AntigravityLogScope, fixture: Fixture) -> URL {
        AntigravityOfflineStore.appDataDirectory(home: fixture.home, env: scope.environment)
    }

    private enum TestError: Error { case database, operation }

    func testPrivateSnapshotExcludesProvenIndexAndPreservesOriginalDatabases() throws {
        let fixture = try fixture()
        try summary(fixture)
        let session = fixture.conversations.appendingPathComponent("synthetic-session.db")
        try emptyConversation(session)
        let legacy = fixture.app.appendingPathComponent("synthetic-legacy.db")
        try emptyConversation(legacy)
        try emptyConversation(fixture.cli.appendingPathComponent("synthetic-cli.db"))
        let index = fixture.app.appendingPathComponent("conversation_summaries.db")
        let originalIndex = try Data(contentsOf: index)
        let originalLegacy = try Data(contentsOf: legacy)
        let originalSession = try Data(contentsOf: session)
        let scope = try AntigravityLogScope(environment: fixture.environment, cacheRoot: fixture.cache)
        let app = scopedApp(scope, fixture: fixture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("conversation_summaries.db").path))
        let copiedSession = app.appendingPathComponent("conversations/synthetic-session.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedSession.path))
        XCTAssertNotEqual(copiedSession.resolvingSymlinksInPath().path, session.path)
        let cli = AntigravityOfflineStore.conversationsDirectory(home: fixture.home, env: scope.environment)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cli.appendingPathComponent("synthetic-cli.db").path))
        XCTAssertNotEqual(cli.path, fixture.cli.path)
        let copiedLegacy = app.appendingPathComponent("synthetic-legacy.db")
        XCTAssertFalse(try copiedLegacy.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        let filePermissions = try FileManager.default.attributesOfItem(atPath: copiedLegacy.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(filePermissions?.intValue, 0o600)
        XCTAssertEqual(scope.environment["HOME"], fixture.home.path)
        let permissions = try FileManager.default.attributesOfItem(atPath: scope.directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
        try scope.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: scope.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.path))
        XCTAssertEqual(try Data(contentsOf: index), originalIndex)
        XCTAssertEqual(try Data(contentsOf: legacy), originalLegacy)
        XCTAssertEqual(try Data(contentsOf: session), originalSession)
    }

    func testKnownNameWithUnknownSchemaOrAdditionalTableIsNotExcluded() throws {
        let fixture = try fixture()
        try summary(fixture, extra: "CREATE TABLE unsupported_log(value BLOB);")
        let scope = try AntigravityLogScope(environment: fixture.environment, cacheRoot: fixture.cache)
        defer { try? scope.cleanup() }
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            scopedApp(scope, fixture: fixture).appendingPathComponent("conversation_summaries.db").path))
    }

    func testKnownNameWithConversationMetadataIsNotExcluded() throws {
        let fixture = try fixture()
        try summary(fixture, extra: "CREATE TABLE gen_metadata(idx INTEGER, data BLOB);")
        let scope = try AntigravityLogScope(environment: fixture.environment, cacheRoot: fixture.cache)
        defer { try? scope.cleanup() }
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            scopedApp(scope, fixture: fixture).appendingPathComponent("conversation_summaries.db").path))
    }

    func testOnlyRecognizedFilenameCanBeExcludedEvenWhenAliasPointsAtIndex() throws {
        let fixture = try fixture()
        try summary(fixture)
        try FileManager.default.createSymbolicLink(at: fixture.app.appendingPathComponent("other.db"),
            withDestinationURL: fixture.app.appendingPathComponent("conversation_summaries.db"))
        let scope = try AntigravityLogScope(environment: fixture.environment, cacheRoot: fixture.cache)
        defer { try? scope.cleanup() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: scopedApp(scope, fixture: fixture).appendingPathComponent("other.db").path))
    }

    func testRealLocalReaderCompletesWhenOnlyNonUsageIndexIsExcluded() async throws {
        let fixture = try fixture()
        try summary(fixture)
        try emptyConversation(fixture.conversations.appendingPathComponent("synthetic-session.db"))
        let reading = await AntigravityTokenCollector.collect(previous: .unavailable("No log data"), now: .now,
            cacheRoot: fixture.cache, environment: fixture.environment)
        XCTAssertEqual(reading.status, .ready)
        XCTAssertEqual(reading.value?.totalTokens, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).allSatisfy {
            !$0.hasPrefix("log-scope-")
        })
    }

    func testUnknownRootDatabaseStillBlocksPublicationOfAProvenZero() async throws {
        let fixture = try fixture()
        try summary(fixture)
        try emptyConversation(fixture.conversations.appendingPathComponent("synthetic-session.db"))
        try database(fixture.app.appendingPathComponent("unknown.db"), sql: "CREATE TABLE future_log(value BLOB);")
        let reading = await AntigravityTokenCollector.collect(previous: .unavailable("No log data"), now: .now,
            cacheRoot: fixture.cache, environment: fixture.environment)
        XCTAssertEqual(reading.status, .unavailable)
        XCTAssertNil(reading.value)
    }

    func testPrivateSnapshotReplaysUncheckpointedWALWithoutChangingSource() throws {
        let fixture = try fixture()
        let legacy = fixture.app.appendingPathComponent("synthetic-legacy.db")
        let writer = try XCTUnwrap(database(legacy, sql: """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE gen_metadata(idx INTEGER, data BLOB);
            INSERT INTO gen_metadata VALUES(1, X'00');
            """, keepOpen: true))
        defer { sqlite3_close(writer) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path + "-wal"))
        let originalDB = try Data(contentsOf: legacy)
        let originalWAL = try Data(contentsOf: URL(fileURLWithPath: legacy.path + "-wal"))
        let scope = try AntigravityLogScope(environment: fixture.environment, cacheRoot: fixture.cache)
        defer { try? scope.cleanup() }
        var reader: OpaquePointer?
        let copied = scopedApp(scope, fixture: fixture).appendingPathComponent("synthetic-legacy.db")
        XCTAssertEqual(sqlite3_open_v2(copied.path, &reader, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let handle = try XCTUnwrap(reader)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT count(*) FROM gen_metadata", -1, &statement, nil), SQLITE_OK)
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(query, 0), 1)
        XCTAssertEqual(try Data(contentsOf: legacy), originalDB)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: legacy.path + "-wal")), originalWAL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path + "-wal"))
    }

    func testExplicitGeminiHomeAndTokscaleConfigurationArePreserved() throws {
        let fixture = try fixture()
        let custom = fixture.root.appendingPathComponent("custom-gemini")
        let customCLI = custom.appendingPathComponent("antigravity-cli/conversations")
        try FileManager.default.createDirectory(at: customCLI, withIntermediateDirectories: true)
        let original = ["HOME": fixture.home.path, "GEMINI_CLI_HOME": custom.path,
                        "TOKSCALE_CONFIG_DIR": fixture.root.appendingPathComponent("custom-tokscale").path]
        let scope = try AntigravityLogScope(environment: original, cacheRoot: fixture.cache)
        defer { try? scope.cleanup() }
        XCTAssertEqual(scope.environment["HOME"], original["HOME"])
        XCTAssertEqual(scope.environment["TOKSCALE_CONFIG_DIR"], original["TOKSCALE_CONFIG_DIR"])
        let copiedCLI = AntigravityOfflineStore.conversationsDirectory(home: fixture.home, env: scope.environment)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedCLI.path))
        XCTAssertNotEqual(copiedCLI.path, customCLI.path)
    }

    func testColdWALWithoutSidecarsIsReadableThroughPublicScannerAndOriginalStaysUnchanged() async throws {
        let fixture = try fixture()
        let source = fixture.conversations.appendingPathComponent("synthetic-cold-wal.db")
        try database(source, sql: """
            PRAGMA journal_mode=WAL;
            CREATE TABLE gen_metadata(idx INTEGER, data BLOB);
            PRAGMA wal_checkpoint(TRUNCATE);
            """)
        // Apple's SQLite may retain empty WAL/SHM files after the final close.
        // Remove only this checkpointed synthetic store's sidecars to reproduce
        // the observed cold-WAL store exactly.
        let wal = URL(fileURLWithPath: source.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            XCTAssertEqual(try Data(contentsOf: wal).count, 0)
            try FileManager.default.removeItem(at: wal)
        }
        let shm = URL(fileURLWithPath: source.path + "-shm")
        if FileManager.default.fileExists(atPath: shm.path) { try FileManager.default.removeItem(at: shm) }
        let original = try Data(contentsOf: source)
        XCTAssertEqual(original[18], 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path + "-shm"))
        let reading = await AntigravityTokenCollector.collect(previous: .unavailable("No log data"), now: .now,
            cacheRoot: fixture.cache, environment: fixture.environment)
        XCTAssertEqual(reading.status, .ready)
        XCTAssertEqual(reading.value?.totalTokens, 0)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path + "-shm"))
    }

    func testSourceDatabaseChangeDuringCopyIsRejectedAndPrivateCopiesRemoved() throws {
        let fixture = try fixture()
        try emptyConversation(fixture.conversations.appendingPathComponent("changing.db"))
        XCTAssertThrowsError(try AntigravityLogScope(environment: fixture.environment, cacheRoot: fixture.cache,
            afterCopy: { source in
                let handle = try FileHandle(forWritingTo: source)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0]))
            }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).isEmpty)
    }

    func testSourceWALChangeDuringCopyIsRejected() throws {
        let fixture = try fixture()
        let source = fixture.conversations.appendingPathComponent("changing-wal.db")
        let writer = try XCTUnwrap(database(source, sql: """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE gen_metadata(idx INTEGER, data BLOB);
            INSERT INTO gen_metadata VALUES(1, X'00');
            """, keepOpen: true))
        defer { sqlite3_close(writer) }
        XCTAssertThrowsError(try AntigravityLogScope(environment: fixture.environment, cacheRoot: fixture.cache,
            afterCopy: { _ in
                guard sqlite3_exec(writer, "INSERT INTO gen_metadata VALUES(2, X'00');", nil, nil, nil) == SQLITE_OK else {
                    throw TestError.database
                }
            }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).isEmpty)
    }

    func testSnapshotBudgetsNeverTruncateIntoACompleteReading() throws {
        let fixture = try fixture()
        try emptyConversation(fixture.conversations.appendingPathComponent("synthetic-session.db"))
        let limits: [AntigravityLogScope.Limits] = [
            .init(databases: 0), .init(directoryEntries: 0), .init(databaseBytes: 1), .init(totalBytes: 1),
        ]
        for limit in limits {
            XCTAssertThrowsError(try AntigravityLogScope(environment: fixture.environment,
                cacheRoot: fixture.cache, limits: limit))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).isEmpty)
        }
    }

    func testNonemptyRollbackJournalOrJournalChangeCannotCertifyASnapshot() throws {
        let fixture = try fixture()
        let source = fixture.conversations.appendingPathComponent("rollback-transaction.db")
        try emptyConversation(source)
        let original = try Data(contentsOf: source)
        let journal = URL(fileURLWithPath: source.path + "-journal")
        try Data([1]).write(to: journal)
        XCTAssertThrowsError(try AntigravityLogScope(environment: fixture.environment, cacheRoot: fixture.cache))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).isEmpty)
        try Data().write(to: journal)
        XCTAssertThrowsError(try AntigravityLogScope(environment: fixture.environment, cacheRoot: fixture.cache,
            afterCopy: { _ in try Data([1]).write(to: journal) }))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).isEmpty)
    }

    func testInitializerFailureRemovesItsTemporaryView() throws {
        let fixture = try fixture()
        try FileManager.default.createDirectory(at: fixture.cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: fixture.cli)
        XCTAssertThrowsError(try AntigravityLogScope(environment: fixture.environment, cacheRoot: fixture.cache))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).isEmpty)
    }

    func testOperationSuccessFailureAndCancellationCleanUpTheView() async throws {
        let fixture = try fixture()
        let usedPath = try await AntigravityLogScope.withScope(environment: fixture.environment,
            cacheRoot: fixture.cache) { $0["GEMINI_CLI_HOME"]! }
        XCTAssertFalse(FileManager.default.fileExists(atPath: usedPath))
        do {
            let _: String = try await AntigravityLogScope.withScope(environment: fixture.environment,
                cacheRoot: fixture.cache) { _ in throw TestError.operation }
            XCTFail("Expected operation failure")
        } catch TestError.operation {}
        do {
            let _: String = try await AntigravityLogScope.withScope(environment: fixture.environment,
                cacheRoot: fixture.cache) { _ in throw CancellationError() }
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).isEmpty)
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var output: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            output.append(byte)
        } while remaining != 0
        return output
    }

    private func integer(_ field: Int, _ value: UInt64) -> [UInt8] {
        varint(UInt64(field << 3)) + varint(value)
    }

    private func message(_ field: Int, _ bytes: [UInt8]) -> [UInt8] {
        varint(UInt64(field << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }

    private func generationDatabase(_ fixture: Fixture, auxiliary: [UInt8]? = nil,
                                    auxiliaryType: Int = 17, missingNeededTime: Bool = false,
                                    trigger: Bool = false) throws -> (URL, Date) {
        let date = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!
        let timestamp = message(1, integer(1, UInt64(date.timeIntervalSince1970)))
        let bot = message(7, Array("synthetic-bot".utf8))
        let uuid = message(12, Array("synthetic-step".utf8))
        let usage = integer(1, 10) + integer(2, 20) + integer(5, 30)
            + integer(9, 40) + integer(10, 50) + bot
        let generation = message(1, message(4, usage)) + message(4, Array("synthetic-step".utf8))
        let needed = (missingNeededTime ? [] : timestamp) + message(9, bot) + uuid
        let helper = auxiliary ?? (timestamp + integer(3, 3)
            + message(20, Array("synthetic error".utf8)) + message(26, []) + message(35, []))
        func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
        let source = fixture.conversations.appendingPathComponent("synthetic-generation.db")
        let extra = trigger ? "CREATE TRIGGER preserve_guard AFTER DELETE ON steps BEGIN DELETE FROM gen_metadata; END;" : ""
        try database(source, sql: """
            CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY, data BLOB, size INTEGER);
            CREATE TABLE steps(idx INTEGER PRIMARY KEY, metadata BLOB, step_type INTEGER);
            INSERT INTO gen_metadata VALUES(1, X'\(hex(generation))', \(generation.count));
            INSERT INTO steps VALUES(1, X'\(hex(needed))', 2);
            INSERT INTO steps VALUES(2, X'\(hex(helper))', \(auxiliaryType));
            \(extra)
            """)
        return (source, date)
    }

    func testPublicReaderAcceptsValidUnkeyedAuxiliaryErrorWithoutChangingOriginal() async throws {
        let fixture = try fixture()
        let (source, now) = try generationDatabase(fixture)
        let original = try Data(contentsOf: source)
        let reading = await AntigravityTokenCollector.collect(previous: .unavailable("No log data"), now: now,
            cacheRoot: fixture.cache, environment: fixture.environment)
        XCTAssertEqual(reading.status, .ready)
        XCTAssertEqual(reading.value?.totalTokens, 150)
        XCTAssertEqual(reading.value?.inputTokens, 30)
        XCTAssertEqual(reading.value?.cacheReadTokens, 30)
        XCTAssertEqual(reading.value?.outputTokens, 40)
        XCTAssertEqual(reading.value?.reasoningTokens, 50)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testTruncatedAuxiliaryMetadataStillMakesPublicationUnknown() async throws {
        let fixture = try fixture()
        let (source, now) = try generationDatabase(fixture, auxiliary: [0x0a, 0x20, 0x08])
        let original = try Data(contentsOf: source)
        let reading = await AntigravityTokenCollector.collect(previous: .unavailable("No log data"), now: now,
            cacheRoot: fixture.cache, environment: fixture.environment)
        XCTAssertEqual(reading.status, .unavailable)
        XCTAssertNil(reading.value)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testMissingNeededGenerationTimestampIsNeverReplacedByAuxiliaryTime() async throws {
        let fixture = try fixture()
        let (source, now) = try generationDatabase(fixture, missingNeededTime: true)
        let original = try Data(contentsOf: source)
        let reading = await AntigravityTokenCollector.collect(previous: .unavailable("No log data"), now: now,
            cacheRoot: fixture.cache, environment: fixture.environment)
        XCTAssertEqual(reading.status, .unavailable)
        XCTAssertNil(reading.value)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testTriggerOrUnrecognizedAuxiliaryTypePreventsFiltering() async throws {
        for hasTrigger in [false, true] {
            let fixture = try fixture()
            let (source, now) = try generationDatabase(fixture, auxiliaryType: hasTrigger ? 17 : 99,
                                                       trigger: hasTrigger)
            let original = try Data(contentsOf: source)
            let reading = await AntigravityTokenCollector.collect(previous: .unavailable("No log data"), now: now,
                cacheRoot: fixture.cache, environment: fixture.environment)
            XCTAssertEqual(reading.status, .unavailable)
            XCTAssertNil(reading.value)
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }
}
