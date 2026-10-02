import CodexBarCore
import Foundation

enum CodexWorkspaceLoginCollector {
    enum LoginError: LocalizedError, Equatable {
        case missingCLI, timedOut, failed, wrongWorkspace, unsafeDirectory
        case cliFailed(Int32, String)
        var errorDescription: String? {
            switch self {
            case .missingCLI: "Codex CLI was not found. Install Codex, then try again."
            case .timedOut: "Sign-in timed out. Choose Sign in to try again."
            case .failed: "Codex sign-in did not finish. Try again and complete the browser sign-in."
            case .wrongWorkspace: "The signed-in workspace differs from this workspace. Select the matching workspace in your browser."
            case .unsafeDirectory: "The workspace login directory is invalid."
            case let .cliFailed(code, reason): "Codex sign-in failed (exit code \(code)). \(reason)"
            }
        }
    }

    static func run(id: UUID, label: String, directory: URL,
                    environment: [String: String] = ProcessInfo.processInfo.environment,
                    executableOverride: URL? = nil, timeout: TimeInterval = 180) throws {
        let store = CodexWorkspaceStore(directory: directory)
        let saved = try store.load().first { $0.id == id }
        let home = store.home(for: id).standardizedFileURL
        guard home.resolvingSymlinksInPath().path == home.path else { throw LoginError.unsafeDirectory }
        var scoped = CodexHomeScope.scopedEnvironment(base: environment, codexHome: home.path)
        scoped["PATH"] = PathBuilder.effectivePATH(purposes: [.rpc, .tty, .nodeTooling], env: scoped,
                                                  loginPATH: LoginShellPathCache.shared.current)
        let executable = try executableOverride ?? resolvedCLI(environment: scoped)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.deletingLastPathComponent().path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        let authLock = try SnapshotWriter.lock(for: home.appendingPathComponent("auth.json"))
        defer { authLock.unlock() }
        var arguments = ["-c", "cli_auth_credentials_store=\"file\""]
        if let saved {
            // JSON string quoting is Codex's TOML config value here, never a shell command.
            let value = String(data: try JSONEncoder().encode(saved.workspaceAccountID), encoding: .utf8)!
            arguments += ["-c", "forced_chatgpt_workspace_id=\(value)"]
        }
        arguments.append("login")
        let result = try SubprocessRunner.run(executable: executable, arguments: arguments,
            timeout: timeout, environment: scoped, captureStandardOutput: false)
        // CLI output can contain OAuth URLs. Only fixed messages cross into UI/logs.
        if result.timedOut { throw LoginError.timedOut }
        if result.status != 0 || result.cancelled {
            let reason = failureReason(stderr: result.standardError)
            let diagnostic = LoginFailureDiagnostic(attemptedAt: Date(), exitCode: result.status,
                executable: executable.path, reason: reason)
            try? AtomicFileWriter.writeJSON(diagnostic, to: home.appendingPathComponent("beaver-meter-login-error.json"))
            throw LoginError.cliFailed(result.status, reason)
        }
        let credentials = try CodexOAuthCredentialsStore.loadOAuthTokens(env: scoped)
        guard !credentials.isAPIKey,
              let workspaceID = CodexOpenAIWorkspaceResolver.normalizeWorkspaceAccountID(credentials.accountId) else {
            throw LoginError.failed
        }
        if let saved, saved.workspaceAccountID != workspaceID { throw LoginError.wrongWorkspace }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.appendingPathComponent("auth.json").path)
        let registryLock = try SnapshotWriter.lock(for: store.metadataURL)
        defer { registryLock.unlock() }
        try store.save(CodexWorkspaceLogin(id: id, label: saved?.label ?? label, workspaceAccountID: workspaceID))
    }

    private struct LoginFailureDiagnostic: Encodable {
        let attemptedAt: Date
        let exitCode: Int32
        let executable: String
        let reason: String
    }

    static func resolvedCLI(environment: [String: String]) throws -> URL {
        if environment["CODEX_CLI_PATH"] == nil {
            // Recent desktop releases moved the native CLI into CodexCLI.app;
            // the pinned upstream resolver knows the previous flat layout.
            for app in ["/Applications/ChatGPT.app", "/Applications/Codex.app",
                        NSHomeDirectory() + "/Applications/ChatGPT.app", NSHomeDirectory() + "/Applications/Codex.app"] {
                let path = app + "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
                var candidate = environment
                candidate["CODEX_CLI_PATH"] = path
                if BinaryLocator.resolveCodexBinary(env: candidate) == path { return URL(fileURLWithPath: path) }
            }
        }
        guard let path = BinaryLocator.resolveCodexBinary(env: environment) else { throw LoginError.missingCLI }
        return URL(fileURLWithPath: path)
    }

    /// Fixed classifications only: OAuth URLs, state, authorization codes and
    /// tokens in CLI output are never copied into UI, diagnostics or snapshots.
    static func failureReason(stderr: Data) -> String {
        let text = String(decoding: stderr, as: UTF8.self).lowercased()
        if text.contains("node") && (text.contains("no such file") || text.contains("not found")) {
            return "The selected Codex launcher requires Node.js, which could not be found. Use the desktop Codex CLI or install Node.js."
        }
        if text.contains("address already in use") || text.contains("port is already") {
            return "Another sign-in is using the local callback port. Finish that sign-in, then try again."
        }
        if text.contains("error loading configuration") || text.contains("error parsing -c") {
            return "Codex could not load its login configuration."
        }
        if text.contains("permission denied") || text.contains("operation not permitted") {
            return "Codex was denied access to its login directory or callback server."
        }
        if text.contains("token exchange") {
            return "The browser authorization could not be exchanged for a login. Start a new sign-in and complete its browser flow."
        }
        if text.contains("cancelled") || text.contains("canceled") || text.contains("access_denied") {
            return "Browser authorization was cancelled or denied."
        }
        if text.contains("device") && (text.contains("403") || text.contains("disabled") || text.contains("not enabled")) {
            return "Device-code sign-in is unavailable for this account. Use browser sign-in."
        }
        if text.contains("connection refused") || text.contains("dns") || text.contains("connect error") || text.contains("error sending request") {
            return "Codex could not connect to the sign-in service. Check the network or proxy settings."
        }
        return "Browser sign-in did not complete. Try again with a new sign-in request."
    }
}
