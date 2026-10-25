import Foundation

/// The app and helper share the command contract for explicit Claude actions.
/// Verify stays noninteractive; only a user-requested login or access action may
/// ask macOS for access to the existing Keychain credential.
enum ClaudeAuthenticationMode: String, CaseIterable, Hashable, Sendable {
    case signIn = "--claude-login"
    case verify = "--claude-verify"
    case authorizeAccess = "--claude-authorize"
    case repairKeychainSession = "--claude-repair-keychain"

    var argument: String { rawValue }

    var timeout: TimeInterval {
        switch self {
        case .signIn: 210
        case .verify: 60
        case .authorizeAccess, .repairKeychainSession: 120
        }
    }

    var timeoutMessage: String {
        switch self {
        case .signIn: "Claude sign-in timed out. Finish signing in, then verify the login."
        case .verify: "Claude login verification timed out. Try again."
        case .authorizeAccess: "Claude access authorization timed out. Verify the saved login again."
        case .repairKeychainSession: "Keychain session repair timed out. Verify the saved Claude login again."
        }
    }

    var progressMessage: String {
        switch self {
        case .signIn: "Complete Claude sign-in in your browser. The quota will be verified automatically…"
        case .verify: "Verifying Claude login and loading current quota…"
        case .authorizeAccess: "Allow macOS access to the saved Claude login. Current quota will be verified automatically…"
        case .repairKeychainSession: "Unlock the login Keychain in the macOS dialog. Current Claude quota will be verified automatically…"
        }
    }

    var allowsKeychainInteraction: Bool {
        switch self {
        case .verify: false
        case .signIn, .authorizeAccess, .repairKeychainSession: true
        }
    }
}
