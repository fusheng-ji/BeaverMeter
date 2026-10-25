import Security
import XCTest

final class ClaudeSecurityReadAuthorizationTests: XCTestCase {
    private let service = "Claude Code-credentials-selected-profile"
    private let account = "selected-user"

    private func entry(authorization: String = kSecACLAuthorizationDecrypt as String,
                       requiresPassphrase: Bool = false, trusted: Bool = true) -> ClaudeSecurityReadAuthorization.Entry {
        .init(authorizations: [authorization], requiresPassphrase: requiresPassphrase, trustsSecurityExecutable: trusted)
    }

    private func metadata(service: String? = nil, account: String? = nil, unlocked: Bool = true,
                          settingsReadable: Bool = true,
                          entries: [ClaudeSecurityReadAuthorization.Entry]) -> ClaudeSecurityReadAuthorization.Metadata {
        .init(service: service ?? self.service, account: account ?? self.account, keychainUnlocked: unlocked,
              keychainSettingsReadable: settingsReadable, entries: entries)
    }

    private func permits(_ metadata: ClaudeSecurityReadAuthorization.Metadata?) -> Bool {
        ClaudeSecurityReadAuthorization.permitsRead(service: service, account: account) { requestedService, requestedAccount in
            XCTAssertEqual(requestedService, service)
            XCTAssertEqual(requestedAccount, account)
            return metadata
        }
    }

    func testExactSelectedItemWithTrustedDecryptOrAnyGrantCanBeRead() {
        XCTAssertTrue(permits(metadata(entries: [entry()])))
        XCTAssertTrue(permits(metadata(entries: [entry(authorization: kSecACLAuthorizationAny as String)])))
    }

    func testMissingMetadataOrDifferentIdentityCannotAuthorizeARead() {
        XCTAssertFalse(permits(nil))
        XCTAssertFalse(permits(metadata(service: "another-profile", entries: [entry()])))
        XCTAssertFalse(permits(metadata(account: "another-user", entries: [entry()])))
    }

    func testLockedOrUnreadableKeychainNeverAuthorizesTheExternalReader() {
        XCTAssertFalse(permits(metadata(unlocked: false, entries: [entry()])))
        XCTAssertFalse(permits(metadata(settingsReadable: false, entries: [entry()])))
    }

    func testPassphraseRequirementMissingTrustOrUnrelatedAuthorizationIsDenied() {
        XCTAssertFalse(permits(metadata(entries: [])))
        XCTAssertFalse(permits(metadata(entries: [entry(requiresPassphrase: true)])))
        XCTAssertFalse(permits(metadata(entries: [entry(trusted: false)])))
        XCTAssertFalse(permits(metadata(entries: [entry(authorization: kSecACLAuthorizationChangeACL as String)])))
    }

    func testReadPermissionAndTrustMustBelongToTheSameEntry() {
        XCTAssertFalse(permits(metadata(entries: [entry(trusted: false),
            entry(authorization: kSecACLAuthorizationChangeACL as String)])))
        XCTAssertTrue(permits(metadata(entries: [entry(trusted: false), entry()])))
    }

    func testEmptyOrNulIdentityDoesNotQueryAnyMetadata() {
        for identity in ["", "bad\0suffix"] {
            XCTAssertFalse(ClaudeSecurityReadAuthorization.permitsRead(service: identity, account: account) { _, _ in
                XCTFail("Invalid service must not query Keychain metadata")
                return nil
            })
            XCTAssertFalse(ClaudeSecurityReadAuthorization.permitsRead(service: service, account: identity) { _, _ in
                XCTFail("Invalid account must not query Keychain metadata")
                return nil
            })
        }
    }
}
