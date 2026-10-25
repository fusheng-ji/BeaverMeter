import Darwin
import Foundation

enum SnapshotWriter {
    private enum LockFailure: Error { case busy }

    final class Lock: @unchecked Sendable {
        private var descriptor: Int32

        fileprivate init(url: URL, nonblocking: Bool = false) throws {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let lockURL = url.appendingPathExtension("lock")
            descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                descriptor = -1
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            guard Darwin.lockf(descriptor, nonblocking ? F_TLOCK : F_LOCK, 0) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                descriptor = -1
                // Only record-lock contention is a harmless skipped poll. In particular,
                // EACCES from open/fchmod above must remain an actual filesystem failure.
                if nonblocking && (code == EACCES || code == EAGAIN) { throw LockFailure.busy }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }

        func unlock() {
            guard descriptor >= 0 else { return }
            Darwin.lockf(descriptor, F_ULOCK, 0)
            Darwin.close(descriptor)
            descriptor = -1
        }

        deinit {
            unlock()
        }
    }

    static func lock(for url: URL) throws -> Lock {
        try Lock(url: url)
    }

    /// Frequent local polls are redundant while another collector owns the snapshot.
    /// Full refresh and authentication use the blocking lock above.
    static func tryLock(for url: URL) throws -> Lock? {
        do { return try Lock(url: url, nonblocking: true) }
        catch LockFailure.busy { return nil }
    }

    static func loadPrevious(from url: URL) -> UsageSnapshot {
        UsageSnapshot.load(from: url)
    }

    static func write(_ snapshot: UsageSnapshot, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let protectDirectory = directory.standardizedFileURL
            == UsageSnapshot.snapshotURL.deletingLastPathComponent().standardizedFileURL
        try AtomicFileWriter.writeJSON(snapshot, to: url, prettyPrinted: true, protectDirectory: protectDirectory)
    }
}
