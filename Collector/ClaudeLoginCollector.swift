import Darwin
import Foundation

enum ClaudeLoginError: LocalizedError {
    case cliMissing, timedOut, cancelled, failed

    var errorDescription: String? {
        switch self {
        case .cliMissing: "Claude Code is missing. Install Claude Code, then try signing in again."
        case .timedOut: "Claude sign-in timed out. Complete the browser login, then choose Verify login."
        case .cancelled: "Claude sign-in cancelled."
        case .failed: "Claude sign-in did not complete. Try signing in again, or complete login in Claude Code and choose Verify login."
        }
    }
}

/// Claude Code owns its browser flow and credential storage. No OAuth secret or
/// login output is forwarded to the app, and no model request is made.
enum ClaudeLoginCollector {
    static func login(environment: [String: String], timeout: TimeInterval = 180,
                      cancellation suppliedCancellation: SubprocessCancellation? = nil) throws {
        _ = try ClaudeCredentialResolver.keychainServiceName(environment: environment)
        guard let cli = ClaudeSignInRenewer.cliURL(environment: environment) else {
            throw ClaudeLoginError.cliMissing
        }
        let cancellation = suppliedCancellation ?? SubprocessCancellation()
        // The app cancels its helper with SIGTERM. Forward that cancellation to
        // the CLI rather than leaving a browser-login process running detached.
        let termination = ClaudeAuthenticationSignalHandler(cancellation: cancellation)
        defer { termination.stop() }
        var loginEnvironment = environment
        loginEnvironment["DISABLE_AUTOUPDATER"] = "1"
        let result: SubprocessRunner.Result
        do {
            result = try SubprocessRunner.run(executable: cli, arguments: ["auth", "login", "--claudeai"],
                                              timeout: timeout, environment: loginEnvironment,
                                              captureStandardOutput: false, cancellation: cancellation,
                                              terminationGrace: 0.2)
        } catch {
            throw ClaudeLoginError.failed
        }
        if result.cancelled { throw ClaudeLoginError.cancelled }
        if result.timedOut { throw ClaudeLoginError.timedOut }
        guard result.status == 0 else { throw ClaudeLoginError.failed }
    }
}

/// Kept alive for the whole browser-login and quota-verification operation.
/// Cancellation also reaches a renewal started during verification.
final class ClaudeAuthenticationSignalHandler {
    // SIG_DFL is represented by a nil function pointer on Darwin.
    private let previousHandler: sig_t?
    private let source: DispatchSourceSignal

    init(cancellation: SubprocessCancellation) {
        previousHandler = signal(SIGTERM, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler { cancellation.cancel() }
        source.resume()
    }

    func stop() {
        source.cancel()
        signal(SIGTERM, previousHandler)
    }
}
