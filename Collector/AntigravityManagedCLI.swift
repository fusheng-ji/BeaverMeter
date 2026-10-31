import CodexBarCore
import Darwin
import Foundation

/// CLI 1.4.12 protects its local HTTP service with a CSRF token. Give only the
/// process we launch a fresh token; never discover or copy another login/token.
enum AntigravityManagedCLI {
    static let maximumResponseBytes = 1_048_576
    private static let summaryPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let identityPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"

    protocol Session: AnyObject, Sendable {
        var pid: pid_t { get }
        var isRunning: Bool { get }
        func listeningPorts() throws -> [Int]
        func drainOutput() -> Data
        func stop()
    }

    struct Response: Sendable {
        let status: Int
        let data: Data
    }

    struct Dependencies: Sendable {
        var resolve: @Sendable ([String: String]) -> String?
        var launch: @Sendable (String, [String: String], String) throws -> any Session
        var send: @Sendable (URLRequest) async throws -> Response
        var pause: @Sendable () async throws -> Void
        var nonce: @Sendable () -> String

        static var live: Self {
            Self(resolve: { BinaryLocator.resolveAntigravityBinary(env: $0) },
                 launch: { try ProcessSession(binary: $0, environment: $1, nonce: $2) },
                 send: sendLocal,
                 pause: { try await Task.sleep(nanoseconds: 150_000_000) },
                 nonce: { UUID().uuidString })
        }
    }

    enum Failure: LocalizedError, Equatable {
        case unavailable, launchFailed, invalidResponse, localHandshake, responseTooLarge

        var errorDescription: String? {
            switch self {
            case .unavailable: "The official Antigravity CLI is unavailable."
            case .launchFailed: "The official Antigravity CLI could not start."
            case .invalidResponse: "Antigravity's local service has not reported quota yet."
            case .localHandshake: "Antigravity's local CSRF handshake is not ready."
            case .responseTooLarge: "Antigravity's local quota response exceeded its size limit."
            }
        }
    }

    static func isAvailable(environment: [String: String]) -> Bool {
        BinaryLocator.resolveAntigravityBinary(env: environment) != nil
    }

    static func fetch(environment: [String: String], timeout: TimeInterval = 20,
                      cancellation: SubprocessCancellation? = nil,
                      dependencies: Dependencies = .live) async throws -> ProviderFetchResult {
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }
        guard let binary = dependencies.resolve(environment) else { throw AntigravityStatusProbeError.notRunning }
        let nonce = dependencies.nonce()
        guard !nonce.isEmpty, !nonce.contains(where: { $0.isWhitespace }) else { throw Failure.launchFailed }
        let session: any Session
        do { session = try dependencies.launch(binary, environment, nonce) }
        catch { throw Failure.launchFailed }
        defer { session.stop() }
        let handler = cancellation?.onCancel { session.stop() }
        defer { if let handler { cancellation?.removeHandler(handler) } }
        return try await withTaskCancellationHandler {
            let deadline = ProcessInfo.processInfo.systemUptime + min(max(timeout, 0), 30)
            var outputTail = Data()
            var lastError: Error = AntigravityStatusProbeError.timedOut
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                if cancellation?.isCancelled == true { throw CancellationError() }
                guard session.isRunning else { throw Failure.unavailable }
                outputTail.append(session.drainOutput())
                if outputTail.count > 16_384 { outputTail = Data(outputTail.suffix(16_384)) }
                if hasBlockingLoginPrompt(outputTail) { throw AntigravityStatusProbeError.authenticationRequired }
                let ports = (try? session.listeningPorts()) ?? []
                for port in ports {
                    try Task.checkCancellation()
                    guard session.isRunning else { throw Failure.unavailable }
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else { throw AntigravityStatusProbeError.timedOut }
                    do {
                        let usage = try await readUsage(port: port, nonce: nonce, session: session,
                                                       deadline: deadline, dependencies: dependencies)
                        try Task.checkCancellation()
                        if cancellation?.isCancelled == true { throw CancellationError() }
                        return ProviderFetchResult(usage: usage, credits: nil, dashboard: nil,
                            sourceLabel: "cli", strategyID: "antigravity.cli-csrf", strategyKind: .cli)
                    } catch is CancellationError { throw CancellationError() }
                    catch let error as AntigravityStatusProbeError where error == .authenticationRequired { throw error }
                    catch { lastError = error }
                }
                try await dependencies.pause()
            }
            try Task.checkCancellation()
            throw lastError
        } onCancel: {
            session.stop()
        }
    }

    private static var metadata: [String: Any] {
        ["metadata": ["ideName": "antigravity", "extensionName": "antigravity", "ideVersion": "unknown", "locale": "en"]]
    }

    private static func readUsage(port: Int, nonce: String, session: any Session, deadline: TimeInterval,
                                  dependencies: Dependencies) async throws -> CodexBarCore.UsageSnapshot {
        func remaining() throws -> TimeInterval {
            let value = deadline - ProcessInfo.processInfo.systemUptime
            guard value > 0 else { throw AntigravityStatusProbeError.timedOut }
            return min(2, value)
        }
        do {
            let summary = try await request(path: summaryPath, body: ["forceRefresh": true], port: port,
                nonce: nonce, session: session, timeout: remaining(), dependencies: dependencies)
            let identity = try? await request(path: identityPath, body: metadata, port: port, nonce: nonce,
                session: session, timeout: min(1, remaining()), dependencies: dependencies)
            return try decode(summary: summary, identity: identity, now: Date())
        } catch let error as Failure where error == .invalidResponse {
            // Older official clients expose model quotas but no summary RPC.
            let identity = try await request(path: identityPath, body: metadata, port: port, nonce: nonce,
                session: session, timeout: remaining(), dependencies: dependencies)
            if let body = try? JSONSerialization.jsonObject(with: identity) as? [String: Any],
               let message = body["message"] as? String, message.localizedCaseInsensitiveContains("csrf") {
                throw Failure.localHandshake
            }
            do { return try AntigravityStatusProbe.parseUserStatusResponse(identity).toUsageSnapshot() }
            catch let error as AntigravityStatusProbeError {
                if case .apiError(let code) = error, Code.isAuthenticationCode(code) {
                    throw AntigravityStatusProbeError.authenticationRequired
                }
                throw Failure.invalidResponse
            } catch { throw Failure.invalidResponse }
        }
    }

    private static func request(path: String, body: [String: Any], port: Int, nonce: String,
                                session: any Session, timeout: TimeInterval,
                                dependencies: Dependencies) async throws -> Data {
        guard [summaryPath, identityPath].contains(path), (1...65_535).contains(port), session.isRunning,
              try session.listeningPorts().contains(port),
              let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw Failure.unavailable }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(nonce, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        let response = try await dependencies.send(request)
        try Task.checkCancellation()
        guard session.isRunning, try session.listeningPorts().contains(port) else { throw Failure.unavailable }
        guard response.data.count <= maximumResponseBytes else { throw Failure.responseTooLarge }
        guard response.status == 200 else {
            if [401, 403].contains(response.status) {
                // Local transport rejection is not an expired Google login,
                // including older plaintext and nested JSON error responses.
                if String(decoding: response.data, as: UTF8.self).localizedCaseInsensitiveContains("csrf") {
                    throw Failure.localHandshake
                }
                throw AntigravityStatusProbeError.authenticationRequired
            }
            // TLS-only ports reject plaintext, redirects are never followed,
            // and startup failures may recover during this bounded attempt.
            throw Failure.invalidResponse
        }
        return response.data
    }

    static func decode(summary: Data, identity: Data?, now: Date) throws -> CodexBarCore.UsageSnapshot {
        let parsed: SummaryResponse
        do { parsed = try JSONDecoder().decode(SummaryResponse.self, from: summary) }
        catch { throw Failure.invalidResponse }
        if let code = parsed.code, !code.isOK {
            if parsed.message?.localizedCaseInsensitiveContains("csrf") == true { throw Failure.localHandshake }
            if code.isAuthenticationFailure { throw AntigravityStatusProbeError.authenticationRequired }
            throw Failure.invalidResponse
        }
        let groups = parsed.response?.groups ?? parsed.summary?.groups ?? parsed.groups ?? []
        let windows = groups.flatMap { group -> [NamedRateWindow] in
            let title = group.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Quota"
            return (group.buckets ?? []).compactMap { bucket in
                guard let id = bucket.bucketId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
                let minutes = cadence(id: id, name: bucket.displayName)
                let fraction = bucket.remainingFraction ?? bucket.remaining?.remainingFraction
                let known = bucket.disabled != true && fraction?.isFinite == true
                let percent = fraction.map { min(max($0, 0), 1) * 100 } ?? 100
                let date = bucket.resetTime.flatMap { CollectorSupport.parseISODate($0) ?? Double($0).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil } }
                let window = RateWindow(usedPercent: known ? 100 - percent : 0,
                    windowMinutes: minutes, resetsAt: date, resetDescription: bucket.description)
                let period = minutes == 300 ? "5-hour" : minutes == 10_080 ? "weekly" : bucket.displayName ?? id
                return NamedRateWindow(id: "antigravity-quota-summary-\(id)", title: "\(title) \(period)",
                                       window: window, usageKnown: known)
            }
        }
        guard !windows.isEmpty else { throw Failure.invalidResponse }
        let account = identity.flatMap { try? AntigravityStatusProbe.parseUserStatusResponse($0) }
        return CodexBarCore.UsageSnapshot(primary: nil, secondary: nil, extraRateWindows: windows, updatedAt: now,
            identity: ProviderIdentitySnapshot(providerID: .antigravity, accountEmail: account?.accountEmail,
                accountOrganization: nil, loginMethod: account?.accountPlan))
    }

    private static func cadence(id: String, name: String?) -> Int? {
        let aliases = [id, name ?? ""].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " limit", with: "")
        }
        if aliases.contains(where: { $0 == "weekly" || $0.hasSuffix("-weekly") }) { return 10_080 }
        if aliases.contains(where: { value in
            ["session", "5h", "5-hour", "five-hour", "five hour"].contains { value == $0 || value.hasSuffix("-\($0)") }
        }) { return 300 }
        return nil
    }

    static func listeningPorts(in data: Data, pid: pid_t) -> [Int] {
        var owner: pid_t?
        var ports: Set<Int> = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.first == "p" { owner = Int32(line.dropFirst()); continue }
            guard owner == pid, line.hasPrefix("n127.0.0.1:"),
                  let port = Int(line.dropFirst("n127.0.0.1:".count)), (1...65_535).contains(port) else { continue }
            ports.insert(port)
        }
        return ports.sorted()
    }

    private static func hasBlockingLoginPrompt(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        return text.range(of: #"select\s+login\s+method|you\s+are\s+not\s+logged\s+into\s+antigravity|keyring\s*auth\s*:\s*timed\s+out"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let localSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config, delegate: RedirectBlocker(), delegateQueue: nil)
    }()

    private static func sendLocal(_ request: URLRequest) async throws -> Response {
        guard request.url?.scheme == "http", request.url?.host == "127.0.0.1",
              [summaryPath, identityPath].contains(request.url?.path ?? "") else { throw Failure.unavailable }
        let (bytes, response) = try await localSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse, response.url == request.url else { throw Failure.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else { throw Failure.responseTooLarge }
            data.append(byte)
        }
        return Response(status: http.statusCode, data: data)
    }

    private struct SummaryResponse: Decodable {
        let code: Code?
        let message: String?
        let response: Payload?
        let summary: Payload?
        let groups: [Group]?
    }
    private struct Payload: Decodable { let groups: [Group]? }
    private struct Group: Decodable { let displayName: String?; let buckets: [Bucket]? }
    private struct Bucket: Decodable {
        let bucketId: String?; let displayName: String?; let description: String?
        let disabled: Bool?; let remainingFraction: Double?; let remaining: Remaining?; let resetTime: String?
    }
    private struct Remaining: Decodable {
        let remainingFraction: Double?
        enum CodingKeys: String, CodingKey { case remainingFraction, kind = "case", value }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let fraction = try values.decodeIfPresent(Double.self, forKey: .remainingFraction) { remainingFraction = fraction }
            else if try values.decodeIfPresent(String.self, forKey: .kind) == "remainingFraction" {
                remainingFraction = try values.decodeIfPresent(Double.self, forKey: .value)
            } else { remainingFraction = nil }
        }
    }
    private struct Code: Decodable {
        let text: String
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let string = try? value.decode(String.self) { text = string }
            else { text = String(try value.decode(Int.self)) }
        }
        var normalized: String { text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var isOK: Bool { ["0", "ok", "success"].contains(normalized) }
        var isAuthenticationFailure: Bool { Self.isAuthenticationCode(text) }
        static func isAuthenticationCode(_ text: String) -> Bool {
            ["401", "403", "7", "16", "unauthenticated", "unauthorized", "permission_denied"].contains(
                text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    /// Only this child gets a new process group. Output is drained and discarded
    /// in memory; the private nonce is never copied to logs or temporary files.
    final class ProcessSession: Session, @unchecked Sendable {
        let pid: pid_t
        private let lock = NSLock()
        private var descriptor: Int32
        private var reaped = false
        private var exited = false
        private var stopped = false

        init(binary: String, environment: [String: String], nonce: String) throws {
            var master: Int32 = -1, slave: Int32 = -1
            var size = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw Failure.launchFailed }
            var keepMaster = false
            defer { close(slave); if !keepMaster { close(master) } }
            _ = fcntl(master, F_SETFL, O_NONBLOCK)
            var actions: posix_spawn_file_actions_t?
            guard posix_spawn_file_actions_init(&actions) == 0 else { throw Failure.launchFailed }
            defer { posix_spawn_file_actions_destroy(&actions) }
            guard posix_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO) == 0,
                  posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO) == 0,
                  posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO) == 0,
                  posix_spawn_file_actions_addclose(&actions, master) == 0,
                  posix_spawn_file_actions_addclose(&actions, slave) == 0 else { throw Failure.launchFailed }
            var attributes: posix_spawnattr_t?
            guard posix_spawnattr_init(&attributes) == 0 else { throw Failure.launchFailed }
            defer { posix_spawnattr_destroy(&attributes) }
            var signals = sigset_t()
            sigemptyset(&signals)
            for signal in [SIGTERM, SIGINT, SIGHUP] { sigaddset(&signals, signal) }
            guard posix_spawnattr_setsigdefault(&attributes, &signals) == 0,
                  posix_spawnattr_setflags(&attributes,
                    Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF)) == 0,
                  posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw Failure.launchFailed }
            var env = environment
            let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
            env["TERM"] = "xterm-256color"
            env["HOME"] = home
            env["PWD"] = home
            guard home.withCString({ posix_spawn_file_actions_addchdir_np(&actions, $0) }) == 0 else { throw Failure.launchFailed }
            var arguments: [UnsafeMutablePointer<CChar>?] = [binary, "--csrf_token=\(nonce)"].map { text in
                text.withCString { strdup($0) }
            }
            arguments.append(nil)
            defer { for item in arguments { free(item) } }
            var variables: [UnsafeMutablePointer<CChar>?] = env.map { key, value in
                "\(key)=\(value)".withCString { strdup($0) }
            }
            variables.append(nil)
            defer { for item in variables { free(item) } }
            var child: pid_t = 0
            let status = binary.withCString { posix_spawn(&child, $0, &actions, &attributes, &arguments, &variables) }
            guard status == 0 else { throw Failure.launchFailed }
            pid = child; descriptor = master; keepMaster = true
        }

        var isRunning: Bool {
            lock.lock(); defer { lock.unlock() }
            return runningLocked()
        }

        private func runningLocked() -> Bool {
            guard !reaped, !exited else { return false }
            // Keep an exited child unreaped until group cleanup. Its reserved
            // PID prevents signaling an unrelated reused process-group ID.
            var info = siginfo_t()
            let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if result == 0, info.si_pid == pid {
                exited = true
                return false
            }
            if result < 0, errno == ECHILD { reaped = true; return false }
            return true
        }

        func listeningPorts() throws -> [Int] {
            guard isRunning else { return [] }
            let result = try SubprocessRunner.run(executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
                arguments: ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fpn"],
                timeout: 0.8, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"], terminationGrace: 0.1)
            guard isRunning, !result.timedOut, result.status == 0 else { return [] }
            return AntigravityManagedCLI.listeningPorts(in: result.standardOutput, pid: pid)
        }

        func drainOutput() -> Data {
            lock.lock(); defer { lock.unlock() }
            guard descriptor >= 0 else { return Data() }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            var data = Data()
            while data.count < 65_536 {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
                else if count < 0 && errno == EINTR { continue }
                else { break }
            }
            return data
        }

        func stop() {
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return }
            stopped = true
            if !reaped {
                _ = kill(-pid, SIGTERM)
                if runningLocked() { _ = kill(pid, SIGTERM) }
                let deadline = ProcessInfo.processInfo.systemUptime + 0.25
                while runningLocked(), ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
                _ = kill(-pid, SIGKILL)
                if runningLocked() { _ = kill(pid, SIGKILL) }
            }
            if descriptor >= 0 { close(descriptor); descriptor = -1 }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.75
            while !reaped, ProcessInfo.processInfo.systemUptime < deadline {
                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid || (result < 0 && errno == ECHILD) { reaped = true }
                else { Thread.sleep(forTimeInterval: 0.01) }
            }
        }

        deinit { stop() }
    }
}
