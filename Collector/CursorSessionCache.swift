import CryptoKit
import Darwin
import Foundation

/// An app-owned credential file, separate from the Widget's usage snapshot.
/// The current Cursor database must still contain the exact login that was
/// verified. Never persist Cursor's long-lived Safe Storage encryption key.
struct CursorSessionCache {
    /// Credentials stay in app-owned storage even when a CLI usage report is
    /// written to a shared or temporary directory.
    static let defaultURL = UsageSnapshot.snapshotURL
        .deletingLastPathComponent()
        .appendingPathComponent("cursor-session.json")

    let url: URL
    private static let maximumBytes = 64 * 1024

    private struct Entry: Codable {
        let version: Int
        let sourceFingerprint: String
        let accessToken: String
    }

    static func fingerprint(databasePath: String, storedToken: String) -> String {
        let path = URL(fileURLWithPath: databasePath).standardizedFileURL.resolvingSymlinksInPath().path
        return SHA256.hash(data: Data("cursor-session-v1\0\(path)\0\(storedToken)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func load(fingerprint: String, now: Date) -> CursorAppAuthSession? {
        guard let entry = readEntry(), entry.sourceFingerprint == fingerprint else { return nil }
        let session = CursorAppAuthSession(accessToken: entry.accessToken, sourceFingerprint: fingerprint)
        return session.isUsableForCache(at: now) ? session : nil
    }

    func save(session: CursorAppAuthSession, now: Date) throws {
        guard let fingerprint = session.sourceFingerprint, session.isUsableForCache(at: now) else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(Entry(version: 1, sourceFingerprint: fingerprint, accessToken: session.accessToken))
            guard data.count <= Self.maximumBytes else { throw CocoaError(.fileWriteUnknown) }
            try AtomicFileWriter.write(data, to: url, protectDirectory: true)
        } catch {
            throw CursorDashboardError.invalidSession(
                "Cursor login was verified but could not be saved for automatic refresh. Check BeaverMeter's data folder permissions."
            )
        }
    }

    func invalidate(fingerprint: String) {
        guard readEntry()?.sourceFingerprint == fingerprint else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func readEntry() -> Entry? {
        // Validate the opened file itself, so symlinks and permissive files
        // cannot supply a credential. Bound reads even if the file grows.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_mode & 0o777 == 0o600,
              metadata.st_uid == getuid(), metadata.st_size > 0,
              metadata.st_size <= Self.maximumBytes else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: Self.maximumBytes + 1),
              data.count <= Self.maximumBytes,
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.version == 1 else { return nil }
        return entry
    }
}
