import Foundation
import XCTest

final class CollectorProcessRunnerTests: XCTestCase {
    func testConfiguredRefreshUsesBundledHelperAndSuppliedSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("collector")
        let wrapper = directory.appendingPathComponent("refresh.sh")
        let output = directory.appendingPathComponent("local test snapshot.json")
        try """
        #!/bin/zsh
        [[ "$1" == --output ]] || exit 2
        print -r -- "$CODEX_REMOTE_SSH_HOST" > "$2"
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        try """
        export CODEX_REMOTE_SSH_HOST=fixture-remote
        exec "$BEAVERMETER_COLLECTOR" "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)

        let result = CollectorProcessRunner.refresh(helper: helper, script: wrapper, output: output.path)
        XCTAssertEqual(result.status, 0, result.message)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "fixture-remote\n")
    }

    func testClaudeLoginAndVerificationUseConfiguredWrapperAndOutputPath() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("collector")
        let wrapper = directory.appendingPathComponent("refresh.sh")
        let output = directory.appendingPathComponent("snapshot with spaces.json")
        try writeExecutable("""
        #!/bin/zsh
        [[ "$1" == --claude-login || "$1" == --claude-verify ]] || exit 2
        [[ "$2" == --output ]] || exit 3
        print -r -- "$1" "$CLAUDE_CONFIG_DIR" "$CLAUDE_KEYCHAIN_ACCESS" > "$3"
        """, to: helper)
        try """
        export CLAUDE_CONFIG_DIR='/fixture/custom Claude profile'
        export CLAUDE_KEYCHAIN_ACCESS=0
        exec "$BEAVERMETER_COLLECTOR" "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)

        for opensBrowser in [true, false] {
            let result = CollectorProcessRunner.authenticateClaude(
                helper: helper, script: wrapper, output: output.path, opensBrowser: opensBrowser
            )
            XCTAssertEqual(result.status, 0, result.message)
            let mode = opensBrowser ? "--claude-login" : "--claude-verify"
            XCTAssertEqual(
                try String(contentsOf: output, encoding: .utf8),
                "\(mode) /fixture/custom Claude profile 0\n"
            )
        }
    }

    func testClaudeVerificationNeverIncludesCLIStandardOutputInResult() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("collector")
        try writeExecutable("""
        #!/bin/zsh
        print -r -- 'private-cli-output-sentinel'
        print -r -- 'Claude login needs verification.' >&2
        exit 1
        """, to: helper)

        let result = CollectorProcessRunner.authenticateClaude(
            helper: helper, script: nil,
            output: directory.appendingPathComponent("snapshot.json").path, opensBrowser: false
        )
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.message, "Claude login needs verification.")
        XCTAssertFalse(result.message.contains("private-cli-output-sentinel"))
    }

    func testClaudeAccessAuthorizationUsesConfiguredWrapperAndOutputPath() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("collector")
        let wrapper = directory.appendingPathComponent("refresh.sh")
        let output = directory.appendingPathComponent("snapshot with spaces.json")
        try writeExecutable("""
        #!/bin/zsh
        [[ "$1" == --claude-authorize ]] || exit 2
        [[ "$2" == --output ]] || exit 3
        print -r -- "$CLAUDE_CONFIG_DIR" "$CLAUDE_KEYCHAIN_ACCESS" > "$3"
        """, to: helper)
        try """
        export CLAUDE_CONFIG_DIR='/fixture/saved Claude profile'
        export CLAUDE_KEYCHAIN_ACCESS=1
        exec "$BEAVERMETER_COLLECTOR" "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)

        let result = CollectorProcessRunner.authorizeClaudeAccess(
            helper: helper, script: wrapper, output: output.path
        )
        XCTAssertEqual(result.status, 0, result.message)
        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            "/fixture/saved Claude profile 1\n"
        )
    }

    func testClaudeAccessAuthorizationDiscardsStandardOutputAndReportsFailure() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("collector")
        try writeExecutable("""
        #!/bin/zsh
        [[ "$1" == --claude-authorize ]] || exit 2
        print -r -- 'saved-credential-output-sentinel'
        print -r -- 'macOS denied access to the saved Claude login.' >&2
        exit 1
        """, to: helper)

        let result = CollectorProcessRunner.authorizeClaudeAccess(
            helper: helper, script: nil,
            output: directory.appendingPathComponent("snapshot.json").path
        )
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.message, "macOS denied access to the saved Claude login.")
        XCTAssertFalse(result.message.contains("saved-credential-output-sentinel"))
    }

    func testCancelledClaudeAccessAuthorizationDoesNotLaunchHelper() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("collector")
        let output = directory.appendingPathComponent("snapshot.json")
        try writeExecutable("""
        #!/bin/zsh
        print -r -- launched > "$3"
        """, to: helper)
        let cancellation = SubprocessCancellation()
        cancellation.cancel()

        let result = CollectorProcessRunner.authorizeClaudeAccess(
            helper: helper, script: nil, output: output.path, cancellation: cancellation
        )
        XCTAssertEqual(result.status, -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCursorAccessAuthorizationUsesConfiguredWrapperAndOutputPath() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("collector")
        let wrapper = directory.appendingPathComponent("refresh.sh")
        let output = directory.appendingPathComponent("snapshot with spaces.json")
        try writeExecutable("""
        #!/bin/zsh
        [[ "$1" == --cursor-authorize ]] || exit 2
        [[ "$2" == --output ]] || exit 3
        print -r -- "$CURSOR_STATE_DB" > "$3"
        """, to: helper)
        try """
        export CURSOR_STATE_DB='/fixture/Cursor profile/state.vscdb'
        exec "$BEAVERMETER_COLLECTOR" "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)

        let result = CollectorProcessRunner.authorizeCursorAccess(
            helper: helper, script: wrapper, output: output.path
        )

        XCTAssertEqual(result.status, 0, result.message)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "/fixture/Cursor profile/state.vscdb\n")
    }

    func testCursorAccessAuthorizationDiscardsStandardOutputAndReportsFailure() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("collector")
        try writeExecutable("""
        #!/bin/zsh
        [[ "$1" == --cursor-authorize ]] || exit 2
        print -r -- 'cursor-credential-output-sentinel'
        print -r -- 'macOS denied access to Cursor Safe Storage.' >&2
        exit 1
        """, to: helper)

        let result = CollectorProcessRunner.authorizeCursorAccess(
            helper: helper, script: nil,
            output: directory.appendingPathComponent("snapshot.json").path
        )

        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.message, "macOS denied access to Cursor Safe Storage.")
        XCTAssertFalse(result.message.contains("cursor-credential-output-sentinel"))
    }

    func testCancelledCursorAccessAuthorizationDoesNotLaunchHelper() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("collector")
        let output = directory.appendingPathComponent("snapshot.json")
        try writeExecutable("""
        #!/bin/zsh
        print -r -- launched > "$3"
        """, to: helper)
        let cancellation = SubprocessCancellation()
        cancellation.cancel()

        let result = CollectorProcessRunner.authorizeCursorAccess(
            helper: helper, script: nil, output: output.path, cancellation: cancellation
        )

        XCTAssertEqual(result.status, -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testClaudeKeychainRepairUsesConfiguredWrapperAndOutputPath() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("collector")
        let wrapper = directory.appendingPathComponent("refresh.sh")
        let output = directory.appendingPathComponent("snapshot with spaces.json")
        try writeExecutable("""
        #!/bin/zsh
        [[ "$1" == --claude-repair-keychain ]] || exit 2
        [[ "$2" == --output ]] || exit 3
        print -r -- "$CLAUDE_CONFIG_DIR" "$CLAUDE_KEYCHAIN_ACCESS" > "$3"
        """, to: helper)
        try """
        export CLAUDE_CONFIG_DIR='/fixture/saved Claude profile'
        export CLAUDE_KEYCHAIN_ACCESS=1
        exec "$BEAVERMETER_COLLECTOR" "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)

        let result = CollectorProcessRunner.repairClaudeKeychainSession(
            helper: helper, script: wrapper, output: output.path
        )
        XCTAssertEqual(result.status, 0, result.message)
        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            "/fixture/saved Claude profile 1\n"
        )
    }

    func testClaudeKeychainRepairDiscardsStandardOutputAndReportsFailure() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("collector")
        try writeExecutable("""
        #!/bin/zsh
        [[ "$1" == --claude-repair-keychain ]] || exit 2
        print -r -- 'saved-keychain-output-sentinel'
        print -r -- 'macOS Keychain session could not be repaired.' >&2
        exit 1
        """, to: helper)

        let result = CollectorProcessRunner.repairClaudeKeychainSession(
            helper: helper, script: nil,
            output: directory.appendingPathComponent("snapshot.json").path
        )
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.message, "macOS Keychain session could not be repaired.")
        XCTAssertFalse(result.message.contains("saved-keychain-output-sentinel"))
    }

    func testCancelledClaudeKeychainRepairDoesNotLaunchHelper() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("collector")
        let output = directory.appendingPathComponent("snapshot.json")
        try writeExecutable("""
        #!/bin/zsh
        print -r -- launched > "$3"
        """, to: helper)
        let cancellation = SubprocessCancellation()
        cancellation.cancel()

        let result = CollectorProcessRunner.repairClaudeKeychainSession(
            helper: helper, script: nil, output: output.path, cancellation: cancellation
        )
        XCTAssertEqual(result.status, -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCancelledClaudeLoginDoesNotLaunchHelper() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("collector")
        let output = directory.appendingPathComponent("snapshot.json")
        try writeExecutable("""
        #!/bin/zsh
        print -r -- launched > "$3"
        """, to: helper)
        let cancellation = SubprocessCancellation()
        cancellation.cancel()

        let result = CollectorProcessRunner.authenticateClaude(
            helper: helper, script: nil, output: output.path,
            opensBrowser: true, cancellation: cancellation
        )
        XCTAssertEqual(result.status, -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
