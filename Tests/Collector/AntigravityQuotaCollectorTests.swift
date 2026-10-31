import CodexBarCore
import Foundation
import XCTest

final class AntigravityQuotaCollectorTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!
    private var empty: UsageValue<AntigravityQuotaSnapshot> { .unavailable("No quota yet") }

    private actor CleanupCount {
        var count = 0
        func increment() { count += 1 }
    }

    private actor AttemptLog {
        var ids: [String] = []
        func append(_ id: String) { ids.append(id) }
    }

    private struct Strategy: ProviderFetchStrategy {
        let id: String
        let kind: ProviderFetchKind
        let error: AntigravityStatusProbeError?
        let result: ProviderFetchResult
        let log: AttemptLog

        func isAvailable(_ context: ProviderFetchContext) async -> Bool { true }
        func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
            await log.append(id)
            if let error { throw error }
            return result
        }
        func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool { true }
    }

    private func window(_ used: Double, minutes: Int = 300, reset: Date? = nil,
                        description: String? = nil, placeholder: Bool = false) -> RateWindow {
        RateWindow(usedPercent: used, windowMinutes: minutes,
                   resetsAt: reset, resetDescription: description, isSyntheticPlaceholder: placeholder)
    }

    private func named(_ group: String, _ cadence: String, used: Double, minutes: Int,
                       known: Bool = true, reset: Date? = nil, description: String? = nil) -> NamedRateWindow {
        NamedRateWindow(id: "antigravity-quota-summary-\(group)-\(cadence)", title: "\(group) \(cadence)",
            window: window(used, minutes: minutes, reset: reset, description: description), usageKnown: known)
    }

    private func result(_ rows: [NamedRateWindow], account: String = "synthetic@example.test",
                        source: String = "app", strategy: String = "antigravity.app-local") -> ProviderFetchResult {
        let snapshot = CodexBarCore.UsageSnapshot(primary: nil, secondary: nil,
            extraRateWindows: rows, updatedAt: now,
            identity: ProviderIdentitySnapshot(providerID: .antigravity, accountEmail: account,
                                               accountOrganization: nil, loginMethod: "Google AI Ultra"))
        return ProviderFetchResult(usage: snapshot, credits: nil, dashboard: nil,
            sourceLabel: source, strategyID: strategy, strategyKind: .localProbe)
    }

    private func collect(_ result: ProviderFetchResult,
                         previous: UsageValue<AntigravityQuotaSnapshot>? = nil,
                         at date: Date? = nil) async -> UsageValue<AntigravityQuotaSnapshot> {
        await AntigravityQuotaCollector.collect(previous: previous ?? empty, now: date ?? now,
            environment: [:], fetch: { _ in result }, cleanup: {})
    }

    func testFourWindowsKeepIndependentPoolsAndRealZeroAndHundred() async throws {
        let reading = await collect(result([
            named("Gemini Models", "Session", used: 20, minutes: 300),
            named("Gemini Models", "Weekly", used: 40, minutes: 10_080),
            named("Claude and GPT", "Session", used: 100, minutes: 300),
            named("Claude and GPT", "Weekly", used: 0, minutes: 10_080),
        ]))
        XCTAssertEqual(reading.status, .ready)
        XCTAssertEqual(reading.source, .antigravityLocal)
        XCTAssertNil(reading.message)
        let snapshot = try XCTUnwrap(reading.value)
        XCTAssertEqual(snapshot.groups.map(\.id), [.gemini, .claudeGPT])
        XCTAssertEqual(snapshot.groups[0].windows.map(\.remainingPercent), [80, 60])
        XCTAssertEqual(snapshot.groups[1].windows.map(\.remainingPercent), [0, 100])
        XCTAssertEqual(snapshot.planName, "Google AI Ultra")
        XCTAssertEqual(snapshot.accountID, CodexUsageSupport.hash("synthetic@example.test"))
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("synthetic@example.test"))
    }

    func testUnknownAndDisabledWindowsNeverBecomeUntouchedAllowances() async throws {
        let reading = await collect(result([
            named("Gemini Models", "Session", used: 0, minutes: 300, known: false),
            named("Claude and GPT", "Weekly", used: 0, minutes: 10_080, known: false),
        ]))
        XCTAssertEqual(reading.status, .unavailable)
        let snapshot = try XCTUnwrap(reading.value)
        XCTAssertTrue(snapshot.groups.flatMap(\.windows).allSatisfy { $0.remainingPercent == nil })
    }

    func testSuccessfulPartialPoolResponseDoesNotBorrowPreviousWindows() async throws {
        let previous = await collect(result([
            named("Gemini Models", "Session", used: 20, minutes: 300),
            named("Claude and GPT", "Weekly", used: 10, minutes: 10_080),
        ]))
        let updated = await collect(result([
            named("Gemini Models", "Weekly", used: 70, minutes: 10_080),
        ], account: "replacement@example.test"), previous: previous)
        let snapshot = try XCTUnwrap(updated.value)
        XCTAssertEqual(updated.status, .ready)
        XCTAssertEqual(snapshot.groups[0].windows.map(\.windowSeconds), [604_800])
        XCTAssertEqual(snapshot.groups[0].windows.first?.remainingPercent, 30)
        XCTAssertTrue(snapshot.groups[1].windows.isEmpty)
        XCTAssertNotEqual(snapshot.accountID, previous.value?.accountID)
    }

    func testSuccessfulUnknownResponseClearsOldKnownPool() async throws {
        let previous = await collect(result([named("Gemini", "Weekly", used: 20, minutes: 10_080)]))
        let updated = await collect(result([named("Gemini", "Weekly", used: 0, minutes: 10_080, known: false)]),
                                    previous: previous)
        XCTAssertEqual(updated.status, .unavailable)
        XCTAssertNil(updated.value?.groups.first?.windows.first?.remainingPercent)
    }

    func testResetProseIsPreservedAndPastWindowIsNotCurrentQuota() async throws {
        let reading = await collect(result([
            named("Gemini", "Session", used: 5, minutes: 300, description: "Refills in 4 hours"),
            named("Gemini", "Weekly", used: 90, minutes: 10_080, reset: now),
        ]))
        let windows = try XCTUnwrap(reading.value?.groups.first?.windows)
        XCTAssertEqual(windows[0].resetDescription, "Refills in 4 hours")
        XCTAssertNil(windows[0].resetAt)
        XCTAssertNil(windows[1].remainingPercent)
    }

    func testNonfiniteAndSyntheticWindowCannotPublishPercent() async throws {
        let snapshot = CodexBarCore.UsageSnapshot(primary: window(0, placeholder: true),
            secondary: window(.infinity), updatedAt: now)
        let projected = AntigravityQuotaCollector.project(snapshot, now: now)
        XCTAssertTrue(projected.groups.flatMap(\.windows).allSatisfy { $0.remainingPercent == nil })
    }

    func testLegacyModelAdapterUsesOnlyExplicitRemainingFraction() throws {
        let old = AntigravityStatusSnapshot(modelQuotas: [
            AntigravityModelQuota(label: "Gemini 3 Pro", modelId: "gemini-3-pro-high",
                remainingFraction: 0.42, resetTime: now.addingTimeInterval(300), resetDescription: nil),
            AntigravityModelQuota(label: "Claude Fable", modelId: "claude-fable",
                remainingFraction: nil, resetTime: now.addingTimeInterval(500), resetDescription: "Later"),
        ], accountEmail: nil, accountPlan: nil, source: .local)
        let projected = AntigravityQuotaCollector.project(try old.toUsageSnapshot(), now: now)
        XCTAssertEqual(projected.groups[0].windows.first?.remainingPercent, 42)
        XCTAssertEqual(projected.groups[0].windows.first?.label, "Gemini quota")
        XCTAssertNil(projected.groups[0].windows.first?.windowSeconds)
        XCTAssertTrue(projected.groups[1].windows.allSatisfy { $0.remainingPercent == nil })
    }

    func testTransientFailureRetainsOnlyThirtyMinuteMeasurementCache() async throws {
        let previous = await collect(result([named("Gemini", "Weekly", used: 20, minutes: 10_080)]))
        for (seconds, expected) in [(1_799.0, UsageDataStatus.stale), (1_800.0, .unavailable)] {
            let failed = await AntigravityQuotaCollector.collect(previous: previous,
                now: now.addingTimeInterval(seconds), environment: [:],
                fetch: { _ in throw AntigravityStatusProbeError.timedOut }, cleanup: {})
            XCTAssertEqual(failed.status, expected)
            XCTAssertEqual(failed.value != nil, seconds < 1_800)
            if seconds < 1_800 { XCTAssertEqual(failed.measuredAt, now) }
        }
    }

    func testRepeatedFailureDoesNotExtendCacheDeadline() async throws {
        let original = await collect(result([named("Gemini", "Weekly", used: 20, minutes: 10_080)]))
        let failure: AntigravityQuotaCollector.Fetch = { _ in throw AntigravityStatusProbeError.notRunning }
        let cached = await AntigravityQuotaCollector.collect(previous: original,
            now: now.addingTimeInterval(1_700), environment: [:], fetch: failure, cleanup: {})
        let expired = await AntigravityQuotaCollector.collect(previous: cached,
            now: now.addingTimeInterval(1_801), environment: [:], fetch: failure, cleanup: {})
        XCTAssertNil(expired.value)
        XCTAssertEqual(expired.status, .unavailable)
    }

    func testAuthenticationFailuresImmediatelyRemoveCacheAndSanitizeMessage() async throws {
        let previous = await collect(result([named("Gemini", "Weekly", used: 20, minutes: 10_080)]))
        let errors: [AntigravityStatusProbeError] = [
            .authenticationRequired, .apiError("HTTP 401 synthetic-secret"),
            .apiError("HTTP 403 synthetic-secret"), .accountMismatch(expected: "private", found: "other"),
            .apiError("401"), .apiError("403"), .apiError("UNAUTHENTICATED"),
            .apiError(" permission_denied "), .apiError("16"), .apiError("7"),
        ]
        for error in errors {
            let failed = await AntigravityQuotaCollector.collect(previous: previous,
                now: now.addingTimeInterval(1), environment: [:], fetch: { _ in throw error }, cleanup: {})
            XCTAssertEqual(failed.status, .unauthenticated)
            XCTAssertNil(failed.value)
            XCTAssertFalse(failed.message?.contains("synthetic-secret") == true)
            XCTAssertFalse(failed.message?.contains("private") == true)
        }
    }

    func testOfflineConversationPlaceholderIsNeverReadyQuota() async throws {
        let offline = result([named("Gemini", "Weekly", used: 0, minutes: 10_080)],
                             source: "offline", strategy: "antigravity.offline")
        let reading = await collect(offline)
        XCTAssertEqual(reading.status, .unavailable)
        XCTAssertNil(reading.value)
    }

    func testLocalCSRFChallengeDoesNotInvalidateGoogleLogin() async throws {
        let previous = await collect(result([named("Gemini", "Weekly", used: 20, minutes: 10_080)]))
        for error in [AntigravityStatusProbeError.apiError("HTTP 401: CSRF token required"),
                      .apiError("HTTP 403: invalid csrf token"), .missingCSRFToken] {
            let failed = await AntigravityQuotaCollector.collect(previous: previous,
                now: now.addingTimeInterval(1), environment: [:], fetch: { _ in throw error }, cleanup: {})
            XCTAssertEqual(failed.status, .stale)
            XCTAssertEqual(failed.value, previous.value)
            XCTAssertFalse(failed.message?.localizedCaseInsensitiveContains("login") == true)
        }
    }

    func testNonAuthenticationBusinessCodesRemainTransientFailures() async throws {
        let previous = await collect(result([named("Gemini", "Weekly", used: 20, minutes: 10_080)]))
        for code in ["429", "RESOURCE_EXHAUSTED", "UNAVAILABLE", "HTTP 503: authentication service unavailable"] {
            let failed = await AntigravityQuotaCollector.collect(previous: previous,
                now: now.addingTimeInterval(1), environment: [:],
                fetch: { _ in throw AntigravityStatusProbeError.apiError(code) }, cleanup: {})
            XCTAssertEqual(failed.status, .stale)
            XCTAssertEqual(failed.value, previous.value)
        }
    }

    func testLocalPipelineCannotHideAuthenticationFailureBehindOfflineOrOAuthSuccess() async throws {
        let log = AttemptLog()
        let placeholder = result([], source: "offline", strategy: "antigravity.offline")
        let strategies: [any ProviderFetchStrategy] = [
            Strategy(id: "antigravity.app-local", kind: .localProbe, error: .authenticationRequired,
                     result: placeholder, log: log),
            Strategy(id: "antigravity.ide-local", kind: .localProbe, error: .notRunning,
                     result: placeholder, log: log),
            Strategy(id: "antigravity.offline", kind: .localProbe, error: nil, result: placeholder, log: log),
            Strategy(id: "antigravity.oauth", kind: .oauth, error: nil, result: placeholder, log: log),
        ]
        let upstream = ProviderFetchPipeline(resolveStrategies: { _ in strategies })
        let context = AntigravityQuotaCollector.localContext(environment: [:])
        XCTAssertEqual(context.sourceMode, .cli)
        XCTAssertFalse(context.persistsCLISessions)
        XCTAssertFalse(context.includeCredits)
        let outcome = await AntigravityQuotaCollector.localPipeline(from: upstream)
            .fetch(context: context, provider: .antigravity)
        switch outcome.result {
        case .success: XCTFail("An offline or OAuth success must not replace authentication failure")
        case .failure(let error): XCTAssertEqual(error as? AntigravityStatusProbeError, .authenticationRequired)
        }
        let attempted = await log.ids
        XCTAssertEqual(attempted, ["antigravity.app-local", "antigravity.ide-local"])
    }

    func testCleanupRunsOnSuccessFailureAndCancellation() async throws {
        let counter = CleanupCount()
        let cleanup: AntigravityQuotaCollector.Cleanup = { await counter.increment() }
        let success = result([named("Gemini", "Weekly", used: 20, minutes: 10_080)])
        _ = await AntigravityQuotaCollector.collect(previous: empty, now: now, environment: [:],
            fetch: { _ in success }, cleanup: cleanup)
        _ = await AntigravityQuotaCollector.collect(previous: empty, now: now, environment: [:],
            fetch: { _ in throw AntigravityStatusProbeError.timedOut }, cleanup: cleanup)
        let cancelled = await AntigravityQuotaCollector.collect(previous: empty, now: now, environment: [:],
            fetch: { _ in throw CancellationError() }, cleanup: cleanup)
        let calls = await counter.count
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(cancelled.status, .unavailable)
        XCTAssertNil(cancelled.value)
    }

    func testOwnedCLIAdapterReplacesOnlyTheCLIStepInThePublicPipeline() async throws {
        let log = AttemptLog()
        let good = result([named("Gemini", "Weekly", used: 20, minutes: 10_080)],
                          source: "cli", strategy: "antigravity.cli-csrf")
        let strategies: [any ProviderFetchStrategy] = [
            Strategy(id: "antigravity.app-local", kind: .localProbe, error: .notRunning,
                     result: good, log: log),
            Strategy(id: "antigravity.cli-https", kind: .cli, error: .missingCSRFToken,
                     result: good, log: log),
            Strategy(id: "antigravity.ide-local", kind: .localProbe, error: .notRunning,
                     result: good, log: log),
        ]
        let replacement = Strategy(id: "antigravity.cli-csrf", kind: .cli, error: nil,
                                   result: good, log: log)
        let outcome = await AntigravityQuotaCollector.localPipeline(
            from: ProviderFetchPipeline(resolveStrategies: { _ in strategies }), managedCLI: replacement)
            .fetch(context: AntigravityQuotaCollector.localContext(environment: [:]), provider: .antigravity)
        XCTAssertEqual(try outcome.result.get().strategyID, "antigravity.cli-csrf")
        let attempted = await log.ids
        XCTAssertEqual(attempted, ["antigravity.app-local", "antigravity.cli-csrf"])
    }

    func testUnavailableIDEFallbackDoesNotHideCLIInitializationFailure() async {
        let log = AttemptLog()
        let placeholder = result([])
        let strategies: [any ProviderFetchStrategy] = [
            Strategy(id: "antigravity.app-local", kind: .localProbe, error: .notRunning,
                     result: placeholder, log: log),
            Strategy(id: "antigravity.cli-https", kind: .cli, error: .portDetectionFailed("Synthetic CLI initialization"),
                     result: placeholder, log: log),
            Strategy(id: "antigravity.ide-local", kind: .localProbe, error: .notRunning,
                     result: placeholder, log: log),
        ]
        let upstream = ProviderFetchPipeline(resolveStrategies: { _ in strategies })
        let outcome = await AntigravityQuotaCollector.localPipeline(from: upstream)
            .fetch(context: AntigravityQuotaCollector.localContext(environment: [:]), provider: .antigravity)
        switch outcome.result {
        case .success: XCTFail("A missing service cannot certify quota")
        case .failure(let error): XCTAssertEqual(error as? AntigravityStatusProbeError,
                                                 .portDetectionFailed("Synthetic CLI initialization"))
        }
    }

    func testDiagnosticsDoNotExposeUpstreamBodiesOrAccountDetails() {
        let secret = "private-token synthetic@example.test https://example.test/?token=secret"
        let outcome = ProviderFetchOutcome(result: .failure(AntigravityStatusProbeError.apiError(secret)), attempts: [
            ProviderFetchAttempt(strategyID: "antigravity.cli-https", kind: .cli, wasAvailable: true,
                                 errorDescription: secret)
        ])
        let text = AntigravityQuotaCollector.diagnostics(outcome)
        XCTAssertTrue(text.contains("antigravity.cli-https:available=true,failed=true"))
        XCTAssertFalse(text.contains("private-token"))
        XCTAssertFalse(text.contains("example.test"))
        XCTAssertFalse(text.contains("https://"))
    }
}
