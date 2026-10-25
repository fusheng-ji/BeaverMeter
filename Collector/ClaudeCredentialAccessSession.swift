import Foundation

/// An explicit verification may ask macOS once. Polling during token renewal
/// remains noninteractive even if Claude Code replaces the Keychain item.
final class ClaudeCredentialAccessSession: @unchecked Sendable {
    typealias Reader = @Sendable ([String: String], ClaudeKeychainReader.Interaction) throws -> Data
    private let lock = NSLock()
    private var firstRead = true
    private let authorize: Bool
    private let reader: Reader

    init(authorize: Bool, cancellation: SubprocessCancellation? = nil, reader: Reader? = nil) {
        self.authorize = authorize
        self.reader = reader ?? { environment, interaction in
            try ClaudeCredentialResolver.credentialsData(environment: environment, interaction: interaction,
                                                         cancellation: cancellation)
        }
    }

    func read(environment: [String: String]) throws -> Data {
        lock.lock()
        let interaction: ClaudeKeychainReader.Interaction = authorize && firstRead ? .userInitiated : .background
        firstRead = false
        lock.unlock()
        return try reader(environment, interaction)
    }
}
