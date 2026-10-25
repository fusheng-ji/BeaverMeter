import AppKit
import SwiftUI
import WidgetKit

@main
enum WidgetQAApp {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            if arguments == ["--self-test"] {
                try WidgetQASelfTest.run()
                print("Widget QA contract self-test passed.")
                return
            }
            if arguments == ["--reload"] {
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetQAStore.kind)
                print("Requested reload for \(WidgetQAStore.kind).")
                return
            }
            if arguments.count == 2, arguments[0] == "--apply" {
                let fixture = try WidgetQAStore.apply(Data(contentsOf: URL(fileURLWithPath: arguments[1])))
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetQAStore.kind)
                print("Applied synthetic case \(fixture.caseID).")
                return
            }
            guard arguments.isEmpty || arguments.allSatisfy({ $0.hasPrefix("-psn_") }) else {
                throw WidgetQAStore.Failure("Usage: BeaverMeter QA [--apply FILE | --reload | --self-test]")
            }
        } catch {
            FileHandle.standardError.write(Data("Widget QA: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        let application = NSApplication.shared
        let delegate = WidgetQADelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class WidgetQAHostModel: ObservableObject {
    @Published var fixture: WidgetQACase?
    @Published var failure: String?

    func load() {
        do { fixture = try WidgetQAStore.load(); failure = nil }
        catch { fixture = nil; failure = error.localizedDescription }
    }
}

@MainActor
final class WidgetQADelegate: NSObject, NSApplicationDelegate {
    private let model = WidgetQAHostModel()
    private var window: NSWindow?
    private var timer: Timer?
    private var fingerprint = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        refresh()
        showWindow()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForCaseChange() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == WidgetQAStore.scheme {
            if url.host == "reload" { refresh() }
            else if AppNavigation.accepts(url, scheme: WidgetQAStore.scheme) { refresh(); showWindow() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        refresh(); showWindow(); return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate() }

    private func checkForCaseChange() {
        if WidgetQAStore.fingerprint() != fingerprint { refresh() }
    }

    private func refresh() {
        fingerprint = WidgetQAStore.fingerprint()
        model.load()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetQAStore.kind)
    }

    private func showWindow() {
        if window == nil {
            let content = WidgetQAHostView(model: model)
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            panel.title = "BeaverMeter QA"
            panel.contentView = NSHostingView(rootView: content)
            panel.isReleasedWhenClosed = false
            panel.center()
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct WidgetQAHostView: View {
    @ObservedObject var model: WidgetQAHostModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BeaverMeter QA").font(.title2.bold())
            Text("Synthetic desktop Widget validation").foregroundStyle(.secondary)
            if let fixture = model.fixture {
                Text("Case: \(fixture.caseID)").font(.headline).textSelection(.enabled)
                Text("Frozen: \(fixture.referenceDate.ISO8601Format())").font(.caption)
                Text("Codex workspaces").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(fixture.snapshot.codexAccounts.value ?? []) { account in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.workspaceName ?? account.displayName).fontWeight(.medium)
                                Text("ID: \(account.id)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("QA load failed").font(.headline)
                Text(model.failure ?? "No synthetic case is available.").foregroundStyle(.secondary)
            }
            Text(WidgetQAStore.currentURL.path).font(.caption).textSelection(.enabled)
            Button("Reload QA Widget") { WidgetCenter.shared.reloadTimelines(ofKind: WidgetQAStore.kind) }
        }
        .padding(22)
        .frame(minWidth: 460, minHeight: 360, alignment: .topLeading)
    }
}
