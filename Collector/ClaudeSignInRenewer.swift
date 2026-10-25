import Darwin
import Foundation

/// Lets Claude Code renew its own expired sign-in. Claude Code refreshes its
/// OAuth token and rewrites its credentials while an interactive session starts,
/// so BeaverMeter briefly launches the CLI in a pseudo-terminal, waits until the
/// stored token changes and stops it. Only the built-in `/status` command may
/// be sent after the normal input prompt is visible. Folder-trust and login
/// questions are never answered and no model prompt is sent; BeaverMeter itself
/// never touches the refresh token.
enum ClaudeSignInRenewer {
    /// The cancellation callback can outlive its registration if cancel() has
    /// already copied it. Guard the Process lifetime so a delayed callback
    /// never signals a PID after the child has finished.
    private final class RenewalChild: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var active = true

        init(_ process: Process) { self.process = process }
        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            if active, process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        func finish() {
            lock.lock()
            active = false
            lock.unlock()
        }
    }

    struct State: Codable {
        let lastAttemptAt: Date
    }

    static let cooldown: TimeInterval = 5 * 60

    /// The first installed Claude Code CLI. The LaunchAgent's PATH is minimal,
    /// so the usual install locations are checked explicitly.
    static func cliURL(
        environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        if let configured = CodexUsageSupport.nonempty(environment["CLAUDE_CLI_PATH"]) {
            let url = URL(fileURLWithPath: configured)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        return [
            homeDirectory.appendingPathComponent(".local/bin/claude"),
            homeDirectory.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ].first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func isAllowed(environment: [String: String]) -> Bool {
        environment["CLAUDE_CLI_REFRESH"] != "0" && environment["CLAUDE_KEYCHAIN_ACCESS"] != "0"
    }

    static func refreshStateURL(stateDirectory: URL, environment: [String: String]) throws -> URL {
        let profile = try ClaudeCredentialResolver.profileIdentity(environment: environment)
        let identity = CodexUsageSupport.hash(profile)
        return stateDirectory.appendingPathComponent("beaver-meter-claude-refresh-v2-\(identity).json")
    }

    /// Claude hashes the raw root string and resolves relative roots against
    /// its cwd. Preserve both when a caller explicitly selected such a root.
    /// This changes only the child process, never the application's cwd.
    static func renewalWorkingDirectory(
        preferred: URL, environment: [String: String],
        callerDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) -> URL {
        let roots = [environment["CLAUDE_CONFIG_DIR"], environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"]].compactMap { $0 }
        return roots.contains(where: { !($0 as NSString).isAbsolutePath }) ? callerDirectory : preferred
    }

    /// At most one CLI launch per cooldown, so a dead refresh token does not
    /// start Claude Code on every refresh.
    static func reserveAttempt(stateURL: URL, now: Date) -> Bool {
        if let state = CodexUsageSupport.load(State.self, from: stateURL),
           now.timeIntervalSince(state.lastAttemptAt) < cooldown,
           now >= state.lastAttemptAt {
            return false
        }
        try? AtomicFileWriter.writeJSON(State(lastAttemptAt: now), to: stateURL)
        return true
    }

    /// Runs the CLI until `isRenewed` reports a valid token or the timeout ends.
    static func renew(
        cli: URL,
        workingDirectory: URL,
        timeout: TimeInterval = 20,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cancellation: SubprocessCancellation? = nil,
        isRenewed: () -> Bool
    ) -> Bool {
        guard cancellation?.isCancelled != true else { return false }
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { return false }
        defer { Darwin.close(master) }
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        let childDirectory = renewalWorkingDirectory(preferred: workingDirectory, environment: environment)
        try? FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let process = Process()
        process.executableURL = cli
        process.currentDirectoryURL = childDirectory
        var terminalEnvironment = loginEnvironment(environment)
        terminalEnvironment["TERM"] = "xterm-256color"
        terminalEnvironment["PWD"] = childDirectory.path
        process.environment = terminalEnvironment
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        do {
            guard cancellation?.isCancelled != true else { return false }
            try process.run()
        } catch {
            return false
        }
        try? terminal.close()
        // Credential reads may block while the UI cancels. Kill this known
        // child directly from the callback rather than waiting for the poll.
        let child = RenewalChild(process)
        let cancellationHandler = cancellation?.onCancel { child.cancel() }
        defer {
            child.finish()
            if let cancellationHandler { cancellation?.removeHandler(cancellationHandler) }
        }

        var renewed = false
        var statusSent = false
        var screen = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline, cancellation?.isCancelled != true {
            // Drain the screen output so the CLI never blocks on a full terminal.
            while true {
                let count = Darwin.read(master, &buffer, buffer.count)
                guard count > 0 else { break }
                screen.append(contentsOf: buffer.prefix(count))
                if screen.count > 32_768 { screen.removeFirst(screen.count - 32_768) }
            }
            if !statusSent, cancellation?.isCancelled != true, statusInputIsReady(String(decoding: screen, as: UTF8.self)) {
                // Never send a bare Enter: it could accept a trust/login prompt.
                // The fixed built-in command cannot become a model request.
                let command = Data("/status\r".utf8)
                statusSent = command.withUnsafeBytes { bytes in
                    Darwin.write(master, bytes.baseAddress, bytes.count) == bytes.count
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
            if cancellation?.isCancelled == true { break }
            if isRenewed() {
                renewed = true
                break
            }
        }
        if process.isRunning {
            process.terminate()
            let stopDeadline = ProcessInfo.processInfo.systemUptime + (cancellation?.isCancelled == true ? 0.2 : 2)
            while process.isRunning, ProcessInfo.processInfo.systemUptime < stopDeadline {
                while Darwin.read(master, &buffer, buffer.count) > 0 {}
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        child.finish()
        if let cancellationHandler { cancellation?.removeHandler(cancellationHandler) }
        guard cancellation?.isCancelled != true else { return false }
        return renewed || isRenewed()
    }

    /// Environment tokens can override the selected local sign-in (setup-token
    /// credentials are not usage OAuth credentials). Keep the CLI on the same
    /// stored profile as the resolver, without exposing any override to it.
    static func loginEnvironment(_ environment: [String: String]) -> [String: String] {
        var result = environment.filter { !$0.key.hasPrefix("ANTHROPIC_") && !$0.key.hasPrefix("CLAUDE_CODE_OAUTH_TOKEN") }
        result["DISABLE_AUTOUPDATER"] = "1"
        return result
    }

    static func statusInputIsReady(_ output: String) -> Bool {
        let plain = output.replacingOccurrences(of: #"\x1B\][^\x07]*(?:\x07|\x1B\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        let lower = plain.lowercased()
        guard lower.contains("? for shortcuts"),
              !["trust this folder", "trust the files", "quick safety check", "ready to code here?",
                "press enter to continue", "select login method", "choose the text style"].contains(where: lower.contains)
        else { return false }
        return plain.components(separatedBy: .newlines).contains { line in
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return line == "❯" || line == ">" || line.hasPrefix("❯ Try \"") || line.hasPrefix("> Try \"")
        }
    }
}
