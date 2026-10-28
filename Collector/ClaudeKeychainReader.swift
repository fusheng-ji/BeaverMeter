import Foundation
import Security

/// Reads one credential belonging to the selected Claude Code profile. A
/// scheduled collection never turns an unsuccessful read into a password dialog.
enum ClaudeKeychainReader {
    enum Interaction: Sendable, Equatable {
        case background
        case userInitiated
    }

    enum ReadError: LocalizedError, Equatable {
        case keychainAccessRequired
        case keychainSessionUnavailable
        case userCancelled
        case unavailable(status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychainAccessRequired:
                "BeaverMeter needs permission to read Claude credentials. Choose Allow Claude access to verify quota."
            case .keychainSessionUnavailable:
                "The macOS Keychain session cannot read saved credentials. Choose Repair Keychain session; signing in to Claude again will not repair this system error."
            case .userCancelled:
                "Claude credential access was cancelled. Your saved sign-in has not been changed."
            case .unavailable:
                "Claude credentials are temporarily unavailable. Try verifying access again."
            }
        }
    }

    typealias Query = [String: Any]
    typealias QueryResult = (status: OSStatus, data: Data?)
    typealias QueryExecutor = (Query) -> QueryResult
    private static let interactionLock = NSLock()

    static func read(service: String, account: String, interaction: Interaction, operationPrompt: String? = nil,
                     cancellation: SubprocessCancellation? = nil) throws -> Data? {
        if cancellation?.isCancelled == true { throw URLError(.cancelled) }
        let data = try read(service: service, account: account, interaction: interaction, operationPrompt: operationPrompt,
                           sessionUnavailable: loginKeychainSessionUnavailable,
                           execute: { executeQuery($0, cancellation: cancellation) })
        if cancellation?.isCancelled == true { throw URLError(.cancelled) }
        return data
    }

    /// The executor is injected by tests so they never query a real Keychain or
    /// grant permission while checking status handling and the exact query.
    static func read(
        service: String, account: String, interaction: Interaction, operationPrompt: String? = nil,
        sessionUnavailable: () -> Bool = { false }, execute: QueryExecutor
    ) throws -> Data? {
        var query: Query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationUI as String: interaction == .background
                ? kSecUseAuthenticationUIFail : kSecUseAuthenticationUIAllow,
        ]
        if interaction == .userInitiated {
            query[kSecUseOperationPrompt as String] = operationPrompt
                ?? "BeaverMeter verifies your existing Claude Code sign-in to load quota."
        }
        let result = execute(query)
        switch result.status {
        case errSecSuccess:
            guard let data = result.data else { throw ReadError.unavailable(status: errSecDecode) }
            return data
        case errSecItemNotFound:
            return nil
        case errSecAuthFailed:
            if sessionUnavailable() { throw ReadError.keychainSessionUnavailable }
            throw ReadError.keychainAccessRequired
        case errSecInteractionNotAllowed:
            throw ReadError.keychainAccessRequired
        case errSecUserCanceled:
            throw ReadError.userCancelled
        default:
            throw ReadError.unavailable(status: result.status)
        }
    }

    private static func executeQuery(_ query: Query, cancellation: SubprocessCancellation?) -> QueryResult {
        // Claude Code uses the legacy login Keychain, whose authentication UI
        // is not reliably governed by kSecUseAuthenticationUI alone.
        interactionLock.lock()
        defer { interactionLock.unlock() }
        let interactive = query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIAllow as String
        return withInteractionPolicy(allow: interactive, current: {
            var allowed = DarwinBoolean(false)
            let status = SecKeychainGetUserInteractionAllowed(&allowed)
            return (status, allowed.boolValue)
        }, apply: { SecKeychainSetUserInteractionAllowed($0) }) {
            queryResult(query, executeNative: { nativeQuery in
                var result: CFTypeRef?
                let status = SecItemCopyMatching(nativeQuery as CFDictionary, &result)
                return (status, result as? Data)
            }, readTrusted: { service, account in
                try ClaudeTrustedSecurityReader.read(service: service, account: account, cancellation: cancellation)
            })
        }
    }

    /// Claude Code trusts its system reader, not necessarily this helper's code
    /// identity. Preserve that existing access only after an exact-item ACL
    /// preflight; never add the helper to an ACL or invoke an untrusted reader.
    static func queryResult(_ query: Query, executeNative: QueryExecutor,
                            readTrusted: (String, String) throws -> Data?) -> QueryResult {
        let result = executeNative(query)
        guard [errSecAuthFailed, errSecInteractionNotAllowed].contains(result.status),
              query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String,
              let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String else { return result }
        do {
            guard let data = try readTrusted(service, account) else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        } catch ClaudeKeychainReader.ReadError.userCancelled {
            return (errSecUserCanceled, nil)
        } catch ClaudeKeychainReader.ReadError.unavailable(let status) {
            return (status, nil)
        } catch let error as URLError {
            return (error.code == .cancelled ? errSecUserCanceled : errSecNotAvailable, nil)
        } catch {
            return result
        }
    }

    /// Fails closed if the legacy UI policy cannot be applied. Test injection
    /// checks restoration without touching the user's real Keychain.
    static func withInteractionPolicy(allow: Bool, current: () -> (OSStatus, Bool),
                                      apply: (Bool) -> OSStatus, operation: () -> QueryResult) -> QueryResult {
        let (readStatus, previous) = current()
        guard readStatus == errSecSuccess else { return (readStatus, nil) }
        let setStatus = apply(allow)
        guard setStatus == errSecSuccess else { return (setStatus, nil) }
        defer { _ = apply(previous) }
        return operation()
    }

    /// Detects the system-wide stale legacy session separately from an item
    /// permission denial. No credential data or Keychain contents are changed.
    static func loginKeychainSessionUnavailable() -> Bool {
        var keychain: SecKeychain?
        guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else { return false }
        var status: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess,
              status & UInt32(kSecUnlockStateStatus) != 0 else { return false }
        var settings = SecKeychainSettings(version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1), lockOnSleep: false,
                                            useLockInterval: false, lockInterval: 0)
        return SecKeychainCopySettings(keychain, &settings) == errSecAuthFailed
    }
}
