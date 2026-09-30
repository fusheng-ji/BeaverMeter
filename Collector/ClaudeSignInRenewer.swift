import Darwin
import Foundation

/// Lets Claude Code renew its own expired sign-in. Claude Code refreshes its
/// OAuth token and rewrites its credentials while an interactive session starts,
/// so BeaverMeter briefly launches the CLI in a pseudo-terminal, waits until the
/// stored token is valid again and stops it. No prompt is sent, the folder-trust
/// question is never answered and the model is never called; BeaverMeter itself
/// never touches the refresh token.
enum ClaudeSignInRenewer {
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
        isRenewed: () -> Bool
    ) -> Bool {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { return false }
        defer { Darwin.close(master) }
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let process = Process()
        process.executableURL = cli
        process.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        do {
            try process.run()
        } catch {
            return false
        }
        try? terminal.close()

        var renewed = false
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            // Drain the screen output so the CLI never blocks on a full terminal.
            while Darwin.read(master, &buffer, buffer.count) > 0 {}
            Thread.sleep(forTimeInterval: 0.5)
            if isRenewed() {
                renewed = true
                break
            }
        }
        if process.isRunning {
            process.terminate()
            let stopDeadline = ProcessInfo.processInfo.systemUptime + 2
            while process.isRunning, ProcessInfo.processInfo.systemUptime < stopDeadline {
                while Darwin.read(master, &buffer, buffer.count) > 0 {}
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        return renewed || isRenewed()
    }
}
