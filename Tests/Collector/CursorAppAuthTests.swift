import Foundation
import SQLite3
import XCTest

final class CursorAppAuthTests: XCTestCase {
    private let token = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJhdXRoMHxzeW50aGV0aWMtY3Vyc29yLXVzZXIiLCJleHAiOjQxMDI0NDQ4MDB9.synthetic-signature"
    private let password = Data("synthetic-safe-storage-password".utf8)

    // Independent vectors: Python hashlib.pbkdf2_hmac('sha1', password, b'saltysalt', 1003, 16),
    // followed by openssl enc -aes-128-cbc with an IV of sixteen ASCII spaces and PKCS7 padding.
    private let encryptedToken = "cursor-safe-storage:v1:djEwEfphFJGpvG2GZ5sdgxM9sFZb8mszz8xfcP3P7P+pNeRfx8mbhRQaFtRXeUtSTSpabX7qXAJWc1YpqDnpfTHJGtFfgX6LfFE1GAMpxB4zBSe53aBSbSwgo+6sskXIaJvsXHUIKaC/LH2PtVIYTVvSwxqSwCgsCQmBVzZ9bpG5LIE="
    private let unicodeEncryptedToken = "cursor-safe-storage:v1:djEwqASq1wmOxrMB4PD4nPjSXMRZzGZFiCc36X8S8hOZrqVcx5d95XW/p9iwLxVOxV9+cAJjMrzScN9ffgIhxNBFuacV0tNBK9jXJVNyZCSUrn6AoKAS2UvIEMCx+4CONB+kbxHwILBIway3EWHmrm3/M5viqpCgOtMmcNlXW+t7YkM="

    func testPlaintextLegacyTokenNeverReadsKeychain() throws {
        XCTAssertEqual(try CursorTokenStorage.decode(token) {
            XCTFail("A legacy plaintext token must not access Keychain")
            return Data()
        }, token)
    }

    func testEncryptedCursorTokenMatchesIndependentVectorAndOriginalCookie() throws {
        var reads = 0
        let decoded = try CursorTokenStorage.decode(encryptedToken) {
            reads += 1
            return self.password
        }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(decoded, token)
        XCTAssertEqual(try CursorAppAuthSession(accessToken: decoded).cookieHeader,
                       "WorkosCursorSessionToken=synthetic-cursor-user%3A%3A\(token)")
    }

    func testPasswordUsesUTF8BytesRatherThanCharacterCount() throws {
        XCTAssertEqual(try CursorTokenStorage.decode(unicodeEncryptedToken) {
            Data("测试🔐-safe-storage".utf8)
        }, token)
    }

    func testMalformedAndUnknownStorageVersionsFailBeforeReadingKeychain() {
        let malformed = [
            "cursor-safe-storage:v2:unsupported-secret",
            "cursor-safe-storage:v1:",
            "cursor-safe-storage:v1:%%%invalid-base64-secret%%%",
            "cursor-safe-storage:v1:" + Data("v11".utf8).base64EncodedString(),
            "cursor-safe-storage:v1:" + Data("v10".utf8).base64EncodedString(),
            "cursor-safe-storage:v1:" + (Data("v10".utf8) + Data(repeating: 1, count: 15)).base64EncodedString(),
        ]
        for stored in malformed {
            XCTAssertThrowsError(try CursorTokenStorage.decode(stored) {
                XCTFail("Malformed encrypted storage must fail before Keychain access")
                return self.password
            }) { error in
                self.assertSafeCursorError(error, excluding: [stored, "unsupported-secret", "invalid-base64-secret"])
            }
        }
    }

    func testWrongAndEmptyPasswordsFailWithoutExposingStoredCredentials() {
        for wrong in [Data("wrong-synthetic-password".utf8), Data()] {
            XCTAssertThrowsError(try CursorTokenStorage.decode(encryptedToken) { wrong }) { error in
                self.assertSafeCursorError(error, excluding: [self.encryptedToken, self.token,
                                                             "wrong-synthetic-password"])
            }
        }
    }

    func testKeychainReaderFailureIsReportedWithoutUnderlyingSecretText() {
        let secret = "synthetic-keychain-secret-that-must-not-be-logged"
        XCTAssertThrowsError(try CursorTokenStorage.decode(encryptedToken) {
            throw NSError(domain: "SyntheticKeychainFailure", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: secret])
        }) { error in
            self.assertSafeCursorError(error, excluding: [secret, self.encryptedToken, self.token])
        }
    }

    func testSafeStorageReaderUsesElectronCursorKeyAccountAndTrimsCLIEnding() throws {
        var reads = 0
        let result = try CursorTokenStorage.readSafeStoragePassword { service, account in
            reads += 1
            XCTAssertEqual(service, "Cursor Safe Storage")
            XCTAssertEqual(account, "Cursor Key")
            return self.password + Data("\r\n".utf8)
        }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(result, password)
    }

    func testMissingOrEmptySafeStorageKeyReturnsLocalizedCursorError() {
        let missingOrEmpty: [Data?] = [nil, Data(), Data("\n".utf8)]
        for response in missingOrEmpty {
            XCTAssertThrowsError(try CursorTokenStorage.readSafeStoragePassword { _, _ in response }) { error in
                self.assertSafeCursorError(error, excluding: [self.encryptedToken, self.token])
            }
        }
    }

    func testSafeStorageReaderFailureDoesNotExposeUnderlyingKeychainMessage() {
        let secret = "synthetic-safe-storage-error-secret"
        XCTAssertThrowsError(try CursorTokenStorage.readSafeStoragePassword { _, _ in
            throw NSError(domain: "SyntheticKeychainFailure", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: secret])
        }) { error in
            self.assertSafeCursorError(error, excluding: [secret, self.encryptedToken, self.token])
        }
    }

    func testStoreDecryptsOnlyInMemoryAndLeavesDatabaseUnchanged() throws {
        let url = try database(token: encryptedToken)
        let before = try Data(contentsOf: url)
        var reads = 0
        let session = try CursorAppAuthStore(databasePath: url.path, passwordReader: {
            reads += 1
            return self.password
        }).loadSession()

        XCTAssertEqual(session.accessToken, token)
        XCTAssertEqual(try session.cookieHeader, "WorkosCursorSessionToken=synthetic-cursor-user%3A%3A\(token)")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
    }

    func testMissingDatabaseAndAbsentOrEmptyTokenNeverReadKeychain() throws {
        let empty = try database(token: "")
        let absent = try database(token: nil)
        let missing = empty.deletingLastPathComponent().appendingPathComponent("missing.vscdb")
        for url in [empty, absent, missing] {
            XCTAssertThrowsError(try CursorAppAuthStore(databasePath: url.path, passwordReader: {
                XCTFail("No token must not access Keychain")
                return self.password
            }).loadSession()) { error in
                guard let cursorError = error as? CursorDashboardError else {
                    return XCTFail("Expected a Cursor authentication error")
                }
                switch cursorError {
                case .notInstalled, .notLoggedIn: break
                default: XCTFail("Expected a missing-login error")
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testStoreReadsCurrentTokenFromActiveWALWithoutChangingCursorDatabase() throws {
        let url = try database(token: "previous-synthetic-token")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        let db = try XCTUnwrap(writer)
        defer { sqlite3_close(db) }
        try execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", database: db)
        try execute("UPDATE ItemTable SET value='\(encryptedToken)' WHERE key='cursorAuth/accessToken';", database: db)
        let wal = URL(fileURLWithPath: url.path + "-wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wal.path))
        let before = try Data(contentsOf: url)
        let walBefore = try Data(contentsOf: wal)

        let session = try CursorAppAuthStore(databasePath: url.path, passwordReader: { self.password }).loadSession()

        XCTAssertEqual(session.accessToken, token)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try Data(contentsOf: wal), walBefore)
    }

    private func assertSafeCursorError(_ error: Error, excluding secrets: [String],
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(error is CursorDashboardError, "Expected a localized Cursor error", file: file, line: line)
        XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
        for secret in secrets where !secret.isEmpty {
            XCTAssertFalse(error.localizedDescription.contains(secret), "Error must not include credential contents",
                           file: file, line: line)
        }
    }

    private func database(token: String?) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-auth-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.vscdb")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        let db = try XCTUnwrap(connection)
        defer { sqlite3_close(db) }
        try execute("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);", database: db)
        if let token {
            let escaped = token.replacingOccurrences(of: "'", with: "''")
            try execute("INSERT INTO ItemTable (key,value) VALUES ('cursorAuth/accessToken','\(escaped)');", database: db)
        }
        return url
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        let status = sqlite3_exec(database, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw NSError(domain: "SyntheticCursorSQLite", code: Int(status)) }
    }
}
