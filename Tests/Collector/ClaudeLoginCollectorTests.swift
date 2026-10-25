import Foundation
import XCTest

final class ClaudeLoginCollectorTests: XCTestCase {
    func testUsesOfficialBrowserLoginWithoutPromptAndPreservesProfile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let arguments = directory.appendingPathComponent("arguments")
        let profile = directory.appendingPathComponent("profile")
        let cli = try script(in: directory, body: """
        printf '%s\\n' "$@" > "$ARGUMENT_RECORD"
        printf '%s' "$CLAUDE_CONFIG_DIR" > "$PROFILE_RECORD"
        exit 0
        """)
        try ClaudeLoginCollector.login(environment: ["CLAUDE_CLI_PATH": cli.path,
            "CLAUDE_CONFIG_DIR": profile.path, "ARGUMENT_RECORD": arguments.path, "PROFILE_RECORD": profile.path])
        XCTAssertEqual(try String(contentsOf: arguments, encoding: .utf8), "auth\nlogin\n--claudeai\n")
        XCTAssertEqual(try String(contentsOf: profile, encoding: .utf8), profile.path)
    }

    func testFailedLoginNeverReturnsRawCLISecrets() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = try script(in: directory, body: "printf 'synthetic-private-oauth-link' >&2\nexit 1")
        XCTAssertThrowsError(try ClaudeLoginCollector.login(environment: ["CLAUDE_CLI_PATH": cli.path])) { error in
            XCTAssertTrue(error is ClaudeLoginError)
            XCTAssertFalse(error.localizedDescription.contains("synthetic-private-oauth-link"))
        }
    }

    func testBrowserLoginTimeoutDoesNotCountAsSuccess() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = try script(in: directory, body: "exec /bin/sleep 10")
        XCTAssertThrowsError(try ClaudeLoginCollector.login(environment: ["CLAUDE_CLI_PATH": cli.path], timeout: 0.1)) { error in
            guard case ClaudeLoginError.timedOut = error else { return XCTFail("Expected timeout") }
        }
    }

    func testCustomOAuthIsRejectedBeforeCLILaunch() throws {
        XCTAssertThrowsError(try ClaudeLoginCollector.login(environment: [
            "CLAUDE_CODE_CUSTOM_OAUTH_URL": "https://custom.invalid",
            "CLAUDE_CLI_PATH": "/missing/claude"
        ])) { error in
            XCTAssertEqual(error as? ClaudeCredentialResolver.ResolutionError, .unsupportedOAuthEndpoint)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func script(in directory: URL, body: String) throws -> URL {
        let url = directory.appendingPathComponent("claude")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
