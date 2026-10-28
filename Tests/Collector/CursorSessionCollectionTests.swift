import Foundation
import SQLite3
import XCTest

final class CursorSessionCollectionTests: XCTestCase {
    private typealias Reading = (costs: UsageValue<CursorCostTotals>, quota: UsageValue<CompactQuota>)
    private let now = Date(timeIntervalSince1970: 1_788_192_000)
    private let token = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJhdXRoMHxzeW50aGV0aWMtY3Vyc29yLXVzZXIiLCJleHAiOjQxMDI0NDQ4MDB9.synthetic-signature"
    private let encryptedToken = "cursor-safe-storage:v1:djEwEfphFJGpvG2GZ5sdgxM9sFZb8mszz8xfcP3P7P+pNeRfx8mbhRQaFtRXeUtSTSpabX7qXAJWc1YpqDnpfTHJGtFfgX6LfFE1GAMpxB4zBSe53aBSbSwgo+6sskXIaJvsXHUIKaC/LH2PtVIYTVvSwxqSwCgsCQmBVzZ9bpG5LIE="

    private struct Workspace {
        let database: URL
        let cache: URL
    }

    private actor Dashboard {
        enum Outcome: Sendable {
            case status(Int)
            case timeout
        }

        private let events: Data
        private let summary: Data
        private let eventsOutcome: Outcome
        private let summaryOutcome: Outcome
        private(set) var requests: [URLRequest] = []

        init(events: Data, summary: Data,
             eventsOutcome: Outcome = .status(200), summaryOutcome: Outcome = .status(200)) {
            self.events = events
            self.summary = summary
            self.eventsOutcome = eventsOutcome
            self.summaryOutcome = summaryOutcome
        }

        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            requests.append(request)
            let outcome: Outcome
            let body: Data
            switch request.url?.path {
            case "/api/dashboard/get-filtered-usage-events":
                outcome = eventsOutcome
                body = events
            case "/api/usage-summary":
                outcome = summaryOutcome
                body = summary
            default:
                throw URLError(.unsupportedURL)
            }
            switch outcome {
            case .timeout:
                throw URLError(.timedOut)
            case let .status(code):
                return (body, HTTPURLResponse(url: request.url!, statusCode: code,
                                             httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    func testBothDashboardReadingsMustVerifyBeforePrivateSessionIsSaved() async throws {
        let workspace = try workspace()
        let dashboard = try dashboard()

        let reading = await collect(store(workspace), dashboard: dashboard)

        XCTAssertEqual(reading.costs.status, .ready)
        XCTAssertEqual(reading.costs.value?.todayCostUSD, 0.15)
        XCTAssertEqual(reading.quota.status, .ready)
        XCTAssertEqual(reading.quota.value?.remaining, 57.5)
        let fingerprint = CursorSessionCache.fingerprint(databasePath: workspace.database.path,
                                                        storedToken: encryptedToken)
        XCTAssertEqual(CursorSessionCache(url: workspace.cache).load(fingerprint: fingerprint, now: now)?.accessToken, token)
        XCTAssertEqual(try permissions(workspace.cache), 0o600)
        XCTAssertEqual(try permissions(workspace.cache.deletingLastPathComponent()), 0o700)
        let cacheText = try String(contentsOf: workspace.cache, encoding: .utf8)
        XCTAssertFalse(cacheText.contains("synthetic-safe-storage-password"))
        let snapshotFields = String(decoding: try JSONEncoder().encode([reading.costs]), as: UTF8.self)
            + String(decoding: try JSONEncoder().encode([reading.quota]), as: UTF8.self)
        XCTAssertFalse(snapshotFields.contains(token))
        XCTAssertFalse(snapshotFields.contains("WorkosCursorSessionToken"))
        let requests = await dashboard.requests
        XCTAssertEqual(Set(requests.compactMap { $0.url?.path }),
                       ["/api/usage-summary", "/api/dashboard/get-filtered-usage-events"])
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.url?.host, "cursor.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"),
                           "WorkosCursorSessionToken=synthetic-cursor-user%3A%3A\(token)")
        }
    }

    func testPartialDashboardSuccessDoesNotSaveAnUnverifiedSession() async throws {
        for summaryFails in [true, false] {
            let workspace = try workspace()
            let dashboard = try dashboard(events: .status(summaryFails ? 200 : 500),
                                          summary: .status(summaryFails ? 500 : 200))

            let reading = await collect(store(workspace), dashboard: dashboard)

            XCTAssertEqual(reading.costs.status, summaryFails ? .ready : .error)
            XCTAssertEqual(reading.quota.status, summaryFails ? .error : .ready)
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.cache.path))
            let requestCount = await dashboard.requests.count
            XCTAssertEqual(requestCount, 2)
        }
    }

    func testEitherDashboardEndpointRejectingAuthenticationInvalidatesTheVerifiedSession() async throws {
        for status in [401, 403] {
            for summaryRejects in [true, false] {
                let workspace = try workspace()
                let previous = try await warm(workspace)
                let dashboard = try dashboard(events: .status(summaryRejects ? 200 : status),
                                              summary: .status(summaryRejects ? status : 200))

                let reading = await collect(cachedStore(workspace), dashboard: dashboard, previous: previous,
                                            at: now.addingTimeInterval(30))

                XCTAssertEqual(reading.costs.status, summaryRejects ? .ready : .stale)
                XCTAssertEqual(reading.quota.status, summaryRejects ? .stale : .ready)
                XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.cache.path))
                let requestCount = await dashboard.requests.count
                XCTAssertEqual(requestCount, 2)
            }
        }
    }

    func testTransientTimeoutKeepsTheVerifiedSessionUnchanged() async throws {
        let workspace = try workspace()
        let previous = try await warm(workspace)
        let before = try Data(contentsOf: workspace.cache)
        let dashboard = try dashboard(summary: .timeout)

        let reading = await collect(cachedStore(workspace), dashboard: dashboard, previous: previous,
                                    at: now.addingTimeInterval(30))

        XCTAssertEqual(reading.costs.status, .ready)
        XCTAssertEqual(reading.quota.status, .stale)
        XCTAssertEqual(reading.quota.value, previous.quota.value)
        XCTAssertEqual(reading.quota.measuredAt, previous.quota.measuredAt)
        XCTAssertEqual(try Data(contentsOf: workspace.cache), before)
        let requestCount = await dashboard.requests.count
        XCTAssertEqual(requestCount, 2)
    }

    private func collect(_ store: CursorAppAuthStore, dashboard: Dashboard,
                         previous: Reading? = nil, at date: Date? = nil) async -> Reading {
        await CursorUsageCollector.collect(
            previousCosts: previous?.costs ?? .unavailable("none"),
            previousQuota: previous?.quota ?? .unavailable("none"),
            now: date ?? now, environment: [:], authenticationStore: store,
            dashboardClient: CursorDashboardClient(transport: { try await dashboard.send($0) })
        )
    }

    private func warm(_ workspace: Workspace) async throws -> Reading {
        let reading = await collect(store(workspace), dashboard: try dashboard())
        XCTAssertEqual(reading.costs.status, .ready)
        XCTAssertEqual(reading.quota.status, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.cache.path))
        return reading
    }

    private func store(_ workspace: Workspace) -> CursorAppAuthStore {
        CursorAppAuthStore(databasePath: workspace.database.path, sessionCacheURL: workspace.cache,
                           passwordReader: { Data("synthetic-safe-storage-password".utf8) })
    }

    private func cachedStore(_ workspace: Workspace) -> CursorAppAuthStore {
        CursorAppAuthStore(databasePath: workspace.database.path, sessionCacheURL: workspace.cache,
                           passwordReader: {
            XCTFail("A verified current session must not query the real Keychain or need another password read")
            throw URLError(.userAuthenticationRequired)
        })
    }

    private func dashboard(events: Dashboard.Outcome = .status(200),
                           summary: Dashboard.Outcome = .status(200)) throws -> Dashboard {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures")
        return Dashboard(events: try Data(contentsOf: fixtures.appendingPathComponent("cursor-events-v3.json")),
                         summary: try Data(contentsOf: fixtures.appendingPathComponent("cursor-summary-v3.json")),
                         eventsOutcome: events, summaryOutcome: summary)
    }

    private func workspace() throws -> Workspace {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-session-collection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("state.vscdb")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &connection), SQLITE_OK)
        let db = try XCTUnwrap(connection)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
        INSERT INTO ItemTable (key,value) VALUES ('cursorAuth/accessToken','\(encryptedToken)');
        """
        let status = sqlite3_exec(db, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw NSError(domain: "SyntheticCursorSQLite", code: Int(status)) }
        return Workspace(database: database,
                         cache: root.appendingPathComponent("private").appendingPathComponent("cursor-session.json"))
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}
