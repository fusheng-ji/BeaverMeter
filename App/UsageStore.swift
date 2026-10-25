import AppKit
import Combine
import Foundation
import WidgetKit

enum DeepSeekConnectionState: Equatable {
    case idle
    case waitingForLogin
    case checkingBrowser
    case loadingUsage
    case connected
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .waitingForLogin, .checkingBrowser, .loadingUsage: true
        default: false
        }
    }

    var message: String? {
        switch self {
        case .idle: nil
        case .waitingForLogin: "Finish signing in in your browser. Waiting for the DeepSeek session…"
        case .checkingBrowser: "Checking the system browser session…"
        case .loadingUsage: "Connected. Loading current DeepSeek usage…"
        case .connected: "Connected · DeepSeek usage is up to date."
        case let .failed(message): message
        }
    }
}

enum ClaudeAuthenticationState: Equatable {
    case idle
    case signingIn
    case authorizingAccess
    case repairingKeychainSession
    case verifying
    case cancelling
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .signingIn, .authorizingAccess, .repairingKeychainSession, .verifying, .cancelling: true
        default: false
        }
    }

    var message: String? {
        switch self {
        case .idle: nil
        case .signingIn: ClaudeAuthenticationMode.signIn.progressMessage
        case .authorizingAccess: ClaudeAuthenticationMode.authorizeAccess.progressMessage
        case .repairingKeychainSession: ClaudeAuthenticationMode.repairKeychainSession.progressMessage
        case .verifying: ClaudeAuthenticationMode.verify.progressMessage
        case .cancelling: "Stopping Claude authentication…"
        case let .failed(message): message
        }
    }
}

@MainActor
final class UsageStore: ObservableObject, UpdateRuntimeSession {
    @Published private(set) var snapshot: UsageSnapshot
    @Published private(set) var providerSettings: ProviderSettings
    @Published private var refreshSchedule = RefreshSchedule()
    @Published private(set) var refreshError: String?
    @Published private(set) var deepSeekConnectionState: DeepSeekConnectionState = .idle
    @Published private(set) var claudeAuthenticationState: ClaudeAuthenticationState = .idle
    @Published private(set) var codexLoginMessage: String?
    @Published private(set) var isSigningInCodex = false
    @Published private(set) var canRetryCodexLogin = false
    private var pendingCodexLogin: (id: UUID, label: String)?

    private var lastAutomaticRefresh: Date?
    private var deepSeekConnectionTask: Task<Void, Never>?
    private var snapshotObservationTask: Task<Void, Never>?
    private var codexActivityRefreshTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var codexLoginTask: Task<Void, Never>?
    private var claudeAuthenticationTask: Task<Void, Never>?
    private var claudeAuthenticationID: UUID?
    private var awaitsCodexLoginRefresh = false
    private var runtimeSuspended = false
    private let allowsLiveUpdates: Bool
    private let allowsWorkspaceLogin: Bool
    private let snapshotURL: URL
    private let collectorScript: URL?
    private let snapshotReader: SnapshotFileReader
    private var snapshotAdoption = SnapshotAdoptionGate()

    var isRefreshing: Bool { refreshSchedule.showsFullRefresh }

    var updateInstallationBlockReason: String? {
        if isSigningInCodex { return "Finish signing in to your Codex workspace before installing the update." }
        if claudeAuthenticationState.isBusy { return "Finish Claude login verification before installing the update." }
        switch deepSeekConnectionState {
        case .waitingForLogin, .checkingBrowser:
            return "Finish connecting DeepSeek before installing the update."
        default: return nil
        }
    }

    func suspendForUpdate() {
        runtimeSuspended = true
        refreshTask?.cancel()
        refreshTask = nil
        deepSeekConnectionTask?.cancel()
        deepSeekConnectionTask = nil
        cancelClaudeAuthentication()
        refreshSchedule = RefreshSchedule()
    }

    func resumeAfterUpdate() {
        guard runtimeSuspended else { return }
        runtimeSuspended = false
        refreshIfNeeded(force: true)
    }

    init(
        snapshot: UsageSnapshot = .load(),
        providerSettings: ProviderSettings = .load(),
        observesSnapshotChanges: Bool = true,
        snapshotURL: URL = UsageSnapshot.snapshotURL,
        allowsWorkspaceLogin: Bool = false,
        collectorScript: URL? = Bundle.main.url(forResource: "collect_beaver_meter", withExtension: "sh")
    ) {
        self.snapshot = snapshot
        self.providerSettings = providerSettings
        allowsLiveUpdates = observesSnapshotChanges
        self.snapshotURL = snapshotURL
        snapshotReader = SnapshotFileReader(url: snapshotURL)
        self.collectorScript = collectorScript
        self.allowsWorkspaceLogin = observesSnapshotChanges || allowsWorkspaceLogin
        if observesSnapshotChanges {
            snapshotObservationTask = Task(priority: .utility) { @MainActor [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(15))
                    } catch {
                        return
                    }
                    await self?.adoptNewerSnapshotFromDisk()
                }
            }
            codexActivityRefreshTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(45))
                    } catch {
                        return
                    }
                    self?.requestRefresh(.codex)
                }
            }
        }
    }

    deinit {
        snapshotObservationTask?.cancel()
        codexActivityRefreshTask?.cancel()
        refreshTask?.cancel()
        deepSeekConnectionTask?.cancel()
        codexLoginTask?.cancel()
        claudeAuthenticationTask?.cancel()
    }

    private func adoptNewerSnapshotFromDisk() async {
        guard !runtimeSuspended else { return }
        let reader = snapshotReader
        guard let update = await Task.detached(priority: .utility, operation: {
            await reader.read()
        }).value else { return }
        guard !runtimeSuspended else { return }
        guard snapshotAdoption.accepts(update, over: snapshot) else { return }
        let latest = update.snapshot

        if case .failed = claudeAuthenticationState,
           latest.claudeQuota.status == .ready, !latest.claudeQuota.isStale,
           latest.claudeQuota.value != nil,
           (latest.claudeQuota.measuredAt ?? .distantPast) >= snapshot.claudeQuota.lastAttemptAt {
            claudeAuthenticationState = .idle
        }
        snapshot = latest
        RuntimePerformance.event("snapshot_adopted")
        WidgetCenter.shared.reloadTimelines(ofKind: "BeaverMeterWidget")
        RuntimePerformance.event("widget_reload_requested")
    }

    var visibleProviders: [MeterProvider] {
        providerSettings.visibleProviders(in: snapshot)
    }

    func addCodexWorkspace() {
        guard allowsWorkspaceLogin, !runtimeSuspended, !isSigningInCodex else { return }
        let alert = NSAlert()
        alert.messageText = "Add Codex workspace"
        alert.informativeText = "Name this workspace, then complete sign-in in your browser. Its login is stored separately in BeaverMeter."
        let field = NSTextField(string: "")
        field.placeholderString = "Workspace name (for example, Personal or Research)"
        field.frame = NSRect(x: 0, y: 0, width: 350, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Sign in")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        signInCodexWorkspace(id: UUID(), label: name.isEmpty ? "Workspace" : name)
    }

    func signInCodexWorkspace(id: UUID, label: String) {
        guard allowsWorkspaceLogin, !runtimeSuspended, !isSigningInCodex else { return }
        isSigningInCodex = true
        awaitsCodexLoginRefresh = false
        canRetryCodexLogin = false
        pendingCodexLogin = (id, label)
        codexLoginMessage = "Complete Codex sign-in in your browser and select the workspace to monitor…"
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/BeaverMeterCollector")
        let output = snapshotURL.path
        codexLoginTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                CollectorProcessRunner.loginCodexWorkspace(helper: helper, id: id, label: label, output: output)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.isSigningInCodex = false
            self.canRetryCodexLogin = result.status != 0
            self.codexLoginMessage = result.status == 0 ? "Workspace connected. Refreshing usage…" : result.message
            self.codexLoginTask = nil
            if result.status == 0 {
                self.pendingCodexLogin = nil
                self.awaitsCodexLoginRefresh = true
                self.refresh()
            }
        }
    }

    func retryCodexWorkspaceSignIn() {
        guard let pendingCodexLogin else { return }
        signInCodexWorkspace(id: pendingCodexLogin.id, label: pendingCodexLogin.label)
    }

    var canAuthenticateClaude: Bool {
        allowsLiveUpdates && !runtimeSuspended
    }

    func signInClaude() {
        authenticateClaude(.signIn)
    }

    func authorizeClaudeAccess() {
        authenticateClaude(.authorizeAccess)
    }

    func repairClaudeKeychainSession() {
        guard canAuthenticateClaude, !claudeAuthenticationState.isBusy else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Repair Keychain session?"
        alert.informativeText = "This locks and then asks macOS to unlock your current login Keychain once. Other apps may temporarily lose Keychain access. macOS will ask for your Mac login password. If you cancel unlocking, the Keychain stays locked until you unlock it. This does not delete credentials or start a new Claude login."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Repair")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        authenticateClaude(.repairKeychainSession)
    }

    func verifyClaudeLogin() {
        authenticateClaude(.verify)
    }

    func cancelClaudeAuthentication() {
        guard claudeAuthenticationTask != nil else { return }
        claudeAuthenticationState = .cancelling
        claudeAuthenticationTask?.cancel()
        Task { [weak self] in await self?.adoptNewerSnapshotFromDisk() }
    }

    private func authenticateClaude(_ mode: ClaudeAuthenticationMode) {
        guard canAuthenticateClaude, !claudeAuthenticationState.isBusy else { return }
        let operationID = UUID()
        claudeAuthenticationID = operationID
        switch mode {
        case .signIn: claudeAuthenticationState = .signingIn
        case .authorizeAccess: claudeAuthenticationState = .authorizingAccess
        case .repairKeychainSession: claudeAuthenticationState = .repairingKeychainSession
        case .verify: claudeAuthenticationState = .verifying
        }
        let startedAt = Date()
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/BeaverMeterCollector")
        let script = collectorScript
        let output = snapshotURL.path
        claudeAuthenticationTask = Task { [weak self] in
            let cancellation = SubprocessCancellation()
            let result = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    CollectorProcessRunner.authenticateClaude(
                        helper: helper, script: script, output: output,
                        mode: mode, cancellation: cancellation
                    )
                }.value
            } onCancel: {
                cancellation.cancel()
            }
            // A cancelled helper may have written a final authentication failure.
            // Adopt its snapshot before releasing the authentication controls.
            await self?.adoptNewerSnapshotFromDisk()
            guard let self, self.claudeAuthenticationID == operationID else { return }
            self.claudeAuthenticationID = nil
            self.claudeAuthenticationTask = nil
            guard !Task.isCancelled else {
                self.claudeAuthenticationState = .idle
                return
            }
            let quota = self.snapshot.claudeQuota
            // Snapshot dates may be serialized to whole seconds. A successful
            // CLI exit alone never makes cached quota a verified login.
            let freshnessThreshold = startedAt.addingTimeInterval(-1)
            let verified = result.status == 0 && quota.status == .ready && !quota.isStale
                && quota.value != nil && (quota.measuredAt ?? .distantPast) >= freshnessThreshold
                && quota.lastAttemptAt >= freshnessThreshold
                && self.snapshot.generatedAt >= freshnessThreshold
            if verified {
                self.claudeAuthenticationState = .idle
            } else {
                let fallback = quota.message ?? "Claude quota could not be verified. Try verifying the saved login again."
                self.claudeAuthenticationState = .failed(result.message.isEmpty ? fallback : result.message)
            }
        }
    }

    func openAccountConfiguration() {
        let url = snapshotURL.deletingLastPathComponent().appendingPathComponent("beaver-meter-accounts.json")
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                let template = """
                {"version":1,"providers":[{"id":"codex","codexProfileHomePaths":[]}]}
                """
                try AtomicFileWriter.write(Data(template.utf8), to: url)
            }
            if !NSWorkspace.shared.open(url) { refreshError = "Open beaver-meter-accounts.json in a text editor to configure profile homes." }
        } catch {
            refreshError = "Could not open account configuration: \(error.localizedDescription)"
        }
    }

    func setVisibility(_ visibility: ProviderVisibility, for provider: MeterProvider) {
        let wasCollected = providerSettings.collects(provider)
        providerSettings[provider] = visibility
        guard allowsLiveUpdates else { return }
        do {
            try providerSettings.save()
        } catch {
            refreshError = "Could not save service settings: \(error.localizedDescription)"
        }
        WidgetCenter.shared.reloadAllTimelines()
        // A service switched back on has no fresh value until it is collected.
        if !wasCollected, providerSettings.collects(provider) { refresh() }
    }

    var menuBarText: String {
        let text = visibleProviders.map(menuBarSegment).joined(separator: " · ")
        return text.isEmpty ? "BeaverMeter" : text
    }

    var menuBarAccessibilityText: String {
        visibleProviders.map { provider in
            switch provider {
            case .codex: CodexDailyTokenPresentation(snapshot.codexTokens).accessibilityText
            case .claude: ClaudeDailyTokenPresentation(snapshot.claudeTokens).accessibilityText
            case .cursor: "Cursor latest call \(cursorLatestCost)"
            case .deepseek: "DeepSeek balance \(deepSeekBalance)"
            }
        }.joined(separator: ", ")
    }

    private func menuBarSegment(_ provider: MeterProvider) -> String {
        switch provider {
        case .codex: CodexDailyTokenPresentation(snapshot.codexTokens).value
        case .claude: "✳︎ " + ClaudeDailyTokenPresentation(snapshot.claudeTokens).value
        case .cursor: "C " + cursorLatestCost
        case .deepseek: "D " + deepSeekBalance
        }
    }

    private var cursorLatestCost: String {
        UsageFormatting.usd(snapshot.cursorCosts.value?.latestEvent?.costUSD, minimumDigits: 2, maximumDigits: 3)
    }

    private var deepSeekBalance: String {
        UsageFormatting.money(UsageFormatting.firstValidMoney(snapshot.deepseekUsage.value?.balances ?? []))
    }

    var isConnectingDeepSeek: Bool {
        deepSeekConnectionState.isBusy
    }

    var deepSeekConnectionMessage: String? {
        deepSeekConnectionState.message
    }

    func refreshIfNeeded(force: Bool = false) {
        if !force, let lastAutomaticRefresh, Date().timeIntervalSince(lastAutomaticRefresh) < 30 {
            return
        }
        refresh()
    }

    func refresh() {
        requestRefresh(.all)
    }

    private func requestRefresh(_ mode: RefreshSchedule.Mode) {
        guard !runtimeSuspended, allowsLiveUpdates || allowsWorkspaceLogin,
              let next = refreshSchedule.request(mode) else { return }
        startRefresh(next)
    }

    private func startRefresh(_ mode: RefreshSchedule.Mode) {
        RuntimePerformance.event(mode == .all ? "refresh_all_start" : "refresh_codex_start")
        if mode == .all {
            refreshError = nil
            lastAutomaticRefresh = .now
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/BeaverMeterCollector")
        let script = collectorScript
        let output = snapshotURL.path
        refreshTask = Task { [weak self] in
            let cancellation = SubprocessCancellation()
            let result = await withTaskCancellationHandler {
                await Task.detached(priority: .utility) {
                    switch mode {
                    case .all:
                        CollectorProcessRunner.refresh(helper: helper, script: script, output: output, cancellation: cancellation)
                    case .codex:
                        CollectorProcessRunner.refreshCodexTokens(helper: helper, script: script, output: output, cancellation: cancellation)
                    }
                }.value
            } onCancel: {
                cancellation.cancel()
            }
            guard !Task.isCancelled else { return }
            await self?.finishRefresh(mode, result: result)
        }
    }

    private func finishRefresh(_ mode: RefreshSchedule.Mode, result: CollectorProcessResult) async {
        // Only a newer snapshot changes the UI or requests a WidgetKit timeline.
        await adoptNewerSnapshotFromDisk()
        guard !Task.isCancelled, !runtimeSuspended else { return }
        RuntimePerformance.event(mode == .all ? "refresh_all_complete" : "refresh_codex_complete")
        if result.status != 0 {
            refreshError = result.message.isEmpty
                ? "Refresh failed; the previous data was preserved."
                : result.message
        } else if mode == .all {
            refreshError = nil
        }
        if mode == .all, awaitsCodexLoginRefresh {
            awaitsCodexLoginRefresh = false
            codexLoginMessage = result.status == 0 ? nil : "Workspace connected, but usage could not be refreshed."
        }
        if mode == .all, deepSeekConnectionState == .loadingUsage {
            if result.status == 0, snapshot.deepseekUsage.status == .ready {
                deepSeekConnectionState = .connected
            } else {
                deepSeekConnectionState = .failed(
                    refreshError ?? snapshot.deepseekUsage.message ?? "Could not load DeepSeek usage."
                )
            }
        }
        refreshTask = nil
        if let next = refreshSchedule.finish() { startRefresh(next) }
    }

    func connectDeepSeekInBrowser() {
        guard allowsLiveUpdates, !runtimeSuspended else { return }
        guard let url = URL(string: "https://platform.deepseek.com/usage") else { return }
        guard NSWorkspace.shared.open(url) else {
            deepSeekConnectionState = .failed("Could not open the system browser.")
            return
        }
        deepSeekConnectionState = .waitingForLogin
        beginDeepSeekBrowserImport()
    }

    func checkDeepSeekBrowserSession() {
        guard allowsLiveUpdates, !runtimeSuspended else { return }
        deepSeekConnectionState = .checkingBrowser
        beginDeepSeekBrowserImport()
    }

    private func beginDeepSeekBrowserImport() {
        deepSeekConnectionTask?.cancel()
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/BeaverMeterCollector")

        deepSeekConnectionTask = Task { [weak self] in
            let cancellation = SubprocessCancellation()
            await withTaskCancellationHandler {
                for _ in 0..<100 {
                    guard !Task.isCancelled, self != nil else { return }
                    let result = await Task.detached(priority: .utility) {
                        CollectorProcessRunner.importBrowserSession(helper: helper, cancellation: cancellation)
                    }.value
                    guard !Task.isCancelled else { return }
                    if self?.handleDeepSeekImport(result) != false { return }

                    switch DeepSeekSafariSessionReader.readToken() {
                    case let .token(token):
                        let safariResult = await Task.detached(priority: .utility) {
                            CollectorProcessRunner.importToken(helper: helper, token: token, cancellation: cancellation)
                        }.value
                        guard !Task.isCancelled else { return }
                        if self?.handleDeepSeekImport(safariResult) != false { return }
                    case .notFound:
                        break
                    case let .unavailable(message):
                        self?.deepSeekConnectionState = .failed(message)
                        return
                    }

                    do {
                        try await Task.sleep(for: .seconds(3))
                    } catch {
                        return
                    }
                }
                self?.deepSeekConnectionState = .failed(
                    "No signed-in DeepSeek session was found in the system browser."
                )
            } onCancel: {
                cancellation.cancel()
            }
        }
    }

    /// Exit codes distinguish a successful import, a pending login and a terminal failure.
    private func handleDeepSeekImport(_ result: CollectorProcessResult) -> Bool {
        if result.status == 3 { return false }
        if result.status == 0 {
            deepSeekConnectionState = .loadingUsage
            refresh()
        } else {
            deepSeekConnectionState = .failed(
                result.message.isEmpty ? "Could not import the DeepSeek browser session." : result.message
            )
        }
        return true
    }
}
