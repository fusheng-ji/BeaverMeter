import Foundation
import XCTest

final class AppNavigationTests: XCTestCase {
    private let scheme = "com.beavermeter.tests.beavermeter"

    func testMenuRouteAndBuildIsolation() throws {
        let url = try XCTUnwrap(AppNavigation.menuURL(scheme: scheme))
        XCTAssertEqual(url.absoluteString, scheme + "://menu")
        XCTAssertTrue(AppNavigation.accepts(url, scheme: scheme))
        XCTAssertEqual(AppNavigation.target(for: url, scheme: scheme), .menu)
        XCTAssertFalse(AppNavigation.accepts(url, scheme: "com.example.beavermeter"))
        XCTAssertNil(AppNavigation.menuURL(scheme: ""))
    }

    func testWorkspaceRouteAndBuildIsolation() throws {
        let url = try XCTUnwrap(AppNavigation.codexWorkspacesURL(scheme: scheme))
        XCTAssertEqual(url.absoluteString, scheme + "://menu/codex-workspaces")
        XCTAssertEqual(AppNavigation.target(for: url, scheme: scheme), .codexWorkspaces)
        XCTAssertTrue(AppNavigation.accepts(url, scheme: scheme))
        XCTAssertNil(AppNavigation.target(for: url, scheme: "com.example.beavermeter"))
        XCTAssertEqual(AppNavigation.target(for: url, scheme: scheme.uppercased()), .codexWorkspaces)
        XCTAssertNil(AppNavigation.codexWorkspacesURL(scheme: ""))
    }

    func testWorkspaceRouteRejectsAdditionalPayloadAndEncodedAliases() {
        for suffix in ["menu/codex-workspaces/", "menu/codex-workspaces/account",
                       "menu/codex-workspaces?account=one", "menu/codex-workspaces?",
                       "menu/codex-workspaces#one", "menu/codex-workspaces#",
                       "user@menu/codex-workspaces", "menu:80/codex-workspaces",
                       "menu/%63odex-workspaces", "menu/codex%2Dworkspaces",
                       "%6denu/codex-workspaces", "menu//codex-workspaces"] {
            let url = URL(string: scheme + "://" + suffix)!
            XCTAssertNil(AppNavigation.target(for: url, scheme: scheme), suffix)
            XCTAssertFalse(AppNavigation.accepts(url, scheme: scheme), suffix)
        }
    }

    func testUnrecognizedRoutesAndPayloadsHaveNoOpenAction() {
        for suffix in ["settings", "menu/", "menu/file", "menu?command=refresh", "menu#section",
                       "user@menu", "menu:80", "menu?", "menu#"] {
            XCTAssertFalse(AppNavigation.accepts(URL(string: scheme + "://" + suffix)!, scheme: scheme), suffix)
        }
        XCTAssertFalse(AppNavigation.accepts(URL(string: "file:///tmp/menu")!, scheme: scheme))
    }

    func testColdRequestsCoalesceAndWarmRequestsAlwaysPresent() {
        var requests = MenuPresentationRequests()
        XCTAssertFalse(requests.requestOpen())
        XCTAssertFalse(requests.requestOpen())
        XCTAssertTrue(requests.hasPendingOpen)
        XCTAssertTrue(requests.becomeReady())
        XCTAssertFalse(requests.hasPendingOpen)
        XCTAssertTrue(requests.requestOpen())
        XCTAssertTrue(requests.requestOpen())
        XCTAssertFalse(requests.becomeReady())
    }

    func testColdWorkspaceTargetSurvivesGenericLaunchEventsAndIsConsumedOnce() {
        var requests = MenuPresentationRequests()
        XCTAssertFalse(requests.requestOpen())
        XCTAssertFalse(requests.requestOpen(target: .codexWorkspaces))
        XCTAssertFalse(requests.requestOpen())
        XCTAssertEqual(requests.pendingTarget, .codexWorkspaces)
        XCTAssertTrue(requests.becomeReady())
        XCTAssertNil(requests.pendingTarget)
        XCTAssertFalse(requests.hasPendingOpen)
        XCTAssertFalse(requests.becomeReady())
    }

    func testWorkspaceTargetSurvivesDelegateToControllerColdHandoff() {
        var delegate = MenuPresentationRequests(), controller = MenuPresentationRequests()
        XCTAssertFalse(delegate.requestOpen(target: .codexWorkspaces))
        let target = delegate.pendingTarget ?? .menu
        XCTAssertTrue(delegate.becomeReady())
        XCTAssertFalse(controller.requestOpen(target: target))
        XCTAssertEqual(controller.pendingTarget, .codexWorkspaces)
        XCTAssertTrue(controller.becomeReady())
        XCTAssertTrue(controller.requestOpen(target: .codexWorkspaces))
        XCTAssertTrue(controller.requestOpen(target: .codexWorkspaces))
        XCTAssertNil(controller.pendingTarget)
    }
}
