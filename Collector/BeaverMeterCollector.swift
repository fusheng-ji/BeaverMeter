import Darwin
import Foundation
import Security

@main
struct BeaverMeterCollector {
    static func main() async {
        if CommandLine.arguments.contains("--import-deepseek-browser-session") {
            await importDeepSeekBrowserSession()
            return
        }
        if CommandLine.arguments.contains("--import-deepseek-token-stdin") {
            await importDeepSeekTokenFromStandardInput()
            return
        }

        let outputURL = resolvedOutputURL()
        let claudeModes = Set(ClaudeAuthenticationMode.allCases.filter { CommandLine.arguments.contains($0.argument) })
        if !claudeModes.isEmpty {
            let interactive = claudeModes.contains(where: \.allowsKeychainInteraction)
            if !interactive { disableKeychainInteraction() }
            let cancellation = SubprocessCancellation()
            let termination = ClaudeAuthenticationSignalHandler(cancellation: cancellation)
            defer { termination.stop() }
            do {
                if claudeModes.contains(.repairKeychainSession) {
                    // This mode is reached only after the app's explicit
                    // lock/unlock confirmation, never from scheduled refresh.
                    try ClaudeKeychainSessionRepair.repairIfNeeded(cancellation: cancellation)
                }
                var loginFailure: Error?
                if claudeModes.contains(.signIn) {
                    do {
                        try ClaudeLoginCollector.login(environment: ProcessInfo.processInfo.environment,
                                                       cancellation: cancellation)
                    } catch { loginFailure = error }
                }
                // Even a failed CLI login may have cleared or replaced credentials.
                // Write that outcome before returning an error to the menu.
                do {
                    try await verifyClaude(outputURL: outputURL, cancellation: cancellation,
                                           authorizeKeychain: interactive)
                }
                catch {
                    if cancellation.isCancelled { throw ClaudeLoginError.cancelled }
                    throw loginFailure ?? error
                }
                print("Claude login verified.")
            } catch { fail(error.localizedDescription, status: 1) }
            return
        }
        if CommandLine.arguments.contains("--codex-workspace-login") {
            do {
                let arguments = CommandLine.arguments
                guard let index = arguments.firstIndex(of: "--profile-id"), arguments.indices.contains(index + 1),
                      let id = UUID(uuidString: arguments[index + 1]) else {
                    fail("Invalid workspace profile ID.", status: 2)
                }
                let labelIndex = arguments.firstIndex(of: "--workspace-label")
                let label = labelIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "Workspace"
                try CodexWorkspaceLoginCollector.run(id: id, label: label, directory: outputURL.deletingLastPathComponent())
                print("Workspace connected.")
            } catch { fail(error.localizedDescription, status: 1) }
            return
        }
        // Keep the legacy policy disabled for the whole background process.
        // Concurrent provider reads must not restore it to interactive mode.
        disableKeychainInteraction()
        do {
            // `--codex-only` predates Claude support; installed apps still pass it.
            let localTokensOnly = CommandLine.arguments.contains("--codex-only")
                || CommandLine.arguments.contains("--local-tokens")
            let lock: SnapshotWriter.Lock
            if localTokensOnly {
                guard let acquired = try SnapshotWriter.tryLock(for: outputURL) else {
                    print("Local token refresh skipped: another refresh is already running.")
                    return
                }
                lock = acquired
            } else {
                lock = try SnapshotWriter.lock(for: outputURL)
            }
            defer { lock.unlock() }
            if localTokensOnly {
                try await refreshLocalTokens(outputURL: outputURL)
            } else {
                try await refreshAll(outputURL: outputURL)
            }
        } catch {
            fail("Failed to refresh usage: \(error.localizedDescription)", status: 1)
        }
    }

    private static func disableKeychainInteraction() {
        let status = SecKeychainSetUserInteractionAllowed(false)
        guard status == errSecSuccess else { fail("Could not disable background Keychain interaction (\(status)).", status: 1) }
    }

    /// Only Claude's online quota is replaced; local logs and other accounts
    /// are preserved. A successful CLI exit alone is not a verified login.
    private static func verifyClaude(outputURL: URL, cancellation: SubprocessCancellation,
                                     authorizeKeychain: Bool) async throws {
        let lock = try SnapshotWriter.lock(for: outputURL)
        defer { lock.unlock() }
        let previous = SnapshotWriter.loadPrevious(from: outputURL)
        let now = Date()
        let access = ClaudeCredentialAccessSession(authorize: authorizeKeychain, cancellation: cancellation)
        let reading = await ClaudeUsageCollector.collect(previousQuota: previous.claudeQuota,
            previousCards: previous.claudeResetCards, now: now,
            stateDirectory: outputURL.deletingLastPathComponent(), forceRefresh: true, cancellation: cancellation,
            credentialReader: { try access.read(environment: $0) })
        let snapshot = UsageSnapshot(schemaVersion: UsageSnapshot.currentSchemaVersion, generatedAt: now,
            codexTokens: previous.codexTokens, cursorCosts: previous.cursorCosts, cursorQuota: previous.cursorQuota,
            codexQuota: previous.codexQuota, claudeTokens: previous.claudeTokens, claudeQuota: reading.quota,
            deepseekUsage: previous.deepseekUsage, codexAccounts: previous.codexAccounts,
            codexHistory: previous.codexHistory, claudeHistory: previous.claudeHistory,
            claudeResetCards: reading.resetCards)
        try SnapshotWriter.write(snapshot, to: outputURL)
        guard reading.quota.status == .ready, reading.quota.source != .cache,
              reading.quota.value != nil, reading.quota.measuredAt == now else {
            throw NSError(domain: "BeaverMeter.ClaudeVerification", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: reading.quota.message
                            ?? "Claude login could not be verified. Try again."])
        }
    }

    private static func refreshAll(outputURL: URL) async throws {
        let previous = SnapshotWriter.loadPrevious(from: outputURL)
        let now = Date()
        let scanCacheURL = codexScanCacheURL(for: outputURL)
        let settings = providerSettings(for: outputURL)
        let environment = ProcessInfo.processInfo.environment
        let directory = outputURL.deletingLastPathComponent()
        let configuration = settings.collects(.codex)
            ? CodexAccountConfiguration.load(directory: directory, environment: environment)
            : CodexAccountConfiguration(homes: [], message: nil)
        let historyReading = settings.collects(.codex)
            ? await TokenHistoryCollector.codex(previous: previous.codexHistory, configuration: configuration,
                                                now: now, directory: directory, environment: environment)
            : TokenHistoryCollector.CodexReading(history: previous.codexHistory, remoteToday: nil)
        async let claudeHistory = settings.collects(.claude)
            ? await TokenHistoryCollector.claude(previous: previous.claudeHistory, now: now,
                                                 directory: directory.appendingPathComponent("claude-history-cost"),
                                                 environment: environment)
            : previous.claudeHistory

        // Services switched off keep their previous values and are never contacted.
        async let codexTokens = settings.collects(.codex)
            ? await CodexTokenCollector.collect(previous: previous.codexTokens, now: now, scanCacheURL: scanCacheURL, remoteReading: historyReading.remoteToday)
            : previous.codexTokens
        async let codexAccounts = settings.collects(.codex)
            ? await CodexAccountsCollector.collect(configuration: configuration, previous: previous.codexAccounts,
                                                    now: now, environment: environment)
            : previous.codexAccounts
        async let claudeUsage = settings.collects(.claude)
            ? await ClaudeUsageCollector.collect(previousQuota: previous.claudeQuota,
                                                  previousCards: previous.claudeResetCards, now: now,
                                                  stateDirectory: directory, environment: environment)
            : ClaudeUsageCollector.Reading(quota: previous.claudeQuota, resetCards: previous.claudeResetCards)
        async let claudeTokens = settings.collects(.claude)
            ? await ClaudeTokenCollector.collect(
                previous: previous.claudeTokens, now: now, cacheRoot: claudeCostCacheRoot(for: outputURL)
            )
            : previous.claudeTokens
        async let cursor = settings.collects(.cursor)
            ? await CursorUsageCollector.collect(
                previousCosts: previous.cursorCosts, previousQuota: previous.cursorQuota, now: now
            )
            : (costs: previous.cursorCosts, quota: previous.cursorQuota)
        async let deepseekUsage = settings.collects(.deepseek)
            ? await DeepSeekUsageCollector.collect(previous: previous.deepseekUsage, now: now)
            : previous.deepseekUsage

        let collectedCodexAccounts = await codexAccounts
        let resolvedCodexAccounts = settings.collects(.codex)
            ? await CodexWorkspaceActivityCollector.collect(
                accounts: collectedCodexAccounts, previous: previous.codexAccounts, configuration: configuration,
                aggregateHistory: historyReading.history, remoteHistory: historyReading.remoteHistory,
                scanSummary: historyReading.workspaceSummary,
                now: now, directory: directory, environment: environment)
            : previous.codexAccounts
        let resolvedCodexQuota = settings.collects(.codex)
            ? await CodexAccountsCollector.defaultQuota(accounts: resolvedCodexAccounts, previous: previous.codexQuota,
                                                       now: now, environment: environment)
            : previous.codexQuota
        let (resolvedCodexTokens, resolvedCursor, resolvedDeepSeek) = await (
            codexTokens,
            cursor,
            deepseekUsage
        )
        let (resolvedClaudeTokens, resolvedClaudeUsage) = await (claudeTokens, claudeUsage)
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now,
            codexTokens: resolvedCodexTokens,
            cursorCosts: resolvedCursor.costs,
            cursorQuota: resolvedCursor.quota,
            codexQuota: resolvedCodexQuota,
            claudeTokens: resolvedClaudeTokens,
            claudeQuota: resolvedClaudeUsage.quota,
            deepseekUsage: resolvedDeepSeek,
            codexAccounts: resolvedCodexAccounts, codexHistory: historyReading.history,
            claudeHistory: await claudeHistory, claudeResetCards: resolvedClaudeUsage.resetCards
        )

        try SnapshotWriter.write(snapshot, to: outputURL)
        print(outputURL.path)
    }

    /// The App's frequent refresh: only the local token scans, never account APIs.
    private static func refreshLocalTokens(outputURL: URL) async throws {
        let previous = SnapshotWriter.loadPrevious(from: outputURL)
        let now = Date()
        let settings = providerSettings(for: outputURL)
        let environment = ProcessInfo.processInfo.environment
        let directory = outputURL.deletingLastPathComponent()
        let configuration = settings.collects(.codex)
            ? CodexAccountConfiguration.load(directory: directory, environment: environment)
            : CodexAccountConfiguration(homes: [], message: nil)
        let historyReading = settings.collects(.codex)
            ? await TokenHistoryCollector.codex(previous: previous.codexHistory, configuration: configuration,
                                                now: now, directory: directory, environment: environment)
            : TokenHistoryCollector.CodexReading(history: previous.codexHistory, remoteToday: nil)
        async let claudeHistory = settings.collects(.claude)
            ? await TokenHistoryCollector.claude(previous: previous.claudeHistory, now: now,
                                                 directory: directory.appendingPathComponent("claude-history-cost"),
                                                 environment: environment)
            : previous.claudeHistory
        async let codexTokens = settings.collects(.codex)
            ? await CodexTokenCollector.collect(
                previous: previous.codexTokens, now: now, scanCacheURL: codexScanCacheURL(for: outputURL), remoteReading: historyReading.remoteToday
            )
            : previous.codexTokens
        async let claudeTokens = settings.collects(.claude)
            ? await ClaudeTokenCollector.collect(
                previous: previous.claudeTokens, now: now, cacheRoot: claudeCostCacheRoot(for: outputURL)
            )
            : previous.claudeTokens
        async let codexAccounts = settings.collects(.codex)
            ? await CodexWorkspaceActivityCollector.collect(
                accounts: previous.codexAccounts, previous: previous.codexAccounts, configuration: configuration,
                aggregateHistory: historyReading.history, remoteHistory: historyReading.remoteHistory,
                scanSummary: historyReading.workspaceSummary,
                now: now, directory: directory, environment: environment)
            : previous.codexAccounts
        let (resolvedCodexTokens, resolvedClaudeTokens) = await (codexTokens, claudeTokens)
        let resolvedCodexAccounts = await codexAccounts
        let resolvedClaudeHistory = await claudeHistory
        guard isChanged(previous.codexTokens, resolvedCodexTokens, now: now)
                || isChanged(previous.claudeTokens, resolvedClaudeTokens, now: now)
                || isChanged(previous.codexHistory, historyReading.history, now: now)
                || isChanged(previous.claudeHistory, resolvedClaudeHistory, now: now)
                || workspaceActivityChanged(previous.codexAccounts, resolvedCodexAccounts, now: now)
        else {
            print(outputURL.path)
            return
        }

        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now,
            codexTokens: resolvedCodexTokens,
            cursorCosts: previous.cursorCosts,
            cursorQuota: previous.cursorQuota,
            codexQuota: previous.codexQuota,
            claudeTokens: resolvedClaudeTokens,
            claudeQuota: previous.claudeQuota,
            deepseekUsage: previous.deepseekUsage,
            codexAccounts: resolvedCodexAccounts, codexHistory: historyReading.history,
            claudeHistory: resolvedClaudeHistory, claudeResetCards: previous.claudeResetCards
        )
        try SnapshotWriter.write(snapshot, to: outputURL)
        print(outputURL.path)
    }

    /// A same-day identical reading is not rewritten, so widgets are not reloaded needlessly.
    private static func isChanged<Value>(_ previous: UsageValue<Value>, _ current: UsageValue<Value>, now: Date) -> Bool {
        let sameDay = previous.measuredAt.map { Calendar.current.isDate($0, inSameDayAs: now) }
            ?? (current.measuredAt == nil)
        return !sameDay
            || previous.status != current.status
            || previous.message != current.message
            || previous.value != current.value
    }

    /// Ignore polling timestamps when a workspace's actual readings are unchanged.
    private static func workspaceActivityChanged(
        _ previous: UsageValue<[CodexAccountUsage]>, _ current: UsageValue<[CodexAccountUsage]>, now: Date
    ) -> Bool {
        let old = previous.value ?? [], new = current.value ?? []
        guard old.map(\.id) == new.map(\.id) else { return true }
        return zip(old, new).contains { lhs, rhs in
            if (lhs.tokens == nil) != (rhs.tokens == nil) || (lhs.history == nil) != (rhs.history == nil) { return true }
            if (lhs.tokenActivity == nil) != (rhs.tokenActivity == nil) { return true }
            if let a = lhs.tokens, let b = rhs.tokens, a.source != b.source || isChanged(a, b, now: now) { return true }
            if let a = lhs.history, let b = rhs.history, a.source != b.source || isChanged(a, b, now: now) { return true }
            if let a = lhs.tokenActivity, let b = rhs.tokenActivity, a.source != b.source || isChanged(a, b, now: now) { return true }
            return false
        }
    }

    /// Settings live beside the snapshot, so test outputs use their own switches.
    private static func providerSettings(for outputURL: URL) -> ProviderSettings {
        ProviderSettings.load(
            from: outputURL.deletingLastPathComponent().appendingPathComponent(ProviderSettings.settingsURL.lastPathComponent)
        )
    }

    private static func codexScanCacheURL(for outputURL: URL) -> URL {
        CodexCacheLocations(snapshotURL: outputURL).local
    }

    /// BeaverMeter keeps its own CodexBarCore index instead of sharing CodexBar.app's cache.
    private static func claudeCostCacheRoot(for outputURL: URL) -> URL {
        ProcessInfo.processInfo.environment["CLAUDE_TOKEN_CACHE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? outputURL.deletingLastPathComponent().appendingPathComponent("claude-cost-usage", isDirectory: true)
    }

    private static func importDeepSeekBrowserSession() async {
        do {
            if try await DeepSeekBrowserSessionImporter.importValidatedSession() {
                print("DeepSeek browser session imported.")
                exit(0)
            }
            fail("No signed-in DeepSeek Chromium browser session was found yet.", status: 3)
        } catch {
            fail("Could not import the DeepSeek browser session: \(error.localizedDescription)", status: 4)
        }
    }

    private static func importDeepSeekTokenFromStandardInput() async {
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard data.count <= 64 * 1024,
                  let rawValue = String(data: data, encoding: .utf8),
                  let token = DeepSeekCredentialStore.token(fromLocalStorageValue: rawValue)
            else {
                fail("The DeepSeek session token was invalid.", status: 4)
            }
            try await DeepSeekPlatformClient().validate(token: token)
            try DeepSeekCredentialStore.writeToken(token)
            print("DeepSeek browser session imported.")
            exit(0)
        } catch DeepSeekPlatformError.sessionExpired {
            fail("The DeepSeek browser session is not signed in yet.", status: 3)
        } catch {
            fail("Could not import the DeepSeek browser session: \(error.localizedDescription)", status: 4)
        }
    }

    private static func fail(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(status)
    }

    private static func resolvedOutputURL() -> URL {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--output"),
           arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1])
        }
        if arguments.count > 1, !arguments[1].hasPrefix("-") {
            return URL(fileURLWithPath: arguments[1])
        }
        return UsageSnapshot.snapshotURL
    }
}
