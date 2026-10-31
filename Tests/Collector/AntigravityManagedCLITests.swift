import CodexBarCore
import Darwin
import Foundation
import XCTest

final class AntigravityManagedCLITests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!
    private let summary = Data(#"{"response":{"groups":[{"displayName":"Gemini","buckets":[{"bucketId":"gemini-session","remainingFraction":0.8},{"bucketId":"gemini-weekly","remainingFraction":0.4}]},{"displayName":"Claude and GPT","buckets":[{"bucketId":"claude-session","remainingFraction":0},{"bucketId":"claude-weekly","remainingFraction":1}]}]}}"#.utf8)
    private let identity = Data(#"{"userStatus":{"email":"synthetic@example.test","userTier":{"name":"Google AI Ultra"}}}"#.utf8)

    private final class Session: AntigravityManagedCLI.Session, @unchecked Sendable {
        let pid: pid_t = 123
        private let lock = NSLock()
        private var stopped = false
        private var stops = 0
        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
        var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
        func listeningPorts() -> [Int] { isRunning ? [31_415] : [] }
        func drainOutput() -> Data { Data() }
        func stop() {
            lock.lock(); defer { lock.unlock() }
            if !stopped { stopped = true; stops += 1 }
        }
    }

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URLRequest] = []
        func record(_ request: URLRequest) { lock.lock(); storage.append(request); lock.unlock() }
        var values: [URLRequest] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private func dependencies(_ session: Session, requests: Requests,
                              send: (@Sendable (URLRequest) async throws -> AntigravityManagedCLI.Response)? = nil)
        -> AntigravityManagedCLI.Dependencies {
        let summary = self.summary, identity = self.identity
        return .init(resolve: { _ in "/synthetic/agy" }, launch: { _, _, _ in session },
            send: { request in
                requests.record(request)
                if let send { return try await send(request) }
                return .init(status: 200, data: request.url?.path.hasSuffix("GetUserStatus") == true ? identity : summary)
            }, pause: { try await Task.sleep(nanoseconds: 1_000_000) }, nonce: { "synthetic-owned-nonce" })
    }

    func testOwnedNonceAndLoopbackAreUsedForBothReadOnlyEndpointsAndCleanedOnSuccess() async throws {
        let session = Session(), requests = Requests()
        let result = try await AntigravityManagedCLI.fetch(environment: [:], timeout: 1,
            dependencies: dependencies(session, requests: requests))
        XCTAssertEqual(result.strategyID, "antigravity.cli-csrf")
        XCTAssertEqual(result.sourceLabel, "cli")
        XCTAssertEqual(result.usage.extraRateWindows?.count, 4)
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertEqual(requests.values.count, 2)
        for request in requests.values {
            XCTAssertEqual(request.url?.scheme, "http")
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertEqual(request.url?.port, 31_415)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Codeium-Csrf-Token"), "synthetic-owned-nonce")
            XCTAssertFalse(request.httpShouldHandleCookies)
        }
        XCTAssertEqual(result.usage.accountEmail(for: .antigravity), "synthetic@example.test")
    }

    func testSummaryParserKeepsIndependentWindowsZeroHundredAndResetProse() throws {
        let usage = try AntigravityManagedCLI.decode(summary: summary, identity: identity, now: now)
        let projected = AntigravityQuotaCollector.project(usage, now: now)
        XCTAssertEqual(projected.groups[0].windows.map(\.remainingPercent), [80, 40])
        XCTAssertEqual(projected.groups[1].windows.map(\.remainingPercent), [0, 100])
        XCTAssertEqual(projected.groups[0].windows.map(\.windowSeconds), [18_000, 604_800])
        XCTAssertEqual(projected.planName, "Google AI Ultra")
        let wrapped = Data(#"{"summary":{"groups":[{"displayName":"Gemini","buckets":[{"bucketId":"gemini-weekly","remaining":{"case":"remainingFraction","value":0.25},"description":"Refills next week"},{"bucketId":"gemini-session","disabled":true,"remainingFraction":1},{"bucketId":"unknown","remaining":{"case":"unknown","value":1}}]}]}}"#.utf8)
        let decoded = try AntigravityManagedCLI.decode(summary: wrapped, identity: nil, now: now)
        XCTAssertEqual(decoded.extraRateWindows?.map(\.usageKnown), [true, false, false])
        let windows = AntigravityQuotaCollector.project(decoded, now: now).groups[0].windows
        XCTAssertEqual(windows[0].remainingPercent, 25)
        XCTAssertEqual(windows[0].resetDescription, "Refills next week")
        XCTAssertNil(windows[0].resetAt)
        XCTAssertNil(windows[1].remainingPercent)
        XCTAssertNil(windows[2].remainingPercent)
    }

    func testPortDiscoveryOnlyAcceptsOwnPIDIPv4LoopbackAndValidPortNumbers() {
        let output = Data("p123\nn127.0.0.1:31415\nn*:31416\nn192.0.2.1:31417\nn127.0.0.1:0\nn127.0.0.1:65536\np456\nn127.0.0.1:31418\np123\nn127.0.0.1:31415\n".utf8)
        XCTAssertEqual(AntigravityManagedCLI.listeningPorts(in: output, pid: 123), [31_415])
    }

    func testLegacyUserStatusIsReadWhenSummaryEndpointIsUnsupported() async throws {
        let session = Session(), requests = Requests()
        let legacy = Data(#"{"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[{"label":"Gemini 3 Pro","modelOrAlias":{"model":"gemini-3-pro-high"},"quotaInfo":{"remainingFraction":0.42}}]}}}"#.utf8)
        let result = try await AntigravityManagedCLI.fetch(environment: [:], timeout: 1,
            dependencies: dependencies(session, requests: requests, send: { request in
                request.url?.path.hasSuffix("GetUserStatus") == true
                    ? .init(status: 200, data: legacy) : .init(status: 404, data: Data())
            }))
        XCTAssertEqual(AntigravityQuotaCollector.project(result.usage, now: now).groups[0].windows.first?.remainingPercent, 42)
        XCTAssertEqual(session.stopCount, 1)
    }

    func testPlaintextNestedAndBusinessCodeCSRFRejectionAreNotGoogleSignOut() async {
        let cases: [(Int, Data)] = [
            (401, Data("missing CSRF token".utf8)),
            (403, Data(#"{"error":{"message":"invalid CSRF token"}}"#.utf8)),
            (200, Data(#"{"code":7,"message":"CSRF token missing"}"#.utf8))
        ]
        for (status, body) in cases {
            let session = Session(), requests = Requests()
            do {
                _ = try await AntigravityManagedCLI.fetch(environment: [:], timeout: 0.02,
                    dependencies: dependencies(session, requests: requests, send: { _ in .init(status: status, data: body) }))
                XCTFail("Expected a local readiness error")
            } catch {
                XCTAssertEqual(error as? AntigravityManagedCLI.Failure, .localHandshake)
                XCTAssertNil(error as? AntigravityStatusProbeError)
            }
            XCTAssertEqual(session.stopCount, 1)
        }
    }

    func testActualAuthenticationFailureClearsAsAuthenticationWithoutLeakingResponse() async {
        let session = Session(), requests = Requests()
        do {
            _ = try await AntigravityManagedCLI.fetch(environment: [:], timeout: 1,
                dependencies: dependencies(session, requests: requests, send: { _ in
                    .init(status: 401, data: Data(#"{"message":"expired synthetic-private-marker"}"#.utf8))
                }))
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertEqual(error as? AntigravityStatusProbeError, .authenticationRequired)
            XCTAssertFalse(error.localizedDescription.contains("synthetic-private-marker"))
        }
        XCTAssertEqual(session.stopCount, 1)
    }

    func testRedirectStatusNeverProducesAnExternalRequestAndAlwaysCleansUp() async {
        let session = Session(), requests = Requests()
        do {
            _ = try await AntigravityManagedCLI.fetch(environment: [:], timeout: 0.02,
                dependencies: dependencies(session, requests: requests, send: { _ in .init(status: 302, data: Data()) }))
            XCTFail("Expected unavailable quota")
        } catch { XCTAssertEqual(error as? AntigravityManagedCLI.Failure, .invalidResponse) }
        XCTAssertFalse(requests.values.isEmpty)
        XCTAssertTrue(requests.values.allSatisfy { $0.url?.host == "127.0.0.1" })
        XCTAssertEqual(session.stopCount, 1)
    }

    func testCancellationAwaitsOwnedSessionCleanup() async {
        let session = Session(), requests = Requests()
        let dependencies = dependencies(session, requests: requests, send: { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return .init(status: 200, data: Data())
        })
        let task = Task { try await AntigravityManagedCLI.fetch(environment: [:], dependencies: dependencies) }
        for _ in 0..<1_000 {
            if !requests.values.isEmpty { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        switch await task.result {
        case .success: XCTFail("Cancelled work must not return a reading")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertFalse(session.isRunning)
    }

    private func script(_ contents: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("beavermeter-managed-cli-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("fake-cli")
        try ("#!/bin/zsh\n" + contents).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, file)
    }

    private func waitUntil(_ condition: () -> Bool) {
        for _ in 0..<200 { if condition() { return }; Thread.sleep(forTimeInterval: 0.01) }
    }

    func testRealFixtureHonorsIsolatedHomeAndKillsItsOwnProcessGroup() throws {
        let (home, executable) = try script("print -r -- \"$HOME\" > \"$HOME/seen-home\"\npwd > \"$HOME/seen-cwd\"\nsleep 30\n")
        let session = try AntigravityManagedCLI.ProcessSession(binary: executable.path,
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"], nonce: "synthetic")
        defer { session.stop() }
        waitUntil { FileManager.default.fileExists(atPath: home.appendingPathComponent("seen-cwd").path) }
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("seen-home"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), home.path)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("seen-cwd"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), home.path)
        session.stop()
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(kill(session.pid, 0), -1)
    }

    func testExitedRootRetainsItsPIDUntilDescendantsAreStoppedAndDoesNotKillForeignProcess() throws {
        let (home, executable) = try script("( trap '' TERM HUP; while true; do sleep 1; done ) &\nprint -r -- \"$!\" > \"$HOME/child-pid\"\nexit 0\n")
        let foreign = Process(); foreign.executableURL = URL(fileURLWithPath: "/bin/sleep"); foreign.arguments = ["30"]
        try foreign.run()
        defer { if foreign.isRunning { foreign.terminate(); foreign.waitUntilExit() } }
        let session = try AntigravityManagedCLI.ProcessSession(binary: executable.path,
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"], nonce: "synthetic")
        defer { session.stop() }
        let childFile = home.appendingPathComponent("child-pid")
        waitUntil { FileManager.default.fileExists(atPath: childFile.path) && !session.isRunning }
        let child = try XCTUnwrap(Int32(try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(kill(session.pid, 0), 0, "Exited root remains reserved until group cleanup")
        session.stop()
        waitUntil { kill(child, 0) != 0 }
        XCTAssertEqual(kill(session.pid, 0), -1)
        if kill(child, 0) == 0 {
            let status = try SubprocessRunner.run(executable: URL(fileURLWithPath: "/bin/ps"), arguments: ["-p", String(child), "-o", "stat="], timeout: 1)
            XCTAssertTrue(String(decoding: status.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z"), "Any unreaped orphan is already stopped")
        }
        XCTAssertTrue(foreign.isRunning)
    }
}
