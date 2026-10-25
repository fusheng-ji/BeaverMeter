import Foundation

/// Delegates credential renewal and CLI identification to Claude Code. Quota
/// parsing stays in ClaudeQuotaCollector; this type owns the CLI interaction.
enum ClaudeCredentialRenewal {
    struct Credential: Sendable {
        let token: String
        let planName: String?
    }

    /// Asks Claude Code to renew its sign-in and reads the renewed token.
    static func renewedToken(
        now: Date,
        stateDirectory: URL,
        environment: [String: String],
        rejectedToken: String? = nil,
        cancellation: SubprocessCancellation? = nil,
        credentialReader: ClaudeQuotaCollector.CredentialReader = ClaudeQuotaCollector.credentialsData
    ) throws -> String {
        try renewedCredential(now: now, stateDirectory: stateDirectory, environment: environment,
                              rejectedToken: rejectedToken, cancellation: cancellation,
                              credentialReader: credentialReader).token
    }

    /// Keeps metadata paired with the same final document as the verified token.
    static func renewedCredential(
        now: Date,
        stateDirectory: URL,
        environment: [String: String],
        rejectedToken: String? = nil,
        cancellation: SubprocessCancellation? = nil,
        credentialReader: ClaudeQuotaCollector.CredentialReader = ClaudeQuotaCollector.credentialsData
    ) throws -> Credential {
        func checkCancellation() throws {
            if cancellation?.isCancelled == true { throw URLError(.cancelled) }
        }
        try checkCancellation()
        let baseline: String?
        if let rejectedToken {
            baseline = rejectedToken
        } else {
            do {
                let credentials = try credentialReader(environment)
                baseline = try? ClaudeQuotaCollector.accessToken(fromCredentials: credentials, now: .distantPast)
            } catch let error as ClaudeKeychainReader.ReadError {
                // An unreadable stored login cannot establish a baseline. It
                // needs access verification, not another sign-in or CLI launch.
                throw error
            } catch where (error as? URLError)?.code == .cancelled {
                throw error
            } catch {
                baseline = nil
            }
        }
        guard ClaudeSignInRenewer.isAllowed(environment: environment) else {
            try checkCancellation()
            throw ClaudeRenewalError.disabled
        }
        guard let cli = ClaudeSignInRenewer.cliURL(environment: environment) else {
            try checkCancellation()
            throw ClaudeRenewalError.cliUnavailable
        }
        guard ClaudeSignInRenewer.reserveAttempt(
            stateURL: try ClaudeSignInRenewer.refreshStateURL(stateDirectory: stateDirectory, environment: environment), now: now
        ) else {
            try checkCancellation()
            throw ClaudeRenewalError.retryLater
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let currentDate = { now.addingTimeInterval(ProcessInfo.processInfo.systemUptime - startedAt) }
        // A Keychain read can fail after Claude Code rotates its credential.
        // Stop this child promptly, but do not cancel the caller's whole task:
        // the original access error must remain distinguishable from logout.
        let renewalCancellation = SubprocessCancellation()
        let cancellationHandler = cancellation?.onCancel { renewalCancellation.cancel() }
        defer {
            if let cancellationHandler { cancellation?.removeHandler(cancellationHandler) }
        }
        var credentialReadFailure: Error?
        let isRenewed = {
            guard cancellation?.isCancelled != true else { return false }
            let credentials: Data
            do {
                credentials = try credentialReader(environment)
            } catch let error as ClaudeKeychainReader.ReadError {
                credentialReadFailure = error
                renewalCancellation.cancel()
                return false
            } catch where (error as? URLError)?.code == .cancelled {
                credentialReadFailure = error
                renewalCancellation.cancel()
                return false
            } catch { return false }
            guard let token = try? ClaudeQuotaCollector.accessToken(fromCredentials: credentials, now: currentDate()) else { return false }
            // A server-rejected token can still have a future local expiry.
            // Wait for Claude Code to replace it before stopping the CLI.
            return token != baseline
        }
        let renewed = ClaudeSignInRenewer.renew(
            cli: cli,
            workingDirectory: stateDirectory.appendingPathComponent("claude-sign-in", isDirectory: true),
            environment: environment,
            cancellation: renewalCancellation,
            isRenewed: isRenewed
        )
        try checkCancellation()
        if let credentialReadFailure { throw credentialReadFailure }
        guard renewed else { throw ClaudeRenewalError.notCompleted }
        let credentials: Data
        do {
            credentials = try credentialReader(environment)
        } catch let error as ClaudeQuotaError where error == .notLoggedIn || error == .expired {
            // The CLI may be replacing the stored document between polling
            // and this final read. That gap does not prove a revoked login.
            throw ClaudeRenewalError.notCompleted
        }
        let token: String
        do {
            token = try ClaudeQuotaCollector.accessToken(fromCredentials: credentials, now: currentDate())
        } catch {
            // A token observed during polling may have changed again. Until
            // the usage endpoint verifies a replacement, this is incomplete
            // renewal rather than proof that a browser login is necessary.
            throw ClaudeRenewalError.notCompleted
        }
        try checkCancellation()
        guard token != baseline else { throw ClaudeRenewalError.notCompleted }
        return Credential(token: token, planName: ClaudeQuotaCollector.planName(fromCredentials: credentials))
    }

    static func userAgent(environment: [String: String], cancellation: SubprocessCancellation? = nil) -> String {
        guard let cli = ClaudeSignInRenewer.cliURL(environment: environment),
              let result = try? SubprocessRunner.run(executable: cli, arguments: ["--version"], timeout: 5,
                                                     environment: environment, cancellation: cancellation, terminationGrace: 0.2),
              result.status == 0, !result.timedOut,
              let text = String(data: result.standardOutput, encoding: .utf8),
              let range = text.range(of: #"^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?"#, options: .regularExpression)
        else { return "BeaverMeter" }
        return "claude-cli/\(text[range]) (external, cli)"
    }
}
