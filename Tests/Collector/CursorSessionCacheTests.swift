import Foundation
import SQLite3
import XCTest

final class CursorSessionCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let token = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJhdXRoMHxzeW50aGV0aWMtY3Vyc29yLXVzZXIiLCJleHAiOjQxMDI0NDQ4MDB9.synthetic-signature"
    private let password = Data("synthetic-safe-storage-password".utf8)
    private let encryptedToken = "cursor-safe-storage:v1:djEwEfphFJGpvG2GZ5sdgxM9sFZb8mszz8xfcP3P7P+pNeRfx8mbhRQaFtRXeUtSTSpabX7qXAJWc1YpqDnpfTHJGtFfgX6LfFE1GAMpxB4zBSe53aBSbSwgo+6sskXIaJvsXHUIKaC/LH2PtVIYTVvSwxqSwCgsCQmBVzZ9bpG5LIE="

    func testDefaultCredentialLocationUsesPrivateAppStorage() {
        let url = CursorSessionCache.defaultURL
        XCTAssertEqual(url.lastPathComponent, "cursor-session.json")
        XCTAssertEqual(url.deletingLastPathComponent(), UsageSnapshot.snapshotURL.deletingLastPathComponent())
        XCTAssertTrue(url.path.hasSuffix("/Library/Application Support/BeaverMeter/cursor-session.json"))
        XCTAssertFalse(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    func testVerifiedSessionIsWrittenOwnerOnlyInProtectedDirectory() throws {
        let root = try workspace()
        let url = root.appendingPathComponent("private/cursor-session.json")
        let cache = CursorSessionCache(url: url)
        let fingerprint = CursorSessionCache.fingerprint(databasePath: root.appendingPathComponent("state.vscdb").path,
                                                        storedToken: encryptedToken)
        try cache.save(session: session(fingerprint: fingerprint), now: now)

        XCTAssertEqual(try permissions(url), 0o600)
        XCTAssertEqual(try permissions(url.deletingLastPathComponent()), 0o700)
        let loaded = try XCTUnwrap(cache.load(fingerprint: fingerprint, now: now))
        XCTAssertEqual(loaded.accessToken, token)
        XCTAssertEqual(loaded.sourceFingerprint, fingerprint)
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(document?["version"] as? Int, 1)
        XCTAssertEqual(document?["sourceFingerprint"] as? String, fingerprint)
        XCTAssertEqual(document?["accessToken"] as? String, token)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains(String(decoding: password, as: UTF8.self)))
    }

    func testFingerprintBindsCanonicalDatabasePathAndCurrentStoredCredential() throws {
        let root = try workspace()
        let path = root.appendingPathComponent("state.vscdb").path
        let fingerprint = CursorSessionCache.fingerprint(databasePath: path, storedToken: encryptedToken)

        XCTAssertEqual(fingerprint, CursorSessionCache.fingerprint(databasePath: root.path + "/child/../state.vscdb",
                                                                  storedToken: encryptedToken))
        XCTAssertNotEqual(fingerprint, CursorSessionCache.fingerprint(databasePath: root.appendingPathComponent("other.vscdb").path,
                                                                     storedToken: encryptedToken))
        XCTAssertNotEqual(fingerprint, CursorSessionCache.fingerprint(databasePath: path, storedToken: encryptedToken + "changed"))
        XCTAssertFalse(fingerprint.contains(root.path))
        XCTAssertFalse(fingerprint.contains(encryptedToken))
    }

    func testLoadingDoesNotPersistUntilCallerConfirmsAPIVerification() throws {
        let root = try workspace()
        let database = try database(root: root, token: encryptedToken)
        let cacheURL = root.appendingPathComponent("session/cursor-session.json")
        var passwordReads = 0
        let store = CursorAppAuthStore(databasePath: database.path, sessionCacheURL: cacheURL, passwordReader: {
            passwordReads += 1
            return self.password
        })

        let loaded = try store.loadSession(now: now)
        XCTAssertEqual(loaded.accessToken, token)
        XCTAssertEqual(passwordReads, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))

        try store.saveVerifiedSession(loaded, now: now)
        XCTAssertEqual(try permissions(cacheURL), 0o600)
        let backgroundStore = CursorAppAuthStore(databasePath: database.path, sessionCacheURL: cacheURL, passwordReader: {
            XCTFail("A verified unchanged session must not request Keychain access on the next refresh")
            throw SyntheticError.keychainDenied
        })
        XCTAssertEqual(try backgroundStore.loadSession(now: now).accessToken, token)
    }

    func testExplicitCacheBypassReadsCurrentEncryptedCredentialAgain() throws {
        let root = try workspace()
        let database = try database(root: root, token: encryptedToken)
        let cacheURL = root.appendingPathComponent("cursor-session.json")
        let fingerprint = CursorSessionCache.fingerprint(databasePath: database.path, storedToken: encryptedToken)
        try CursorSessionCache(url: cacheURL).save(session: session(fingerprint: fingerprint), now: now)
        var reads = 0
        let store = CursorAppAuthStore(databasePath: database.path, sessionCacheURL: cacheURL, passwordReader: {
            reads += 1
            throw SyntheticError.keychainDenied
        })

        XCTAssertThrowsError(try store.loadSession(now: now, useCachedSession: false))
        XCTAssertEqual(reads, 1)
    }

    func testChangedCurrentDatabaseCredentialNeverFallsBackToPreviousAccount() throws {
        let root = try workspace()
        let database = try database(root: root, token: encryptedToken)
        let cacheURL = root.appendingPathComponent("cursor-session.json")
        let fingerprint = CursorSessionCache.fingerprint(databasePath: database.path, storedToken: encryptedToken)
        try CursorSessionCache(url: cacheURL).save(session: session(fingerprint: fingerprint), now: now)
        try replaceStoredToken("cursor-safe-storage:v1:changed-account", databaseURL: database)

        let store = CursorAppAuthStore(databasePath: database.path, sessionCacheURL: cacheURL, passwordReader: {
            throw SyntheticError.keychainDenied
        })
        XCTAssertThrowsError(try store.loadSession(now: now))
    }

    func testMissingEmptyAndAbsentCurrentDatabaseCredentialNeverUseCachedSession() throws {
        for replacement in ["missing-database", "empty-token", "absent-token"] {
            let root = try workspace()
            let database = try database(root: root, token: encryptedToken)
            let cacheURL = root.appendingPathComponent("cursor-session.json")
            let fingerprint = CursorSessionCache.fingerprint(databasePath: database.path, storedToken: encryptedToken)
            try CursorSessionCache(url: cacheURL).save(session: session(fingerprint: fingerprint), now: now)
            switch replacement {
            case "missing-database": try FileManager.default.removeItem(at: database)
            case "empty-token": try replaceStoredToken("", databaseURL: database)
            default: try replaceStoredToken(nil, databaseURL: database)
            }

            let store = CursorAppAuthStore(databasePath: database.path, sessionCacheURL: cacheURL, passwordReader: {
                XCTFail("A missing current login must not read Keychain or revive a saved account")
                throw SyntheticError.keychainDenied
            })
            XCTAssertThrowsError(try store.loadSession(now: now))
        }
    }

    func testExpiredAndNearlyExpiredTokensCannotBeLoadedOrSaved() throws {
        let root = try workspace()
        let url = root.appendingPathComponent("cursor-session.json")
        let cache = CursorSessionCache(url: url)
        let expiring = CursorAppAuthSession(accessToken: try jwt(subject: "synthetic-user", expiration: now.timeIntervalSince1970 + 61),
                                           sourceFingerprint: "synthetic-fingerprint")
        try cache.save(session: expiring, now: now)
        XCTAssertNotNil(cache.load(fingerprint: "synthetic-fingerprint", now: now))
        XCTAssertNil(cache.load(fingerprint: "synthetic-fingerprint", now: now.addingTimeInterval(1)))

        cache.invalidate(fingerprint: "synthetic-fingerprint")
        for expiration in [now.timeIntervalSince1970 - 1, now.timeIntervalSince1970 + 60] {
            let invalid = CursorAppAuthSession(accessToken: try jwt(subject: "synthetic-user", expiration: expiration),
                                              sourceFingerprint: "synthetic-fingerprint")
            XCTAssertFalse(invalid.isUsableForCache(at: now))
            try cache.save(session: invalid, now: now)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testMissingExpiryInvalidIdentityAndUnboundSessionsAreNotPersisted() throws {
        let root = try workspace()
        let url = root.appendingPathComponent("cursor-session.json")
        let cache = CursorSessionCache(url: url)
        let invalid = [
            CursorAppAuthSession(accessToken: try jwt(subject: "synthetic-user", expiration: nil), sourceFingerprint: "bound"),
            CursorAppAuthSession(accessToken: try jwt(subject: "user;injected", expiration: 4_102_444_800), sourceFingerprint: "bound"),
            CursorAppAuthSession(accessToken: token + "\n", sourceFingerprint: "bound"),
            CursorAppAuthSession(accessToken: "not-a-jwt", sourceFingerprint: "bound"),
            CursorAppAuthSession(accessToken: token),
        ]
        for session in invalid {
            try cache.save(session: session, now: now)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testCorruptUnknownVersionAndWrongFingerprintCacheMisses() throws {
        let root = try workspace()
        let url = root.appendingPathComponent("cursor-session.json")
        let cache = CursorSessionCache(url: url)
        try cache.save(session: session(fingerprint: "expected"), now: now)
        XCTAssertNil(cache.load(fingerprint: "another-account", now: now))
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        document["version"] = 999
        try writePrivate(try JSONSerialization.data(withJSONObject: document), to: url)
        XCTAssertNil(cache.load(fingerprint: "expected", now: now))
        try writePrivate(Data("broken-private-cache".utf8), to: url)
        XCTAssertNil(cache.load(fingerprint: "expected", now: now))
    }

    func testUnsafePermissionsSymlinksAndOversizedEntriesAreRejected() throws {
        let root = try workspace()
        let url = root.appendingPathComponent("cursor-session.json")
        let cache = CursorSessionCache(url: url)
        try cache.save(session: session(fingerprint: "expected"), now: now)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertNil(cache.load(fingerprint: "expected", now: now))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertNotNil(cache.load(fingerprint: "expected", now: now))
        let link = root.appendingPathComponent("linked-cursor-session.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertNil(CursorSessionCache(url: link).load(fingerprint: "expected", now: now))

        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        document["ignoredPadding"] = String(repeating: "x", count: 65_536)
        try writePrivate(try JSONSerialization.data(withJSONObject: document), to: url)
        XCTAssertNil(cache.load(fingerprint: "expected", now: now))
    }

    func testInvalidationOnlyRemovesTheMatchingSession() throws {
        let root = try workspace()
        let url = root.appendingPathComponent("cursor-session.json")
        let cache = CursorSessionCache(url: url)
        try cache.save(session: session(fingerprint: "current-account"), now: now)

        cache.invalidate(fingerprint: "rejected-old-account")
        XCTAssertNotNil(cache.load(fingerprint: "current-account", now: now))
        cache.invalidate(fingerprint: "current-account")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(cache.load(fingerprint: "current-account", now: now))
    }

    private enum SyntheticError: Error { case keychainDenied }

    private func session(fingerprint: String) -> CursorAppAuthSession {
        CursorAppAuthSession(accessToken: token, sourceFingerprint: fingerprint)
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-cache-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func jwt(subject: String, expiration: Double?) throws -> String {
        var claims: [String: Any] = ["sub": subject]
        if let expiration { claims["exp"] = expiration }
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(payload).synthetic-signature"
    }

    private func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func database(root: URL, token: String?) throws -> URL {
        let url = root.appendingPathComponent("state.vscdb")
        try withDatabase(url) { db in
            try execute("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);", database: db)
            if let token {
                try execute("INSERT INTO ItemTable (key,value) VALUES ('cursorAuth/accessToken','\(token)');", database: db)
            }
        }
        return url
    }

    private func replaceStoredToken(_ token: String?, databaseURL: URL) throws {
        try withDatabase(databaseURL) { db in
            if let token {
                let escaped = token.replacingOccurrences(of: "'", with: "''")
                try execute("UPDATE ItemTable SET value='\(escaped)' WHERE key='cursorAuth/accessToken';", database: db)
            } else {
                try execute("DELETE FROM ItemTable WHERE key='cursorAuth/accessToken';", database: db)
            }
        }
    }

    private func withDatabase(_ url: URL, body: (OpaquePointer) throws -> Void) throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        let db = try XCTUnwrap(connection)
        defer { sqlite3_close(db) }
        try body(db)
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        let status = sqlite3_exec(database, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw NSError(domain: "SyntheticCursorCacheSQLite", code: Int(status)) }
    }
}
