import Foundation
import XCTest

final class ClaudeRenewalStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_164_800)
    private let current = Data(#"{"claudeAiOauth":{"accessToken":"synthetic-original","refreshToken":"synthetic-refresh","expiresAt":4070908800000}}"#.utf8)

    private final class CredentialSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Result<Data, Error>]

        init(_ values: [Data]) { self.values = values.map { .success($0) } }
        init(results: [Result<Data, Error>]) { self.values = results }

        func read() throws -> Data {
            lock.lock()
            defer { lock.unlock() }
            return try (values.count > 1 ? values.removeFirst() : values[0]).get()
        }
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("beavermeter-claude-renewal-state-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func environment(_ root: URL, script: String = "exit 0") throws -> [String: String] {
        let cli = root.appendingPathComponent("synthetic-claude")
        try Data("""
        #!/bin/sh
        printf launched > "$CLAUDE_CONFIG_DIR/cli-launched"
        \(script)
        """.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return ["CLAUDE_CONFIG_DIR": root.path, "CLAUDE_CLI_PATH": cli.path, "CLAUDE_CLI_REFRESH": "1"]
    }

    func testCooldownDoesNotLaunchCLIReadCredentialsOrRequestAnotherLogin() throws {
        let root = try workspace(), environment = try self.environment(root)
        let state = try ClaudeSignInRenewer.refreshStateURL(stateDirectory: root, environment: environment)
        XCTAssertTrue(ClaudeSignInRenewer.reserveAttempt(stateURL: state, now: now))

        XCTAssertThrowsError(try ClaudeQuotaCollector.renewedToken(
            now: now.addingTimeInterval(1), stateDirectory: root, environment: environment,
            rejectedToken: "synthetic-original", credentialReader: { _ in
                XCTFail("A cooldown must not introduce another credential read")
                return Data()
            }
        )) {
            XCTAssertEqual($0 as? ClaudeRenewalError, .retryLater)
            XCTAssertNil($0 as? ClaudeQuotaError)
            XCTAssertFalse($0.localizedDescription.contains("Sign in"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cli-launched").path))
    }

    func testExplicitOptOutAndMissingCLIStayDistinctFromAnExpiredLogin() throws {
        for option in ["CLAUDE_CLI_REFRESH", "CLAUDE_KEYCHAIN_ACCESS"] {
            let root = try workspace()
            var environment = try self.environment(root)
            environment[option] = "0"
            XCTAssertThrowsError(try ClaudeQuotaCollector.renewedToken(
                now: now, stateDirectory: root, environment: environment, rejectedToken: "synthetic-original",
                credentialReader: { _ in XCTFail("Opt-out must not read credentials"); return Data() }
            )) {
                XCTAssertEqual($0 as? ClaudeRenewalError, .disabled)
                XCTAssertNil($0 as? ClaudeQuotaError)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cli-launched").path))
        }
        let root = try workspace()
        XCTAssertThrowsError(try ClaudeQuotaCollector.renewedToken(
            now: now, stateDirectory: root,
            environment: ["CLAUDE_CONFIG_DIR": root.path, "CLAUDE_CLI_PATH": root.appendingPathComponent("absent-cli").path],
            rejectedToken: "synthetic-original", credentialReader: { _ in XCTFail("Missing CLI must not read credentials"); return Data() }
        )) {
            XCTAssertEqual($0 as? ClaudeRenewalError, .cliUnavailable)
            XCTAssertNil($0 as? ClaudeQuotaError)
        }
    }

    func testCLIStartupFailureDoesNotClaimTheRefreshGrantWasRejected() throws {
        let root = try workspace(), cli = root.appendingPathComponent("synthetic-claude")
        try Data("#!/nonexistent/beavermeter-test-interpreter\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        XCTAssertThrowsError(try ClaudeQuotaCollector.renewedToken(
            now: now, stateDirectory: root,
            environment: ["CLAUDE_CONFIG_DIR": root.path, "CLAUDE_CLI_PATH": cli.path],
            rejectedToken: "synthetic-original", credentialReader: { _ in Data() }
        )) {
            XCTAssertEqual($0 as? ClaudeRenewalError, .notCompleted)
            XCTAssertNil($0 as? ClaudeQuotaError)
        }
    }

    func testUnchangedAccessTokenNeverCertifiesRenewalOrRequestsAnotherLogin() throws {
        let root = try workspace(), environment = try self.environment(root), credentials = current
        XCTAssertThrowsError(try ClaudeQuotaCollector.renewedToken(
            now: now, stateDirectory: root, environment: environment,
            rejectedToken: "synthetic-original", credentialReader: { _ in credentials }
        )) {
            XCTAssertEqual($0 as? ClaudeRenewalError, .notCompleted)
            XCTAssertNil($0 as? ClaudeQuotaError)
        }
    }

    func testCredentialChangingAgainAfterPollingIsIncompleteRatherThanExpiredLogin() throws {
        let replacement = Data(#"{"claudeAiOauth":{"accessToken":"synthetic-replacement","expiresAt":4070908800000}}"#.utf8)
        for final in [current, Data(#"{"claudeAiOauth":{"accessToken":"synthetic-replacement","expiresAt":0}}"#.utf8),
                      Data(#"{"claudeAiOauth":{"refreshToken":"synthetic-refresh"}}"#.utf8)] {
            let root = try workspace(), environment = try self.environment(root, script: "exec /bin/sleep 30")
            let sequence = CredentialSequence([replacement, final])
            XCTAssertThrowsError(try ClaudeQuotaCollector.renewedToken(
                now: now, stateDirectory: root, environment: environment,
                rejectedToken: "synthetic-original", credentialReader: { _ in try sequence.read() }
            )) {
                XCTAssertEqual($0 as? ClaudeRenewalError, .notCompleted)
                XCTAssertNil($0 as? ClaudeQuotaError)
            }
        }
    }

    func testFinalReadDuringCredentialReplacementDoesNotDemandAnotherLogin() throws {
        let replacement = Data(#"{"claudeAiOauth":{"accessToken":"synthetic-replacement","expiresAt":4070908800000}}"#.utf8)
        for failure in [ClaudeQuotaError.notLoggedIn, .expired] {
            let root = try workspace(), environment = try self.environment(root, script: "exec /bin/sleep 30")
            let sequence = CredentialSequence(results: [.success(replacement), .failure(failure)])
            XCTAssertThrowsError(try ClaudeQuotaCollector.renewedToken(now: now,
                stateDirectory: root, environment: environment, rejectedToken: "synthetic-original",
                credentialReader: { _ in try sequence.read() })) {
                XCTAssertEqual($0 as? ClaudeRenewalError, .notCompleted)
                XCTAssertNil($0 as? ClaudeQuotaError)
            }
        }
    }

    func testCredentialReadCancellationNeverLaunchesOrContinuesTheCLI() throws {
        let root = try workspace(), environment = try self.environment(root)
        XCTAssertThrowsError(try ClaudeQuotaCollector.renewedToken(
            now: now, stateDirectory: root, environment: environment,
            credentialReader: { _ in throw URLError(.cancelled) }
        )) {
            XCTAssertEqual(($0 as? URLError)?.code, .cancelled)
            XCTAssertNil($0 as? ClaudeRenewalError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cli-launched").path))

        let pollingRoot = try workspace(), pollingEnvironment = try self.environment(pollingRoot, script: "exec /bin/sleep 30")
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try ClaudeQuotaCollector.renewedToken(
            now: now, stateDirectory: pollingRoot, environment: pollingEnvironment,
            rejectedToken: "synthetic-original", credentialReader: { _ in throw URLError(.cancelled) }
        )) {
            XCTAssertEqual(($0 as? URLError)?.code, .cancelled)
            XCTAssertNil($0 as? ClaudeRenewalError)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
    }
}
