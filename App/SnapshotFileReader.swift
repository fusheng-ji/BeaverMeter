import Darwin
import Foundation

struct SnapshotReadUpdate: Sendable {
    let revision: UInt64
    let snapshot: UsageSnapshot
}

/// A newer read wins even when two atomic replacements share a snapshot timestamp.
struct SnapshotAdoptionGate {
    private(set) var observedRevision: UInt64 = 0

    mutating func accepts(_ update: SnapshotReadUpdate, over current: UsageSnapshot) -> Bool {
        guard update.revision > observedRevision else { return false }
        observedRevision = update.revision
        return update.snapshot.supersedes(current)
    }
}

/// Keeps IO and decoding off the main actor. Cached snapshots share their value storage with the UI.
actor SnapshotFileReader {
    private struct Stamp: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let seconds: Int
        let nanoseconds: Int
    }

    private let url: URL
    private var lastStamp: Stamp?
    private var cachedUpdate: SnapshotReadUpdate?
    private var revision: UInt64 = 0

    init(url: URL) { self.url = url }

    func read() -> SnapshotReadUpdate? {
        guard let before = stamp() else {
            lastStamp = nil
            cachedUpdate = nil
            return nil
        }
        // Return the same revision until a consumer adopts it. A concurrent auth
        // completion must not miss a version decoded by a poll that has not published yet.
        if before == lastStamp { return cachedUpdate }
        guard let data = try? Data(contentsOf: url),
              let snapshot = UsageSnapshot.decode(data),
              stamp() == before else { return nil }
        lastStamp = before
        revision += 1
        let update = SnapshotReadUpdate(revision: revision, snapshot: snapshot)
        cachedUpdate = update
        return update
    }

    private func stamp() -> Stamp? {
        var information = stat()
        let exists = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return stat(path, &information) == 0
        }
        guard exists, information.st_mode & S_IFMT == S_IFREG else { return nil }
        return Stamp(device: information.st_dev, inode: information.st_ino, size: information.st_size,
                     seconds: information.st_mtimespec.tv_sec, nanoseconds: information.st_mtimespec.tv_nsec)
    }
}
