import Foundation
import Security
import XCTest

final class ClaudeKeychainReaderTests: XCTestCase {
    func testBackgroundQueryReadsOnlyTheSelectedItemAndDisallowsAuthenticationUI() throws {
        let data = Data("test-credential-document".utf8)
        var queries: [ClaudeKeychainReader.Query] = []
        let result = try ClaudeKeychainReader.read(
            service: "Claude Code-credentials-profile", account: "selected-user", interaction: .background
        ) { query in
            queries.append(query)
            return (errSecSuccess, data)
        }

        XCTAssertEqual(result, data)
        XCTAssertEqual(queries.count, 1)
        let query = try XCTUnwrap(queries.first)
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "Claude Code-credentials-profile")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "selected-user")
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
        XCTAssertNil(query[kSecUseOperationPrompt as String])
        XCTAssertNil(query[kSecReturnAttributes as String])
        XCTAssertNil(query[kSecMatchSearchList as String])
    }

    func testOnlyExplicitUserInitiatedQueryAllowsAnAuthorizationPrompt() throws {
        var query: ClaudeKeychainReader.Query = [:]
        _ = try ClaudeKeychainReader.read(service: "selected-service", account: "selected-user", interaction: .userInitiated) {
            query = $0
            return (errSecSuccess, Data("test-credential-document".utf8))
        }

        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIAllow as String)
        XCTAssertTrue(query[kSecUseOperationPrompt as String] as? String != nil)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "selected-service")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "selected-user")
    }

    func testOnlyMissingItemReturnsNil() throws {
        XCTAssertNil(try ClaudeKeychainReader.read(service: "service", account: "account", interaction: .background) { _ in
            (errSecItemNotFound, nil)
        })
        XCTAssertThrowsError(try ClaudeKeychainReader.read(service: "service", account: "account", interaction: .background) { _ in
            (errSecSuccess, nil)
        }) {
            XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, .unavailable(status: errSecDecode))
        }
    }

    func testAccessFailuresAreNotMissingLoginAndNeverRetryInteractively() {
        for status in [errSecAuthFailed, errSecInteractionNotAllowed] {
            var attempts = 0
            XCTAssertThrowsError(try ClaudeKeychainReader.read(service: "service", account: "account", interaction: .background) { query in
                attempts += 1
                XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
                return (status, nil)
            }) {
                XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, .keychainAccessRequired)
            }
            XCTAssertEqual(attempts, 1)
        }
    }

    func testUserCancellationRemainsDistinctFromDeniedAndUnavailableAccess() {
        XCTAssertThrowsError(try ClaudeKeychainReader.read(service: "service", account: "account", interaction: .userInitiated) { _ in
            (errSecUserCanceled, nil)
        }) {
            XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, .userCancelled)
        }
        XCTAssertThrowsError(try ClaudeKeychainReader.read(service: "service", account: "account", interaction: .background) { _ in
            (errSecNotAvailable, nil)
        }) {
            XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, .unavailable(status: errSecNotAvailable))
        }
    }

    func testStaleSystemSessionIsNotAnItemPermissionOrMissingLogin() {
        XCTAssertThrowsError(try ClaudeKeychainReader.read(service: "service", account: "account", interaction: .background,
            sessionUnavailable: { true }, execute: { _ in (errSecAuthFailed, nil) })) {
            XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, .keychainSessionUnavailable)
        }
        XCTAssertThrowsError(try ClaudeKeychainReader.read(service: "service", account: "account", interaction: .background,
            sessionUnavailable: { XCTFail("Only authentication failure needs system diagnosis"); return true },
            execute: { _ in (errSecInteractionNotAllowed, nil) })) {
            XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, .keychainAccessRequired)
        }
    }

    func testLegacyInteractionPolicyIsRestoredAfterSuccessfulAndFailedReads() {
        for allow in [false, true] {
            for status in [errSecSuccess, errSecAuthFailed, errSecUserCanceled] {
                var applied: [Bool] = []
                let result = ClaudeKeychainReader.withInteractionPolicy(allow: allow, current: { (errSecSuccess, !allow) },
                    apply: { applied.append($0); return errSecSuccess }, operation: {
                        XCTAssertEqual(applied, [allow])
                        return (status, nil)
                    })
                XCTAssertEqual(result.status, status)
                XCTAssertEqual(applied, [allow, !allow])
            }
        }
    }

    func testLegacyPolicyFailureNeverReadsCredential() {
        let readFailure = ClaudeKeychainReader.withInteractionPolicy(allow: false, current: { (errSecNotAvailable, true) },
            apply: { _ in XCTFail("Must not mutate policy after failed inspection"); return errSecSuccess },
            operation: { XCTFail("Must fail closed"); return (errSecSuccess, nil) })
        XCTAssertEqual(readFailure.status, errSecNotAvailable)
        let setFailure = ClaudeKeychainReader.withInteractionPolicy(allow: false, current: { (errSecSuccess, true) },
            apply: { _ in errSecNotAvailable },
            operation: { XCTFail("Must fail closed"); return (errSecSuccess, nil) })
        XCTAssertEqual(setFailure.status, errSecNotAvailable)
    }

    func testBackgroundNativeDenialCanUseOnlyTheSameTrustedSystemItem() throws {
        let data = Data("synthetic-only".utf8)
        let value = try ClaudeKeychainReader.read(service: "selected-service", account: "selected-account", interaction: .background) { query in
            ClaudeKeychainReader.queryResult(query, executeNative: { _ in (errSecInteractionNotAllowed, nil) },
                readTrusted: { service, account in
                    XCTAssertEqual(service, "selected-service")
                    XCTAssertEqual(account, "selected-account")
                    return data
                })
        }
        XCTAssertEqual(value, data)
    }

    func testMissingOrSuccessfulNativeReadsAndInteractiveActionsNeverStartCompatibilityReader() throws {
        for interaction in [ClaudeKeychainReader.Interaction.background, .userInitiated] {
            for status in [errSecSuccess, errSecItemNotFound] {
                _ = try ClaudeKeychainReader.read(service: "service", account: "account", interaction: interaction) { query in
                    ClaudeKeychainReader.queryResult(query, executeNative: { _ in (status, Data("synthetic".utf8)) },
                        readTrusted: { _, _ in XCTFail("Native outcome must remain authoritative"); return nil })
                }
            }
        }
        XCTAssertThrowsError(try ClaudeKeychainReader.read(service: "service", account: "account", interaction: .userInitiated) { query in
            ClaudeKeychainReader.queryResult(query, executeNative: { _ in (errSecAuthFailed, nil) },
                readTrusted: { _, _ in XCTFail("Explicit native permission must not switch readers"); return nil })
        })
    }

    func testUntrustedCompatibilityReaderPreservesAccessErrorAndUserCancellation() {
        for expected in [ClaudeKeychainReader.ReadError.keychainAccessRequired, .userCancelled] {
            XCTAssertThrowsError(try ClaudeKeychainReader.read(service: "service", account: "account", interaction: .background) { query in
                ClaudeKeychainReader.queryResult(query, executeNative: { _ in (errSecInteractionNotAllowed, nil) },
                    readTrusted: { _, _ in throw expected })
            }) { XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, expected) }
        }
    }

    func testCancelledNativeEntryNeverQueriesARealKeychain() {
        let cancellation = SubprocessCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try ClaudeKeychainReader.read(service: "unused", account: "unused",
            interaction: .userInitiated, cancellation: cancellation)) {
            XCTAssertEqual(($0 as? URLError)?.code, .cancelled)
        }
    }
}
