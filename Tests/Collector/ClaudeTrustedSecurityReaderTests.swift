import Darwin
import Foundation
import Security
import XCTest

final class ClaudeTrustedSecurityReaderTests: XCTestCase {
    private func result(status: Int32 = 0, output: Data = Data("synthetic-credential".utf8),
                        timedOut: Bool = false, cancelled: Bool = false) -> SubprocessRunner.Result {
        .init(status: status, standardOutput: output, standardError: Data(), timedOut: timedOut, cancelled: cancelled)
    }

    func testMissingAuthorizationNeverStartsTheTrustedReader() {
        var checks: [(String, String)] = []
        XCTAssertThrowsError(try ClaudeTrustedSecurityReader.read(
            service: "profile-service", account: "selected-user", authorization: { service, account in
                checks.append((service, account))
                return false
            }, execute: { _, _, _, _ in XCTFail("An unauthorized reader must not start."); return self.result() }
        )) {
            XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, .keychainAccessRequired)
        }
        XCTAssertEqual(checks.count, 1)
        XCTAssertEqual(checks.first?.0, "profile-service")
        XCTAssertEqual(checks.first?.1, "selected-user")
    }

    func testAuthorizedReaderKeepsExactScopeAndReturnsOnlyInMemoryData() throws {
        let expected = Data("{\"synthetic\":\"credential\"}\n".utf8)
        let cancellation = SubprocessCancellation()
        var authorized = false
        let data = try ClaudeTrustedSecurityReader.read(
            service: "Claude Code-credentials-custom", account: "selected-user", cancellation: cancellation,
            authorization: { service, account in
                XCTAssertEqual(service, "Claude Code-credentials-custom")
                XCTAssertEqual(account, "selected-user")
                authorized = true
                return true
            }, execute: { executable, arguments, timeout, suppliedCancellation in
                XCTAssertTrue(authorized)
                XCTAssertEqual(executable.path, "/usr/bin/security")
                XCTAssertEqual(arguments, ["find-generic-password", "-a", "selected-user", "-s", "Claude Code-credentials-custom", "-w"])
                XCTAssertEqual(timeout, 2)
                XCTAssertTrue(suppliedCancellation === cancellation)
                return self.result(output: expected)
            }
        )
        XCTAssertEqual(data, expected)
    }

    func testOnlyMissingItemReturnsNil() throws {
        XCTAssertNil(try ClaudeTrustedSecurityReader.read(
            service: "service", account: "account", authorization: { _, _ in true },
            execute: { _, _, _, _ in self.result(status: 44) }
        ))
        for output in [Data(), Data(repeating: 0, count: ClaudeTrustedSecurityReader.maximumPayloadBytes + 1)] {
            XCTAssertThrowsError(try ClaudeTrustedSecurityReader.read(
                service: "service", account: "account", authorization: { _, _ in true },
                execute: { _, _, _, _ in self.result(output: output) }
            )) { XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, .unavailable(status: errSecDecode)) }
        }
    }

    func testAuthenticationFailuresRemainAccessErrorsEvenWithPartialOutput() {
        for status in [Int32(51), Int32(36)] {
            XCTAssertThrowsError(try ClaudeTrustedSecurityReader.read(
                service: "service", account: "account", authorization: { _, _ in true },
                execute: { _, _, _, _ in self.result(status: status) }
            )) { XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, .keychainAccessRequired) }
        }
        XCTAssertThrowsError(try ClaudeTrustedSecurityReader.read(
            service: "service", account: "account", authorization: { _, _ in true },
            execute: { _, _, _, _ in self.result(status: 128) }
        )) { XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, .userCancelled) }
    }

    func testUnknownExitAndLaunchErrorsNeverExposeProcessOutputOrBecomeMissingLogin() {
        XCTAssertThrowsError(try ClaudeTrustedSecurityReader.read(
            service: "service", account: "account", authorization: { _, _ in true },
            execute: { _, _, _, _ in self.result(status: 9) }
        )) { XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, .unavailable(status: 9)) }
        XCTAssertThrowsError(try ClaudeTrustedSecurityReader.read(
            service: "service", account: "account", authorization: { _, _ in true },
            execute: { _, _, _, _ in throw NSError(domain: "synthetic-private-process-error", code: 1) }
        )) {
            XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, .unavailable(status: errSecNotAvailable))
            XCTAssertFalse($0.localizedDescription.contains("synthetic-private"))
        }
    }

    func testCancellationBeforeOrDuringGuardNeverStartsTheProcess() {
        let alreadyCancelled = SubprocessCancellation()
        alreadyCancelled.cancel()
        XCTAssertThrowsError(try ClaudeTrustedSecurityReader.read(
            service: "service", account: "account", cancellation: alreadyCancelled,
            authorization: { _, _ in XCTFail("Cancelled operation must not inspect ACL metadata."); return true },
            execute: { _, _, _, _ in XCTFail("Cancelled operation must not start."); return self.result() }
        )) { XCTAssertEqual(($0 as? URLError)?.code, .cancelled) }

        let cancelledDuringGuard = SubprocessCancellation()
        XCTAssertThrowsError(try ClaudeTrustedSecurityReader.read(
            service: "service", account: "account", cancellation: cancelledDuringGuard,
            authorization: { _, _ in cancelledDuringGuard.cancel(); return true },
            execute: { _, _, _, _ in XCTFail("Cancelled operation must not start."); return self.result() }
        )) { XCTAssertEqual(($0 as? URLError)?.code, .cancelled) }
    }

    func testProcessCancellationAndTimeoutDiscardAnyPartialCredential() {
        for cancelled in [true, false] {
            XCTAssertThrowsError(try ClaudeTrustedSecurityReader.read(
                service: "service", account: "account", authorization: { _, _ in true },
                execute: { _, _, _, _ in self.result(timedOut: !cancelled, cancelled: cancelled) }
            )) { XCTAssertEqual(($0 as? URLError)?.code, cancelled ? .cancelled : .timedOut) }
        }
    }

    func testMemoryRunnerCapturesExactSyntheticOutputAndDiscardsStandardError() throws {
        let reading = try ClaudeTrustedSecurityReader.executeInMemory(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' synthetic-output; printf '%s' synthetic-error >&2"],
            timeout: 2, cancellation: nil
        )

        XCTAssertEqual(reading.status, 0)
        XCTAssertEqual(reading.standardOutput, Data("synthetic-output".utf8))
        XCTAssertTrue(reading.standardError.isEmpty)
        XCTAssertFalse(reading.timedOut)
        XCTAssertFalse(reading.cancelled)
    }

    func testMemoryRunnerRejectsSyntheticOutputLargerThanItsLimit() {
        XCTAssertThrowsError(try ClaudeTrustedSecurityReader.executeInMemory(
            executable: URL(fileURLWithPath: "/usr/bin/head"),
            arguments: ["-c", String(ClaudeTrustedSecurityReader.maximumPayloadBytes + 1), "/dev/zero"],
            timeout: 2, cancellation: nil
        )) {
            XCTAssertEqual($0 as? ClaudeKeychainReader.ReadError, .unavailable(status: errSecDecode))
        }
    }

    func testMemoryRunnerTimeoutStopsItsSyntheticChildWithoutLeavingAProcess() throws {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let reading = try ClaudeTrustedSecurityReader.executeInMemory(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", #"printf '%s\n' "$$"; exec /bin/sleep 30"#],
            timeout: 0.25, cancellation: nil
        )

        XCTAssertTrue(reading.timedOut)
        XCTAssertFalse(reading.cancelled)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 2)
        let pid = try XCTUnwrap(Int32(String(decoding: reading.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testMemoryRunnerCancellationStopsItsSyntheticChildWithoutLeavingAProcess() throws {
        let cancellation = SubprocessCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { cancellation.cancel() }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let reading = try ClaudeTrustedSecurityReader.executeInMemory(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", #"printf '%s\n' "$$"; exec /bin/sleep 30"#],
            timeout: 5, cancellation: cancellation
        )

        XCTAssertTrue(reading.cancelled)
        XCTAssertFalse(reading.timedOut)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 2)
        let pid = try XCTUnwrap(Int32(String(decoding: reading.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
