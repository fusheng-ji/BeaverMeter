import Darwin
import Foundation

/// Synthetic input only. The production snapshot loader is excluded from both QA targets.
struct WidgetQACase: Codable, Hashable, Sendable {
    let caseID: String
    let snapshot: UsageSnapshot
    let settings: ProviderSettings
    let referenceDate: Date
    var selectedModuleIDs: [String]? = nil
}

enum WidgetQAStore {
    static let kind = "BeaverMeterWidgetQA"
    static let scheme = "com.jiwenbo.beavermeter.widgetqa"

    static var directory: URL {
        let home: URL
        if let account = getpwuid(getuid()) {
            home = URL(fileURLWithPath: String(cString: account.pointee.pw_dir), isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        return home.appendingPathComponent("Library/Application Support/BeaverMeter-WidgetQA", isDirectory: true)
    }

    static var currentURL: URL { directory.appendingPathComponent("current-case.json") }

    static func decode(_ data: Data) throws -> WidgetQACase {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fixture = try decoder.decode(WidgetQACase.self, from: data)
        guard !fixture.caseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure("The QA caseID is empty.")
        }
        guard fixture.snapshot.schemaVersion == UsageSnapshot.currentSchemaVersion else {
            throw Failure("The QA snapshot schema is unsupported.")
        }
        return fixture
    }

    static func load(from url: URL = currentURL) throws -> WidgetQACase {
        try decode(Data(contentsOf: url))
    }

    /// Validate before replacing the previous case, using private atomic file creation.
    @discardableResult
    static func apply(_ data: Data, to url: URL = currentURL) throws -> WidgetQACase {
        let fixture = try decode(data)
        try AtomicFileWriter.writeJSON(fixture, to: url, prettyPrinted: true, protectDirectory: true)
        return fixture
    }

    static func fingerprint(at url: URL = currentURL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "missing" }
        return [attributes[.modificationDate], attributes[.size], attributes[.systemFileNumber]]
            .map { String(describing: $0) }.joined(separator: "|")
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

/// Shared settings types reference this property in unused default arguments.
/// Their QA-only destination stays inside the synthetic directory; the real
/// UsageSnapshotStore (including every production load method) is not compiled.
extension UsageSnapshot {
    static var snapshotURL: URL { WidgetQAStore.directory.appendingPathComponent("unused-snapshot.json") }
}
