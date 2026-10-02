import AppKit
import SwiftUI
import WidgetKit

@main
struct PreviewRenderer {
    @MainActor
    static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--interactive" {
            showInteractivePreview(snapshotURL: URL(fileURLWithPath: arguments[2]))
            return
        }
        let outputDirectory = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var monitoringSettings = ProviderSettings.default
        monitoringSettings[.cursor] = .hidden
        monitoringSettings[.deepseek] = .hidden
        for expanded in [false, true] {
            let height = UsageMenuView.fittedHeight(
                for: [.codex, .claude], maxHeight: expanded ? 1250 : 650,
                claudeWindowCount: UsageSnapshot.monitoringPreview.claudeQuota.value?.windows?.count ?? 0,
                expandedMonitoringHeight: expanded ? 800 : 0
            )
            let menu = UsageMenuView(
                store: UsageStore(snapshot: .monitoringPreview, providerSettings: monitoringSettings, observesSnapshotChanges: false),
                automaticRefresh: false, scrollsContent: false, updatedDescriptionOverride: "from demo data",
                viewHeight: height, referenceDate: UsageSnapshot.previewDate,
                historyExpanded: expanded, accountsExpanded: expanded, resetCardsExpanded: expanded
            ).background(Color(nsColor: .windowBackgroundColor))
            for scheme in [ColorScheme.dark, .light] {
                render(menu, size: CGSize(width: 410, height: height), colorScheme: scheme,
                       to: outputDirectory.appendingPathComponent("menu-monitoring-\(expanded ? "expanded" : "collapsed")-\(scheme == .dark ? "dark" : "light").png"))
            }
        }

        let servicesSnapshot = UsageSnapshot.monitoringPreview
        let servicesHeight = UsageMenuView.fittedHeight(
            for: MeterProvider.allCases, maxHeight: 1_160, servicesExpanded: true,
            claudeWindowCount: servicesSnapshot.claudeQuota.value?.windows?.count ?? 0
        )
        let servicesMenu = UsageMenuView(
            store: UsageStore(snapshot: servicesSnapshot, providerSettings: .default, observesSnapshotChanges: false),
            automaticRefresh: false,
            scrollsContent: false,
            updatedDescriptionOverride: "from demo data",
            viewHeight: servicesHeight,
            referenceDate: UsageSnapshot.previewDate,
            servicesExpanded: true
        )
        .background(Color(nsColor: .windowBackgroundColor))
        render(servicesMenu, size: CGSize(width: 410, height: servicesHeight), colorScheme: .dark,
               to: outputDirectory.appendingPathComponent("menu-popover-services.png"))

        for scenario in UsagePreviewScenario.allCases {
            let suffix = scenario == .normal ? "" : "-\(scenario.rawValue)"
            let snapshot = scenario.snapshot
            let height = UsageMenuView.fittedHeight(
                for: scenario.providerSettings.visibleProviders(in: snapshot),
                maxHeight: scenario == .longList ? 1_950 : scenario == .refreshError ? 1_360 : 1_220,
                claudeWindowCount: snapshot.claudeQuota.value?.windows?.count ?? 0
            )
            for scheme in [ColorScheme.dark, .light] {
                let menu = UsageMenuView(
                    store: UsageStore(snapshot: snapshot, providerSettings: scenario.providerSettings,
                                      observesSnapshotChanges: false),
                    automaticRefresh: false,
                    scrollsContent: false,
                    updatedDescriptionOverride: "from demo data",
                    viewHeight: height,
                    referenceDate: UsageSnapshot.previewDate,
                    refreshErrorOverride: scenario == .refreshError ? "Refresh failed; the previous data was preserved." : nil
                )
                .background(Color(nsColor: .windowBackgroundColor))
                let appearance = scheme == .dark ? "" : "-light"
                render(menu, size: CGSize(width: 410, height: height), colorScheme: scheme,
                       to: outputDirectory.appendingPathComponent("menu-popover\(suffix)\(appearance).png"))
            }
            for (family, size, name) in [
                (WidgetFamily.systemSmall, CGSize(width: 174, height: 174), "small"),
                (.systemMedium, CGSize(width: 352, height: 174), "medium"),
                (.systemLarge, CGSize(width: 352, height: 352), "large"),
                (.systemExtraLarge, CGSize(width: 710, height: 352), "extra-large")
            ] {
                let view = QuotaWidgetContent(snapshot: snapshot, family: family,
                                              providers: scenario.providerSettings.visibleProviders(in: snapshot),
                                              referenceDate: UsageSnapshot.previewDate)
                    .background(QuotaWidgetBackground())
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                render(view, size: size, colorScheme: .dark,
                       to: outputDirectory.appendingPathComponent("widget-\(name)\(suffix).png"))
            }
        }
    }

    /// Automatic polling is disabled; explicit login and refresh use this snapshot's directory.
    @MainActor
    private static func showInteractivePreview(snapshotURL: URL) {
        let snapshot = UsageSnapshot.load(from: snapshotURL)
        let settings = ProviderSettings.load(from: snapshotURL.deletingLastPathComponent()
            .appendingPathComponent("beaver-meter-settings.json"))
        let app = NSApplication.shared
        let delegate = InteractivePreviewDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        let view = UsageMenuView(
            store: UsageStore(snapshot: snapshot, providerSettings: settings, observesSnapshotChanges: false,
                              snapshotURL: snapshotURL, allowsWorkspaceLogin: true,
                              collectorScript: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                                .deletingLastPathComponent().appendingPathComponent("scripts/collect_beaver_meter.sh")),
            automaticRefresh: false, updatedDescriptionOverride: "from local test data", viewHeight: 700
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "BeaverMeter — Local Test"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime((window, delegate)) { app.run() }
    }

    @MainActor
    private static func render<Content: View>(
        _ content: Content, size: CGSize, colorScheme: ColorScheme, to destination: URL
    ) {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(
                content: content
                    .frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.isRenderingUsagePreview, true)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            )
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(size)
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                fatalError("Could not render \(destination.lastPathComponent)")
            }
            do {
                try png.write(to: destination, options: .atomic)
                print("Rendered \(destination.path)")
            } catch {
                fatalError("Could not write \(destination.path): \(error.localizedDescription)")
            }
        }
    }
}

private final class InteractivePreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
