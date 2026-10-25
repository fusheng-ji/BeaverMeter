import Foundation
import XCTest

final class ClaudeUsageTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-23T12:00:00Z")!
    private let body = #"{"five_hour":{"utilization":28,"resets_at":"2026-09-23T15:00:00Z"},"cedar_ember":{"eligible":true,"grants":[{"id":"demo","resets_left":1,"ends_at":"2026-10-22T12:00:00Z"}]}}"#

    private actor Server {
        var requests: [URLRequest] = []
        let responseCodes: [Int]
        let body: Data
        let headers: [String: String]
        init(code: Int = 200, body: String, headers: [String: String] = [:], responseCodes: [Int]? = nil) {
            self.responseCodes = responseCodes.flatMap { $0.isEmpty ? nil : $0 } ?? [code]
            self.body = Data(body.utf8)
            self.headers = headers
        }
        func send(_ request: URLRequest) -> (Data, HTTPURLResponse) {
            requests.append(request)
            let code = responseCodes[min(requests.count - 1, responseCodes.count - 1)]
            return (body, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!)
        }
        var count: Int { requests.count }
        var query: String? { requests.first?.url?.query }
        var authorizations: [String?] { requests.map { $0.value(forHTTPHeaderField: "Authorization") } }
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("beavermeter-claude-usage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try credentials(root, token: "demo-secret")
        return root
    }

    private func credentials(_ root: URL, token: String, expiresAt: Double = 4070908800000,
                             refreshToken: String = "", subscriptionType: String? = nil,
                             rateLimitTier: String? = nil) throws {
        var oauth: [String: Any] = ["accessToken": token, "refreshToken": refreshToken, "expiresAt": expiresAt]
        oauth["subscriptionType"] = subscriptionType
        oauth["rateLimitTier"] = rateLimitTier
        try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
            .write(to: root.appendingPathComponent(".credentials.json"))
    }

    private static func fileCredentials(_ environment: [String: String]) throws -> Data {
        // The synthetic collector tests never query a real Keychain or source.
        try Data(contentsOf: ClaudeCredentialResolver.credentialFileURL(environment: environment))
    }

    private final class CredentialSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<Data, Error>]
        private var count = 0

        init(_ results: [Result<Data, Error>]) { self.results = results }

        func read() throws -> Data {
            lock.lock()
            count += 1
            let result = results.count > 1 ? results.removeFirst() : results[0]
            lock.unlock()
            return try result.get()
        }

        var readCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private func renewalEnvironment(_ root: URL, script: String) throws -> [String: String] {
        let cli = root.appendingPathComponent("fake-claude")
        let contents = """
        #!/bin/sh
        set -eu
        if [ "${1:-}" = "--version" ]; then
            printf '2.1.284\\n'
            exit 0
        fi
        test "${BEAVERMETER_TEST_AUTH_ENV:-}" = "caller-environment" || exit 10
        : "${CLAUDE_CONFIG_DIR:?}"
        \(script)
        """
        try Data(contents.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return ["CLAUDE_CONFIG_DIR": root.path, "CLAUDE_CLI_PATH": cli.path,
                "CLAUDE_CLI_REFRESH": "1", "BEAVERMETER_TEST_AUTH_ENV": "caller-environment"]
    }

    private func collect(_ root: URL, server: Server, at date: Date? = nil,
                         previous: ClaudeUsageCollector.Reading? = nil, environment: [String: String]? = nil,
                         forceRefresh: Bool = false, cancellation: SubprocessCancellation? = nil,
                         credentialReader: ClaudeQuotaCollector.CredentialReader = ClaudeUsageTests.fileCredentials) async -> ClaudeUsageCollector.Reading {
        await ClaudeUsageCollector.collect(
            previousQuota: previous?.quota ?? .unavailable("none"),
            previousCards: previous?.resetCards ?? .unavailable("none"),
            now: date ?? now, stateDirectory: root,
            environment: environment ?? ["CLAUDE_CONFIG_DIR": root.path, "CLAUDE_KEYCHAIN_ACCESS": "0",
                          "CLAUDE_CLI_REFRESH": "0", "CLAUDE_CLI_PATH": root.appendingPathComponent("missing-cli").path],
            forceRefresh: forceRefresh, cancellation: cancellation, credentialReader: credentialReader,
            transport: { await server.send($0) }
        )
    }

    func testOneRequestReadsBothAndReusesDiskCacheUntilFiveMinutes() async throws {
        let root = try workspace(), server = Server(body: body)
        let first = await collect(root, server: server)
        XCTAssertEqual(first.quota.value?.remainingPercent, 72)
        XCTAssertEqual(first.resetCards.value?.availableCount, 1)
        let cached = await collect(root, server: server, at: now.addingTimeInterval(299))
        XCTAssertEqual(cached.quota.measuredAt, now)
        let count = await server.count, query = await server.query
        XCTAssertEqual(count, 1)
        XCTAssertEqual(query, "cedar_ember=1&skip_spend=1")
        _ = await collect(root, server: server, at: now.addingTimeInterval(300))
        let refreshedCount = await server.count
        XCTAssertEqual(refreshedCount, 2)
        let state = root.appendingPathComponent("beaver-meter-claude-usage-v1.json")
        XCTAssertFalse(try String(contentsOf: state, encoding: .utf8).contains("demo-secret"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: state.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testPlanMetadataNormalizesOnlyRecognizedSubscriptionAndTierValues() throws {
        let cases: [(String?, String?, String?)] = [
            ("pro", nil, "Claude Pro"),
            ("max", "default_claude_max_5x", "Claude Max 5x"),
            (nil, "default_claude_max_20x", "Claude Max 20x"),
            ("team", nil, "Claude Team"),
            ("enterprise", nil, "Claude Enterprise"),
            ("ultra", nil, "Claude Ultra"),
            (nil, nil, nil),
            ("unknown", "unknown", nil),
        ]
        for (subscription, tier, expected) in cases {
            var oauth: [String: Any] = ["accessToken": "synthetic-plan-token"]
            oauth["subscriptionType"] = subscription
            oauth["rateLimitTier"] = tier
            let document = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
            XCTAssertEqual(ClaudeQuotaCollector.planName(fromCredentials: document), expected)
        }
        XCTAssertNil(ClaudeQuotaCollector.planName(fromCredentials: Data("invalid".utf8)))
        XCTAssertNil(ClaudeQuotaCollector.planName(fromCredentials: Data(#"{"claudeAiOauth":{"subscriptionType":"pro"}}"#.utf8)))
    }

    func testPlanUsesExistingCredentialReadAndPersistsOnlyTheNormalizedLabel() async throws {
        let root = try workspace(), server = Server(body: body)
        try credentials(root, token: "demo-secret", subscriptionType: "max", rateLimitTier: "default_claude_max_5x")
        let document = try Data(contentsOf: root.appendingPathComponent(".credentials.json"))
        let reads = CredentialSequence([.success(document)])
        let result = await collect(root, server: server, credentialReader: { _ in try reads.read() })
        XCTAssertEqual(result.quota.value?.planName, "Claude Max 5x")
        XCTAssertEqual(reads.readCount, 1)
        let requests = await server.count
        XCTAssertEqual(requests, 1)
        let stored = try String(contentsOf: root.appendingPathComponent("beaver-meter-claude-usage-v1.json"), encoding: .utf8)
        XCTAssertTrue(stored.contains("Claude Max 5x"))
        XCTAssertFalse(stored.contains("demo-secret"))
        XCTAssertFalse(stored.contains("subscriptionType"))
        XCTAssertFalse(stored.contains("rateLimitTier"))
    }

    func testLegacySuccessfulCacheAddsPlanFromExistingSameCredentialReadWithoutFetching() async throws {
        let root = try workspace(), server = Server(body: body)
        let first = await collect(root, server: server)
        XCTAssertNil(first.quota.value?.planName)
        try credentials(root, token: "demo-secret", subscriptionType: "pro")
        let document = try Data(contentsOf: root.appendingPathComponent(".credentials.json"))
        let reads = CredentialSequence([.success(document)])
        let cached = await collect(root, server: server, at: now.addingTimeInterval(1),
                                   credentialReader: { _ in try reads.read() })
        XCTAssertEqual(cached.quota.value?.planName, "Claude Pro")
        XCTAssertEqual(cached.quota.measuredAt, first.quota.measuredAt)
        XCTAssertEqual(reads.readCount, 1)
        let requests = await server.count
        XCTAssertEqual(requests, 1)
    }

    func testCachedPlanSurvivesMissingMetadataAndTransientFailureButNotAnotherLogin() async throws {
        let root = try workspace(), server = Server(body: body)
        try credentials(root, token: "demo-secret", subscriptionType: "pro")
        _ = await collect(root, server: server)
        try credentials(root, token: "demo-secret")
        let cached = await collect(root, server: server, at: now.addingTimeInterval(299))
        XCTAssertEqual(cached.quota.value?.planName, "Claude Pro")
        let failing = Server(code: 503, body: "")
        let failed = await collect(root, server: failing, at: now.addingTimeInterval(300))
        XCTAssertEqual(failed.quota.status, .stale)
        XCTAssertEqual(failed.quota.value?.planName, "Claude Pro")
        try credentials(root, token: "different-login", subscriptionType: "max")
        let changed = await collect(root, server: failing, at: now.addingTimeInterval(301), previous: failed)
        XCTAssertNil(changed.quota.value)
        let requests = await failing.count
        XCTAssertEqual(requests, 2)
    }

    func testMalformedQuotaDoesNotAttachCurrentCredentialPlanToRetainedOldQuota() async throws {
        let root = try workspace()
        try credentials(root, token: "demo-secret", subscriptionType: "pro")
        _ = await collect(root, server: Server(body: body))
        try credentials(root, token: "demo-secret", subscriptionType: "max")
        let server = Server(body: #"{"five_hour":"malformed","cedar_ember":{"eligible":true,"grants":[]}}"#)
        let result = await collect(root, server: server, at: now.addingTimeInterval(300))
        XCTAssertEqual(result.quota.status, .stale)
        XCTAssertEqual(result.quota.value?.planName, "Claude Pro")
        XCTAssertEqual(result.resetCards.status, .ready)
        let cached = await collect(root, server: server, at: now.addingTimeInterval(301))
        XCTAssertEqual(cached.quota.value?.planName, "Claude Pro")
        let requests = await server.count
        XCTAssertEqual(requests, 1)
    }

    func testPlanStaysWithWeeklyQuotaWhenFiveHourWindowExpires() throws {
        let response = Data(#"{"five_hour":{"utilization":28,"resets_at":"2026-09-23T12:01:00Z"},"seven_day":{"utilization":40,"resets_at":"2026-09-29T12:00:00Z"}}"#.utf8)
        let reading = ClaudeUsageCollector.parse(quotaData: .success(response), cardsData: .success(response),
            previous: .init(quota: .unavailable("none"), resetCards: .unavailable("none")), now: now,
            planName: "Claude Max 20x")
        let later = ClaudeQuotaVisibility.quota(reading.quota, relativeTo: now.addingTimeInterval(61))
        XCTAssertEqual(later.value?.windowSeconds, 604_800)
        XCTAssertEqual(later.value?.planName, "Claude Max 20x")
    }

    func testAlreadyCancelledCollectionNeverReadsCredentialsOrRequestsQuota() async throws {
        let root = try workspace(), server = Server(body: body)
        let cancellation = SubprocessCancellation()
        cancellation.cancel()
        let result = await ClaudeUsageCollector.collect(previousQuota: .unavailable("none"),
            previousCards: .unavailable("none"), now: now, stateDirectory: root,
            environment: [:], cancellation: cancellation,
            credentialReader: { _ in XCTFail("Cancelled verification must not open Keychain UI"); return Data() },
            transport: { await server.send($0) })
        XCTAssertEqual(result.quota.status, .error)
        XCTAssertNil(result.quota.value)
        let count = await server.count
        XCTAssertEqual(count, 0)
    }

    func testParsersFailIndependentlyAndUnknownCardsAreNotZero() async throws {
        let root = try workspace()
        let noCards = await collect(root, server: Server(body: #"{"five_hour":{"utilization":10}}"#))
        XCTAssertEqual(noCards.quota.status, .ready)
        XCTAssertEqual(noCards.resetCards.status, .unavailable)
        XCTAssertNil(noCards.resetCards.value)
        let invalidQuota = await collect(root, server: Server(body: #"{"five_hour":"malformed","cedar_ember":{"eligible":true,"grants":[]}}"#), at: now.addingTimeInterval(300))
        XCTAssertEqual(invalidQuota.quota.status, .stale)
        XCTAssertEqual(invalidQuota.resetCards.status, .ready)
        XCTAssertEqual(invalidQuota.resetCards.value?.availableCount, 0)
        let invalidCards = await collect(root, server: Server(body: #"{"five_hour":{"utilization":20},"cedar_ember":{"eligible":true,"grants":[{"id":"bad"}]}}"#), at: now.addingTimeInterval(600))
        XCTAssertEqual(invalidCards.quota.status, .ready)
        XCTAssertEqual(invalidCards.resetCards.status, .stale)
    }

    func testRateLimitHonoursHeaderAndPreservesValuesAcrossInvocations() async throws {
        let root = try workspace()
        let first = await collect(root, server: Server(body: body))
        let limited = Server(code: 429, body: "", headers: ["Retry-After": "600"])
        let failed = await collect(root, server: limited, at: now.addingTimeInterval(300))
        XCTAssertEqual(failed.quota.status, .stale)
        XCTAssertEqual(failed.resetCards.value, first.resetCards.value)
        XCTAssertEqual(failed.resetCards.measuredAt, first.resetCards.measuredAt)
        XCTAssertTrue(failed.resetCards.message?.contains("Rate limited by Anthropic") == true)
        XCTAssertTrue(failed.resetCards.message?.contains("Retry after") == true)
        _ = await collect(root, server: limited, at: now.addingTimeInterval(899))
        let count = await limited.count
        XCTAssertEqual(count, 1)
        let recovery = Server(body: body)
        let recovered = await collect(root, server: recovery, at: now.addingTimeInterval(900))
        XCTAssertEqual(recovered.resetCards.status, .ready)
        XCTAssertNil(recovered.resetCards.message)
    }

    func testFallbackBackoffEscalatesCapsAndResetsAfterSuccess() async throws {
        let root = try workspace(), limited = Server(code: 429, body: "")
        var attempt = now
        for interval in [300.0, 600, 1200, 1800, 1800] {
            _ = await collect(root, server: limited, at: attempt)
            let before = await limited.count
            _ = await collect(root, server: limited, at: attempt.addingTimeInterval(interval - 1))
            let after = await limited.count
            XCTAssertEqual(after, before)
            attempt = attempt.addingTimeInterval(interval)
        }
        _ = await collect(root, server: Server(body: body), at: attempt)
        attempt = attempt.addingTimeInterval(300)
        _ = await collect(root, server: limited, at: attempt)
        let before = await limited.count
        _ = await collect(root, server: limited, at: attempt.addingTimeInterval(300))
        let after = await limited.count
        XCTAssertEqual(after, before + 1)
    }

    func testRetryAfterHTTPDateAndInvalidValues() async throws {
        let expected = now.addingTimeInterval(600)
        XCTAssertEqual(ClaudeUsageCollector.retryDate("600", now: now), expected)
        XCTAssertEqual(ClaudeUsageCollector.retryDate("0", now: now), now)
        XCTAssertEqual(ClaudeUsageCollector.retryDate("Wed, 23 Sep 2026 12:10:00 GMT", now: now), expected)
        for value in ["garbage", "-1", "nan", "inf", "1e300", "Wed, 23 Sep 2026 11:59:00 GMT"] {
            XCTAssertNil(ClaudeUsageCollector.retryDate(value, now: now))
        }
        let root = try workspace(), limited = Server(code: 429, body: "", headers: ["Retry-After": "Wed, 23 Sep 2026 12:10:00 GMT"])
        _ = await collect(root, server: limited)
        _ = await collect(root, server: limited, at: now.addingTimeInterval(599))
        let count = await limited.count
        XCTAssertEqual(count, 1)
    }

    func testOutOfRangePersistedBackoffCountDoesNotCrashRefresh() async throws {
        let root = try workspace(), server = Server(code: 429, body: "")
        _ = await collect(root, server: server)
        let url = root.appendingPathComponent("beaver-meter-claude-usage-v1.json")
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        stored["rateLimitCount"] = Int.max
        try JSONSerialization.data(withJSONObject: stored).write(to: url)
        let reading = await collect(root, server: server, at: now.addingTimeInterval(300))
        XCTAssertTrue(reading.resetCards.message?.contains("Retry after") == true)
        _ = await collect(root, server: server, at: now.addingTimeInterval(2099))
        let count = await server.count
        XCTAssertEqual(count, 2)
    }

    func testNewCredentialCannotReuseAnotherLoginCacheOrBackoff() async throws {
        let root = try workspace()
        let first = await collect(root, server: Server(body: body))
        _ = await collect(root, server: Server(code: 429, body: ""), at: now.addingTimeInterval(300))
        try credentials(root, token: "different-login")
        let server = Server(code: 500, body: "")
        let changed = await collect(root, server: server, at: now.addingTimeInterval(301), previous: first)
        let count = await server.count
        XCTAssertEqual(count, 1)
        XCTAssertNil(changed.quota.value)
        XCTAssertNil(changed.resetCards.value)
        XCTAssertEqual(changed.resetCards.status, .error)
    }

    func testDifferentConfigurationDirectoriesDoNotShareCache() async throws {
        let root = try workspace(), other = try workspace(), server = Server(body: body)
        _ = await collect(root, server: server)
        let reading = await ClaudeUsageCollector.collect(
            previousQuota: .unavailable("none"), previousCards: .unavailable("none"), now: now,
            stateDirectory: root,
            environment: ["CLAUDE_CONFIG_DIR": other.path, "CLAUDE_CLI_PATH": other.appendingPathComponent("missing").path],
            credentialReader: Self.fileCredentials,
            transport: { await server.send($0) })
        let count = await server.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(reading.resetCards.status, .ready)
    }

    func testUnauthorizedClearsCachedValuesAndPersistentSuccessWhenRenewalDisabled() async throws {
        let root = try workspace()
        _ = await collect(root, server: Server(body: body))
        let server = Server(code: 401, body: "")
        let reading = await collect(root, server: server, at: now.addingTimeInterval(300))
        let count = await server.count
        XCTAssertEqual(count, 1)
        XCTAssertNil(reading.quota.value)
        XCTAssertNil(reading.resetCards.value)
        XCTAssertEqual(reading.quota.status, .error)
        XCTAssertEqual(reading.resetCards.status, .error)
        XCTAssertEqual(reading.resetCards.source, .none)
        XCTAssertTrue(reading.resetCards.message?.contains("renewal is disabled") == true)
        XCTAssertFalse(reading.resetCards.message?.contains("Sign in again") == true)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("beaver-meter-claude-usage-v1.json"))) as? [String: Any])
        XCTAssertNil(state["successfulAt"])
        XCTAssertNil(state["retryAt"])
        let persistedReading = try XCTUnwrap(state["reading"] as? [String: Any])
        XCTAssertNil((persistedReading["quota"] as? [String: Any])?["value"])
        XCTAssertNil((persistedReading["resetCards"] as? [String: Any])?["value"])
    }

    func testEmptyCredentialsRequireLoginWithoutLaunchingCLIOrRequestingUsage() async throws {
        let root = try workspace(), server = Server(body: body)
        try Data(#"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}"#.utf8)
            .write(to: root.appendingPathComponent(".credentials.json"))
        let marker = root.appendingPathComponent("unexpected-renewal")
        let environment = try renewalEnvironment(root, script: """
        printf 'launched' > "$CLAUDE_CONFIG_DIR/unexpected-renewal"
        """)
        let reading = await ClaudeUsageCollector.collect(
            previousQuota: .unavailable("none"), previousCards: .unavailable("none"),
            now: now, stateDirectory: root, environment: environment,
            credentialReader: Self.fileCredentials,
            transport: { await server.send($0) })

        XCTAssertEqual(reading.quota.status, .unauthenticated)
        XCTAssertEqual(reading.resetCards.status, .unauthenticated)
        XCTAssertTrue(reading.quota.message?.contains("Sign in to Claude") == true)
        XCTAssertTrue(reading.resetCards.message?.contains("Sign in to Claude") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let count = await server.count
        XCTAssertEqual(count, 0)
    }

    func testExpiredCredentialsRenewThroughConfiguredCLIAndUseCallerEnvironment() async throws {
        let root = try workspace(), server = Server(body: body)
        try credentials(root, token: "expired-token", expiresAt: 0, subscriptionType: "pro")
        let environment = try renewalEnvironment(root, script: """
        printf '%s' "$BEAVERMETER_TEST_AUTH_ENV" > "$CLAUDE_CONFIG_DIR/renewal-environment"
        /bin/cat > "$CLAUDE_CONFIG_DIR/.credentials.json" <<'JSON'
        {"claudeAiOauth":{"accessToken":"renewed-token","expiresAt":4070908800000,"subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}
        JSON
        """)
        let reading = await ClaudeUsageCollector.collect(
            previousQuota: .unavailable("none"), previousCards: .unavailable("none"),
            now: now, stateDirectory: root, environment: environment,
            credentialReader: Self.fileCredentials,
            transport: { await server.send($0) })

        XCTAssertEqual(reading.quota.status, .ready)
        XCTAssertEqual(reading.quota.value?.remainingPercent, 72)
        XCTAssertEqual(reading.quota.value?.planName, "Claude Max 5x")
        XCTAssertEqual(reading.resetCards.value?.availableCount, 1)
        let authorizations = await server.authorizations
        XCTAssertEqual(authorizations, ["Bearer renewed-token"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("renewal-environment"), encoding: .utf8),
                       "caller-environment")
    }

    func testUnauthorizedWaitsForChangedCredentialAndRetriesWithNewToken() async throws {
        for rejectedStatus in [401, 403] {
            let root = try workspace(), server = Server(body: body, responseCodes: [rejectedStatus, 200])
            try credentials(root, token: "demo-secret", subscriptionType: "pro")
            let environment = try renewalEnvironment(root, script: """
            /bin/sleep 1
            /bin/cat > "$CLAUDE_CONFIG_DIR/.credentials.json" <<'JSON'
            {"claudeAiOauth":{"accessToken":"replacement-token","expiresAt":4070908800000,"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}
            JSON
            """)
            let reading = await ClaudeUsageCollector.collect(
                previousQuota: .unavailable("none"), previousCards: .unavailable("none"),
                now: now, stateDirectory: root, environment: environment,
                credentialReader: Self.fileCredentials,
                transport: { await server.send($0) })

            XCTAssertEqual(reading.quota.status, .ready, "HTTP \(rejectedStatus)")
            XCTAssertEqual(reading.quota.value?.planName, "Claude Max 20x", "HTTP \(rejectedStatus)")
            XCTAssertEqual(reading.resetCards.status, .ready, "HTTP \(rejectedStatus)")
            let authorizations = await server.authorizations
            XCTAssertEqual(authorizations, ["Bearer demo-secret", "Bearer replacement-token"], "HTTP \(rejectedStatus)")
        }
    }

    func testRejectedUnchangedTokenIsNotAcceptedAsRenewed() throws {
        let root = try workspace()
        let environment = try renewalEnvironment(root, script: "exit 0")

        XCTAssertThrowsError(try ClaudeQuotaCollector.renewedToken(
            now: now, stateDirectory: root, environment: environment, rejectedToken: "demo-secret",
            credentialReader: Self.fileCredentials
        )) { XCTAssertEqual($0 as? ClaudeRenewalError, .notCompleted) }
    }

    func testRenewalCapturesBaselineWhenRejectedTokenWasNotSupplied() throws {
        let root = try workspace(), environment = try renewalEnvironment(root, script: "exit 0")
        XCTAssertThrowsError(try ClaudeQuotaCollector.renewedToken(
            now: now, stateDirectory: root, environment: environment, credentialReader: Self.fileCredentials
        )) { XCTAssertEqual($0 as? ClaudeRenewalError, .notCompleted) }
    }

    func testBaselineKeychainFailureDoesNotLaunchCLIOrBecomeAnExpiredLogin() throws {
        for failure in [ClaudeKeychainReader.ReadError.keychainAccessRequired, .userCancelled,
                        .unavailable(status: -12345)] {
            let root = try workspace()
            let marker = root.appendingPathComponent("launched")
            let environment = try renewalEnvironment(root, script: "printf launched > \"$CLAUDE_CONFIG_DIR/launched\"")
            XCTAssertThrowsError(try ClaudeQuotaCollector.renewedToken(
                now: now, stateDirectory: root, environment: environment,
                credentialReader: { _ in throw failure }
            )) {
                XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, failure)
                XCTAssertNil($0 as? ClaudeQuotaError)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testKeychainFailureDuringRenewalStopsCLIAndPreservesItsOriginalError() throws {
        for failure in [ClaudeKeychainReader.ReadError.keychainAccessRequired, .userCancelled,
                        .unavailable(status: -12345)] {
            let root = try workspace(), marker = root.appendingPathComponent("launched")
            let environment = try renewalEnvironment(root, script: """
            printf launched > "$CLAUDE_CONFIG_DIR/launched"
            exec /bin/sleep 30
            """)
            let reads = CredentialSequence([.failure(failure)])
            let cancellation = SubprocessCancellation()
            let startedAt = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try ClaudeQuotaCollector.renewedToken(
                now: now, stateDirectory: root, environment: environment, rejectedToken: "demo-secret",
                cancellation: cancellation, credentialReader: { _ in try reads.read() }
            )) {
                XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, failure)
                XCTAssertNil($0 as? ClaudeQuotaError)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 3)
            XCTAssertEqual(reads.readCount, 1, "A denied/cancelled read must not be polled again.")
            XCTAssertFalse(cancellation.isCancelled, "Stopping this CLI must not cancel the caller's task.")
        }
    }

    func testFinalCredentialReadAfterRenewalPreservesKeychainFailure() throws {
        let root = try workspace()
        let environment = try renewalEnvironment(root, script: "exec /bin/sleep 30")
        let renewed = Data(#"{"claudeAiOauth":{"accessToken":"changed-token","expiresAt":4070908800000}}"#.utf8)
        let reads = CredentialSequence([.success(renewed), .failure(ClaudeKeychainReader.ReadError.keychainAccessRequired)])
        XCTAssertThrowsError(try ClaudeQuotaCollector.renewedToken(
            now: now, stateDirectory: root, environment: environment, rejectedToken: "demo-secret",
            credentialReader: { _ in try reads.read() }
        )) {
            XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, .keychainAccessRequired)
        }
        XCTAssertEqual(reads.readCount, 2)
    }

    func testRenewedPlanComesFromExistingFinalCredentialReadRatherThanPollingDocument() throws {
        let root = try workspace()
        let environment = try renewalEnvironment(root, script: "exec /bin/sleep 30")
        let polled = Data(#"{"claudeAiOauth":{"accessToken":"changed-token","expiresAt":4070908800000,"subscriptionType":"pro"}}"#.utf8)
        let final = Data(#"{"claudeAiOauth":{"accessToken":"final-token","expiresAt":4070908800000,"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#.utf8)
        let reads = CredentialSequence([.success(polled), .success(final)])
        let renewed = try ClaudeCredentialRenewal.renewedCredential(
            now: now, stateDirectory: root, environment: environment, rejectedToken: "demo-secret",
            credentialReader: { _ in try reads.read() }
        )
        XCTAssertEqual(renewed.token, "final-token")
        XCTAssertEqual(renewed.planName, "Claude Max 20x")
        XCTAssertEqual(reads.readCount, 2, "Metadata must reuse the existing polling and final reads.")
    }

    func testParentCancellationDuringRenewalStillReportsCancellation() throws {
        let root = try workspace()
        let environment = try renewalEnvironment(root, script: "exec /bin/sleep 30")
        let cancellation = SubprocessCancellation()
        let renewed = Data(#"{"claudeAiOauth":{"accessToken":"changed-token","expiresAt":4070908800000}}"#.utf8)
        XCTAssertThrowsError(try ClaudeQuotaCollector.renewedToken(
            now: now, stateDirectory: root, environment: environment, rejectedToken: "demo-secret",
            cancellation: cancellation, credentialReader: { _ in cancellation.cancel(); return renewed }
        )) {
            XCTAssertEqual(($0 as? URLError)?.code, .cancelled)
        }
    }

    func testRejectedTokenFollowedByKeychainDenialNeedsAccessRatherThanAnotherLogin() async throws {
        let root = try workspace(), server = Server(code: 401, body: "")
        let environment = try renewalEnvironment(root, script: "exec /bin/sleep 30")
        let original = try Self.fileCredentials(environment)
        let reads = CredentialSequence([.success(original), .failure(ClaudeKeychainReader.ReadError.keychainAccessRequired)])
        let reading = await ClaudeUsageCollector.collect(
            previousQuota: .unavailable("none"), previousCards: .unavailable("none"),
            now: now, stateDirectory: root, environment: environment,
            credentialReader: { _ in try reads.read() }, transport: { await server.send($0) }
        )

        XCTAssertEqual(reading.quota.status, .error)
        XCTAssertEqual(reading.resetCards.status, .error)
        XCTAssertNil(reading.quota.value)
        XCTAssertNil(reading.resetCards.value)
        XCTAssertTrue(reading.quota.message?.contains("Allow Claude access") == true)
        XCTAssertFalse(reading.quota.message?.contains("Sign in again") == true)
        let requests = await server.count
        XCTAssertEqual(requests, 1)
    }

    func testSignOutClearsOldValuesAndBackoffThenAllowsImmediateVerification() async throws {
        let root = try workspace(), server = Server(body: body)
        let first = await collect(root, server: server)
        _ = await collect(root, server: Server(code: 429, body: "", headers: ["Retry-After": "3600"]), at: now.addingTimeInterval(300))
        try credentials(root, token: "")
        let signedOut = await collect(root, server: server, at: now.addingTimeInterval(301), previous: first)
        XCTAssertEqual(signedOut.quota.status, .unauthenticated)
        XCTAssertEqual(signedOut.quota.source, .none)
        XCTAssertNil(signedOut.quota.value)
        XCTAssertNil(signedOut.resetCards.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("beaver-meter-claude-usage-v1.json").path))
        try credentials(root, token: "demo-secret")
        let recovered = await collect(root, server: server, at: now.addingTimeInterval(302), previous: signedOut)
        XCTAssertEqual(recovered.quota.status, .ready)
        let requests = await server.count
        XCTAssertEqual(requests, 2)
    }

    func testExpiredTokenCannotHitSuccessCacheOrRateLimitGate() async throws {
        for rateLimited in [false, true] {
            let root = try workspace(), server = Server(body: body)
            _ = await collect(root, server: server)
            if rateLimited {
                _ = await collect(root, server: Server(code: 429, body: "", headers: ["Retry-After": "3600"]),
                                  at: now.addingTimeInterval(300))
            }
            try credentials(root, token: "demo-secret", expiresAt: 0, refreshToken: "synthetic-refresh")
            let environment = try renewalEnvironment(root, script: """
            /bin/cat > "$CLAUDE_CONFIG_DIR/.credentials.json" <<'JSON'
            {"claudeAiOauth":{"accessToken":"renewed-token","expiresAt":4070908800000}}
            JSON
            """)
            let result = await collect(root, server: server, at: now.addingTimeInterval(rateLimited ? 301 : 1),
                                       environment: environment)
            XCTAssertEqual(result.quota.status, .ready)
            let tokens = await server.authorizations
            XCTAssertEqual(tokens, ["Bearer demo-secret", "Bearer renewed-token"])
        }
    }

    func testMissingAccessWithRefreshTokenUsesCLIAndVerifiesNewCredential() async throws {
        let root = try workspace(), server = Server(body: body)
        try credentials(root, token: "", expiresAt: 0, refreshToken: "synthetic-refresh")
        let environment = try renewalEnvironment(root, script: """
        /bin/cat > "$CLAUDE_CONFIG_DIR/.credentials.json" <<'JSON'
        {"claudeAiOauth":{"accessToken":"renewed-token","expiresAt":4070908800000}}
        JSON
        """)
        let result = await collect(root, server: server, environment: environment)
        XCTAssertEqual(result.quota.status, .ready)
        let tokens = await server.authorizations
        XCTAssertEqual(tokens, ["Bearer renewed-token"])
    }

    func testSecondUnauthorizedResponseClearsValuesAfterOnlyOneRenewal() async throws {
        let root = try workspace()
        let previous = await collect(root, server: Server(body: body))
        let environment = try renewalEnvironment(root, script: """
        /bin/cat > "$CLAUDE_CONFIG_DIR/.credentials.json" <<'JSON'
        {"claudeAiOauth":{"accessToken":"renewed-token","expiresAt":4070908800000}}
        JSON
        """)
        let server = Server(code: 401, body: "")
        let result = await collect(root, server: server, at: now.addingTimeInterval(300), previous: previous,
                                   environment: environment)
        XCTAssertEqual(result.quota.status, .unauthenticated)
        XCTAssertNil(result.quota.value)
        XCTAssertNil(result.resetCards.value)
        let requests = await server.count
        XCTAssertEqual(requests, 2)
    }

    func testTransientFailuresStopRetainingValuesAfterThirtyMeasuredMinutes() async throws {
        let root = try workspace()
        let first = await collect(root, server: Server(body: body))
        let server = Server(code: 500, body: "")
        let retained = await collect(root, server: server, at: now.addingTimeInterval(1799), previous: first)
        XCTAssertEqual(retained.quota.status, .stale)
        XCTAssertEqual(retained.quota.measuredAt, now)
        XCTAssertEqual(retained.quota.value?.remainingPercent, 72)
        let expired = await collect(root, server: server, at: now.addingTimeInterval(1800), previous: retained)
        XCTAssertNil(expired.quota.value)
        XCTAssertNil(expired.resetCards.value)
        XCTAssertEqual(expired.quota.status, .error)
    }

    func testSuccessfulResponseWithMalformedComponentsCannotExtendTheirCacheLifetime() async throws {
        let root = try workspace()
        _ = await collect(root, server: Server(body: body))
        let server = Server(body: #"{"five_hour":"malformed","cedar_ember":{"eligible":true,"grants":[{"id":"bad"}]}}"#)
        let retained = await collect(root, server: server, at: now.addingTimeInterval(1799))
        XCTAssertEqual(retained.quota.status, .stale)
        XCTAssertEqual(retained.quota.measuredAt, now)
        XCTAssertNotNil(retained.quota.value)
        XCTAssertNotNil(retained.resetCards.value)
        let expired = await collect(root, server: server, at: now.addingTimeInterval(1800))
        XCTAssertNil(expired.quota.value)
        XCTAssertNil(expired.resetCards.value)
        let requests = await server.count
        XCTAssertEqual(requests, 1, "The success-cache gate still runs, but must crop both retained components.")
    }

    func testResetWindowCannotBeReturnedFromFiveMinuteCacheOrNetworkFallback() async throws {
        let root = try workspace()
        let response = #"{"five_hour":{"utilization":28,"resets_at":"2026-09-23T12:01:00Z"},"seven_day":{"utilization":40,"resets_at":"2026-09-25T12:00:00Z"}}"#
        _ = await collect(root, server: Server(body: response))
        let server = Server(code: 500, body: "")
        let result = await collect(root, server: server, at: now.addingTimeInterval(60))
        XCTAssertEqual(result.quota.status, .stale)
        XCTAssertEqual(result.quota.value?.label, "Claude Week")
        XCTAssertEqual(result.quota.value?.remainingPercent, 60)
        XCTAssertFalse(result.quota.value?.windows?.contains(where: { $0.label == "Claude 5h" }) == true)
        let requests = await server.count
        XCTAssertEqual(requests, 1)
    }

    func testForceRefreshBypassesBothSuccessfulCacheAndRateLimitGate() async throws {
        let root = try workspace(), server = Server(body: body)
        _ = await collect(root, server: server)
        _ = await collect(root, server: server, at: now.addingTimeInterval(1), forceRefresh: true)
        _ = await collect(root, server: Server(code: 429, body: "", headers: ["Retry-After": "3600"]),
                          at: now.addingTimeInterval(2), forceRefresh: true)
        let verified = await collect(root, server: server, at: now.addingTimeInterval(3), forceRefresh: true)
        XCTAssertEqual(verified.quota.status, .ready)
        let requests = await server.count
        XCTAssertEqual(requests, 3)
    }

    func testUnsupportedOAuthClearsValuesWithoutUsageRequest() async throws {
        let root = try workspace(), server = Server(body: body)
        let previous = await collect(root, server: server)
        let result = await ClaudeUsageCollector.collect(
            previousQuota: previous.quota, previousCards: previous.resetCards,
            now: now.addingTimeInterval(1), stateDirectory: root,
            environment: ["CLAUDE_CODE_CUSTOM_OAUTH_URL": "https://synthetic.invalid/oauth"],
            transport: { await server.send($0) })
        XCTAssertEqual(result.quota.status, .unauthenticated)
        XCTAssertNil(result.quota.value)
        XCTAssertNil(result.resetCards.value)
        let requests = await server.count
        XCTAssertEqual(requests, 1)
    }

    func testCancelledVerificationClearsUnverifiedValuesAndDefersSignOutCheck() async throws {
        let root = try workspace(), server = Server(body: body)
        let previous = await collect(root, server: server)
        let cancellation = SubprocessCancellation()
        cancellation.cancel()
        let cancelled = await collect(root, server: server, at: now.addingTimeInterval(1), previous: previous,
                                      forceRefresh: true, cancellation: cancellation)
        XCTAssertEqual(cancelled.quota.status, .error)
        XCTAssertNil(cancelled.quota.value)
        XCTAssertNil(cancelled.resetCards.value)
        try credentials(root, token: "")
        let signedOut = await collect(root, server: server, at: now.addingTimeInterval(2), previous: cancelled,
                                      forceRefresh: true)
        XCTAssertEqual(signedOut.quota.status, .unauthenticated)
        XCTAssertNil(signedOut.quota.value)
        XCTAssertNil(signedOut.resetCards.value)
        let requests = await server.count
        XCTAssertEqual(requests, 1)
    }

    func testCancelledRenewedTokenReportsCancellationInsteadOfAuthenticationFailure() throws {
        let root = try workspace(), marker = root.appendingPathComponent("launched")
        let environment = try renewalEnvironment(root, script: "printf launched > \"$CLAUDE_CONFIG_DIR/launched\"")
        let cancellation = SubprocessCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try ClaudeQuotaCollector.renewedToken(
            now: now, stateDirectory: root, environment: environment, cancellation: cancellation,
            credentialReader: Self.fileCredentials
        )) { XCTAssertEqual(($0 as? URLError)?.code, .cancelled) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
