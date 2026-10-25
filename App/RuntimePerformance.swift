import CoreFoundation
import Dispatch
import Foundation
import OSLog

/// Opt-in diagnostics contain fixed event names and durations, never account data.
enum RuntimePerformance {
    private static let log = OSLog(subsystem: "com.jiwenbo.beavermeter.performance", category: "Runtime")

    static var isEnabled: Bool { log.isEnabled(type: .debug) }

    static func event(_ name: StaticString) {
        guard isEnabled else { return }
        os_log(name, log: log, type: .debug)
    }

    static func mainRunLoopBusy(milliseconds: Double) {
        guard isEnabled, milliseconds.isFinite, milliseconds >= 0 else { return }
        os_log("main_runloop_busy_ms=%{public}.3f", log: log, type: .debug, milliseconds)
    }
}

/// Measures a completed awake interval only. Time between beforeWaiting and the
/// next afterWaiting is deliberately absent, so an idle/sleeping app is not busy.
struct MainRunLoopBusyTracker: Sendable {
    enum Boundary: Sendable { case afterWaiting, beforeWaiting }

    let minimumBusyDuration: TimeInterval
    private var awakeSince: TimeInterval?

    init(minimumBusyDuration: TimeInterval = 0.1) {
        self.minimumBusyDuration = minimumBusyDuration
    }

    mutating func observe(_ boundary: Boundary, at instant: TimeInterval, enabled: Bool) -> Double? {
        guard enabled, instant.isFinite else {
            reset()
            return nil
        }
        switch boundary {
        case .afterWaiting:
            awakeSince = instant
            return nil
        case .beforeWaiting:
            let start = awakeSince
            awakeSince = nil
            guard let start else { return nil }
            let duration = instant - start
            guard duration.isFinite, duration >= 0, duration >= minimumBusyDuration else { return nil }
            return duration * 1_000
        }
    }

    mutating func reset() { awakeSince = nil }
}

/// CF invalidation is thread-safe; keeping it in a Sendable owner also guarantees
/// cleanup if the main-actor observer's final reference is released elsewhere.
private final class MainRunLoopObserverToken: @unchecked Sendable {
    let observer: CFRunLoopObserver

    init(_ observer: CFRunLoopObserver) { self.observer = observer }
    func invalidate() { CFRunLoopObserverInvalidate(observer) }
    deinit { invalidate() }
}

/// Adds no timer or wakeup. Enable debug logging before calling start(); stop()
/// removes the observer and clears any unfinished measurement.
@MainActor
final class MainRunLoopBusyObserver {
    private var token: MainRunLoopObserverToken?
    private var tracker = MainRunLoopBusyTracker()

    func start() {
        guard RuntimePerformance.isEnabled else {
            stop()
            return
        }
        guard token == nil else { return }
        tracker.reset()
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        // Run the beforeWaiting boundary after late AppKit/Core Animation commits.
        guard let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, CFIndex.max, { [weak self] _, activity in
            // This observer is registered only on the main run loop.
            MainActor.assumeIsolated { self?.observe(activity) }
        }) else { return }
        token = MainRunLoopObserverToken(observer)
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func stop() {
        token?.invalidate()
        token = nil
        tracker.reset()
    }

    private func observe(_ activity: CFRunLoopActivity) {
        let enabled = RuntimePerformance.isEnabled
        // Disabling the stream while running should not leave diagnostic callbacks
        // installed or allow a partial interval to become a later false positive.
        guard enabled else {
            stop()
            return
        }
        let boundary: MainRunLoopBusyTracker.Boundary
        if activity == .afterWaiting { boundary = .afterWaiting }
        else if activity == .beforeWaiting { boundary = .beforeWaiting }
        else { return }
        let instant = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        if let milliseconds = tracker.observe(boundary, at: instant, enabled: enabled) {
            RuntimePerformance.mainRunLoopBusy(milliseconds: milliseconds)
        }
    }
}
