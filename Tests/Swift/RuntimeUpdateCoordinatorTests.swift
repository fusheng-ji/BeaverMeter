import XCTest

@MainActor
private final class RuntimeSessionFixture: UpdateRuntimeSession {
    var updateInstallationBlockReason: String?
    var suspended = false
    var resumes = 0
    func suspendForUpdate() { suspended = true }
    func resumeAfterUpdate() { suspended = false; resumes += 1 }
}

@MainActor
final class RuntimeUpdateCoordinatorTests: XCTestCase {
    func testPreparationIsIdempotentAndAbortRestoresServices() {
        let session = RuntimeSessionFixture()
        var operations: [String] = []
        let coordinator = RuntimeUpdateCoordinator(session: session, run: { operation, build in
            operations.append(operation)
            if operation == "prepare" { XCTAssertEqual(build, "37") }
        })
        XCTAssertTrue(coordinator.prepare(targetBuild: "37"))
        XCTAssertTrue(coordinator.prepare(targetBuild: "37"))
        XCTAssertTrue(session.suspended)
        XCTAssertEqual(operations, ["prepare"])
        coordinator.recoverAfterAbort()
        XCTAssertEqual(operations, ["prepare", "recover"])
        XCTAssertFalse(coordinator.isPrepared)
        XCTAssertFalse(session.suspended)
    }

    func testActiveLoginPreventsAnyRuntimeMutation() {
        let session = RuntimeSessionFixture()
        session.updateInstallationBlockReason = "Finish signing in."
        var message: String?
        let coordinator = RuntimeUpdateCoordinator(session: session, run: { _, _ in
            XCTFail("An active login must not stop runtime services")
        }, reportError: { message = $0 })
        XCTAssertFalse(coordinator.prepare(targetBuild: "37"))
        XCTAssertFalse(session.suspended)
        XCTAssertEqual(message, "Finish signing in.")
    }

    func testPreparationFailureRecoversBeforeRefusingInstallation() {
        let session = RuntimeSessionFixture()
        var operations: [String] = []
        let coordinator = RuntimeUpdateCoordinator(session: session, run: { operation, _ in
            operations.append(operation)
            if operation == "prepare" { throw NSError(domain: "fixture", code: 1) }
        })
        XCTAssertFalse(coordinator.prepare(targetBuild: "37"))
        XCTAssertEqual(operations, ["prepare", "recover"])
        XCTAssertFalse(session.suspended)
        XCTAssertFalse(coordinator.isPrepared)
    }

    func testRecoveryFailureKeepsCollectionSuspendedForNextLaunch() {
        let session = RuntimeSessionFixture()
        var messages: [String] = []
        let coordinator = RuntimeUpdateCoordinator(session: session, run: { operation, _ in
            if operation == "recover" { throw NSError(domain: "fixture", code: 2) }
        }, reportError: { messages.append($0) })
        XCTAssertTrue(coordinator.prepare(targetBuild: "37"))
        coordinator.recoverAfterAbort()
        XCTAssertTrue(session.suspended)
        XCTAssertTrue(coordinator.isPrepared)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("Reopen BeaverMeter"))
    }
}
