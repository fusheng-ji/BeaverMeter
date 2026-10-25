import XCTest

final class ClaudeAuthenticationModeTests: XCTestCase {
    func testOnlyExplicitLoginAndAccessActionsAllowKeychainInteraction() {
        let interactiveModes = Set(ClaudeAuthenticationMode.allCases.filter(\.allowsKeychainInteraction))
        XCTAssertEqual(interactiveModes, [.signIn, .authorizeAccess, .repairKeychainSession])
        XCTAssertFalse(ClaudeAuthenticationMode.verify.allowsKeychainInteraction)
    }
}
