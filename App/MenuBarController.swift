import AppKit
import Combine
import SwiftUI

/// Owns one status item, one popover and the shared stores for the app lifetime.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private let appearance: AppearanceStore
    private let updates: UpdateStore
    private let runtimeUpdates: RuntimeUpdateCoordinator
    private let runtimeReady: Bool
    private let isDemo: Bool
    private let navigation = UsageMenuNavigation()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var requests = MenuPresentationRequests()
    private var subscriptions: Set<AnyCancellable> = []
    private var escapeMonitor: Any?
    private var renderedImageKey: MenuBarUpdateIndicator.ImageKey?
    private var renderedAccessibilityText: String?
    private let busyObserver = MainRunLoopBusyObserver()

    init(runtimeReady: Bool = true) {
        self.runtimeReady = runtimeReady
        isDemo = CommandLine.arguments.contains("--interaction-demo")
            || DirectInstallSetup.flag("BeaverMeterInteractionDemo", in: .main)
        if isDemo {
            store = UsageStore(snapshot: .preview, providerSettings: .default,
                               observesSnapshotChanges: false, collectorScript: nil)
            appearance = AppearanceStore(settings: .default, observesChanges: false,
                                         referenceDate: UsageSnapshot.previewDate)
        } else {
            store = UsageStore(observesSnapshotChanges: runtimeReady)
            appearance = AppearanceStore()
        }
        let coordinator = RuntimeUpdateCoordinator(session: store) { message in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "BeaverMeter update"
                alert.informativeText = message
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
        runtimeUpdates = coordinator
        let enabled = runtimeReady && ReleaseUpdateConfiguration.isEnabled(
            info: Bundle.main.infoDictionary ?? [:], bundleIdentifier: Bundle.main.bundleIdentifier,
            bundleURL: Bundle.main.bundleURL, isDemo: isDemo)
        let backend = enabled ? SparkleUpdateBackend(
            prepareForInstallation: { coordinator.prepare(targetBuild: $0) },
            recoverAfterAbort: {
                if coordinator.needsRecovery { coordinator.recoverAfterAbort() }
            }) : nil
        updates = UpdateStore(observesChanges: enabled, backend: backend)
        super.init()
    }

    func prepare() {
        guard statusItem == nil else { return }
        busyObserver.start()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "BeaverMeter"
        item.button?.target = self
        item.button?.action = #selector(toggleMenu)
        item.button?.imagePosition = .imageOnly
        statusItem = item
        popover.behavior = .transient
        popover.delegate = self
        let height = min(700, (NSScreen.main?.visibleFrame.height ?? 724) - 24)
        let content = UsageMenuView(store: store, appearance: appearance,
                                    updates: updates,
                                    navigation: navigation,
                                    automaticRefresh: !isDemo && runtimeReady,
                                    updatedDescriptionOverride: isDemo ? "Demo data" : nil,
                                    viewHeight: height,
                                    referenceDate: isDemo ? UsageSnapshot.previewDate : nil)
            .environment(\.isRenderingUsagePreview, isDemo)
            .onExitCommand { [weak self] in self?.popover.performClose(nil) }
            .accessibilityElement(children: .contain)
            .accessibilityAction(.escape) { [weak self] in self?.popover.performClose(nil) }
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 410, height: height)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.popover.isShown else { return event }
            self.popover.performClose(nil)
            return nil
        }
        store.$snapshot.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateLabel() }.store(in: &subscriptions)
        store.$providerSettings.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateLabel() }.store(in: &subscriptions)
        appearance.$variant.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateLabel() }.store(in: &subscriptions)
        updates.$available.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateLabel() }.store(in: &subscriptions)
        updateLabel()
        updates.start()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let target = self.requests.pendingTarget ?? .menu
            if self.requests.becomeReady() { self.presentMenu(target: target) }
        }
    }

    func openMenu(target: AppNavigation.Target = .menu) {
        if requests.requestOpen(target: target) { presentMenu(target: target) }
    }

    func prepareForTermination() -> Bool {
        guard let build = updates.pendingInstallationBuild else { return true }
        return runtimeUpdates.prepare(targetBuild: build)
    }

    @objc private func toggleMenu() {
        if popover.isShown { popover.performClose(nil) } else { openMenu() }
    }

    private func presentMenu(target: AppNavigation.Target = .menu, attempt: Int = 0) {
        guard let item = statusItem, let button = item.button else { return }
        guard button.window != nil else {
            retryPresentation(target: target, after: attempt)
            return
        }
        if !anchorIsVisible(button) { item.isVisible = true }
        guard anchorIsVisible(button) else {
            retryPresentation(target: target, after: attempt)
            return
        }
        updateLabel()
        busyObserver.start()
        NSApplication.shared.activate(ignoringOtherApps: true)
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        if let view = popover.contentViewController?.view, let window = view.window {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        }
        navigation.open(target)
    }

    private func retryPresentation(target: AppNavigation.Target, after attempt: Int) {
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.presentMenu(target: target, attempt: attempt + 1)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        RuntimePerformance.event("menu_did_close")
        navigation.endPresentation()
    }

    func popoverWillShow(_ notification: Notification) {
        RuntimePerformance.event("menu_will_show")
    }

    func popoverDidShow(_ notification: Notification) {
        RuntimePerformance.event("menu_did_show")
    }

    private func anchorIsVisible(_ button: NSStatusBarButton) -> Bool {
        guard let window = button.window, window.isVisible, let screen = window.screen else { return false }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard screen.frame.intersects(frame) else { return false }
        if screen.safeAreaInsets.top > 0 {
            return [screen.auxiliaryTopLeftArea, screen.auxiliaryTopRightArea]
                .compactMap { $0 }.contains { $0.contains(frame) }
        }
        return true
    }

    private func updateLabel() {
        guard let item = statusItem, let button = item.button else { return }
        let indicator = MenuBarUpdateIndicator(variant: appearance.variant, available: updates.available)
        if renderedImageKey != indicator.imageKey {
            button.image = MenuBarUpdateAssets.image(for: indicator)
            renderedImageKey = indicator.imageKey
        }
        let text = store.menuBarAccessibilityText
        let accessibilityText = indicator.accessibilityText(usageDescription: text)
        guard renderedAccessibilityText != accessibilityText else { return }
        renderedAccessibilityText = accessibilityText
        button.toolTip = indicator.tooltip(usageDescription: text)
        button.setAccessibilityLabel(accessibilityText)
    }

    func stop() {
        busyObserver.stop()
        updates.stop()
        popover.close()
        subscriptions.removeAll()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        renderedImageKey = nil
        renderedAccessibilityText = nil
    }
}
