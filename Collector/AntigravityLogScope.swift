import CodexBarCore
import Darwin
import Foundation
import SQLite3

/// Antigravity keeps a search/preview index beside its conversation databases.
/// The pinned reader conservatively treats every unsupported .db as incomplete.
/// Scan a bounded private snapshot: source DB/WAL bytes are never opened writable,
/// while a cold WAL database can be normalized safely inside the private copy.
struct AntigravityLogScope: Sendable {
    let environment: [String: String]
    let directory: URL

    struct Limits: Sendable {
        var databases = 500
        var directoryEntries = 10_000
        var databaseBytes: Int64 = 64 * 1024 * 1024
        var totalBytes: Int64 = 128 * 1024 * 1024
    }

    init(environment: [String: String], cacheRoot: URL, limits: Limits = Limits(),
         afterCopy: (URL) throws -> Void = { _ in }) throws {
        let files = FileManager.default
        try files.createDirectory(at: cacheRoot, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let view = cacheRoot.appendingPathComponent("log-scope-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: view, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        var scoped = environment
        do {
            let home = environment["HOME"].flatMap(CodexUsageSupport.nonempty)
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? files.homeDirectoryForCurrentUser
            let sourceApp = AntigravityOfflineStore.appDataDirectory(home: home, env: environment)
            let sourceCLI = AntigravityOfflineStore.conversationsDirectory(home: home, env: environment)
            let app = view.appendingPathComponent("antigravity", isDirectory: true)
            let cli = view.appendingPathComponent("antigravity-cli", isDirectory: true)
            try files.createDirectory(at: app, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
            try files.createDirectory(at: cli, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
            var budget = Budget(limits: limits)
            var observations: [Observation] = []
            try Self.snapshotDirectory(sourceCLI, to: cli.appendingPathComponent("conversations"),
                excludesIndex: false, budget: &budget, observations: &observations, afterCopy: afterCopy)
            try Self.snapshotDirectory(sourceApp, to: app, excludesIndex: true,
                budget: &budget, observations: &observations, afterCopy: afterCopy)
            try Self.snapshotDirectory(sourceApp.appendingPathComponent("conversations"),
                to: app.appendingPathComponent("conversations"), excludesIndex: false,
                budget: &budget, observations: &observations, afterCopy: afterCopy)
            // Also reject directories/files added, removed or replaced while a
            // multi-database snapshot was being assembled.
            for observation in observations {
                guard try FileState.read(observation.url) == observation.state else { throw ScopeError.changed }
            }
            scoped["GEMINI_CLI_HOME"] = view.path
        } catch {
            try? files.removeItem(at: view)
            throw error
        }
        self.environment = scoped
        self.directory = view
    }

    func cleanup() throws {
        try FileManager.default.removeItem(at: directory)
    }

    static func withScope<Value: Sendable>(
        environment: [String: String], cacheRoot: URL,
        operation: @Sendable ([String: String]) async throws -> Value
    ) async throws -> Value {
        let scope = try Self(environment: environment, cacheRoot: cacheRoot)
        do {
            let value = try await operation(scope.environment)
            try scope.cleanup()
            return value
        } catch {
            try? scope.cleanup()
            throw error
        }
    }

    private enum ScopeError: Error { case unreadable, changed, exhausted }

    private struct FileState: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let mode: mode_t
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int

        var isRegular: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFREG) }
        var isDirectory: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }

        static func read(_ url: URL) throws -> FileState? {
            var value = stat()
            guard url.path.withCString({ lstat($0, &value) }) == 0 else {
                if errno == ENOENT { return nil }
                throw ScopeError.unreadable
            }
            return FileState(device: value.st_dev, inode: value.st_ino, size: value.st_size,
                mode: value.st_mode, modifiedSeconds: value.st_mtimespec.tv_sec,
                modifiedNanos: value.st_mtimespec.tv_nsec, changedSeconds: value.st_ctimespec.tv_sec,
                changedNanos: value.st_ctimespec.tv_nsec)
        }
    }

    private struct Observation {
        let url: URL
        let state: FileState?
    }

    private struct Budget {
        let limits: Limits
        var entries = 0
        var databases = 0
        var bytes: Int64 = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 10

        func check() throws {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ScopeError.exhausted }
        }
    }

    private static func snapshotDirectory(_ original: URL, to destination: URL, excludesIndex: Bool,
        budget: inout Budget, observations: inout [Observation], afterCopy: (URL) throws -> Void) throws {
        try budget.check()
        let source = original.resolvingSymlinksInPath()
        let state = try FileState.read(source)
        observations.append(Observation(url: source, state: state))
        guard let state else { return }
        guard state.isDirectory else { throw ScopeError.unreadable }
        let files = FileManager.default
        try files.createDirectory(at: destination, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        var enumerationFailed = false
        guard let entries = files.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }) else { throw ScopeError.unreadable }
        while let entry = entries.nextObject() as? URL {
            try budget.check()
            budget.entries += 1
            guard budget.entries <= budget.limits.directoryEntries else { throw ScopeError.exhausted }
            guard !entry.lastPathComponent.hasPrefix("."), entry.pathExtension.lowercased() == "db" else { continue }
            budget.databases += 1
            guard budget.databases <= budget.limits.databases else { throw ScopeError.exhausted }
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            try snapshotDatabase(entry.resolvingSymlinksInPath(), to: target,
                budget: &budget, observations: &observations, afterCopy: afterCopy)
            if excludesIndex, entry.lastPathComponent == "conversation_summaries.db",
               try isKnownSummaryIndex(target) {
                try files.removeItem(at: target)
            } else {
                try AntigravityAuxiliaryStepCompatibility.preparePrivateDatabase(target)
            }
        }
        guard !enumerationFailed else { throw ScopeError.unreadable }
    }

    private static func snapshotDatabase(_ source: URL, to destination: URL,
        budget: inout Budget, observations: inout [Observation], afterCopy: (URL) throws -> Void) throws {
        let sourceWAL = URL(fileURLWithPath: source.path + "-wal")
        let sourceJournal = URL(fileURLWithPath: source.path + "-journal")
        guard let database = try FileState.read(source), database.isRegular,
              database.size >= 0 else { throw ScopeError.unreadable }
        let wal = try FileState.read(sourceWAL)
        guard wal == nil || (wal!.isRegular && wal!.size >= 0) else { throw ScopeError.unreadable }
        let journal = try FileState.read(sourceJournal)
        // A rollback transaction can leave stable-looking uncommitted main-DB
        // pages while its writer is paused. Without its recovery journal this
        // is not a trustworthy DB/WAL snapshot. Empty TRUNCATE journals are safe
        // only while their fingerprint remains unchanged throughout the copy.
        guard journal == nil || (journal!.isRegular && journal!.size == 0) else { throw ScopeError.changed }
        let (pairSize, pairOverflow) = Int64(database.size).addingReportingOverflow(Int64(wal?.size ?? 0))
        let (total, totalOverflow) = budget.bytes.addingReportingOverflow(pairSize)
        guard !pairOverflow, !totalOverflow, pairSize <= budget.limits.databaseBytes,
              total <= budget.limits.totalBytes else { throw ScopeError.exhausted }
        budget.bytes = total
        try copyPrivate(source, to: destination)
        if wal != nil { try copyPrivate(sourceWAL, to: URL(fileURLWithPath: destination.path + "-wal")) }
        try afterCopy(source)
        guard try FileState.read(source) == database,
              try FileState.read(sourceWAL) == wal,
              try FileState.read(sourceJournal) == journal else { throw ScopeError.changed }
        observations.append(Observation(url: source, state: database))
        observations.append(Observation(url: sourceWAL, state: wal))
        observations.append(Observation(url: sourceJournal, state: journal))
        try normalizePrivateDatabase(destination)
        try budget.check()
    }

    private static func copyPrivate(_ source: URL, to destination: URL) throws {
        let copied = source.path.withCString { from in
            destination.path.withCString { to in clonefile(from, to, 0) == 0 }
        }
        if !copied {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    /// Only a private copy is writable. SQLite validates/replays its copied WAL
    /// and converts the cold WAL header to ordinary rollback-journal mode before
    /// the original public read-only scanner sees it. No immutable bypass is used.
    private static func normalizePrivateDatabase(_ url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database = handle else {
            if let handle { sqlite3_close(handle) }
            throw ScopeError.unreadable
        }
        defer { sqlite3_close(database) }
        let deadline = Deadline(seconds: 2)
        sqlite3_progress_handler(database, 1000, { pointer in
            guard let pointer else { return 1 }
            return Unmanaged<Deadline>.fromOpaque(pointer).takeUnretainedValue().hasExpired ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
        defer { withExtendedLifetime(deadline) { sqlite3_progress_handler(database, 0, nil, nil) } }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA journal_mode=DELETE", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ScopeError.unreadable }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              text(statement, column: 0)?.lowercased() == "delete",
              sqlite3_step(statement) == SQLITE_DONE else { throw ScopeError.unreadable }
    }

    /// A name alone is insufficient: a changed/future database with this name
    /// must go through the original reader and keep its fail-closed behavior.
    private static func isKnownSummaryIndex(_ url: URL) throws -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw ScopeError.unreadable
        }
        defer { sqlite3_close(database) }
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 64 * 1024)
        let deadline = Deadline()
        sqlite3_progress_handler(database, 1000, { pointer in
            guard let pointer else { return 1 }
            return Unmanaged<Deadline>.fromOpaque(pointer).takeUnretainedValue().hasExpired ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
        defer { withExtendedLifetime(deadline) { sqlite3_progress_handler(database, 0, nil, nil) } }
        let allowedTables: Set<String> = [
            "conversation_summaries", "search_schema_version", "conversations_fts",
            "conversations_fts_data", "conversations_fts_idx", "conversations_fts_content",
            "conversations_fts_docsize", "conversations_fts_config",
        ]
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
            "SELECT name,type,rootpage FROM main.sqlite_master LIMIT 129", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ScopeError.unreadable }
        defer { sqlite3_finalize(statement) }
        var tables: Set<String> = []
        var count = 0
        while true {
            guard !deadline.hasExpired else { throw ScopeError.unreadable }
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ScopeError.unreadable }
            count += 1
            guard count <= 128, let name = text(statement, column: 0),
                  let type = text(statement, column: 1) else { throw ScopeError.unreadable }
            let key = name.lowercased()
            guard key != "gen_metadata" else { return false }
            if type == "index" { continue }
            guard type == "table", allowedTables.contains(key) else { return false }
            if key == "conversation_summaries" || key == "search_schema_version" {
                guard sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
                      sqlite3_column_int64(statement, 2) > 0 else { return false }
            }
            tables.insert(key)
        }
        guard tables.isSuperset(of: ["conversation_summaries", "search_schema_version"]) else { return false }
        return try columns(database, table: "conversation_summaries", deadline: deadline)
            .isSuperset(of: ["conversation_id", "title", "preview", "raw_summary"])
            && columns(database, table: "search_schema_version", deadline: deadline) == ["version"]
    }

    private static func columns(_ database: OpaquePointer, table: String, deadline: Deadline) throws -> Set<String> {
        // Only the two constant names above reach this helper.
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA main.table_xinfo('\(table)')", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ScopeError.unreadable }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        var count = 0
        while true {
            guard !deadline.hasExpired else { throw ScopeError.unreadable }
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return names }
            guard step == SQLITE_ROW else { throw ScopeError.unreadable }
            count += 1
            guard count <= 64, sqlite3_column_count(statement) >= 7,
                  sqlite3_column_type(statement, 6) == SQLITE_INTEGER,
                  sqlite3_column_int(statement, 6) == 0,
                  let name = text(statement, column: 1) else { throw ScopeError.unreadable }
            names.insert(name.lowercased())
        }
    }

    private static func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              sqlite3_column_bytes(statement, column) <= 256,
              let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private final class Deadline {
        private let end: TimeInterval
        init(seconds: TimeInterval = 1) { end = ProcessInfo.processInfo.systemUptime + seconds }
        var hasExpired: Bool { ProcessInfo.processInfo.systemUptime >= end }
    }
}
