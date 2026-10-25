import Foundation
import XCTest

/// Expiry recovery starts with a real persisted collector success, but every
/// credential, CLI and HTTP response belongs to this test's temporary profile.
final class ClaudeExpiryRenewalTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-16T12:00:00Z")!
    private let oldBody = #"{"five_hour":{"utilization":28,"resets_at":"2026-10-16T15:00:00Z"},"seven_day":{"utilization":45,"resets_at":"2026-10-22T12:00:00Z"},"cedar_ember":{"eligible":true,"grants":[{"id":"synthetic-old","resets_left":2,"ends_at":"2026-10-22T12:00:00Z"}]}}"#
    private let renewedBody = #"{"five_hour":{"utilization":19,"resets_at":"2026-10-16T15:00:00Z"},"seven_day":{"utilization":32,"resets_at":"2026-10-22T12:00:00Z"},"cedar_ember":{"eligible":true,"grants":[{"id":"synthetic-new","resets_left":4,"ends_at":"2026-10-22T12:00:00Z"}]}}"#

    private struct Response: Sendable {
        let status: Int
        let body: String
        var headers: [String: String] = [:]
    }

    private actor Server {
        private let responses: [Response]
        private var requests: [URLRequest] = []

        init(_ responses: [Response]) { self.responses = responses }

        func send(_ request: URLRequest) -> (Data, HTTPURLResponse) {
            let response = responses[min(requests.count, responses.count - 1)]
            requests.append(request)
            return (Data(response.body.utf8), HTTPURLResponse(url: request.url!, statusCode: response.status,
                    httpVersion: nil, headerFields: response.headers)!)
        }

        var count: Int { requests.count }
        var authorizations: [String?] { requests.map { $0.value(forHTTPHeaderField: "Authorization") } }
    }

    private final class CredentialSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<Data, Error>]

        init(_ results: [Result<Data, Error>]) { self.results = results }

        func read() throws -> Data {
            lock.lock()
            let result = results.count > 1 ? results.removeFirst() : results[0]
            lock.unlock()
            return try result.get()
        }
    }

    private func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beavermeter-claude-expiry-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try credentials(directory, expiresAt: now.addingTimeInterval(3_600))
        return directory
    }

    private func credentials(_ directory: URL, token: String = "synthetic-original", expiresAt: Date) throws {
        let document: [String: Any] = ["claudeAiOauth": ["accessToken": token,
            "refreshToken": "synthetic-refresh", "expiresAt": expiresAt.timeIntervalSince1970 * 1_000]]
        try JSONSerialization.data(withJSONObject: document)
            .write(to: directory.appendingPathComponent(".credentials.json"))
    }

    private static func fileCredentials(_ environment: [String: String]) throws -> Data {
        try Data(contentsOf: ClaudeCredentialResolver.credentialFileURL(environment: environment))
    }

    private func environment(_ directory: URL, renewalScript: String) throws -> [String: String] {
        let cli = directory.appendingPathComponent("synthetic-claude")
        try """
        #!/bin/sh
        set -eu
        : "${CLAUDE_CONFIG_DIR:?}"
        printf '<call' >> "$CLAUDE_CONFIG_DIR/cli-invocations"
        for arg in "$@"; do printf '|%s' "$arg" >> "$CLAUDE_CONFIG_DIR/cli-invocations"; done
        printf '>\\n' >> "$CLAUDE_CONFIG_DIR/cli-invocations"
        if [ "${1:-}" = '--version' ]; then printf '2.1.301\\n'; exit 0; fi
        printf 'renew\\n' >> "$CLAUDE_CONFIG_DIR/renewal-launches"
        [ "$#" -eq 0 ] || exit 91
        \(renewalScript)
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        return ["CLAUDE_CONFIG_DIR": directory.path, "CLAUDE_CLI_PATH": cli.path,
                "CLAUDE_CLI_REFRESH": "1", "CLAUDE_KEYCHAIN_ACCESS": "1"]
    }

    private var replaceCredentialScript: String {
        """
        /bin/cat > "$CLAUDE_CONFIG_DIR/.credentials.json" <<'JSON'
        {"claudeAiOauth":{"accessToken":"synthetic-renewed","refreshToken":"synthetic-refresh-new","expiresAt":4070908800000}}
        JSON
        exit 0
        """
    }

    private func collect(_ directory: URL, environment: [String: String], server: Server, at date: Date,
                         previous: ClaudeUsageCollector.Reading? = nil,
                         credentialReader: ClaudeQuotaCollector.CredentialReader = ClaudeExpiryRenewalTests.fileCredentials) async -> ClaudeUsageCollector.Reading {
        await ClaudeUsageCollector.collect(
            previousQuota: previous?.quota ?? .unavailable("synthetic initial state"),
            previousCards: previous?.resetCards ?? .unavailable("synthetic initial state"),
            now: date, stateDirectory: directory, environment: environment,
            credentialReader: credentialReader, transport: { await server.send($0) }
        )
    }

    private func launchCount(_ directory: URL) throws -> Int {
        let marker = directory.appendingPathComponent("renewal-launches")
        guard FileManager.default.fileExists(atPath: marker.path) else { return 0 }
        return try String(contentsOf: marker, encoding: .utf8).split(separator: "\n").count
    }

    func testLocallyExpiredCredentialWithFreshSuccessCacheAndKeychainPollFailureClearsOldValues() async throws {
        let directory = try workspace()
        let environment = try environment(directory, renewalScript: "exec /bin/sleep 30")
        let server = Server([Response(status: 200, body: oldBody)])
        let previous = await collect(directory, environment: environment, server: server, at: now)
        XCTAssertEqual(previous.quota.status, .ready)
        XCTAssertEqual(previous.resetCards.value?.availableCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("beaver-meter-claude-usage-v1.json").path))

        try credentials(directory, expiresAt: now.addingTimeInterval(-1))
        let expired = try Self.fileCredentials(environment)
        let reads = CredentialSequence([.success(expired), .failure(ClaudeKeychainReader.ReadError.keychainAccessRequired)])
        let result = await collect(directory, environment: environment, server: server,
                                   at: now.addingTimeInterval(1), previous: previous,
                                   credentialReader: { _ in try reads.read() })

        XCTAssertEqual(result.quota.status, .error)
        XCTAssertEqual(result.resetCards.status, .error)
        XCTAssertEqual(result.quota.source, .none)
        XCTAssertEqual(result.resetCards.source, .none)
        XCTAssertNil(result.quota.value, "A locally expired login cannot retain its last verified percentage.")
        XCTAssertNil(result.resetCards.value, "Reset cards from the expired login must also be cleared.")
        XCTAssertNil(result.quota.measuredAt)
        XCTAssertNil(result.resetCards.measuredAt)
        XCTAssertTrue(result.quota.message?.contains("Allow Claude access") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("beaver-meter-claude-usage-v1.json").path),
            "An expired login's persisted success must not reappear after a temporary read failure.")
        let requests = await server.count
        XCTAssertEqual(requests, 1, "The failed credential read must not issue a usage request.")
        XCTAssertEqual(try launchCount(directory), 1)
    }

    func testExpiredCredentialRenewsAndVerifiesBeforeAnExistingLongRateLimitBackoff() async throws {
        let directory = try workspace()
        let environment = try environment(directory, renewalScript: replaceCredentialScript)
        let priorServer = Server([Response(status: 200, body: oldBody),
                                  Response(status: 429, body: "", headers: ["Retry-After": "7200"])])
        let previous = await collect(directory, environment: environment, server: priorServer, at: now)
        let rateLimited = await collect(directory, environment: environment, server: priorServer,
                                        at: now.addingTimeInterval(300), previous: previous)
        XCTAssertEqual(rateLimited.quota.status, .stale)
        XCTAssertNotNil(rateLimited.quota.value)
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("beaver-meter-claude-usage-v1.json"))) as? [String: Any]
        XCTAssertNotNil(persisted?["retryAt"], "This scenario must begin with a persisted backoff.")

        try credentials(directory, expiresAt: now.addingTimeInterval(-1))
        let renewedServer = Server([Response(status: 200, body: renewedBody)])
        let result = await collect(directory, environment: environment, server: renewedServer,
                                   at: now.addingTimeInterval(301), previous: rateLimited)

        XCTAssertEqual(result.quota.status, .ready)
        XCTAssertEqual(result.quota.source, .accountAPI)
        XCTAssertEqual(result.quota.value?.remainingPercent, 81)
        XCTAssertEqual(result.resetCards.status, .ready)
        XCTAssertEqual(result.resetCards.value?.availableCount, 4)
        XCTAssertNil(result.quota.message)
        let authorizations = await renewedServer.authorizations
        XCTAssertEqual(authorizations, ["Bearer synthetic-renewed"])
        XCTAssertEqual(try launchCount(directory), 1)
    }

    func testChangedCredentialWithServerFailureCannotRestoreOldValuesAndNextSuccessNeedsNoFurtherRenewal() async throws {
        let directory = try workspace()
        let environment = try environment(directory, renewalScript: replaceCredentialScript)
        let priorServer = Server([Response(status: 200, body: oldBody)])
        let previous = await collect(directory, environment: environment, server: priorServer, at: now)
        try credentials(directory, expiresAt: now.addingTimeInterval(-1))
        let server = Server([Response(status: 503, body: ""), Response(status: 200, body: renewedBody)])
        let failed = await collect(directory, environment: environment, server: server,
                                   at: now.addingTimeInterval(1), previous: previous)

        XCTAssertEqual(failed.quota.status, .error)
        XCTAssertEqual(failed.resetCards.status, .error)
        XCTAssertNil(failed.quota.value)
        XCTAssertNil(failed.resetCards.value)
        XCTAssertEqual(try launchCount(directory), 1)

        let recovered = await collect(directory, environment: environment, server: server,
                                      at: now.addingTimeInterval(2), previous: failed)
        XCTAssertEqual(recovered.quota.status, .ready)
        XCTAssertEqual(recovered.quota.value?.remainingPercent, 81)
        XCTAssertEqual(recovered.quota.measuredAt, now.addingTimeInterval(2))
        XCTAssertEqual(recovered.resetCards.value?.availableCount, 4)
        XCTAssertNil(recovered.quota.message)
        XCTAssertNil(recovered.resetCards.message)
        let authorizations = await server.authorizations
        XCTAssertEqual(authorizations, ["Bearer synthetic-renewed", "Bearer synthetic-renewed"])
        XCTAssertEqual(try launchCount(directory), 1, "A valid renewed token must not start another CLI.")
    }

    func testUnchangedCredentialAfterSuccessfulCLIExitStaysEmptyAndCooldownDoesNotLaunchLogin() async throws {
        let directory = try workspace()
        let environment = try environment(directory, renewalScript: "exit 0")
        let priorServer = Server([Response(status: 200, body: oldBody)])
        var previous = await collect(directory, environment: environment, server: priorServer, at: now)
        try credentials(directory, expiresAt: now.addingTimeInterval(-1))
        let unusedServer = Server([Response(status: 200, body: renewedBody)])

        for seconds in [1.0, 2, 10, 299] {
            let result = await collect(directory, environment: environment, server: unusedServer,
                                       at: now.addingTimeInterval(seconds), previous: previous)
            XCTAssertEqual(result.quota.status, .error)
            XCTAssertEqual(result.resetCards.status, .error)
            XCTAssertNil(result.quota.value)
            XCTAssertNil(result.resetCards.value)
            previous = result
        }
        XCTAssertEqual(try launchCount(directory), 1)
        let requests = await unusedServer.count
        XCTAssertEqual(requests, 0, "A CLI exit code cannot certify an unchanged expired token.")
        let calls = try String(contentsOf: directory.appendingPathComponent("cli-invocations"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(calls.filter { $0 == "<call>" }.count, 1)
        XCTAssertTrue(calls.allSatisfy { $0 == "<call>" || $0 == "<call|--version>" })
        for forbidden in ["auth", "login", "open", "browser"] {
            XCTAssertFalse(calls.joined().lowercased().contains(forbidden), "Automatic renewal must not issue a browser-login command.")
        }
    }

    func testNewAccessTokenWorksWithUnchangedAndRotatedRefreshTokens() async throws {
        for refreshToken in ["synthetic-refresh", "synthetic-refresh-rotated"] {
            let directory = try workspace()
            let script = replaceCredentialScript.replacingOccurrences(of: "synthetic-refresh-new", with: refreshToken)
            let environment = try environment(directory, renewalScript: script)
            try credentials(directory, expiresAt: now.addingTimeInterval(-1))
            let server = Server([Response(status: 200, body: renewedBody)])
            let result = await collect(directory, environment: environment, server: server, at: now)
            XCTAssertEqual(result.quota.status, .ready)
            XCTAssertEqual(result.quota.value?.remainingPercent, 81)
            let authorizations = await server.authorizations
            XCTAssertEqual(authorizations, ["Bearer synthetic-renewed"])
            XCTAssertEqual(try launchCount(directory), 1)
        }
    }

    func testServerRejectsOldTokenThenTransientFailureCannotReviveOldValues() async throws {
        for failureStatus in [503, 429] {
            let directory = try workspace()
            let environment = try environment(directory, renewalScript: replaceCredentialScript)
            let previous = await collect(directory, environment: environment,
                server: Server([Response(status: 200, body: oldBody)]), at: now)
            let server = Server([Response(status: 401, body: ""),
                Response(status: failureStatus, body: "", headers: ["Retry-After": "1"]),
                Response(status: 200, body: renewedBody)])
            let failed = await collect(directory, environment: environment, server: server,
                at: now.addingTimeInterval(300), previous: previous)
            XCTAssertEqual(failed.quota.status, .error)
            XCTAssertNil(failed.quota.value)
            XCTAssertNil(failed.resetCards.value)
            let recovered = await collect(directory, environment: environment, server: server,
                at: now.addingTimeInterval(302), previous: failed)
            XCTAssertEqual(recovered.quota.status, .ready)
            XCTAssertEqual(recovered.quota.measuredAt, now.addingTimeInterval(302))
            XCTAssertEqual(recovered.quota.value?.remainingPercent, 81)
            let authorizations = await server.authorizations
            XCTAssertEqual(authorizations, ["Bearer synthetic-original", "Bearer synthetic-renewed", "Bearer synthetic-renewed"])
            XCTAssertEqual(try launchCount(directory), 1)
        }
    }
}
