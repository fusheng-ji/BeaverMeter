import Security
import XCTest

final class ClaudeKeychainSessionRepairTests: XCTestCase {
    func testUserRequestedRepairLocksThenUnlocksExactlyOnce() throws {
        var actions: [String] = []
        try ClaudeKeychainSessionRepair.repair(lock: { actions.append("lock"); return errSecSuccess },
            unlock: { actions.append("unlock"); return errSecSuccess })
        XCTAssertEqual(actions, ["lock", "unlock"])
    }

    func testLockFailureDoesNotAskForPassword() {
        XCTAssertThrowsError(try ClaudeKeychainSessionRepair.repair(lock: { errSecNotAvailable },
            unlock: { XCTFail("Must not unlock after a failed lock"); return errSecSuccess })) {
            XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, .unavailable(status: errSecNotAvailable))
        }
    }

    func testCancelledUnlockIsNotRetriedOrReportedAsMissingClaudeLogin() {
        var attempts = 0
        XCTAssertThrowsError(try ClaudeKeychainSessionRepair.repair(lock: { errSecSuccess },
            unlock: { attempts += 1; return errSecUserCanceled })) {
            XCTAssertEqual($0 as? ClaudeKeychainSessionRepair.RepairError, .unlockFailed(errSecUserCanceled))
            XCTAssertTrue($0.localizedDescription.contains("may remain locked"))
        }
        XCTAssertEqual(attempts, 1)
    }

    func testCancelledActionNeverLocksKeychain() {
        let cancellation = SubprocessCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try ClaudeKeychainSessionRepair.repair(cancellation: cancellation,
            lock: { XCTFail("Cancelled action must not lock Keychain"); return errSecSuccess },
            unlock: { XCTFail("Cancelled action must not prompt"); return errSecSuccess })) {
            XCTAssertEqual(($0 as? URLError)?.code, .cancelled)
        }
    }
}
