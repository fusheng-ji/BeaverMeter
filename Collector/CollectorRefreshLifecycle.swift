import Darwin
import Foundation

/// Normal refreshes own asynchronous scanners and CLI children too. SIGTERM
/// must cancel that work and let its cleanup finish before the helper exits.
enum CollectorRefreshLifecycle {
    typealias StopSignalHandler = @Sendable () -> Void
    typealias SignalInstaller = @Sendable (@escaping @Sendable () -> Void) -> StopSignalHandler

    static func run(
        signalInstaller: SignalInstaller = installSignalHandler,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let cancellation = SubprocessCancellation()
        let stopSignals = signalInstaller { cancellation.cancel() }
        defer { stopSignals() }
        let work = Task<Void, Error> {
            guard !cancellation.isCancelled else { throw CancellationError() }
            try Task.checkCancellation()
            try await operation()
            try Task.checkCancellation()
            guard !cancellation.isCancelled else { throw CancellationError() }
        }
        // onCancel is latched, including a termination received just before the
        // child task was installed, so the signal/task startup race is bounded.
        let registration = cancellation.onCancel { work.cancel() }
        defer { cancellation.removeHandler(registration) }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func installSignalHandler(cancel: @escaping @Sendable () -> Void) -> StopSignalHandler {
        let handler = RefreshTerminationHandler(cancel: cancel)
        return { handler.stop() }
    }

    private final class RefreshTerminationHandler: @unchecked Sendable {
        private let previous: sig_t?
        private let source: DispatchSourceSignal
        private let lock = NSLock()
        private var stopped = false

        init(cancel: @escaping @Sendable () -> Void) {
            previous = signal(SIGTERM, SIG_IGN)
            source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            source.setEventHandler(handler: cancel)
            source.resume()
        }

        func stop() {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped else { return }
            stopped = true
            source.cancel()
            signal(SIGTERM, previous)
        }
    }
}
