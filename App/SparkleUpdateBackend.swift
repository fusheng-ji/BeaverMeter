import Foundation
import Sparkle

/// Sparkle owns version selection, authenticated downloads, and replacement.
/// The application only mirrors reminder state and gates runtime handoff.
@MainActor
final class SparkleUpdateBackend: NSObject, UpdateBackend, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private(set) var state = UpdateBackendState() {
        didSet { if isActive { stateDidChange?(state) } }
    }
    var stateDidChange: ((UpdateBackendState) -> Void)?
    private let prepareForInstallation: (String) -> Bool
    private let recoverAfterAbort: () -> Void
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    private var isActive = false
    private var startup = UpdateStartupState()
    private var installation = UpdateInstallationState()

    init(prepareForInstallation: @escaping (String) -> Bool,
         recoverAfterAbort: @escaping () -> Void) {
        self.prepareForInstallation = prepareForInstallation
        self.recoverAfterAbort = recoverAfterAbort
        super.init()
    }

    func start() {
        isActive = true
        let updater = controller.updater
        do {
            try startup.start(startUpdater: { try updater.start() },
                              automaticChecksEnabled: { updater.automaticallyChecksForUpdates },
                              checkInBackground: { updater.checkForUpdatesInBackground() })
        } catch {
            state.isChecking = false
            state.message = "Could not start update checks: \(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        guard isActive else { return }
        // A failed startup may be retried without relaunching the application.
        if !startup.hasStarted { start() }
        guard startup.hasStarted,
              state.prepareUserCheck(canCheckForUpdates: controller.updater.canCheckForUpdates) else { return }
        // Also brings a deferred scheduled update into focus using native UI.
        // Only mayPerform marks checking: bringing an existing alert to the
        // front does not begin another check or send completion callbacks.
        controller.checkForUpdates(nil)
    }

    func stop() {
        isActive = false
        stateDidChange = nil
        // Sparkle has no stop method. The delegate rejects subsequent checks.
        // A runtime already handed to its installer must remain suspended.
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard isActive else {
            throw NSError(domain: "io.github.fushengji.beavermeter.updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The application is shutting down."])
        }
        installation.beginCycle()
        state.isChecking = true
        state.message = nil
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard isActive else { return }
        remember(item)
        state.isChecking = false
        state.message = nil
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        guard isActive else { return }
        state.finishWithoutUpdate(message: error.localizedDescription)
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate update: SUAppcastItem, state updateState: SPUUserUpdateState) {
        guard isActive else { return }
        if choice == .skip {
            installation.skip(recover: recoverAfterAbort)
            state.available = nil
        } else if updateState.stage == .installing {
            installation.schedule(build: update.versionString)
        }
        syncInstallationState()
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        guard isActive else { return }
        // In Sparkle 2.10 this arrives after the helper has launched and
        // received the archive. The helper can finish if the user quits while
        // extraction or the first Ready to Install window is still open.
        installation.schedule(build: item.versionString)
        syncInstallationState()
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        guard isActive else { return false }
        let ready = installation.prepare(using: prepareForInstallation)
        syncInstallationState()
        if !ready {
            state.message = "Could not prepare BeaverMeter for installation. Try the update again."
        }
        return ready
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        guard isActive else { return }
        // This is a notification, not an asynchronous installation gate.
        installation.handOff(build: item.versionString)
        syncInstallationState()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        guard isActive else { return false }
        installation.schedule(build: item.versionString)
        syncInstallationState()
        return false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard isActive else { return }
        let error = error as NSError
        if isNoUpdate(error) {
            state.finishWithoutUpdate(message: error.localizedDescription)
        } else {
            abortInstallation(for: error)
            state.message = error.localizedDescription
        }
        state.isChecking = false
        syncInstallationState()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        guard isActive else { return }
        if let error = error as NSError? {
            if isNoUpdate(error) {
                state.finishWithoutUpdate(message: error.localizedDescription)
                installation.finish(recover: recoverAfterAbort)
            } else {
                abortInstallation(for: error)
                state.message = error.localizedDescription
            }
        } else {
            installation.finish(recover: recoverAfterAbort)
        }
        state.isChecking = false
        syncInstallationState()
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                  forUpdate update: SUAppcastItem,
                                                  state updateState: SPUUserUpdateState) {
        guard isActive else { return }
        remember(update)
        if updateState.stage == .installing {
            installation.schedule(build: update.versionString)
        }
        state.isChecking = false
        syncInstallationState()
    }

    func standardUserDriverWillFinishUpdateSession() {
        guard isActive else { return }
        installation.finishSession(recover: recoverAfterAbort)
        state.isChecking = false
        syncInstallationState()
    }

    private func remember(_ item: SUAppcastItem) {
        installation.found(build: item.versionString)
        state.available = AvailableUpdate(version: item.displayVersionString,
                                          releaseURL: ReleaseUpdateConfiguration.releaseURL(version: item.displayVersionString),
                                          build: item.versionString)
    }

    private func syncInstallationState() { state.pendingInstallationBuild = installation.pendingBuild }

    private func abortInstallation(for error: NSError) {
        if error.domain == SUSparkleErrorDomain && error.code == SUError.resumeAppcastError.rawValue {
            // The installer status probe could no longer recover its item.
            // Discard the stale quit gate even if this cycle never staged it.
            installation.skip(recover: recoverAfterAbort)
        } else {
            installation.abort(recover: recoverAfterAbort)
        }
    }

    private func isNoUpdate(_ error: NSError) -> Bool {
        error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue
    }
}
