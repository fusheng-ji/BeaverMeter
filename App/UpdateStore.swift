import Combine
import Foundation

struct UpdateBackendState: Equatable {
    var available: AvailableUpdate?
    var isChecking = false
    var message: String?
    var pendingInstallationBuild: String?

    /// Focusing an existing native alert does not start a new check. Sparkle's
    /// canCheckForUpdates is the authority, rather than our progress indicator.
    mutating func prepareUserCheck(canCheckForUpdates: Bool) -> Bool {
        guard canCheckForUpdates else {
            message = "An update check or download is in progress. Please try again when it finishes."
            return false
        }
        message = nil
        return true
    }

    mutating func finishWithoutUpdate(message: String) {
        available = nil
        isChecking = false
        self.message = message
    }
}

/// One launch check supplements Sparkle's scheduler without replacing its
/// interval or overriding the user's automatic-check preference.
struct UpdateStartupState {
    private(set) var hasStarted = false

    mutating func start(startUpdater: () throws -> Void,
                        automaticChecksEnabled: () -> Bool,
                        checkInBackground: () -> Void) throws {
        guard !hasStarted else { return }
        try startUpdater()
        hasStarted = true
        if automaticChecksEnabled() { checkInBackground() }
    }
}

/// Kept independent of Sparkle so previews and unit tests never load an updater.
@MainActor
protocol UpdateBackend: AnyObject {
    var state: UpdateBackendState { get }
    var stateDidChange: ((UpdateBackendState) -> Void)? { get set }
    func start()
    func checkForUpdates()
    func stop()
}

/// Tracks the replacement boundary independently of Sparkle's UI session.
/// A completed UI session may leave an installer waiting for application quit.
struct UpdateInstallationState {
    private(set) var targetBuild: String?
    private(set) var pendingBuild: String?
    private var prepared = false
    private var handedOff = false
    private var installingInCurrentCycle = false

    mutating func beginCycle() { installingInCurrentCycle = false }

    mutating func found(build: String) { targetBuild = build }

    mutating func schedule(build: String) {
        targetBuild = build
        pendingBuild = build
        installingInCurrentCycle = true
    }

    mutating func prepare(using prepare: (String) -> Bool) -> Bool {
        guard let targetBuild = targetBuild ?? pendingBuild else { return false }
        if prepared { return true }
        guard prepare(targetBuild) else { return false }
        prepared = true
        installingInCurrentCycle = true
        pendingBuild = targetBuild
        return true
    }

    mutating func handOff(build: String) {
        schedule(build: build)
        handedOff = true
    }

    mutating func abort(recover: () -> Void) {
        if prepared || installingInCurrentCycle {
            // The quit gate can prepare the runtime outside this backend.
            // Its recovery closure must check its own prepared state as well.
            recover()
            pendingBuild = nil
        }
        prepared = false
        handedOff = false
        installingInCurrentCycle = false
    }

    mutating func finishSession(recover: () -> Void) {
        if prepared && !handedOff {
            recover()
            prepared = false
            pendingBuild = nil
        }
        // Sparkle dismisses its UI before delivering an installer error.
        // Keep the active-install marker until the updater reports its outcome.
    }

    mutating func finish(recover: () -> Void) {
        finishSession(recover: recover)
        installingInCurrentCycle = false
    }

    mutating func skip(recover: () -> Void) {
        abort(recover: recover)
        targetBuild = nil
        pendingBuild = nil
    }
}

@MainActor
final class UpdateStore: ObservableObject {
    @Published private(set) var available: AvailableUpdate?
    @Published private(set) var isChecking = false
    @Published private(set) var message: String?
    @Published private(set) var pendingInstallationBuild: String?
    let observesChanges: Bool
    private let backend: (any UpdateBackend)?
    private var started = false

    var hasPendingInstallation: Bool { pendingInstallationBuild != nil }

    init(observesChanges: Bool = false, backend: (any UpdateBackend)? = nil,
         previewUpdate: AvailableUpdate? = nil) {
        self.observesChanges = observesChanges && backend != nil
        self.backend = observesChanges ? backend : nil
        available = previewUpdate
        if self.observesChanges, let backend {
            apply(backend.state)
        }
    }

    func start() {
        guard observesChanges, !started, let backend else { return }
        started = true
        backend.stateDidChange = { [weak self] state in self?.apply(state) }
        backend.start()
        apply(backend.state)
    }

    /// Sparkle owns scheduled checks. Only an explicit user action opens its UI.
    func checkIfNeeded(force: Bool = false) {
        guard force, observesChanges, let backend else { return }
        start()
        backend.checkForUpdates()
    }

    func installUpdate() {
        guard observesChanges, available != nil else { return }
        checkIfNeeded(force: true)
    }

    // Compatibility for callers of the former release-page update action.
    func openRelease() { installUpdate() }

    func stop() {
        guard started, let backend else { return }
        started = false
        backend.stateDidChange = nil
        backend.stop()
        isChecking = false
    }

    private func apply(_ state: UpdateBackendState) {
        available = state.available
        isChecking = state.isChecking
        message = state.message
        pendingInstallationBuild = state.pendingInstallationBuild
    }
}
