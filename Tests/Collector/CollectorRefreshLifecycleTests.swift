import Foundation
import XCTest

@MainActor
final class CollectorRefreshLifecycleTests: XCTestCase {
    private enum SampleError: Error { case failed }

    private final class Signals: @unchecked Sendable {
        private let lock = NSLock()
        private var callback: (@Sendable () -> Void)?
        private var values: [String] = []

        func install(_ callback: @escaping @Sendable () -> Void) -> CollectorRefreshLifecycle.StopSignalHandler {
            lock.lock()
            self.callback = callback
            values.append("installed")
            lock.unlock()
            return { [self] in
                lock.lock()
                self.callback = nil
                values.append("stopped")
                lock.unlock()
            }
        }

        func fire() {
            lock.lock()
            let handler = callback
            lock.unlock()
            handler?()
        }

        func record(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        var events: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testSuccessAndFailureStopTheInstalledSignalHandler() async throws {
        let success = Signals()
        try await CollectorRefreshLifecycle.run(signalInstaller: { success.install($0) }) {
            success.record("operation")
        }
        XCTAssertEqual(success.events, ["installed", "operation", "stopped"])
        let failure = Signals()
        do {
            try await CollectorRefreshLifecycle.run(signalInstaller: { failure.install($0) }) {
                failure.record("operation")
                throw SampleError.failed
            }
            XCTFail("Expected operation failure")
        } catch SampleError.failed {}
        XCTAssertEqual(failure.events, ["installed", "operation", "stopped"])
    }

    func testTerminationCancelsChildAndWaitsForItsCleanup() async throws {
        let signals = Signals()
        let started = XCTestExpectation(description: "Refresh started")
        let runner = Task {
            try await CollectorRefreshLifecycle.run(signalInstaller: { signals.install($0) }) {
                defer { signals.record("cleanup") }
                started.fulfill()
                try await Task.sleep(nanoseconds: 60_000_000_000)
                signals.record("published")
            }
        }
        let state = await XCTWaiter.fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(state, .completed)
        guard state == .completed else { runner.cancel(); return }
        signals.fire()
        do { try await runner.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertEqual(signals.events, ["installed", "cleanup", "stopped"])
    }

    func testTerminationBeforeWorkerInstallationIsLatched() async throws {
        let signals = Signals()
        do {
            try await CollectorRefreshLifecycle.run(signalInstaller: { callback in
                let stop = signals.install(callback)
                callback()
                return stop
            }) {
                signals.record("published")
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(signals.events, ["installed", "stopped"])
    }

    func testCallerCancellationAlsoStopsWorkerAndCleansUp() async throws {
        let signals = Signals()
        let started = XCTestExpectation(description: "Refresh started")
        let runner = Task {
            try await CollectorRefreshLifecycle.run(signalInstaller: { signals.install($0) }) {
                defer { signals.record("cleanup") }
                started.fulfill()
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        let state = await XCTWaiter.fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(state, .completed)
        guard state == .completed else { runner.cancel(); return }
        runner.cancel()
        do { try await runner.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertEqual(signals.events, ["installed", "cleanup", "stopped"])
    }

    func testOperationCannotSwallowCancellationAndReportSuccess() async throws {
        let signals = Signals()
        let started = XCTestExpectation(description: "Refresh started")
        let runner = Task {
            try await CollectorRefreshLifecycle.run(signalInstaller: { signals.install($0) }) {
                started.fulfill()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                signals.record("returned")
            }
        }
        let state = await XCTWaiter.fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(state, .completed)
        guard state == .completed else { runner.cancel(); return }
        signals.fire()
        do { try await runner.value; XCTFail("Expected cancellation after a swallowed error") }
        catch is CancellationError {}
        XCTAssertEqual(signals.events, ["installed", "returned", "stopped"])
    }
}
