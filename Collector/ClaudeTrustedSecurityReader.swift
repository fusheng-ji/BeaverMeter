import Darwin
import Foundation
import Security

/// Compatibility with Claude Code's trusted `/usr/bin/security` reader. The
/// caller serializes native Keychain policy changes; this reader additionally
/// requires current, exact-item authorization evidence before starting a child.
/// Password data stays in a bounded memory pipe and is never written to stdio,
/// a temporary file, diagnostic text, or a credential cache.
enum ClaudeTrustedSecurityReader {
    typealias Authorization = (_ service: String, _ account: String) -> Bool
    typealias Executor = (
        _ executable: URL, _ arguments: [String], _ timeout: TimeInterval, _ cancellation: SubprocessCancellation?
    ) throws -> SubprocessRunner.Result

    static let maximumPayloadBytes = 1_048_576
    static let timeout: TimeInterval = 2

    static func read(
        service: String, account: String, cancellation: SubprocessCancellation? = nil,
        authorization: Authorization = ClaudeSecurityReadAuthorization.permitsRead,
        execute: Executor = executeInMemory
    ) throws -> Data? {
        if cancellation?.isCancelled == true { throw URLError(.cancelled) }
        guard authorization(service, account) else { throw ClaudeKeychainReader.ReadError.keychainAccessRequired }
        if cancellation?.isCancelled == true { throw URLError(.cancelled) }
        let result: SubprocessRunner.Result
        do {
            result = try execute(URL(fileURLWithPath: "/usr/bin/security"),
                                 ["find-generic-password", "-a", account, "-s", service, "-w"],
                                 timeout, cancellation)
        } catch let error as ClaudeKeychainReader.ReadError {
            throw error
        } catch let error as URLError where [.cancelled, .timedOut].contains(error.code) {
            throw error
        } catch {
            // Raw process errors must not become diagnostic output from a
            // credential reader. The menu only needs the safe failure kind.
            throw ClaudeKeychainReader.ReadError.unavailable(status: errSecNotAvailable)
        }
        if result.cancelled || cancellation?.isCancelled == true { throw URLError(.cancelled) }
        if result.timedOut { throw URLError(.timedOut) }
        switch result.status {
        case 0:
            guard !result.standardOutput.isEmpty, result.standardOutput.count <= maximumPayloadBytes else {
                throw ClaudeKeychainReader.ReadError.unavailable(status: errSecDecode)
            }
            return result.standardOutput
        case 44: // errSecItemNotFound, truncated to the CLI's exit status.
            return nil
        case 51, 36: // errSecAuthFailed / errSecInteractionNotAllowed.
            throw ClaudeKeychainReader.ReadError.keychainAccessRequired
        case 128: // errSecUserCanceled.
            throw ClaudeKeychainReader.ReadError.userCancelled
        default:
            throw ClaudeKeychainReader.ReadError.unavailable(status: result.status)
        }
    }

    /// The general SubprocessRunner is deliberately file-backed and is not
    /// suitable for passwords. Use nonblocking reads to drain this small pipe
    /// while observing cancellation, deadlines and the payload bound.
    static func executeInMemory(
        executable: URL, arguments: [String], timeout: TimeInterval, cancellation: SubprocessCancellation?
    ) throws -> SubprocessRunner.Result {
        if cancellation?.isCancelled == true {
            return .init(status: -1, standardOutput: Data(), standardError: Data(), timedOut: false, cancelled: true)
        }
        let output = Pipe()
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ClaudeKeychainReader.ReadError.unavailable(status: errSecNotAvailable)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        if cancellation?.isCancelled == true {
            return .init(status: -1, standardOutput: Data(), standardError: Data(), timedOut: false, cancelled: true)
        }
        try process.run()
        try? output.fileHandleForWriting.close()

        var data = Data()
        var oversized = false
        var readFailed = false
        var buffer = [UInt8](repeating: 0, count: 16_384)
        func drain() {
            guard !oversized, !readFailed else { return }
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    if count <= maximumPayloadBytes - data.count {
                        data.append(contentsOf: buffer.prefix(count))
                    } else { oversized = true; return }
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    if count < 0, errno != EAGAIN, errno != EWOULDBLOCK { readFailed = true }
                    return
                }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline,
              cancellation?.isCancelled != true, !oversized, !readFailed {
            drain()
            Thread.sleep(forTimeInterval: 0.01)
        }
        let cancelled = cancellation?.isCancelled == true
        let timedOut = process.isRunning && !cancelled && !oversized && !readFailed
        if process.isRunning {
            process.terminate()
            let terminationDeadline = ProcessInfo.processInfo.systemUptime + 0.1
            while process.isRunning, ProcessInfo.processInfo.systemUptime < terminationDeadline {
                drain()
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        drain()
        if oversized || readFailed { throw ClaudeKeychainReader.ReadError.unavailable(status: errSecDecode) }
        return .init(status: process.terminationStatus, standardOutput: data, standardError: Data(),
                     timedOut: timedOut, cancelled: cancelled)
    }
}
