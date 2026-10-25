import AppKit

@main
enum BeaverMeterApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = BeaverMeterApplicationDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class BeaverMeterApplicationDelegate: NSObject, NSApplicationDelegate {
    private var menu: MenuBarController?
    private var shouldOpenMenu = true
    private var requests = MenuPresentationRequests()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let isDemo = CommandLine.arguments.contains("--interaction-demo")
                || DirectInstallSetup.flag("BeaverMeterInteractionDemo", in: .main)
            if !isDemo, DirectInstallSetup.flag("BeaverMeterDirectInstall", in: .main) {
                let preferred = DirectInstallSetup.preferredInstalledApp(for: .main)
                if preferred.resolvingSymlinksInPath() != Bundle.main.bundleURL.resolvingSymlinksInPath() {
                    if await openPreferredApp(preferred) {
                        NSApplication.shared.terminate(nil)
                        return
                    }
                }
            }
            let message = await DirectInstallSetup.configure()
            if !isDemo, DirectInstallSetup.flag("BeaverMeterDirectInstall", in: .main),
               DirectInstallSetup.needsInstallation(at: Bundle.main.bundleURL) {
                if let message { presentSetupMessage(message) }
                NSApplication.shared.terminate(nil)
                return
            }
            let controller = MenuBarController(runtimeReady: message == nil)
            menu = controller
            controller.prepare()
            let target = requests.pendingTarget ?? .menu
            _ = requests.becomeReady()
            if shouldOpenMenu { controller.openMenu(target: target) }
            if let message { presentSetupMessage(message) }
        }
    }

    private func openPreferredApp(_ appURL: URL) async -> Bool {
        let route = requests.pendingTarget == .codexWorkspaces
            ? AppNavigation.codexWorkspacesURL : AppNavigation.menuURL
        guard let route else { return NSWorkspace.shared.open(appURL) }
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([route], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration()) { application, error in
                continuation.resume(returning: application != nil && error == nil)
            }
        }
    }

    private func presentSetupMessage(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "BeaverMeter setup"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let scheme = AppNavigation.scheme else { return }
        let targets = urls.compactMap { AppNavigation.target(for: $0, scheme: scheme) }
        guard !targets.isEmpty else { return }
        let target: AppNavigation.Target = targets.contains(.codexWorkspaces) ? .codexWorkspaces : .menu
        shouldOpenMenu = true
        if requests.requestOpen(target: target) { menu?.openMenu(target: target) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        shouldOpenMenu = true
        if requests.requestOpen() { menu?.openMenu() }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        menu?.prepareForTermination() == false ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) { menu?.stop() }
}
