import Foundation
import XCTest

@MainActor
private final class FixtureUpdateBackend: UpdateBackend {
    private(set) var state = UpdateBackendState()
    var stateDidChange: ((UpdateBackendState) -> Void)?
    var startState: UpdateBackendState?
    private(set) var starts = 0
    private(set) var checks = 0
    private(set) var stops = 0
    var canCheckForUpdates = true

    func start() {
        starts += 1
        if let startState { publish(startState) }
    }
    func checkForUpdates() {
        if state.prepareUserCheck(canCheckForUpdates: canCheckForUpdates) { checks += 1 }
        stateDidChange?(state)
    }
    func stop() { stops += 1 }
    func publish(_ state: UpdateBackendState) {
        self.state = state
        stateDidChange?(state)
    }
}

@MainActor
final class UpdateStoreTests: XCTestCase {
    private var update: AvailableUpdate {
        AvailableUpdate(version: "1.0.1", releaseURL: ReleaseUpdateConfiguration.releaseURL(version: "1.0.1"),
                        build: "2026101001")
    }

    func testSparkleOwnsScheduledChecksAndStartIsIdempotent() {
        let backend = FixtureUpdateBackend()
        let store = UpdateStore(observesChanges: true, backend: backend)
        store.checkIfNeeded()
        XCTAssertEqual(backend.starts, 0)
        XCTAssertEqual(backend.checks, 0)
        store.start()
        store.start()
        store.checkIfNeeded()
        XCTAssertEqual(backend.starts, 1)
        XCTAssertEqual(backend.checks, 0)
        store.checkIfNeeded(force: true)
        XCTAssertEqual(backend.starts, 1)
        XCTAssertEqual(backend.checks, 1)
    }

    func testBackendStateIncludesReminderAndDeferredInstallation() {
        let backend = FixtureUpdateBackend()
        backend.startState = UpdateBackendState(available: update, isChecking: true, message: "Checking")
        let store = UpdateStore(observesChanges: true, backend: backend)
        store.start()
        XCTAssertEqual(store.available, update)
        XCTAssertTrue(store.isChecking)
        XCTAssertEqual(store.message, "Checking")
        backend.publish(UpdateBackendState(available: update, pendingInstallationBuild: update.build))
        XCTAssertFalse(store.isChecking)
        XCTAssertTrue(store.hasPendingInstallation)
        XCTAssertEqual(store.pendingInstallationBuild, update.build)
        backend.publish(UpdateBackendState(message: "Installation canceled"))
        XCTAssertNil(store.available)
        XCTAssertFalse(store.hasPendingInstallation)
        XCTAssertEqual(store.message, "Installation canceled")
    }

    func testLaunchBackgroundCheckRunsOnceAfterStartupAndRespectsPreference() throws {
        var startup = UpdateStartupState()
        var calls: [String] = []
        try startup.start(startUpdater: { calls.append("start") },
                          automaticChecksEnabled: { calls.append("preference"); return true },
                          checkInBackground: { calls.append("background") })
        try startup.start(startUpdater: { XCTFail("Already started") },
                          automaticChecksEnabled: { XCTFail("Already checked"); return true },
                          checkInBackground: { XCTFail("No second launch check") })
        XCTAssertEqual(calls, ["start", "preference", "background"])
        XCTAssertTrue(startup.hasStarted)

        var disabled = UpdateStartupState()
        var starts = 0
        try disabled.start(startUpdater: { starts += 1 }, automaticChecksEnabled: { false },
                           checkInBackground: { XCTFail("Respect disabled automatic checks") })
        // Sparkle owns any later preference change and scheduled checks.
        try disabled.start(startUpdater: { XCTFail("Already started") }, automaticChecksEnabled: { true },
                           checkInBackground: { XCTFail("Not a new launch") })
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(disabled.hasStarted)
    }

    func testStartupFailureDoesNotConsumeTheRetryOrBackgroundCheck() throws {
        var startup = UpdateStartupState()
        var attempts = 0
        var checks = 0
        XCTAssertThrowsError(try startup.start(startUpdater: {
            attempts += 1
            throw NSError(domain: "fixture-updater", code: 1)
        }, automaticChecksEnabled: { XCTFail("Startup failed"); return true },
           checkInBackground: { checks += 1 }))
        XCTAssertFalse(startup.hasStarted)
        XCTAssertEqual(checks, 0)
        try startup.start(startUpdater: { attempts += 1 }, automaticChecksEnabled: { true },
                          checkInBackground: { checks += 1 })
        XCTAssertTrue(startup.hasStarted)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(checks, 1)
    }

    func testBusyNativeBackendShowsFeedbackKeepsTheReminderAndAllowsRetry() {
        let backend = FixtureUpdateBackend()
        let store = UpdateStore(observesChanges: true, backend: backend)
        store.start()
        backend.publish(UpdateBackendState(available: update, isChecking: true))
        backend.canCheckForUpdates = false
        store.installUpdate()
        XCTAssertEqual(backend.checks, 0)
        XCTAssertTrue(store.isChecking)
        XCTAssertEqual(store.available, update)
        XCTAssertTrue(store.message?.contains("in progress") == true)

        backend.publish(UpdateBackendState(available: update))
        backend.canCheckForUpdates = true
        store.installUpdate()
        XCTAssertEqual(backend.checks, 1)
        XCTAssertNil(store.message)
        XCTAssertFalse(store.isChecking, "Focusing native UI must not invent a new in-flight check")
        XCTAssertEqual(store.available, update)
    }

    func testNoUpdateClearsTheReminderAndBusyStateWithoutDiscardingDeferredInstallation() {
        let backend = FixtureUpdateBackend()
        let store = UpdateStore(observesChanges: true, backend: backend)
        store.start()
        var state = UpdateBackendState(available: update, isChecking: true, pendingInstallationBuild: update.build)
        backend.publish(state)
        state.finishWithoutUpdate(message: "BeaverMeter is up to date.")
        backend.publish(state)
        XCTAssertNil(store.available)
        XCTAssertFalse(store.isChecking)
        XCTAssertEqual(store.message, "BeaverMeter is up to date.")
        XCTAssertEqual(store.pendingInstallationBuild, update.build)
    }

    func testFailedCheckMessageIsVisibleAndExplicitRetryClearsIt() {
        let backend = FixtureUpdateBackend()
        let store = UpdateStore(observesChanges: true, backend: backend)
        store.start()
        backend.publish(UpdateBackendState(message: "The update server could not be reached."))
        XCTAssertFalse(store.isChecking)
        XCTAssertEqual(store.message, "The update server could not be reached.")
        store.checkIfNeeded(force: true)
        XCTAssertEqual(backend.checks, 1)
        XCTAssertNil(store.message)
    }

    func testUpdateActionUsesNativeBackendOnlyWhenAnUpdateExists() {
        let backend = FixtureUpdateBackend()
        let store = UpdateStore(observesChanges: true, backend: backend)
        store.installUpdate()
        XCTAssertEqual(backend.checks, 0)
        store.start()
        backend.publish(UpdateBackendState(available: update))
        store.installUpdate()
        XCTAssertEqual(backend.checks, 1)
        store.openRelease()
        XCTAssertEqual(backend.checks, 2)
    }

    func testStopDetachesStateAndPreservesQuitGateWithoutRecoveringRuntime() {
        let backend = FixtureUpdateBackend()
        let store = UpdateStore(observesChanges: true, backend: backend)
        store.start()
        backend.publish(UpdateBackendState(isChecking: true, pendingInstallationBuild: update.build))
        store.stop()
        store.stop()
        XCTAssertEqual(backend.stops, 1)
        XCTAssertNil(backend.stateDidChange)
        XCTAssertFalse(store.isChecking)
        XCTAssertEqual(store.pendingInstallationBuild, update.build)
        backend.publish(UpdateBackendState(message: "Late callback"))
        XCTAssertNil(store.message)
        XCTAssertEqual(store.pendingInstallationBuild, update.build)
    }

    func testPreviewAndDisabledStoreNeverStartAnUpdater() {
        let backend = FixtureUpdateBackend()
        let preview = UpdateStore(backend: backend, previewUpdate: update)
        preview.start()
        preview.checkIfNeeded(force: true)
        preview.installUpdate()
        preview.stop()
        backend.publish(UpdateBackendState(message: "Not preview data"))
        XCTAssertFalse(preview.observesChanges)
        XCTAssertEqual(preview.available, update)
        XCTAssertNil(preview.message)
        XCTAssertEqual(backend.starts, 0)
        XCTAssertEqual(backend.checks, 0)
        XCTAssertEqual(backend.stops, 0)
        let unavailable = UpdateStore(observesChanges: true)
        unavailable.start()
        unavailable.checkIfNeeded(force: true)
        XCTAssertFalse(unavailable.observesChanges)
    }

    func testPreparationMustSucceedBeforeHandoffAndIsIdempotent() {
        var installation = UpdateInstallationState()
        var calls: [String] = []
        XCTAssertFalse(installation.prepare { _ in XCTFail("No target"); return true })
        installation.found(build: "2026101001")
        XCTAssertFalse(installation.prepare { build in calls.append(build); return false })
        XCTAssertNil(installation.pendingBuild)
        XCTAssertTrue(installation.prepare { build in calls.append(build); return true })
        XCTAssertTrue(installation.prepare { _ in XCTFail("Already prepared"); return false })
        XCTAssertEqual(calls, ["2026101001", "2026101001"])
        XCTAssertEqual(installation.pendingBuild, "2026101001")
    }

    func testUnhandedPreparationRecoversWhenSessionEnds() {
        var installation = UpdateInstallationState()
        var recoveries = 0
        installation.found(build: "2026101001")
        XCTAssertTrue(installation.prepare { _ in true })
        installation.finish { recoveries += 1 }
        installation.finish { recoveries += 1 }
        XCTAssertEqual(recoveries, 1)
        XCTAssertNil(installation.pendingBuild)
    }

    func testInstallerHandoffSurvivesSessionFinishButAbortRecoversOnce() {
        var installation = UpdateInstallationState()
        var recoveries = 0
        installation.found(build: "2026101001")
        XCTAssertTrue(installation.prepare { _ in true })
        installation.handOff(build: "2026101001")
        installation.finishSession { recoveries += 1 }
        installation.finish { recoveries += 1 }
        XCTAssertEqual(recoveries, 0)
        XCTAssertEqual(installation.pendingBuild, "2026101001")
        installation.abort { recoveries += 1 }
        installation.abort { recoveries += 1 }
        XCTAssertEqual(recoveries, 1)
        XCTAssertNil(installation.pendingBuild)
    }

    func testLaunchedManualInstallerGatesQuitBeforeRelaunchChoice() {
        var installation = UpdateInstallationState()
        // didExtractUpdate means Sparkle's helper has received the archive;
        // no .installing choice callback accompanies the first ready window.
        installation.schedule(build: "2026101001")
        installation.finishSession { XCTFail("Waiting for quit did not prepare the runtime") }
        XCTAssertEqual(installation.pendingBuild, "2026101001")
        var preparedBuild: String?
        XCTAssertTrue(installation.prepare { build in preparedBuild = build; return true })
        XCTAssertEqual(preparedBuild, "2026101001")
    }

    func testInstallerFailureAfterUiDismissalClearsTheQuitGateOnce() {
        var installation = UpdateInstallationState()
        var recoveries = 0
        installation.schedule(build: "2026101001")
        // Sparkle invokes the UI-session callback before didAbortWithError.
        installation.finishSession { recoveries += 1 }
        XCTAssertEqual(recoveries, 0)
        XCTAssertEqual(installation.pendingBuild, "2026101001")
        installation.abort { recoveries += 1 }
        installation.abort { recoveries += 1 }
        XCTAssertEqual(recoveries, 1)
        XCTAssertNil(installation.pendingBuild)
    }

    func testDeferredInstallRemainsPendingAcrossFinishedAndFailedChecks() {
        var installation = UpdateInstallationState()
        installation.schedule(build: "2026101001")
        installation.finish { XCTFail("A deferred installer did not suspend the runtime") }
        XCTAssertEqual(installation.pendingBuild, "2026101001")
        installation.beginCycle()
        installation.abort { XCTFail("A failed feed check must not resume runtime or discard installer") }
        XCTAssertEqual(installation.pendingBuild, "2026101001")
        installation.skip {}
        XCTAssertNil(installation.pendingBuild)
    }
}
