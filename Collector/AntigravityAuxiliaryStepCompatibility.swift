import Foundation
import SQLite3

/// CortexStepType 17 is ERROR_MESSAGE in the official Antigravity backend's
/// protobuf descriptor. Such auxiliary steps can legally have no step UUID or
/// bot ID. They cannot supply a generation timestamp, but the pinned reader
/// marks all timestamp recovery incomplete merely because one is present.
/// Remove only this positively identified case in our private SQLite copy;
/// generation rows, usage counters and timestamps are never changed.
enum AntigravityAuxiliaryStepCompatibility {
    private static let maximumPayload = 64 * 1024

    static func preparePrivateDatabase(_ url: URL) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database = pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw CompatibilityError.unreadable
        }
        defer { sqlite3_close(database) }
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 64 * 1024)
        let deadline = Deadline()
        sqlite3_progress_handler(database, 1000, { context in
            guard let context else { return 1 }
            return Unmanaged<Deadline>.fromOpaque(context).takeUnretainedValue().expired ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
        defer { withExtendedLifetime(deadline) { sqlite3_progress_handler(database, 0, nil, nil) } }
        guard try supportsFiltering(database) else { return }
        var statement: OpaquePointer?
        let query = """
        SELECT rowid, CASE WHEN typeof(metadata)='blob' AND length(metadata)<=65536 THEN metadata END
        FROM main.steps NOT INDEXED
        WHERE typeof(step_type)='integer' AND step_type=17 LIMIT 10001
        """
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CompatibilityError.unreadable }
        var candidates: [Int64] = []
        var rows = 0
        do {
            while true {
                try Task.checkCancellation()
                guard !deadline.expired else { throw CompatibilityError.unreadable }
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw CompatibilityError.unreadable }
                rows += 1
                guard rows <= 10_000 else { throw CompatibilityError.unreadable }
                let count = Int(sqlite3_column_bytes(statement, 1))
                guard count > 0, count <= maximumPayload,
                      sqlite3_column_type(statement, 1) == SQLITE_BLOB,
                      let bytes = sqlite3_column_blob(statement, 1) else { continue }
                let metadata = Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: count))
                if isUnkeyedErrorMetadata(metadata) { candidates.append(sqlite3_column_int64(statement, 0)) }
            }
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
        sqlite3_finalize(statement)
        guard !candidates.isEmpty else { return }
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw CompatibilityError.unreadable
        }
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        var deletion: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM main.steps WHERE rowid=? AND step_type=17", -1,
                                  &deletion, nil) == SQLITE_OK, let deletion else {
            throw CompatibilityError.unreadable
        }
        defer { sqlite3_finalize(deletion) }
        for row in candidates {
            try Task.checkCancellation()
            guard !deadline.expired else { throw CompatibilityError.unreadable }
            sqlite3_bind_int64(deletion, 1, row)
            guard sqlite3_step(deletion) == SQLITE_DONE else { throw CompatibilityError.unreadable }
            sqlite3_reset(deletion)
            sqlite3_clear_bindings(deletion)
        }
        guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw CompatibilityError.unreadable
        }
    }

    private static func supportsFiltering(_ database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT name,type,rootpage FROM main.sqlite_master LIMIT 129", -1,
                                  &statement, nil) == SQLITE_OK, let statement else {
            throw CompatibilityError.unreadable
        }
        var found = false
        var rows = 0
        do {
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw CompatibilityError.unreadable }
                rows += 1
                guard rows <= 128, let name = text(statement, 0), let type = text(statement, 1) else {
                    throw CompatibilityError.unreadable
                }
                if type == "trigger" { sqlite3_finalize(statement); return false }
                if name.lowercased() == "steps" {
                    guard type == "table", sqlite3_column_int64(statement, 2) > 0 else {
                        sqlite3_finalize(statement); return false
                    }
                    found = true
                }
            }
        } catch { sqlite3_finalize(statement); throw error }
        sqlite3_finalize(statement)
        guard found else { return false }
        var columns: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA main.table_xinfo('steps')", -1, &columns, nil) == SQLITE_OK,
              let columns else { throw CompatibilityError.unreadable }
        defer { sqlite3_finalize(columns) }
        var names: Set<String> = []
        var count = 0
        while true {
            let step = sqlite3_step(columns)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw CompatibilityError.unreadable }
            count += 1
            guard count <= 64, sqlite3_column_count(columns) >= 7,
                  sqlite3_column_int(columns, 6) == 0, let name = text(columns, 1) else { return false }
            names.insert(name.lowercased())
        }
        guard names.isSuperset(of: ["idx", "metadata", "step_type"]),
              names.isDisjoint(with: ["rowid", "_rowid_", "oid"]) else { return false }
        var rowidProbe: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, "SELECT rowid FROM main.steps LIMIT 0", -1, &rowidProbe, nil)
        sqlite3_finalize(rowidProbe)
        return prepared == SQLITE_OK
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              sqlite3_column_bytes(statement, column) <= 256,
              let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    /// Validate every outer field and both recognized nested messages. Opaque
    /// length-delimited fields are skipped, never interpreted as text or usage.
    private static func isUnkeyedErrorMetadata(_ bytes: [UInt8]) -> Bool {
        guard bytes.count <= maximumPayload else { return false }
        do {
            var message = WireReader(bytes[...])
            var hasTimestamp = false
            while let field = try message.next() {
                switch field.number {
                case 1:
                    guard field.wire == 2, let bytes = field.bytes, try validTimestamp(bytes) else { return false }
                    hasTimestamp = true
                case 9:
                    guard field.wire == 2, let bytes = field.bytes else { return false }
                    var auxiliary = WireReader(bytes)
                    while let nested = try auxiliary.next() {
                        if nested.number == 7 { return false }
                    }
                case 12: return false
                default: break
                }
            }
            return hasTimestamp
        } catch { return false }
    }

    private static func validTimestamp(_ bytes: ArraySlice<UInt8>) throws -> Bool {
        var message = WireReader(bytes)
        var seconds: UInt64?
        while let field = try message.next() {
            if field.number == 1 {
                guard field.wire == 0, let value = field.value, value > 0, value <= 253_402_300_799 else { return false }
                seconds = value
            } else if field.number == 2 {
                guard field.wire == 0, let value = field.value, value <= 999_999_999 else { return false }
            }
        }
        return seconds != nil
    }

    private struct Field {
        let number: Int
        let wire: Int
        let value: UInt64?
        let bytes: ArraySlice<UInt8>?
    }

    private struct WireReader {
        let bytes: ArraySlice<UInt8>
        var offset: Int
        var fields = 0
        init(_ bytes: ArraySlice<UInt8>) { self.bytes = bytes; offset = bytes.startIndex }

        mutating func next() throws -> Field? {
            guard offset < bytes.endIndex else { return nil }
            fields += 1
            guard fields <= 512 else { throw CompatibilityError.invalid }
            let tag = try varint()
            guard tag >> 3 > 0, tag >> 3 <= 536_870_911 else { throw CompatibilityError.invalid }
            let number = Int(tag >> 3), wire = Int(tag & 7)
            if wire == 0 { return Field(number: number, wire: wire, value: try varint(), bytes: nil) }
            let count: Int
            switch wire {
            case 1: count = 8
            case 2:
                guard let value = Int(exactly: try varint()) else { throw CompatibilityError.invalid }
                count = value
            case 5: count = 4
            default: throw CompatibilityError.invalid
            }
            guard count <= bytes.endIndex - offset else { throw CompatibilityError.invalid }
            let end = offset + count
            defer { offset = end }
            return Field(number: number, wire: wire, value: nil, bytes: bytes[offset..<end])
        }

        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.endIndex else { throw CompatibilityError.invalid }
                let byte = bytes[offset]; offset += 1
                guard index < 9 || byte <= 1 else { throw CompatibilityError.invalid }
                value |= UInt64(byte & 0x7f) << (index * 7)
                if byte < 128 { return value }
            }
            throw CompatibilityError.invalid
        }
    }

    private enum CompatibilityError: Error { case unreadable, invalid }
    private final class Deadline {
        private let end = ProcessInfo.processInfo.systemUptime + 2
        var expired: Bool { ProcessInfo.processInfo.systemUptime >= end }
    }
}
