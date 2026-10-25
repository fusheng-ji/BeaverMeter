import Foundation

/// The App and its Widget receive the same scheme from their build settings.
enum AppNavigation {
    enum Target: Equatable { case menu, codexWorkspaces }

    static var scheme: String? {
        Bundle.main.object(forInfoDictionaryKey: "BeaverMeterMenuURLScheme") as? String
    }

    static var menuURL: URL? { scheme.flatMap(menuURL(scheme:)) }
    static var codexWorkspacesURL: URL? { scheme.flatMap(codexWorkspacesURL(scheme:)) }

    static func menuURL(scheme: String) -> URL? {
        url(for: .menu, scheme: scheme)
    }

    static func codexWorkspacesURL(scheme: String) -> URL? {
        url(for: .codexWorkspaces, scheme: scheme)
    }

    private static func url(for target: Target, scheme: String) -> URL? {
        guard !scheme.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "menu"
        if target == .codexWorkspaces { components.path = "/codex-workspaces" }
        return components.url
    }

    static func accepts(_ url: URL, scheme: String) -> Bool {
        target(for: url, scheme: scheme) != nil
    }

    static func target(for url: URL, scheme: String) -> Target? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !scheme.isEmpty, components.scheme?.lowercased() == scheme.lowercased(),
              components.host == "menu", components.percentEncodedHost == "menu",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil else { return nil }
        switch components.percentEncodedPath {
        case "": return .menu
        case "/codex-workspaces": return .codexWorkspaces
        default: return nil
        }
    }
}

/// Opening before the status item exists is queued once; repeated open events
/// present the existing popover rather than toggling or creating another one.
struct MenuPresentationRequests {
    private(set) var isReady = false
    private(set) var pendingTarget: AppNavigation.Target?
    var hasPendingOpen: Bool { pendingTarget != nil }

    mutating func requestOpen(target: AppNavigation.Target = .menu) -> Bool {
        if isReady { return true }
        // A generic launch/open event must not erase a queued section link.
        if pendingTarget != .codexWorkspaces { pendingTarget = target }
        return false
    }

    mutating func becomeReady() -> Bool {
        isReady = true
        defer { pendingTarget = nil }
        return hasPendingOpen
    }
}
