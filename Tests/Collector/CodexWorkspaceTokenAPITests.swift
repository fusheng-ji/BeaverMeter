import CodexBarCore
import Foundation
import XCTest

final class CodexWorkspaceTokenAPITests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!

    private func credentials(_ scope: String, claim: String? = nil, apiKey: Bool = false,
                             includesClaim: Bool = true) throws -> CodexOAuthCredentials {
        let auth: [String: Any] = includesClaim ? ["chatgpt_account_id": claim ?? scope] : [:]
        let payload = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": auth])
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return CodexOAuthCredentials(accessToken: "synthetic.\(payload).synthetic", refreshToken: "not-used",
            idToken: nil, accountId: scope, lastRefresh: now, isAPIKey: apiKey)
    }

    private func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    private func profile(_ scope: String = "a", tokens: Int = 100, date: String = "2026-10-24",
                         asOf: String = "2026-10-24") -> [String: Any] {
        ["account_id": scope, "stats": ["daily_usage_buckets": [["start_date": date, "tokens": tokens]],
            "lifetime_tokens": tokens + 1000], "metadata": ["stats_as_of": asOf, "stats_error": NSNull()]]
    }

    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-token-api-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func cached(_ scope: String = "a", age: TimeInterval = 60, source: UsageDataSource = .accountAPI,
                        day: String = "2026-10-24", tokens: Int = 100,
                        generatedAt: Date? = nil) -> UsageValue<CodexAccountTokenActivity> {
        var activity = CodexAccountTokenActivity(workspaceAccountIDHash: CodexUsageSupport.hash(scope),
            dailyUsage: [CodexAccountTokenDay(date: day, tokens: tokens)], lifetimeTokens: 1000, statsAsOf: day)
        activity.serviceGeneratedAt = generatedAt
        return UsageValue(status: .ready, source: source, measuredAt: now.addingTimeInterval(-age),
            lastAttemptAt: now.addingTimeInterval(-age), message: nil,
            value: activity)
    }

    func testRequestFactoryUsesVerifiedOwnScopeAndEphemeralTransport() throws {
        let credentials = try credentials(" Workspace-A ", claim: "workspace-a")
        let request = try CodexWorkspaceTokenAPICollector.request(credentials: credentials, workspaceAccountID: "WORKSPACE-A")
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/profiles/me")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "workspace-a")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + credentials.accessToken)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "codex-cli")
        XCTAssertEqual(request.timeoutInterval, 12)
        XCTAssertFalse(request.httpShouldHandleCookies)
        let configuration = CodexWorkspaceTokenAPICollector.configuration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 12)
    }

    func testSelectedCredentialAndJWTScopesMustAllAgree() throws {
        XCTAssertThrowsError(try CodexWorkspaceTokenAPICollector.request(credentials: credentials("a"), workspaceAccountID: "b"))
        XCTAssertThrowsError(try CodexWorkspaceTokenAPICollector.request(credentials: credentials("a", claim: "b"), workspaceAccountID: "a"))
        XCTAssertThrowsError(try CodexWorkspaceTokenAPICollector.request(credentials: credentials("a", includesClaim: false), workspaceAccountID: "a"))
        XCTAssertThrowsError(try CodexWorkspaceTokenAPICollector.request(credentials: credentials("a", apiKey: true), workspaceAccountID: "a"))
    }

    func testIDTokenWhenPresentMustParseAndMatchSelectedScope() throws {
        let own = try credentials("a")
        for idToken in [try credentials("b").accessToken, try credentials("a", includesClaim: false).accessToken, "not-a-jwt"] {
            let mixed = CodexOAuthCredentials(accessToken: own.accessToken, refreshToken: own.refreshToken,
                idToken: idToken, accountId: "a", lastRefresh: now)
            XCTAssertThrowsError(try CodexWorkspaceTokenAPICollector.request(credentials: mixed, workspaceAccountID: "a"))
        }
        let matching = CodexOAuthCredentials(accessToken: own.accessToken, refreshToken: own.refreshToken,
            idToken: own.accessToken, accountId: "a", lastRefresh: now)
        XCTAssertNoThrow(try CodexWorkspaceTokenAPICollector.request(credentials: matching, workspaceAccountID: "a"))
        XCTAssertNoThrow(try CodexWorkspaceTokenAPICollector.request(credentials: own, workspaceAccountID: "a"))
    }

    func testIDTokenMismatchClearsCacheBeforeAnyFixtureRead() async throws {
        let own = try credentials("a")
        let mixed = CodexOAuthCredentials(accessToken: own.accessToken, refreshToken: own.refreshToken,
            idToken: try credentials("b").accessToken, accountId: "a", lastRefresh: now)
        let value = await CodexWorkspaceTokenAPICollector.collect(credentials: mixed, workspaceAccountID: "a",
            previous: cached(), now: now,
            environment: ["CODEX_WORKSPACE_TOKENS_FIXTURE": "/must-not-read-this-synthetic-missing-file"])
        XCTAssertEqual(value.status, .unauthenticated)
        XCTAssertNil(value.value)
    }

    func testDecodePreservesSparseServiceDatesAndAsOfWithoutInventingTodayOrBreakdown() throws {
        let object: [String: Any] = ["stats": ["daily_usage_buckets": [
            ["start_date": "2026-10-24", "tokens": 501550], ["start_date": "2026-10-20", "tokens": 0]],
            "lifetime_tokens": 600000], "metadata": ["stats_as_of": "2026-10-24"]]
        let activity = try CodexWorkspaceTokenAPICollector.decodeResponse(data(object), workspaceAccountID: " A ")
        XCTAssertEqual(activity.workspaceAccountIDHash, CodexUsageSupport.hash("a"))
        XCTAssertEqual(activity.dailyUsage?.map(\.date), ["2026-10-20", "2026-10-24"])
        XCTAssertEqual(activity.dailyUsage?.map(\.tokens), [0, 501550])
        XCTAssertEqual(activity.statsAsOf, "2026-10-24")
        XCTAssertEqual(activity.lifetimeTokens, 600000)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(activity)) as? [String: Any])
        XCTAssertNil(encoded["inputTokens"])
        XCTAssertNil(encoded["outputTokens"])
    }

    func testNilAndEmptyBucketsRemainDistinctAndNeverBecomeTodayZero() throws {
        let missing = try CodexWorkspaceTokenAPICollector.decodeResponse(data(["stats": ["lifetime_tokens": 0]]), workspaceAccountID: "a")
        let empty = try CodexWorkspaceTokenAPICollector.decodeResponse(data(["stats": ["daily_usage_buckets": []]]), workspaceAccountID: "a")
        XCTAssertNil(missing.dailyUsage)
        XCTAssertEqual(missing.lifetimeTokens, 0)
        XCTAssertEqual(empty.dailyUsage, [])
        XCTAssertNil(empty.lifetimeTokens)
        XCTAssertThrowsError(try CodexWorkspaceTokenAPICollector.decodeResponse(data(["stats": NSNull()]), workspaceAccountID: "a"))
    }

    func testIdenticalDuplicateBucketsDeduplicateButConflictingDuplicatesFail() throws {
        let same: [String: Any] = ["stats": ["daily_usage_buckets": [["start_date": "2026-10-24", "tokens": 1],
                                                                    ["start_date": "2026-10-24", "tokens": 1]]]]
        XCTAssertEqual(try CodexWorkspaceTokenAPICollector.decodeResponse(data(same), workspaceAccountID: "a").dailyUsage?.count, 1)
        let different: [String: Any] = ["stats": ["daily_usage_buckets": [["start_date": "2026-10-24", "tokens": 1],
                                                                         ["start_date": "2026-10-24", "tokens": 2]]]]
        XCTAssertThrowsError(try CodexWorkspaceTokenAPICollector.decodeResponse(data(different), workspaceAccountID: "a"))
    }

    func testInvalidNumbersDatesAndAsOfAreRejected() throws {
        for date in ["2026-02-30", "2026-13-01", "2026-1-01", "0000-01-01", "2026-10-24T00:00:00Z"] {
            XCTAssertThrowsError(try CodexWorkspaceTokenAPICollector.decodeResponse(data(profile(date: date)), workspaceAccountID: "a"), date)
        }
        XCTAssertThrowsError(try CodexWorkspaceTokenAPICollector.decodeResponse(data(profile(tokens: -1)), workspaceAccountID: "a"))
        XCTAssertThrowsError(try CodexWorkspaceTokenAPICollector.decodeResponse(data(["stats": ["lifetime_tokens": -1]]), workspaceAccountID: "a"))
        let overflow = Data(#"{"stats":{"daily_usage_buckets":[{"start_date":"2026-10-24","tokens":9223372036854775808}]}}"#.utf8)
        XCTAssertThrowsError(try CodexWorkspaceTokenAPICollector.decodeResponse(overflow, workspaceAccountID: "a"))
        for asOf in ["not-a-date", "2026-02-30", "2026-10-24T12:00:00", "2026-10-24T24:01:00Z"] {
            XCTAssertThrowsError(try CodexWorkspaceTokenAPICollector.decodeResponse(data(profile(asOf: asOf)), workspaceAccountID: "a"), asOf)
        }
        for asOf in ["2026-10-24T12:34:56Z", "2026-10-24T12:34:56.123+02:00"] {
            XCTAssertEqual(try CodexWorkspaceTokenAPICollector.decodeResponse(data(profile(asOf: asOf)), workspaceAccountID: "a").statsAsOf, asOf)
        }
    }

    func testReturnedIdentityMustMatchAndPrivateProfileFieldsAreNotRetained() throws {
        XCTAssertThrowsError(try CodexWorkspaceTokenAPICollector.decodeResponse(data(profile("b")), workspaceAccountID: "a"))
        var object = profile()
        object["accountId"] = "b"
        XCTAssertThrowsError(try CodexWorkspaceTokenAPICollector.decodeResponse(data(object), workspaceAccountID: "a"))
        object = profile()
        object["username"] = "private-username-never-persist"
        object["email"] = "private-email-never-persist"
        object["id"] = "unrelated-profile-id"
        let value = try CodexWorkspaceTokenAPICollector.decodeResponse(data(object), workspaceAccountID: "a")
        let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-"))
        XCTAssertFalse(encoded.contains("unrelated-profile-id"))
    }

    func testStatisticsErrorCannotPublishLiveValuesOrExposeErrorBody() throws {
        var object = profile()
        object["metadata"] = ["stats_error": "private-server-error", "stats_as_of": "2026-10-24"]
        XCTAssertThrowsError(try CodexWorkspaceTokenAPICollector.decodeResponse(data(object), workspaceAccountID: "a"))
        let value = CodexWorkspaceTokenAPICollector.failed(CodexWorkspaceTokenAPICollector.Failure.statisticsUnavailable,
            previous: cached(), workspaceAccountID: "a", now: now)
        XCTAssertEqual(value.status, .stale)
        XCTAssertFalse(value.message?.contains("private-server-error") == true)
    }

    func testTransientCacheRequiresSameScopeRecentAPIMeasurementAndKeepsServiceDates() {
        for failure in [URLError(.timedOut) as Error, CodexWorkspaceTokenAPICollector.Failure.http(503),
                        CodexWorkspaceTokenAPICollector.Failure.http(429)] {
            let previous = cached()
            let value = CodexWorkspaceTokenAPICollector.failed(failure, previous: previous, workspaceAccountID: "a", now: now)
            XCTAssertEqual(value.status, .stale)
            XCTAssertEqual(value.source, .cache)
            XCTAssertEqual(value.measuredAt, previous.measuredAt)
            XCTAssertEqual(value.lastAttemptAt, now)
            XCTAssertEqual(value.value?.dailyUsage?.first?.date, "2026-10-24")
        }
    }

    func testCrossScopeOldFutureNonAPIAndInvalidTypedCacheAreNotReused() {
        for previous in [cached("b"), cached(age: CodexWorkspaceTokenAPICollector.cacheLifetime + 1),
                         cached(age: -1), cached(source: .codexBarLocal), cached(day: "2026-02-30"), cached(tokens: -1)] {
            let value = CodexWorkspaceTokenAPICollector.failed(URLError(.timedOut), previous: previous, workspaceAccountID: "a", now: now)
            XCTAssertNil(value.value)
        }
    }

    func testAuthenticationAndNonTransientFailuresClearPreviousReading() {
        for failure in [CodexWorkspaceTokenAPICollector.Failure.http(401), .http(403), .workspaceMismatch, .unauthenticated,
                        .http(400), .invalidResponse] {
            let value = CodexWorkspaceTokenAPICollector.failed(failure, previous: cached(), workspaceAccountID: "a", now: now)
            XCTAssertNil(value.value)
            if case .http(let code) = failure, code == 401 || code == 403 { XCTAssertEqual(value.status, .unauthenticated) }
        }
    }

    func testFixtureFetchUsesFetchTimeAndOriginalDataThroughDate() async throws {
        let directory = try fixtureDirectory(), file = directory.appendingPathComponent("profile.json")
        try data(profile()).write(to: file)
        let value = await CodexWorkspaceTokenAPICollector.collect(credentials: try credentials("a"), workspaceAccountID: "a",
            previous: nil, now: now, environment: ["CODEX_WORKSPACE_TOKENS_FIXTURE": file.path])
        XCTAssertEqual(value.status, .ready)
        XCTAssertEqual(value.source, .accountAPI)
        XCTAssertEqual(value.measuredAt, now)
        XCTAssertEqual(value.value?.statsAsOf, "2026-10-24")
        XCTAssertEqual(value.value?.dailyUsage?.map(\.date), ["2026-10-24"])
        XCTAssertTrue(value.message?.contains("unspecified time zone") == true)
    }

    func testGeneratedAtPreservesZonedServerTimeIndependentOfStatisticsDate() throws {
        var object = profile()
        object["metadata"] = ["stats_as_of": "2026-10-24", "generated_at": "2026-10-25T12:00:00.123456+02:00"]
        let value = try CodexWorkspaceTokenAPICollector.decodeResponse(data(object), workspaceAccountID: "a")
        let generatedAt = try XCTUnwrap(value.serviceGeneratedAt)
        XCTAssertEqual(generatedAt.timeIntervalSince1970, now.addingTimeInterval(-7200 + 0.123456).timeIntervalSince1970, accuracy: 0.000001)
        XCTAssertEqual(value.statsAsOf, "2026-10-24")
        XCTAssertEqual(value.dailyUsage?.first?.date, "2026-10-24")
    }

    func testGeneratedAtRejectsNonTimestampTypesDateOnlyMissingOrInvalidZone() throws {
        let invalid: [Any] = [123, false, ["unexpected": "private-server-body"], "2026-10-25", "2026-10-25T12:00:00",
                              "2026-10-25T12:00:00+99:99", "2026-02-30T12:00:00Z", "2026-10-25T12:00:00-25:00"]
        for generatedAt in invalid {
            var object = profile()
            object["metadata"] = ["stats_as_of": "2026-10-24", "generated_at": generatedAt]
            XCTAssertThrowsError(try CodexWorkspaceTokenAPICollector.decodeResponse(data(object), workspaceAccountID: "a"))
        }
    }

    func testGeneratedAtNeverSubstitutesForMissingStatisticsDateOrQueryTime() async throws {
        let directory = try fixtureDirectory(), file = directory.appendingPathComponent("profile.json")
        var object = profile()
        object["metadata"] = ["generated_at": "2026-10-25T11:30:00Z"]
        try data(object).write(to: file)
        let value = await CodexWorkspaceTokenAPICollector.collect(credentials: try credentials("a"), workspaceAccountID: "a",
            previous: nil, now: now, environment: ["CODEX_WORKSPACE_TOKENS_FIXTURE": file.path])
        XCTAssertEqual(value.status, .ready)
        XCTAssertNil(value.value?.statsAsOf)
        XCTAssertEqual(value.value?.serviceGeneratedAt, now.addingTimeInterval(-1800))
        XCTAssertEqual(value.measuredAt, now)
        XCTAssertTrue(value.message?.contains("Account report date unavailable; queried at 2026-10-25T12:00:00.000Z.") == true)
        XCTAssertTrue(value.message?.contains("Service generated response 2026-10-25T11:30:00.000Z.") == true)
        XCTAssertFalse(value.message?.contains("fetched now") == true)
        object["metadata"] = ["generated_at": "private-server-body"]
        try data(object).write(to: file)
        let invalid = await CodexWorkspaceTokenAPICollector.collect(credentials: try credentials("a"), workspaceAccountID: "a",
            previous: value, now: now, environment: ["CODEX_WORKSPACE_TOKENS_FIXTURE": file.path])
        XCTAssertEqual(invalid.status, .error)
        XCTAssertNil(invalid.value)
        XCTAssertFalse(invalid.message?.contains("private-server-body") == true)
    }

    func testTransientCachePreservesOriginalQueryAndServiceGenerationTimes() {
        let generatedAt = now.addingTimeInterval(-7200)
        let previous = cached(age: 3600, generatedAt: generatedAt)
        let value = CodexWorkspaceTokenAPICollector.failed(URLError(.timedOut), previous: previous, workspaceAccountID: "a", now: now)
        XCTAssertEqual(value.status, .stale)
        XCTAssertEqual(value.measuredAt, now.addingTimeInterval(-3600))
        XCTAssertEqual(value.lastAttemptAt, now)
        XCTAssertEqual(value.value?.serviceGeneratedAt, generatedAt)
        XCTAssertEqual(value.value?.statsAsOf, "2026-10-24")
        XCTAssertTrue(value.message?.contains("Account report date 2026-10-24; queried at 2026-10-25T11:00:00.000Z.") == true)
        XCTAssertTrue(value.message?.contains("Service generated response 2026-10-25T10:00:00.000Z.") == true)
        XCTAssertFalse(value.message?.contains("queried at 2026-10-25T12:00:00.000Z") == true)
    }

    func testServiceGeneratedAtRoundtripAndLegacyOptionalCompatibility() throws {
        let value = try XCTUnwrap(cached(generatedAt: now.addingTimeInterval(-1800)).value)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoded = try encoder.encode(value)
        XCTAssertEqual(try decoder.decode(CodexAccountTokenActivity.self, from: encoded), value)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "serviceGeneratedAt")
        let old = try decoder.decode(CodexAccountTokenActivity.self, from: data(legacy))
        XCTAssertNil(old.serviceGeneratedAt)
        XCTAssertEqual(old.dailyUsage, value.dailyUsage)
        XCTAssertEqual(old.statsAsOf, value.statsAsOf)
        var profile = profile()
        profile["metadata"] = ["generated_at": NSNull()]
        XCTAssertNil(try CodexWorkspaceTokenAPICollector.decodeResponse(data(profile), workspaceAccountID: "a").serviceGeneratedAt)
    }

    func testFixtureDirectoryUsesExactWorkspaceHashWithoutSiblingFallback() async throws {
        let directory = try fixtureDirectory()
        for (scope, tokens) in [("a", 100), ("b", 200)] {
            try data(profile(scope, tokens: tokens)).write(to: directory.appendingPathComponent(CodexUsageSupport.hash(scope) + ".json"))
        }
        for (scope, tokens) in [("a", 100), ("b", 200)] {
            let value = await CodexWorkspaceTokenAPICollector.collect(credentials: try credentials(scope), workspaceAccountID: scope,
                previous: nil, now: now, environment: ["CODEX_WORKSPACE_TOKENS_FIXTURE": directory.path])
            XCTAssertEqual(value.value?.dailyUsage?.first?.tokens, tokens)
            XCTAssertEqual(value.value?.workspaceAccountIDHash, CodexUsageSupport.hash(scope))
        }
        let absent = await CodexWorkspaceTokenAPICollector.collect(credentials: try credentials("missing"), workspaceAccountID: "missing",
            previous: cached(), now: now, environment: ["CODEX_WORKSPACE_TOKENS_FIXTURE": directory.path])
        XCTAssertNil(absent.value)
    }

    func testOtherFixtureModesNeverStartLiveIOAndMismatchedFixtureCannotBypassScope() async throws {
        for key in ["CODEX_TOKEN_FIXTURE", "CODEX_HISTORY_FIXTURE", "CODEX_USAGE_FIXTURE", "CODEX_LEGACY_TOKEN_FIXTURE", "CLAUDE_USAGE_FIXTURE"] {
            let value = await CodexWorkspaceTokenAPICollector.collect(credentials: try credentials("a"), workspaceAccountID: "a",
                previous: cached(), now: now, environment: [key: "/nonexistent-synthetic-fixture"])
            XCTAssertEqual(value.status, .unavailable, key)
            XCTAssertNil(value.value, key)
        }
        let directory = try fixtureDirectory(), file = directory.appendingPathComponent("profile.json")
        try data(profile("b")).write(to: file)
        let mismatch = await CodexWorkspaceTokenAPICollector.collect(credentials: try credentials("a"), workspaceAccountID: "a",
            previous: cached(), now: now, environment: ["CODEX_WORKSPACE_TOKENS_FIXTURE": file.path])
        XCTAssertEqual(mismatch.status, .unauthenticated)
        XCTAssertNil(mismatch.value)
    }
}
