import CodexBarCore
import Foundation
import XCTest

final class AccountHistoryTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return value
    }
    private let now = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("beavermeter-history-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func auth(_ id: String, home: URL, email: String? = nil, plan: String? = nil) throws {
        var tokens = ["access_token": "demo-access", "refresh_token": "demo-refresh", "account_id": id]
        if let email {
            let claims: [String: Any] = ["email": email, "https://api.openai.com/auth":
                ["chatgpt_account_id": id, "chatgpt_plan_type": plan ?? "pro"]]
            let encoded = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            tokens["id_token"] = "demo.\(encoded).demo"
        }
        try writeJSON(["tokens": tokens],
                      to: home.appendingPathComponent("auth.json"))
    }

    private func record(_ id: String, date: String, input: Int = 100) -> String {
        let object: [String: Any] = ["type": "token_usage_record", "timestamp": date,
            "payload": ["response_id": id, "session_id": id,
                        "usage": ["input_tokens": input, "cached_input_tokens": 30,
                                  "output_tokens": 20, "reasoning_output_tokens": 10]]]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! + "\n"
    }

    func testProfileConfigurationUsesCodexBarFormatAndDeduplicatesPaths() throws {
        let root = try workspace(), ambient = root.appendingPathComponent("ambient")
        try writeJSON(["version": 1, "providers": [["id": "codex", "codexProfileHomePaths":
            [ambient.path, ambient.appendingPathComponent("../ambient").path, root.appendingPathComponent("work").path]]]],
            to: root.appendingPathComponent("beaver-meter-accounts.json"))
        let configuration = CodexAccountConfiguration.load(directory: root, environment: ["CODEX_HOME": ambient.path])
        XCTAssertEqual(configuration.homes, [ambient.path, root.appendingPathComponent("work").path])
        XCTAssertNil(configuration.message)
        try writeJSON(["version": 999, "providers": []], to: root.appendingPathComponent("beaver-meter-accounts.json"))
        XCTAssertNotNil(CodexAccountConfiguration.load(directory: root, environment: ["CODEX_HOME": ambient.path]).message)
    }

    func testAccountFailuresAreIsolatedAndIdentityChangesDiscardCache() async throws {
        let root = try workspace(), home = root.appendingPathComponent("work")
        try await CodexCredentialFileAccess.withFixtureScope(.init(roots: [root])) {
        try auth("workspace-a", home: home)
        let quota = root.appendingPathComponent("quota.json")
        try writeJSON(["rate_limit": ["primary_window": ["used_percent": 10, "limit_window_seconds": 18000],
                                    "secondary_window": ["used_percent": 30, "limit_window_seconds": 604800]]], to: quota)
        let cards = root.appendingPathComponent("cards.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ResetCardInventory(availableCount: 2, observedAt: now, batches: [])).write(to: cards)
        var environment = ["CODEX_USAGE_FIXTURE": quota.path, "CODEX_RESET_CARDS_FIXTURE": cards.path]
        let configuration = CodexAccountConfiguration(homes: [home.path, root.appendingPathComponent("missing").path], message: nil)
        let initial = await CodexAccountsCollector.collect(configuration: configuration, previous: .unavailable("none"),
                                                            now: now, environment: environment)
        let accounts = try XCTUnwrap(initial.value)
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(accounts[0].quota.value?.windows?.count, 2)
        XCTAssertEqual(accounts[0].resetCards.value?.availableCount, 2)
        XCTAssertEqual(accounts[1].quota.status, .unauthenticated)
        environment["CODEX_USAGE_FIXTURE"] = root.appendingPathComponent("invalid.json").path
        let stale = await CodexAccountsCollector.collectAccount(home: home.path, previous: accounts, now: now, environment: environment)
        XCTAssertEqual(stale.quota.status, .stale)
        XCTAssertEqual(stale.resetCards.status, .ready)
        try auth("workspace-b", home: home)
        let changed = await CodexAccountsCollector.collectAccount(home: home.path, previous: accounts, now: now, environment: environment)
        XCTAssertNotEqual(changed.id, accounts[0].id)
        XCTAssertNil(changed.quota.value)
        let projected = await CodexAccountsCollector.defaultQuota(
            accounts: UsageValue(status: .ready, source: .accountAPI, measuredAt: now,
                                 lastAttemptAt: now, message: nil, value: [changed]),
            previous: accounts[0].quota, now: now, environment: ["CODEX_HOME": home.path]
        )
        XCTAssertNil(projected.value, "The original summary must not borrow the previous identity either.")
        try FileManager.default.removeItem(at: home.appendingPathComponent("auth.json"))
        let missing = await CodexAccountsCollector.collectAccount(home: home.path, previous: accounts, now: now, environment: environment)
        XCTAssertNil(missing.resetCards.value)
        }
    }

    func testSameLoginWorkspacesHaveIndependentPlansUsageAndCaches() async throws {
        let root = try workspace(), home = root.appendingPathComponent("login")
        try await CodexCredentialFileAccess.withFixtureScope(.init(roots: [root])) {
            try auth("personal", home: home, email: "same@example.test", plan: "pro")
            let originalAuth = try Data(contentsOf: home.appendingPathComponent("auth.json"))
            let fixture = root.appendingPathComponent("usage.json")
            func response(_ id: String, plan: String, used: Int) throws {
                try writeJSON(["account_id": id, "plan_type": plan, "rate_limit": [
                    "primary_window": ["used_percent": used, "limit_window_seconds": 604800]]], to: fixture)
            }
            let environment = ["CODEX_USAGE_FIXTURE": fixture.path]
            let personalProfile = CodexWorkspaceProfile(home: home.path, workspaceAccountID: "personal", workspaceLabel: "Personal")
            let teamProfile = CodexWorkspaceProfile(home: home.path, workspaceAccountID: "team", workspaceLabel: "Research")
            try response("personal", plan: "pro", used: 20)
            let personal = await CodexAccountsCollector.collectWorkspace(profile: personalProfile, previous: [], now: now, environment: environment)
            try response("team", plan: "business", used: 70)
            let team = await CodexAccountsCollector.collectWorkspace(profile: teamProfile, previous: [personal], now: now, environment: environment)
            XCTAssertEqual(personal.accountName, team.accountName)
            XCTAssertEqual(personal.homeID, team.homeID)
            XCTAssertNotEqual(personal.id, team.id)
            XCTAssertEqual(personal.planName, "Pro")
            XCTAssertEqual(team.planName, "Business")
            XCTAssertEqual(personal.quota.value?.remainingPercent, 80)
            XCTAssertEqual(team.quota.value?.remainingPercent, 30)
            let failed = await CodexAccountsCollector.collectWorkspace(profile: teamProfile, previous: [personal, team], now: now,
                environment: ["CODEX_USAGE_FIXTURE": fixture.path + ".missing"])
            XCTAssertEqual(failed.quota.status, .stale)
            XCTAssertEqual(failed.quota.value?.remainingPercent, 30)
            XCTAssertEqual(failed.planName, "Business")
            let newWorkspace = await CodexAccountsCollector.collectWorkspace(
                profile: CodexWorkspaceProfile(home: home.path, workspaceAccountID: "other"), previous: [personal, team], now: now,
                environment: ["CODEX_USAGE_FIXTURE": fixture.path + ".missing"])
            XCTAssertNil(newWorkspace.quota.value)
            XCTAssertNil(newWorkspace.planName)
            XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("auth.json")), originalAuth)
            let credentials = try CodexOAuthCredentialsStore.loadOAuthTokens(env: ["CODEX_HOME": home.path])
            XCTAssertEqual(credentials.accountId, "personal", "Monitoring must not switch the login's workspace.")
            let request = CodexQuotaCollector.usageRequest(credentials: credentials, workspaceAccountID: "team")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "team")
        }
    }

    func testWorkspaceOverrideRejectsDefaultAndUnidentifiedResponses() async throws {
        let root = try workspace(), home = root.appendingPathComponent("login")
        try await CodexCredentialFileAccess.withFixtureScope(.init(roots: [root])) {
            try auth("personal", home: home, email: "same@example.test")
            let fixture = root.appendingPathComponent("usage.json")
            for id in ["personal", ""] {
                var response: [String: Any] = ["plan_type": "pro", "rate_limit": [
                    "primary_window": ["used_percent": 20, "limit_window_seconds": 604800]]]
                if !id.isEmpty { response["account_id"] = id }
                try writeJSON(response, to: fixture)
                let result = await CodexAccountsCollector.collectWorkspace(
                    profile: CodexWorkspaceProfile(home: home.path, workspaceAccountID: "team"), previous: [], now: now,
                    environment: ["CODEX_USAGE_FIXTURE": fixture.path])
                XCTAssertNil(result.quota.value, "Never label Personal's usage as Team's.")
                XCTAssertNil(result.resetCards.value)
                XCTAssertNil(result.planName)
            }
        }
    }

    func testConfigurationUsesOwnWorkspaceRegistryAndDeduplicatesLogHomes() throws {
        let root = try workspace(), home = root.appendingPathComponent("login")
        try CodexCredentialFileAccess.withFixtureScope(.init(roots: [root])) {
            try auth("personal", home: home, email: "same@example.test")
            let store = CodexWorkspaceStore(directory: root)
            let teamID = UUID(), secondID = UUID()
            let team = store.home(for: teamID)
            try store.save(CodexWorkspaceLogin(id: teamID, label: "Team", workspaceAccountID: "business"))
            try store.save(CodexWorkspaceLogin(id: secondID, label: "Second", workspaceAccountID: "second"))
            try writeJSON(["version": 1, "providers": [], "codexWorkspaces": [
                ["home": team.path, "workspaceAccountID": "business", "workspaceLabel": "Duplicate"]]],
                to: root.appendingPathComponent("beaver-meter-accounts.json"))
            let config = CodexAccountConfiguration.load(directory: root, environment: ["CODEX_HOME": home.path])
            XCTAssertNil(config.message)
            XCTAssertEqual(config.homes, [home.path, team.path, store.home(for: secondID).path])
            XCTAssertEqual(config.profiles.count, 3)
            XCTAssertEqual(config.profiles.first?.home, home.path)
            XCTAssertEqual(config.workspaces.first?.workspaceLabel, "Team")
            XCTAssertEqual(config.workspaces.first?.loginProfileID, teamID)
        }
    }

    func testOwnWorkspaceLoginStoresPrivateCredentialsWithoutChangingAmbientLogin() throws {
        let root = try workspace(), ambient = root.appendingPathComponent("ambient")
        try CodexCredentialFileAccess.withFixtureScope(.init(roots: [root])) {
            try auth("personal", home: ambient)
            let original = try Data(contentsOf: ambient.appendingPathComponent("auth.json"))
            let fixtureHome = root.appendingPathComponent("fixture")
            try auth("team", home: fixtureHome, email: "same@example.test", plan: "team")
            let cli = root.appendingPathComponent("codex")
            try """
            #!/bin/sh
            printf '%s\\n' "$CODEX_HOME" > "$BEAVERMETER_LOGIN_CAPTURE"
            cp "$BEAVERMETER_LOGIN_FIXTURE" "$CODEX_HOME/auth.json"
            """.write(to: cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
            let id = UUID(), capture = root.appendingPathComponent("capture")
            let store = CodexWorkspaceStore(directory: root)
            try CodexWorkspaceLoginCollector.run(id: id, label: "Research", directory: root, environment: [
                "CODEX_HOME": ambient.path, "PATH": "/usr/bin:/bin",
                "BEAVERMETER_LOGIN_CAPTURE": capture.path, "BEAVERMETER_LOGIN_FIXTURE": fixtureHome.appendingPathComponent("auth.json").path
            ], executableOverride: cli)
            XCTAssertEqual(try store.load(), [CodexWorkspaceLogin(id: id, label: "Research", workspaceAccountID: "team")])
            XCTAssertEqual(try String(contentsOf: capture).trimmingCharacters(in: .whitespacesAndNewlines), store.home(for: id).path)
            XCTAssertEqual(try Data(contentsOf: ambient.appendingPathComponent("auth.json")), original)
            for (url, mode) in [(store.metadataURL, 0o600), (store.home(for: id), 0o700),
                                (store.home(for: id).appendingPathComponent("auth.json"), 0o600)] {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, mode)
            }
            XCTAssertFalse(try String(contentsOf: store.metadataURL).contains("demo-access"))
        }
    }

    func testFailedOwnWorkspaceLoginDoesNotRegisterProfileOrExposeOAuthOutput() throws {
        let root = try workspace(), cli = root.appendingPathComponent("codex")
        try "#!/bin/sh\nprintf 'https://example.test/?secret=oauth-code' >&2\nexit 1\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        XCTAssertThrowsError(try CodexWorkspaceLoginCollector.run(id: UUID(), label: "Team", directory: root, executableOverride: cli)) {
            XCTAssertEqual($0 as? CodexWorkspaceLoginCollector.LoginError,
                .cliFailed(1, "Browser sign-in did not complete. Try again with a new sign-in request."))
            XCTAssertFalse($0.localizedDescription.contains("oauth-code"))
        }
        XCTAssertTrue(try CodexWorkspaceStore(directory: root).load().isEmpty)
        let homes = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("codex-workspaces"), includingPropertiesForKeys: nil)
        let diagnostic = try String(contentsOf: XCTUnwrap(homes.first).appendingPathComponent("beaver-meter-login-error.json"))
        XCTAssertFalse(diagnostic.contains("oauth-code"))
        XCTAssertFalse(diagnostic.contains("https://"))
    }

    func testLoginFailuresExplainKnownCausesWithoutCopyingSecrets() {
        for (output, expected) in [
            ("env: node: No such file or directory https://auth.example/?code=secret", "requires Node.js"),
            ("Error logging in: Address already in use", "callback port"),
            ("Error loading configuration: unknown field secret=token", "login configuration"),
            ("Token exchange failed: code=secret", "could not be exchanged")
        ] {
            let message = CodexWorkspaceLoginCollector.failureReason(stderr: Data(output.utf8))
            XCTAssertTrue(message.contains(expected))
            XCTAssertFalse(message.contains("secret"))
            XCTAssertFalse(message.contains("https://"))
        }
    }

    func testOwnWorkspaceReloginRejectsDifferentWorkspace() throws {
        let root = try workspace(), cli = root.appendingPathComponent("codex"), fixtureHome = root.appendingPathComponent("fixture")
        try CodexCredentialFileAccess.withFixtureScope(.init(roots: [root])) {
            try auth("personal", home: fixtureHome)
            let store = CodexWorkspaceStore(directory: root), id = UUID()
            let saved = CodexWorkspaceLogin(id: id, label: "Team", workspaceAccountID: "team")
            try store.save(saved)
            try "#!/bin/sh\ncp \"$BEAVERMETER_LOGIN_FIXTURE\" \"$CODEX_HOME/auth.json\"\n".write(to: cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
            XCTAssertThrowsError(try CodexWorkspaceLoginCollector.run(id: id, label: "Team", directory: root,
                environment: ["PATH": "/usr/bin:/bin", "BEAVERMETER_LOGIN_FIXTURE": fixtureHome.appendingPathComponent("auth.json").path],
                executableOverride: cli)) {
                XCTAssertEqual($0 as? CodexWorkspaceLoginCollector.LoginError, .wrongWorkspace)
            }
            XCTAssertEqual(try store.load(), [saved])
        }
    }

    func testOwnWorkspaceLoginRejectsSymlinkToExternalHome() throws {
        let root = try workspace(), external = root.appendingPathComponent("external")
        let store = CodexWorkspaceStore(directory: root), id = UUID()
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.home(for: id).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.home(for: id), withDestinationURL: external)
        XCTAssertThrowsError(try CodexWorkspaceLoginCollector.run(id: id, label: "Team", directory: root,
                                                                executableOverride: URL(fileURLWithPath: "/bin/false"))) {
            XCTAssertEqual($0 as? CodexWorkspaceLoginCollector.LoginError, .unsafeDirectory)
        }
        XCTAssertTrue(try CodexWorkspaceStore(directory: root).load().isEmpty)
    }

    func testClaudeResetCardsMissingIsUnknownButEmptyIsZero() throws {
        func read(_ json: String) throws -> ResetCardInventory? {
            try ClaudeResetCardCollector.inventory(from: Data(json.utf8), now: now)
        }
        XCTAssertNil(try read(#"{"five_hour":{"utilization":0}}"#))
        XCTAssertNil(try read(#"{"cedar_ember":{"eligible":true}}"#))
        XCTAssertNil(try read(#"{"cedar_ember":{"eligible":false,"ineligible_reason":"surface","grants":[]}}"#))
        XCTAssertEqual(try read(#"{"cedar_ember":{"eligible":true,"grants":[]}}"#)?.availableCount, 0)
        let inventory = try XCTUnwrap(read(#"""
        {"cedar_ember":{"eligible":true,"grants":[
          {"id":"a","resets_left":2,"ends_at":"2026-10-22T12:00:00.123Z","use_requires_limit":true},
          {"id":"a","resets_left":2,"ends_at":"2026-10-22T12:00:00.123Z"},
          {"id":"b","resets_left":1,"ends_at":null,"paused":true},
          {"id":"expired","resets_left":8,"ends_at":"2026-09-30T00:00:00Z"}
        ]}}
        """#))
        XCTAssertEqual(inventory.availableCount, 3)
        XCTAssertEqual(inventory.batches.count, 2)
        XCTAssertTrue(inventory.batches[0].requiresLimit)
        XCTAssertFalse(inventory.batches.contains { $0.id == "a" })
        XCTAssertThrowsError(try read(#"{"cedar_ember":{"eligible":true,"grants":[{"id":"a","resets_left":-1}]}}"#))
    }

    func testClaudeRequestSurfaceUsesInstalledCLIVersionAndRejectsUnknownOutput() throws {
        let cli = try workspace().appendingPathComponent("claude")
        try "#!/bin/sh\nprintf '2.1.284 (Claude Code)\\n'\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let environment = ["CLAUDE_CLI_PATH": cli.path]
        XCTAssertEqual(ClaudeQuotaCollector.userAgent(environment: environment), "claude-cli/2.1.284 (external, cli)")
        try "#!/bin/sh\nprintf 'unknown version\\n'\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        XCTAssertEqual(ClaudeQuotaCollector.userAgent(environment: environment), "BeaverMeter")
        XCTAssertEqual(ClaudeQuotaCollector.userAgent(environment: ["CLAUDE_CLI_PATH": cli.path + ".missing"]), "BeaverMeter")
    }

    func testSevenDayRangeHandlesDSTWithCalendarDays() throws {
        let spring = ISO8601DateFormatter().date(from: "2026-03-30T12:00:00Z")!
        let dates = try TokenHistoryCollector.dates(now: spring, calendar: calendar)
        XCTAssertEqual(dates.count, 7)
        XCTAssertEqual(TokenHistoryCollector.dateKey(dates[0], calendar: calendar), "2026-03-24")
        XCTAssertEqual(dates[6].timeIntervalSince(dates[5]), 23 * 3600)
    }

    func testSevenDayScannerDeduplicatesHomesRemoteAndAppendsWithoutMixingDates() async throws {
        let root = try workspace(), a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        let fileA = a.appendingPathComponent("sessions/old-date/session.jsonl")
        let fileB = b.appendingPathComponent("archived_sessions/copy.jsonl")
        try FileManager.default.createDirectory(at: fileA.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fileB.deletingLastPathComponent(), withIntermediateDirectories: true)
        let shared = record("shared", date: "2026-09-25T10:00:00Z")
        try (shared + record("outside", date: "2026-09-24T10:00:00Z") + record("today", date: "2026-10-01T10:00:00Z"))
            .write(to: fileA, atomically: true, encoding: .utf8)
        try (shared + record("other", date: "2026-09-30T10:00:00Z")).write(to: fileB, atomically: true, encoding: .utf8)
        let legacy = root.appendingPathComponent("zero.json")
        try JSONEncoder().encode(CodexTokenTotals.zero).write(to: legacy)
        let remote = root.appendingPathComponent("remote.json")
        try writeJSON(["complete": true, "failedFiles": [], "activeFiles": ["fixture"], "files": ["fixture": [
            "offset": 100, "reset": true, "records": [[
                "responseHash": CodexUsageSupport.hash("shared"), "sessionHash": CodexUsageSupport.hash("shared"),
                "timestamp": ISO8601DateFormatter().date(from: "2026-09-25T10:00:00Z")!.timeIntervalSince1970,
                "inputTokens": 100, "cachedInputTokens": 30, "outputTokens": 20, "reasoningTokens": 10
            ]]]]], to: remote)
        let environment = ["CODEX_LEGACY_TOKEN_FIXTURE": legacy.path, "CODEX_REMOTE_SSH_HOST": "fixture",
                           "CODEX_REMOTE_ROOT": "/fixture", "CODEX_REMOTE_PYTHON": "/python",
                           "CODEX_REMOTE_RESPONSE_FIXTURE": remote.path]
        let config = CodexAccountConfiguration(homes: [a.path, b.path], message: nil)
        let initial = await TokenHistoryCollector.codex(previous: .unavailable("none"), configuration: config, now: now,
                                                         directory: root, environment: environment, calendar: calendar)
        let history = try XCTUnwrap(initial.history.value)
        XCTAssertEqual(history.totals.totalTokens, 360)
        XCTAssertEqual(history.days[0].totals.totalTokens, 120)
        XCTAssertEqual(history.days[6].totals.totalTokens, 120)
        XCTAssertTrue(initial.remoteToday?.usageByResponseHash.isEmpty == true)
        let handle = try FileHandle(forWritingTo: fileA); try handle.seekToEnd()
        try handle.write(contentsOf: Data(record("appended", date: "2026-10-01T11:00:00Z").utf8)); try handle.close()
        let updated = await TokenHistoryCollector.codex(previous: initial.history, configuration: config, now: now,
                                                         directory: root, environment: environment, calendar: calendar)
        XCTAssertEqual(updated.history.value?.totals.totalTokens, 480)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: now)!
        let rolled = await TokenHistoryCollector.codex(previous: updated.history, configuration: config, now: nextDay,
                                                        directory: root, environment: [:], calendar: calendar)
        XCTAssertEqual(rolled.history.value?.days.first.map { TokenHistoryCollector.dateKey($0.date, calendar: calendar) }, "2026-09-26")
        XCTAssertEqual(rolled.history.value?.days.last?.totals.totalTokens, 0)
    }

    func testUnpricedClaudeDayKeepsCombinedCostUnknown() throws {
        let unpriced = ClaudeTokenTotals(totalTokens: 100, inputTokens: 50, cacheCreationTokens: 10,
                                         cacheReadTokens: 20, outputTokens: 20, costUSD: nil)
        let result = try TokenHistoryCollector.adding(ClaudeTokenTotals.zero, unpriced)
        XCTAssertNil(result.costUSD)
        XCTAssertEqual(result.totalTokens, 100)
        XCTAssertNil(try TokenHistoryCollector.adding(result, .zero).costUSD)
    }

    func testCodexInventoryUsesUpstreamStatusAndExpiryFiltering() {
        func card(_ id: String, _ status: CodexRateLimitResetCreditStatus, _ expires: Date?) -> CodexRateLimitResetCredit {
            CodexRateLimitResetCredit(id: id, resetType: "codex_rate_limits", status: status,
                                     grantedAt: now.addingTimeInterval(-3600), expiresAt: expires,
                                     redeemStartedAt: nil, redeemedAt: nil, title: nil, description: nil)
        }
        let source = CodexRateLimitResetCreditsSnapshot(credits: [
            card("available", .available, now.addingTimeInterval(3600)),
            card("unknown-expiry", .available, nil),
            card("expired", .available, now.addingTimeInterval(-1)),
            card("redeemed", .redeemed, now.addingTimeInterval(3600))
        ], availableCount: 3, updatedAt: now)
        let inventory = CodexAccountsCollector.inventory(from: source, now: now)
        XCTAssertEqual(inventory.availableCount, 3)
        XCTAssertEqual(inventory.batches.count, 2)
        XCTAssertEqual(inventory.availableBatches(at: now).first?.expiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(inventory.count(at: now.addingTimeInterval(3600)), 2)
    }
}
