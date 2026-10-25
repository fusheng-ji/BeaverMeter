import CryptoKit
import Darwin
import Foundation

/// Mirrors the installed production Claude Code CLI's Keychain-first credential store.
/// A profile is selected once; neither missing credentials nor expiry searches another profile.
enum ClaudeCredentialResolver {
    typealias FileReader = (URL) throws -> Data?
    typealias KeychainReader = (_ service: String, _ account: String) throws -> Data?

    enum ResolutionError: LocalizedError, Equatable {
        case unsupportedOAuthEndpoint
        case credentialStoreUnavailable

        var errorDescription: String? {
            switch self {
            case .unsupportedOAuthEndpoint:
                "Claude custom OAuth endpoints are not supported for usage verification. Use a production Claude Code sign-in."
            case .credentialStoreUnavailable:
                "Claude credentials are temporarily unavailable. Try verifying again."
            }
        }
    }

    static func credentialsData(environment: [String: String]) throws -> Data {
        try credentialsData(environment: environment, interaction: .background)
    }

    static func credentialsData(
        environment: [String: String], interaction: ClaudeKeychainReader.Interaction,
        cancellation: SubprocessCancellation? = nil
    ) throws -> Data {
        try credentialsData(environment: environment,
                            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                            fileReader: readCredentialFile,
                            keychainReader: { service, account in
                                try ClaudeKeychainReader.read(service: service, account: account, interaction: interaction,
                                                             cancellation: cancellation)
                            })
    }

    static func credentialsData(
        environment: [String: String], homeDirectory: URL,
        fileReader: FileReader, keychainReader: KeychainReader
    ) throws -> Data {
        // Reject custom OAuth before touching a source: its token must never reach the production usage endpoint.
        let service = try keychainServiceName(environment: environment, homeDirectory: homeDirectory)
        var keychainFailure: Error?
        var fileReadFailed = false
        if environment["CLAUDE_KEYCHAIN_ACCESS"] != "0" {
            do {
                if let data = try keychainReader(service, keychainAccountName(environment: environment)),
                   isPresentDocument(data) {
                    // Any non-null Keychain document is authoritative, including an expired or signed-out record.
                    return data
                }
            } catch {
                // A user cancellation ends this action; do not bypass it by
                // reading the file and sending an authenticated request anyway.
                if error as? ClaudeKeychainReader.ReadError == .userCancelled { throw error }
                if (error as? URLError)?.code == .cancelled { throw error }
                keychainFailure = error
            }
        }
        do {
            if let data = try fileReader(credentialFileURL(environment: environment, homeDirectory: homeDirectory)),
               isPresentDocument(data) {
                return data
            }
        } catch {
            fileReadFailed = true
        }
        // A denied read is not evidence that Claude is signed out.
        // Preserve that distinction after checking the same-profile CLI fallback.
        if let failure = keychainFailure as? ClaudeKeychainReader.ReadError { throw failure }
        if keychainFailure != nil || fileReadFailed { throw ResolutionError.credentialStoreUnavailable }
        throw ClaudeQuotaError.notLoggedIn
    }

    static func configDirectory(
        environment: [String: String], homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        URL(fileURLWithPath: configPath(environment: environment, homeDirectory: homeDirectory), isDirectory: true)
    }

    static func storageDirectory(
        environment: [String: String], homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        URL(fileURLWithPath: storagePath(environment: environment, homeDirectory: homeDirectory), isDirectory: true)
    }

    static func credentialFileURL(
        environment: [String: String], homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        storageDirectory(environment: environment, homeDirectory: homeDirectory).appendingPathComponent(".credentials.json")
    }

    /// Both renewal cooldown and usage cache must identify the same selected
    /// store. Keep this string stable so existing on-disk state stays compatible.
    static func profileIdentity(environment: [String: String]) throws -> String {
        storageDirectory(environment: environment).standardizedFileURL.path
            + "\n" + (try keychainServiceName(environment: environment))
    }

    static func keychainServiceName(
        environment: [String: String], homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> String {
        if let endpoint = environment["CLAUDE_CODE_CUSTOM_OAUTH_URL"], !endpoint.isEmpty {
            throw ResolutionError.unsupportedOAuthEndpoint
        }
        // Claude Code 2.1.301's production build fixes the OAuth file suffix to "".
        // USE_LOCAL_OAUTH/USE_STAGING_OAUTH do not select another login in that build.
        let hasCustomRoot: Bool
        if let override = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] {
            hasCustomRoot = !override.isEmpty
        } else {
            hasCustomRoot = !(environment["CLAUDE_CONFIG_DIR"] ?? "").isEmpty
        }
        guard hasCustomRoot else { return "Claude Code-credentials" }
        // The CLI hashes the NFC string before filesystem resolution, including a trailing slash or dot segment.
        let path = storagePath(environment: environment, homeDirectory: homeDirectory)
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
        return "Claude Code-credentials-\(hash)"
    }

    static func keychainAccountName(environment: [String: String], userName: String = NSUserName()) -> String {
        let user = environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? userName
        return user.range(of: #"^[a-zA-Z0-9._-]+$"#, options: .regularExpression) != nil ? user : "claude-code-user"
    }

    private static func configPath(environment: [String: String], homeDirectory: URL) -> String {
        let path = environment["CLAUDE_CONFIG_DIR"]
            ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true).path
        return path.precomposedStringWithCanonicalMapping
    }

    private static func storagePath(environment: [String: String], homeDirectory: URL) -> String {
        guard let override = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] else {
            return configPath(environment: environment, homeDirectory: homeDirectory)
        }
        return (override.isEmpty ? homeDirectory.appendingPathComponent(".claude", isDirectory: true).path : override)
            .precomposedStringWithCanonicalMapping
    }

    private static func isPresentDocument(_ data: Data) -> Bool {
        guard let document = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return false }
        return !(document is NSNull)
    }

    private static func readCredentialFile(_ url: URL) throws -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else {
            if [ENOENT, ENOTDIR, EISDIR, ELOOP].contains(errno) { return nil }
            throw ResolutionError.credentialStoreUnavailable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else { throw ResolutionError.credentialStoreUnavailable }
        guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        let limit = 1_048_576
        guard attributes.st_size <= limit else { return nil }
        var data = Data()
        while data.count <= limit {
            let chunk = try handle.read(upToCount: limit + 1 - data.count) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data.count <= limit ? data : nil
    }

}
