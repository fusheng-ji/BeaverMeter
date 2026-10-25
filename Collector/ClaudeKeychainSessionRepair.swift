import Foundation
import Security

/// A user-confirmed workaround for the legacy login Keychain's stale unlocked
/// state. It never deletes a credential or changes its password or access list.
enum ClaudeKeychainSessionRepair {
    enum RepairError: LocalizedError, Equatable {
        case unlockFailed(OSStatus)

        var errorDescription: String? {
            "macOS could not unlock the login Keychain. It may remain locked; unlock it with your Mac login password before verifying Claude again. No Claude credentials were deleted."
        }
    }

    static func repairIfNeeded(cancellation: SubprocessCancellation? = nil) throws {
        if cancellation?.isCancelled == true { throw URLError(.cancelled) }
        guard ClaudeKeychainReader.loginKeychainSessionUnavailable() else { return }
        var keychain: SecKeychain?
        let status = SecKeychainCopyDefault(&keychain)
        guard status == errSecSuccess, let keychain else {
            throw ClaudeKeychainReader.ReadError.unavailable(status: status)
        }
        try repair(cancellation: cancellation, lock: { SecKeychainLock(keychain) }, unlock: {
            // macOS owns the password dialog; the password never enters BeaverMeter.
            SecKeychainUnlock(keychain, 0, nil, false)
        })
    }

    static func repair(cancellation: SubprocessCancellation? = nil, lock: () -> OSStatus, unlock: () -> OSStatus) throws {
        if cancellation?.isCancelled == true { throw URLError(.cancelled) }
        let lockStatus = lock()
        guard lockStatus == errSecSuccess else {
            throw ClaudeKeychainReader.ReadError.unavailable(status: lockStatus)
        }
        let unlockStatus = unlock()
        guard unlockStatus == errSecSuccess else {
            throw RepairError.unlockFailed(unlockStatus)
        }
    }
}
