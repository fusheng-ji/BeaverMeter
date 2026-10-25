import CodexBarCore
import Darwin
import Foundation
import XCTest

final class ClaudeCollectionTests: XCTestCase {
    private var now: Date {
        ISO8601DateFormatter().date(from: "2026-09-23T12:00:00Z")!
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("beavermeter-claude-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func usage(_ json: String) throws -> ClaudeOAuthUsageResponse {
        try JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: Data(json.utf8))
    }

    func testFiveHourWindowIsTheHeadlineEvenWhenAWeekIsTighter() throws {
        let response = try usage("""
        {"five_hour":{"utilization":38,"resets_at":"2026-09-23T15:00:00.000000+00:00"},
         "seven_day":{"utilization":12.5,"resets_at":"2026-09-27T00:00:00Z"},
         "seven_day_opus":{"utilization":71,"resets_at":"2026-09-27T00:00:00Z"},
         "seven_day_sonnet":null}
        """)
        let quota = try XCTUnwrap(ClaudeQuotaCollector.quota(from: response))
        XCTAssertEqual(quota.label, "Claude 5h")
        XCTAssertEqual(quota.remainingPercent, 62)
        XCTAssertEqual(quota.windowSeconds, 18_000)
        let opus = try XCTUnwrap(quota.windows?.last)
        XCTAssertEqual(opus.label, "Claude Opus Week")
        XCTAssertEqual(opus.remainingPercent, 29)
        XCTAssertEqual(opus.resetAt, ISO8601DateFormatter().date(from: "2026-09-27T00:00:00Z"))
        XCTAssertEqual(quota.otherWindowsSummary(), "Weekly 88% · Opus 29%")
        XCTAssertEqual(quota.otherWindowsSummary(short: true), "Wk 88% · Opus 29%")
    }

    func testScopedWeeklyLimitsAddFableAndKeepDisplayOrder() throws {
        let response = try usage("""
        {"five_hour":{"utilization":28,"resets_at":"2026-09-23T15:00:00.282668+00:00"},
         "seven_day":{"utilization":12,"resets_at":"2026-09-27T09:00:00.282694+00:00"},
         "seven_day_opus":null,
         "limits":[
           {"kind":"session","group":"session","percent":28,"resets_at":null,"scope":null,"is_active":true},
           {"kind":"weekly_all","group":"weekly","percent":12,"resets_at":null,"scope":null,"is_active":false},
           {"kind":"weekly_scoped","group":"weekly","percent":5,"resets_at":"2026-09-27T09:00:00.283070+00:00",
            "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false},
           {"kind":"weekly_scoped","group":"weekly","percent":50,"resets_at":null,
            "scope":{"model":{"id":"all-models","display_name":"All models"}},"is_active":false},
           {"kind":"weekly_scoped","group":"weekly","percent":1,"resets_at":null,
            "scope":{"model":null},"is_active":false}
         ]}
        """)
        let quota = try XCTUnwrap(ClaudeQuotaCollector.quota(from: response))
        XCTAssertEqual(quota.label, "Claude 5h")
        let windows = try XCTUnwrap(quota.windows)
        XCTAssertEqual(windows.map(\.label), ["Claude 5h", "Claude Week", "Claude Fable Week"])
        XCTAssertEqual(windows.map(\.remainingPercent), [72, 88, 95])
        XCTAssertNotNil(windows[2].resetAt, "six-digit fractional seconds must parse")
        XCTAssertEqual(windows[2].modelScope, "Fable")
        XCTAssertEqual(windows[2].windowTitle, "Fable weekly")
        XCTAssertEqual(quota.otherWindows.map(\.shortWindowName), ["Wk", "Fable"])
    }

    func testLimitsFillMissingFlatWindowsWithoutDuplicates() throws {
        let response = try usage("""
        {"seven_day_opus":{"utilization":40,"resets_at":null},
         "limits":[
           {"kind":"session","percent":10,"resets_at":null},
           {"kind":"weekly_all","percent":20,"resets_at":null},
           {"kind":"weekly_scoped","percent":40,"resets_at":null,"scope":{"model":{"display_name":"Opus"}}}
         ]}
        """)
        let quota = try XCTUnwrap(ClaudeQuotaCollector.quota(from: response))
        XCTAssertEqual(quota.windows?.map(\.label), ["Claude 5h", "Claude Week", "Claude Opus Week"])
        XCTAssertEqual(quota.label, "Claude 5h")
    }

    func testTightestWindowIsTheHeadlineWithoutAFiveHourWindow() throws {
        let quota = try XCTUnwrap(ClaudeQuotaCollector.quota(from: usage("""
        {"seven_day":{"utilization":20},"seven_day_opus":{"utilization":60}}
        """)))
        XCTAssertEqual(quota.label, "Claude Opus Week")
    }

    func testSingleWindowHasNoBreakdown() throws {
        let quota = try XCTUnwrap(ClaudeQuotaCollector.quota(from: usage(#"{"five_hour":{"utilization":10}}"#)))
        XCTAssertNil(quota.windows)
    }

    func testFiveHourWindowAndOverLimitClamp() throws {
        let response = try usage("""
        {"five_hour":{"utilization":104,"resets_at":"2026-09-23T15:00:00Z"},
         "seven_day":{"utilization":40,"resets_at":null}}
        """)
        let quota = try XCTUnwrap(ClaudeQuotaCollector.quota(from: response))
        XCTAssertEqual(quota.label, "Claude 5h")
        XCTAssertEqual(quota.remainingPercent, 0)
        XCTAssertEqual(quota.windowSeconds, 18_000)
    }

    func testResponseWithoutWindowsHasNoQuota() throws {
        XCTAssertNil(ClaudeQuotaCollector.quota(from: try usage(#"{"five_hour":null}"#)))
    }

    func testCredentialsRequireAnUnexpiredAccessToken() throws {
        let future = (now.timeIntervalSince1970 + 3_600) * 1_000
        let past = (now.timeIntervalSince1970 - 60) * 1_000
        XCTAssertEqual(
            try ClaudeQuotaCollector.accessToken(
                fromCredentials: Data(#"{"claudeAiOauth":{"accessToken":" demo ","expiresAt":\#(future)}}"#.utf8),
                now: now
            ),
            "demo"
        )
        XCTAssertThrowsError(try ClaudeQuotaCollector.accessToken(
            fromCredentials: Data(#"{"claudeAiOauth":{"accessToken":"demo","expiresAt":\#(past)}}"#.utf8), now: now
        )) { XCTAssertEqual($0 as? ClaudeQuotaError, .expired) }
        XCTAssertThrowsError(try ClaudeQuotaCollector.accessToken(
            fromCredentials: Data(#"{"mcpOAuth":{}}"#.utf8), now: now
        )) { XCTAssertEqual($0 as? ClaudeQuotaError, .notLoggedIn) }
    }

    func testRefreshTokenAvailabilityDistinguishesRepairableAndSignedOutStores() {
        XCTAssertTrue(ClaudeQuotaCollector.hasRefreshToken(inCredentials:
            Data(#"{"claudeAiOauth":{"accessToken":"","refreshToken":" synthetic-refresh "}}"#.utf8)))
        for json in [#"{"claudeAiOauth":{"accessToken":"","refreshToken":" "}}"#,
                     #"{"mcpOAuth":{}}"#, "invalid"] {
            XCTAssertFalse(ClaudeQuotaCollector.hasRefreshToken(inCredentials: Data(json.utf8)))
        }
    }

    func testRenewalEnvironmentUsesStoredLoginAndKeepsTheSelectedProfile() {
        let result = ClaudeSignInRenewer.loginEnvironment([
            "CLAUDE_CONFIG_DIR": "/synthetic/profile", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/synthetic/storage",
            "CLAUDE_CODE_OAUTH_TOKEN": "synthetic-setup-token", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR": "3",
            "ANTHROPIC_API_KEY": "synthetic-api-key", "ANTHROPIC_AUTH_TOKEN": "synthetic-auth",
            "ANTHROPIC_BASE_URL": "https://synthetic.invalid", "OTHER": "kept"])
        XCTAssertEqual(result["CLAUDE_CONFIG_DIR"], "/synthetic/profile")
        XCTAssertEqual(result["CLAUDE_SECURESTORAGE_CONFIG_DIR"], "/synthetic/storage")
        XCTAssertEqual(result["OTHER"], "kept")
        XCTAssertEqual(result["DISABLE_AUTOUPDATER"], "1")
        XCTAssertFalse(result.keys.contains(where: { $0.hasPrefix("ANTHROPIC_") || $0.hasPrefix("CLAUDE_CODE_OAUTH_TOKEN") }))
    }

    func testRenewalWorkingDirectoryPreservesRelativeAndEmptyProfileRoots() {
        let preferred = URL(fileURLWithPath: "/synthetic/private", isDirectory: true)
        let caller = URL(fileURLWithPath: "/synthetic/caller", isDirectory: true)
        for environment in [[String: String](), ["CLAUDE_CONFIG_DIR": "/absolute/profile"],
                            ["CLAUDE_CONFIG_DIR": "/absolute/profile", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/absolute/storage"]] {
            XCTAssertEqual(ClaudeSignInRenewer.renewalWorkingDirectory(preferred: preferred, environment: environment,
                                                                      callerDirectory: caller), preferred)
        }
        for key in ["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR"] {
            for value in ["", "relative/profile", "./profile", "../profile"] {
                XCTAssertEqual(ClaudeSignInRenewer.renewalWorkingDirectory(preferred: preferred,
                    environment: [key: value], callerDirectory: caller), caller)
            }
        }
    }

    func testStatusFallbackRequiresNormalPromptAndNeverAnswersTrustOrOnboarding() {
        XCTAssertTrue(ClaudeSignInRenewer.statusInputIsReady("\u{1B}[32m❯\u{1B}[0m \n? for shortcuts"))
        XCTAssertTrue(ClaudeSignInRenewer.statusInputIsReady("❯ Try \"how does this work?\"\n? for shortcuts"))
        for prompt in ["❯ Yes, I trust this folder\n? for shortcuts",
                       "Quick safety check:\n❯\n? for shortcuts",
                       "Press Enter to continue\n❯\n? for shortcuts", "❯", "Select login method"] {
            XCTAssertFalse(ClaudeSignInRenewer.statusInputIsReady(prompt), prompt)
        }
    }

    func testRenewerOnlySendsFixedStatusAfterReady() throws {
        let root = try workspace(), script = root.appendingPathComponent("fake-claude")
        let marker = root.appendingPathComponent("input")
        try Data("""
        #!/bin/sh
        printf '❯ \\n? for shortcuts\\n'
        IFS= read -r command
        printf '%s' "$command" > "$RENEWAL_TEST_MARKER"
        /bin/sleep 10
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        XCTAssertTrue(ClaudeSignInRenewer.renew(cli: script, workingDirectory: root, timeout: 3,
                                              environment: ["RENEWAL_TEST_MARKER": marker.path]) {
            FileManager.default.fileExists(atPath: marker.path)
        })
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "/status")
    }

    func testQuotaFailureKeepsPreviousValueAsStale() async throws {
        let previous = UsageValue(status: .ready, source: .accountAPI, measuredAt: now.addingTimeInterval(-300),
                                  lastAttemptAt: now.addingTimeInterval(-300), message: nil,
                                  value: UsageSnapshot.preview.claudeQuota.value)
        let result = await ClaudeQuotaCollector.collect(
            previous: previous, now: now,
            environment: ["CLAUDE_USAGE_FIXTURE": try workspace().appendingPathComponent("missing.json").path]
        )
        XCTAssertEqual(result.status, .stale)
        XCTAssertEqual(result.source, .cache)
        let expected = ClaudeQuotaVisibility.quota(previous, relativeTo: now)
        XCTAssertEqual(result.value, expected.value)
        XCTAssertFalse(result.value?.windows?.contains(where: { $0.resetAt.map { $0 <= now } == true }) == true)
        XCTAssertTrue(result.message?.hasPrefix("Claude quota refresh failed") == true)
    }

    func testTokenTotalsIncludeBothCacheCounters() throws {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-09-23", inputTokens: 200, outputTokens: 100, cacheReadTokens: 1_900,
            cacheCreationTokens: 300, totalTokens: 2_500, requestCount: 7, costUSD: 0.0123,
            modelsUsed: ["claude-sonnet-4-5"], modelBreakdowns: nil
        )
        let totals = try ClaudeTokenCollector.totals(from: entry)
        XCTAssertEqual(totals.totalTokens, 2_500)
        XCTAssertEqual(totals.cacheCreationTokens, 300)
        XCTAssertEqual(totals.cacheReadTokens, 1_900)
        XCTAssertEqual(totals.costUSD, 0.0123)

        let zero = try ClaudeTokenCollector.totals(from: nil)
        XCTAssertEqual(zero.totalTokens, 0)
        XCTAssertNil(zero.costUSD)
    }

    func testMissingClaudeHomeIsUnavailableRatherThanZero() async throws {
        let root = try workspace()
        let configured = ["CLAUDE_CONFIG_DIR": root.path]
        XCTAssertFalse(ClaudeTokenCollector.projectsRootExists(environment: configured))
        XCTAssertFalse(ClaudeTokenCollector.projectsRootExists(environment: [:], homeDirectory: root))

        let result = await ClaudeTokenCollector.collect(
            previous: .unavailable("none"), now: now, cacheRoot: root.appendingPathComponent("cache"),
            environment: configured
        )
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertNil(result.value)

        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude/projects"),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(ClaudeTokenCollector.projectsRootExists(environment: [:], homeDirectory: root))
    }

    func testTokenFixtureIsReportedAsLiveLocalUsage() async throws {
        let fixture = try workspace().appendingPathComponent("tokens.json")
        let totals = try XCTUnwrap(UsageSnapshot.preview.claudeTokens.value)
        try JSONEncoder().encode(totals).write(to: fixture)
        let result = await ClaudeTokenCollector.collect(
            previous: .unavailable("none"), now: now, cacheRoot: fixture.deletingLastPathComponent(),
            environment: ["CLAUDE_TOKEN_FIXTURE": fixture.path]
        )
        XCTAssertEqual(result.status, .ready)
        XCTAssertEqual(result.source, .codexBarLocal)
        XCTAssertEqual(result.value, totals)
    }

    func testSignInRenewerFindsTheCLIAndHonoursOptOuts() throws {
        let home = try workspace()
        XCTAssertFalse(ClaudeSignInRenewer.cliURL(environment: [:], homeDirectory: home)?.path.hasPrefix(home.path) ?? false)
        let cli = home.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cli.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(ClaudeSignInRenewer.cliURL(environment: [:], homeDirectory: home), cli)
        XCTAssertNil(ClaudeSignInRenewer.cliURL(environment: ["CLAUDE_CLI_PATH": home.appendingPathComponent("none").path],
                                                homeDirectory: home))

        XCTAssertTrue(ClaudeSignInRenewer.isAllowed(environment: [:]))
        XCTAssertFalse(ClaudeSignInRenewer.isAllowed(environment: ["CLAUDE_CLI_REFRESH": "0"]))
        XCTAssertFalse(ClaudeSignInRenewer.isAllowed(environment: ["CLAUDE_KEYCHAIN_ACCESS": "0"]))
    }

    func testSignInRenewalIsLimitedToOneAttemptPerCooldown() throws {
        let state = try workspace().appendingPathComponent("refresh.json")
        XCTAssertTrue(ClaudeSignInRenewer.reserveAttempt(stateURL: state, now: now))
        XCTAssertFalse(ClaudeSignInRenewer.reserveAttempt(stateURL: state, now: now.addingTimeInterval(60)))
        XCTAssertTrue(ClaudeSignInRenewer.reserveAttempt(stateURL: state, now: now.addingTimeInterval(301)))
        // A clock moved backwards does not block renewal indefinitely.
        XCTAssertTrue(ClaudeSignInRenewer.reserveAttempt(stateURL: state, now: now))
    }

    func testRenewalCooldownIsIndependentForEachCredentialProfile() throws {
        let directory = try workspace()
        let first = try ClaudeSignInRenewer.refreshStateURL(stateDirectory: directory,
                                                            environment: ["CLAUDE_CONFIG_DIR": "/synthetic/first"])
        let other = try ClaudeSignInRenewer.refreshStateURL(stateDirectory: directory,
                                                            environment: ["CLAUDE_CONFIG_DIR": "/synthetic/other"])
        XCTAssertNotEqual(first, other)
        XCTAssertTrue(ClaudeSignInRenewer.reserveAttempt(stateURL: first, now: now))
        XCTAssertTrue(ClaudeSignInRenewer.reserveAttempt(stateURL: other, now: now.addingTimeInterval(1)))
        XCTAssertFalse(ClaudeSignInRenewer.reserveAttempt(stateURL: first, now: now.addingTimeInterval(2)))
        XCTAssertFalse(ClaudeSignInRenewer.reserveAttempt(stateURL: other, now: now.addingTimeInterval(2)))
    }

    func testSignInRenewalStopsTheCLIOnceRenewed() throws {
        let script = try workspace().appendingPathComponent("fake-claude")
        FileManager.default.createFile(atPath: script.path, contents: Data("#!/bin/sh\nsleep 30\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        var checks = 0
        let started = Date()
        XCTAssertTrue(ClaudeSignInRenewer.renew(cli: script, workingDirectory: script.deletingLastPathComponent(),
                                                timeout: 10) { checks += 1; return checks >= 2 })
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertFalse(ClaudeSignInRenewer.renew(cli: script, workingDirectory: script.deletingLastPathComponent(),
                                                 timeout: 1) { false })
    }

    func testAlreadyCancelledRenewalNeverStartsTheCLI() throws {
        let root = try workspace(), script = root.appendingPathComponent("fake-claude")
        let marker = root.appendingPathComponent("launched")
        try Data("#!/bin/sh\nprintf launched > \"$RENEWAL_TEST_MARKER\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let cancellation = SubprocessCancellation()
        cancellation.cancel()
        XCTAssertFalse(ClaudeSignInRenewer.renew(cli: script, workingDirectory: root, timeout: 2,
            environment: ["RENEWAL_TEST_MARKER": marker.path], cancellation: cancellation) {
                XCTFail("A cancelled renewal must not read credentials again.")
                return false
            })
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testActiveCancellationStopsCLIThatIgnoresTerminationWhileCredentialReadBlocks() throws {
        let root = try workspace(), script = root.appendingPathComponent("fake-claude")
        let marker = root.appendingPathComponent("pid")
        try Data("""
        #!/bin/sh
        trap '' TERM
        printf '%s' "$$" > "$RENEWAL_TEST_PID"
        while :; do :; done
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let cancellation = SubprocessCancellation()
        let readingStarted = DispatchSemaphore(value: 0)
        let cancelled = expectation(description: "Cancel while credentials are being read")
        DispatchQueue.global().async {
            if readingStarted.wait(timeout: .now() + 3) == .success { cancellation.cancel() }
            cancelled.fulfill()
        }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(ClaudeSignInRenewer.renew(cli: script, workingDirectory: root, timeout: 10,
            environment: ["RENEWAL_TEST_PID": marker.path], cancellation: cancellation) {
                readingStarted.signal()
                // The cancellation callback must kill the child even though a
                // credential read currently prevents the poll from advancing.
                Thread.sleep(forTimeInterval: 1)
                return false
            })
        wait(for: [cancelled], timeout: 1)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
