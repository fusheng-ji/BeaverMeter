import Darwin
import Foundation
import XCTest

final class SnapshotWriterTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-lock-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("snapshot.json")
    }

    func testTryLockAcquiresFreeLockAndReleaseIsIdempotent() throws {
        let output = try fixture()
        let lock = try XCTUnwrap(SnapshotWriter.tryLock(for: output))
        let attributes = try FileManager.default.attributesOfItem(atPath: output.appendingPathExtension("lock").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        lock.unlock()
        lock.unlock()
        let again = try XCTUnwrap(SnapshotWriter.tryLock(for: output))
        again.unlock()
    }

    func testBlockingLockStillAcquiresAnAvailableSnapshot() throws {
        let output = try fixture()
        let lock = try SnapshotWriter.lock(for: output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        lock.unlock()
        let subsequent = try XCTUnwrap(SnapshotWriter.tryLock(for: output))
        subsequent.unlock()
    }

    func testOpenPermissionFailureIsThrownInsteadOfReportedAsContention() throws {
        guard geteuid() != 0 else { throw XCTSkip("Requires an unprivileged user to exercise EACCES.") }
        let output = try fixture()
        let lockURL = output.appendingPathExtension("lock")
        try Data("synthetic-lock-content".utf8).write(to: lockURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: lockURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockURL.path) }
        XCTAssertThrowsError(try SnapshotWriter.tryLock(for: output)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EACCES)
        }
        XCTAssertEqual(try Data(contentsOf: lockURL), Data("synthetic-lock-content".utf8))
    }

    func testInvalidParentDirectoryIsThrownInsteadOfReportedAsContention() throws {
        let file = try fixture()
        try Data().write(to: file)
        XCTAssertThrowsError(try SnapshotWriter.tryLock(for: file.appendingPathComponent("snapshot.json")))
        XCTAssertEqual(try Data(contentsOf: file), Data())
    }
}
