import Foundation
import XCTest

final class SnapshotFileReaderTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-reader-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func snapshot(_ count: Int, date: Date? = nil) -> UsageSnapshot {
        let base = UsageSnapshot.preview
        let date = date ?? now
        return UsageSnapshot(schemaVersion: 7, generatedAt: date,
            codexTokens: UsageValue(status: .ready, source: .preview, measuredAt: date,
                lastAttemptAt: date, message: nil,
                value: CodexTokenTotals(totalTokens: count, inputTokens: count, cachedInputTokens: 0,
                                       outputTokens: 0, reasoningTokens: 0, sessionCount: 1)),
            cursorCosts: base.cursorCosts, cursorQuota: base.cursorQuota, codexQuota: base.codexQuota,
            claudeTokens: base.claudeTokens, claudeQuota: base.claudeQuota, deepseekUsage: base.deepseekUsage)
    }

    private func encoded(_ count: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot(count))
    }

    func testUnchangedFileIsNotDecodedAndPublishedAgain() async throws {
        let url = try directory().appendingPathComponent("snapshot.json")
        try encoded(10).write(to: url)
        let reader = SnapshotFileReader(url: url)
        let first = await reader.read()
        let unchanged = await reader.read()
        XCTAssertEqual(first?.revision, 1)
        XCTAssertEqual(first?.snapshot.codexTokens.value?.totalTokens, 10)
        XCTAssertEqual(unchanged?.revision, first?.revision)
        var gate = SnapshotAdoptionGate()
        XCTAssertTrue(gate.accepts(first!, over: snapshot(20)))
        XCTAssertFalse(gate.accepts(unchanged!, over: snapshot(10)))
    }

    func testSameTimestampSameSizeAtomicReplacementIsDetectedByInode() async throws {
        let url = try directory().appendingPathComponent("snapshot.json")
        let firstData = try encoded(10), nextData = try encoded(20)
        XCTAssertEqual(firstData.count, nextData.count)
        try AtomicFileWriter.write(firstData, to: url)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        let reader = SnapshotFileReader(url: url)
        _ = await reader.read()
        try AtomicFileWriter.write(nextData, to: url)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        let next = await reader.read()
        XCTAssertEqual(next?.revision, 2)
        XCTAssertEqual(next?.snapshot.codexTokens.value?.totalTokens, 20)
    }

    func testFailedDecodeDoesNotCacheItsStampAndCanRetrySameMetadata() async throws {
        let url = try directory().appendingPathComponent("snapshot.json")
        let good = try encoded(10)
        try Data(repeating: 0x21, count: good.count).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        let reader = SnapshotFileReader(url: url)
        let failed = await reader.read()
        XCTAssertNil(failed)
        try good.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        let restored = await reader.read()
        XCTAssertEqual(restored?.revision, 1)
        XCTAssertEqual(restored?.snapshot.codexTokens.value?.totalTokens, 10)
    }

    func testMissingDeletedAndRecreatedFilesAreRetried() async throws {
        let url = try directory().appendingPathComponent("snapshot.json")
        let reader = SnapshotFileReader(url: url)
        let missing = await reader.read()
        XCTAssertNil(missing)
        try encoded(10).write(to: url)
        let first = await reader.read()
        XCTAssertEqual(first?.revision, 1)
        try FileManager.default.removeItem(at: url)
        let deleted = await reader.read()
        XCTAssertNil(deleted)
        try encoded(20).write(to: url)
        let recreated = await reader.read()
        XCTAssertEqual(recreated?.revision, 2)
    }

    func testSymlinkTracksItsReplacedTarget() async throws {
        let root = try directory(), target = root.appendingPathComponent("target.json")
        let link = root.appendingPathComponent("snapshot.json")
        try AtomicFileWriter.write(encoded(10), to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let reader = SnapshotFileReader(url: link)
        let first = await reader.read()
        XCTAssertEqual(first?.snapshot.codexTokens.value?.totalTokens, 10)
        try AtomicFileWriter.write(encoded(20), to: target)
        let next = await reader.read()
        XCTAssertEqual(next?.snapshot.codexTokens.value?.totalTokens, 20)
    }

    func testConcurrentPollAndRefreshReadOneVersionOnce() async throws {
        let url = try directory().appendingPathComponent("snapshot.json")
        try encoded(10).write(to: url)
        let reader = SnapshotFileReader(url: url)
        async let poll = reader.read()
        async let refresh = reader.read()
        let (a, b) = await (poll, refresh)
        XCTAssertEqual([a, b].compactMap { $0 }.map(\.revision), [1, 1])
    }

    func testUnchangedVersionRemainsAvailableAfterSuspensionOrAConcurrentPoll() async throws {
        let url = try directory().appendingPathComponent("snapshot.json")
        try encoded(10).write(to: url)
        let reader = SnapshotFileReader(url: url)
        _ = await reader.read()
        let retry = await reader.read()
        XCTAssertEqual(retry?.revision, 1)
        var gate = SnapshotAdoptionGate()
        XCTAssertTrue(gate.accepts(retry!, over: snapshot(20)))
    }

    func testOutOfOrderMainActorContinuationsCannotRollBackSameSecondData() {
        var gate = SnapshotAdoptionGate()
        var current = snapshot(10)
        let older = SnapshotReadUpdate(revision: 1, snapshot: snapshot(20))
        let newer = SnapshotReadUpdate(revision: 2, snapshot: snapshot(30))
        if gate.accepts(newer, over: current) { current = newer.snapshot }
        if gate.accepts(older, over: current) { current = older.snapshot }
        XCTAssertEqual(current.codexTokens.value?.totalTokens, 30)
        XCTAssertEqual(gate.observedRevision, 2)
    }

    func testNewerFileWithOlderSnapshotDoesNotPermitAnOlderReadToReturnLater() {
        var gate = SnapshotAdoptionGate()
        let current = snapshot(10)
        XCTAssertFalse(gate.accepts(SnapshotReadUpdate(revision: 2,
            snapshot: snapshot(20, date: now.addingTimeInterval(-1))), over: current))
        XCTAssertFalse(gate.accepts(SnapshotReadUpdate(revision: 1, snapshot: snapshot(30)), over: current))
    }
}
