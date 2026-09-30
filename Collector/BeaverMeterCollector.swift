import Darwin
import Foundation

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
        do {
            let lock = try SnapshotWriter.lock(for: outputURL)
            defer { lock.unlock() }
            // `--codex-only` predates Claude support; installed apps still pass it.
            if CommandLine.arguments.contains("--codex-only") || CommandLine.arguments.contains("--local-tokens") {
                try await refreshLocalTokens(outputURL: outputURL)
            } else {
                try await refreshAll(outputURL: outputURL)
            }
        } catch {
            fail("Failed to refresh usage: \(error.localizedDescription)", status: 1)
        }
    }

    private static func refreshAll(outputURL: URL) async throws {
        let previous = SnapshotWriter.loadPrevious(from: outputURL)
        let now = Date()
        let scanCacheURL = codexScanCacheURL(for: outputURL)
        let settings = providerSettings(for: outputURL)

        // Services switched off keep their previous values and are never contacted.
        async let codexTokens = settings.collects(.codex)
            ? await CodexTokenCollector.collect(previous: previous.codexTokens, now: now, scanCacheURL: scanCacheURL)
            : previous.codexTokens
        async let codexQuota = settings.collects(.codex)
            ? await CodexQuotaCollector.collect(previous: previous.codexQuota, now: now)
            : previous.codexQuota
        async let claudeTokens = settings.collects(.claude)
            ? await ClaudeTokenCollector.collect(
                previous: previous.claudeTokens, now: now, cacheRoot: claudeCostCacheRoot(for: outputURL)
            )
            : previous.claudeTokens
        async let claudeQuota = settings.collects(.claude)
            ? await ClaudeQuotaCollector.collect(
                previous: previous.claudeQuota, now: now, stateDirectory: outputURL.deletingLastPathComponent()
            )
            : previous.claudeQuota
        async let cursor = settings.collects(.cursor)
            ? await CursorUsageCollector.collect(
                previousCosts: previous.cursorCosts, previousQuota: previous.cursorQuota, now: now
            )
            : (costs: previous.cursorCosts, quota: previous.cursorQuota)
        async let deepseekUsage = settings.collects(.deepseek)
            ? await DeepSeekUsageCollector.collect(previous: previous.deepseekUsage, now: now)
            : previous.deepseekUsage

        let (resolvedCodexTokens, resolvedCodexQuota, resolvedCursor, resolvedDeepSeek) = await (
            codexTokens,
            codexQuota,
            cursor,
            deepseekUsage
        )
        let (resolvedClaudeTokens, resolvedClaudeQuota) = await (claudeTokens, claudeQuota)
        let snapshot = UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: now,
            codexTokens: resolvedCodexTokens,
            cursorCosts: resolvedCursor.costs,
            cursorQuota: resolvedCursor.quota,
            codexQuota: resolvedCodexQuota,
            claudeTokens: resolvedClaudeTokens,
            claudeQuota: resolvedClaudeQuota,
            deepseekUsage: resolvedDeepSeek
        )

        try SnapshotWriter.write(snapshot, to: outputURL)
        print(outputURL.path)
    }

    /// The App's frequent refresh: only the local token scans, never account APIs.
    private static func refreshLocalTokens(outputURL: URL) async throws {
        let previous = SnapshotWriter.loadPrevious(from: outputURL)
        let now = Date()
        let settings = providerSettings(for: outputURL)
        async let codexTokens = settings.collects(.codex)
            ? await CodexTokenCollector.collect(
                previous: previous.codexTokens, now: now, scanCacheURL: codexScanCacheURL(for: outputURL)
            )
            : previous.codexTokens
        async let claudeTokens = settings.collects(.claude)
            ? await ClaudeTokenCollector.collect(
                previous: previous.claudeTokens, now: now, cacheRoot: claudeCostCacheRoot(for: outputURL)
            )
            : previous.claudeTokens
        let (resolvedCodexTokens, resolvedClaudeTokens) = await (codexTokens, claudeTokens)
        guard isChanged(previous.codexTokens, resolvedCodexTokens, now: now)
                || isChanged(previous.claudeTokens, resolvedClaudeTokens, now: now)
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
            deepseekUsage: previous.deepseekUsage
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
