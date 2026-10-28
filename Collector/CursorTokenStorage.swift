import CommonCrypto
import Foundation

/// Cursor 3.27+ wraps auth tokens with Electron safeStorage. On macOS its
/// `v10` payload uses the Chromium AES-CBC format and Cursor's Keychain key.
/// Cursor's database is never changed. A verified access token may be saved in
/// BeaverMeter's private session file; the Safe Storage key stays in memory.
enum CursorTokenStorage {
    private static let encryptedPrefix = "cursor-safe-storage:v1:"

    static func isEncrypted(_ storedToken: String) -> Bool {
        storedToken.hasPrefix(encryptedPrefix)
    }

    static func decode(
        _ storedToken: String,
        passwordReader: () throws -> Data = readSafeStoragePassword
    ) throws -> String {
        guard storedToken.hasPrefix(encryptedPrefix) else {
            if storedToken.hasPrefix("cursor-safe-storage:") {
                throw CursorDashboardError.invalidSession(
                    "Cursor uses an unsupported encrypted credential format. Update BeaverMeter."
                )
            }
            return storedToken
        }
        guard let encrypted = Data(base64Encoded: String(storedToken.dropFirst(encryptedPrefix.count))),
              encrypted.starts(with: Data("v10".utf8)),
              encrypted.count > 3,
              (encrypted.count - 3) % kCCBlockSizeAES128 == 0 else {
            throw invalidEncryptedToken()
        }

        let password: Data
        do {
            password = try passwordReader()
        } catch let error as CursorDashboardError {
            throw error
        } catch {
            throw keychainReadError()
        }
        guard !password.isEmpty else { throw invalidEncryptedToken() }
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let derived = password.withUnsafeBytes { passwordBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1003, &key, kCCKeySizeAES128
            )
        }
        guard derived == kCCSuccess else { throw invalidEncryptedToken() }

        let ciphertext = Data(encrypted.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        let capacity = ciphertext.count + kCCBlockSizeAES128
        var plaintext = [UInt8](repeating: 0, count: capacity)
        var written = 0
        let status = ciphertext.withUnsafeBytes { ciphertextBytes in
            CCCrypt(
                CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                key, key.count, iv, ciphertextBytes.baseAddress, ciphertext.count,
                &plaintext, capacity, &written
            )
        }
        guard status == kCCSuccess,
              let token = String(bytes: plaintext.prefix(written), encoding: .utf8),
              !token.isEmpty else { throw invalidEncryptedToken() }
        return token
    }

    static func readSafeStoragePassword() throws -> Data {
        try readSafeStoragePassword { service, account in
            // Share the existing noninteractive Keychain policy, including its
            // exact-item ACL check before using the trusted system reader.
            try ClaudeKeychainReader.read(service: service, account: account, interaction: .background)
        }
    }

    /// Only the explicit Cursor access action may ask macOS for permission.
    static func authorizeKeychainAccess(cancellation: SubprocessCancellation? = nil) throws -> Data {
        try readSafeStoragePassword { service, account in
            try ClaudeKeychainReader.read(
                service: service, account: account, interaction: .userInitiated,
                operationPrompt: "BeaverMeter reads your existing Cursor sign-in to load usage.",
                cancellation: cancellation
            )
        }
    }

    static func readSafeStoragePassword(read: (_ service: String, _ account: String) throws -> Data?) throws -> Data {
        do {
            guard var password = try read("Cursor Safe Storage", "Cursor Key") else {
                throw CursorDashboardError.invalidSession(
                    "Cursor's encryption key was not found in macOS Keychain. Open Cursor and sign in again."
                )
            }
            // The trusted `security -w` fallback terminates its output with a
            // newline. Chromium's generated password is a base64 string.
            while password.last == 0x0A || password.last == 0x0D { password.removeLast() }
            guard !password.isEmpty else { throw invalidEncryptedToken() }
            return password
        } catch let error as CursorDashboardError {
            throw error
        } catch {
            throw keychainReadError()
        }
    }

    private static func invalidEncryptedToken() -> CursorDashboardError {
        .invalidSession("Cursor's saved login could not be decrypted. Open Cursor and sign in again.")
    }

    private static func keychainReadError() -> CursorDashboardError {
        .invalidSession("Cursor's encryption key could not be read from macOS Keychain. Choose Allow Cursor access to read Cursor Safe Storage.")
    }
}
