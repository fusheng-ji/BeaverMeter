import Foundation
import XCTest

final class ClaudeCredentialAccessSessionTests: XCTestCase {
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [ClaudeKeychainReader.Interaction] = []
        func append(_ value: ClaudeKeychainReader.Interaction) { lock.lock(); values.append(value); lock.unlock() }
        var interactions: [ClaudeKeychainReader.Interaction] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testOnlyFirstExplicitReadMayAskForPermissionAndReturnsOriginalData() throws {
        let reads = Reads()
        let data = Data("synthetic credential document".utf8)
        let session = ClaudeCredentialAccessSession(authorize: true) { environment, interaction in
            XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/selected-profile")
            reads.append(interaction)
            return data
        }
        for _ in 0..<3 { XCTAssertEqual(try session.read(environment: ["CLAUDE_CONFIG_DIR": "/selected-profile"]), data) }
        XCTAssertEqual(reads.interactions, [.userInitiated, .background, .background])
    }

    func testDeniedReadDoesNotCreateRepeatedPermissionPrompts() {
        let reads = Reads()
        let session = ClaudeCredentialAccessSession(authorize: true) { _, interaction in
            reads.append(interaction)
            throw ClaudeKeychainReader.ReadError.keychainAccessRequired
        }
        for _ in 0..<2 {
            XCTAssertThrowsError(try session.read(environment: [:])) {
                XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, .keychainAccessRequired)
            }
        }
        XCTAssertEqual(reads.interactions, [.userInitiated, .background])
    }

    func testOrdinaryVerificationNeverAllowsPermissionUI() throws {
        let session = ClaudeCredentialAccessSession(authorize: false) { _, interaction in
            XCTAssertEqual(interaction, .background)
            return Data()
        }
        for _ in 0..<2 { _ = try session.read(environment: [:]) }
    }
}
