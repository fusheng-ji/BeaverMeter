import CodexBarCore
import Foundation

/// Reads quota through the official app/CLI's local service. No independent
/// OAuth credential store or model invocation is used by BeaverMeter.
enum AntigravityQuotaCollector {
    typealias Fetch = @Sendable ([String: String]) async throws -> ProviderFetchResult
    typealias Cleanup = @Sendable () async -> Void
    static let maximumCacheAge: TimeInterval = 30 * 60

    static func collect(
        previous: UsageValue<AntigravityQuotaSnapshot>,
        now: Date,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fetch: Fetch = fetchLocal,
        cleanup: Cleanup = cleanupLocal
    ) async -> UsageValue<AntigravityQuotaSnapshot> {
        do {
            if let fixture = environment["ANTIGRAVITY_QUOTA_FIXTURE"] {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let snapshot = try decoder.decode(AntigravityQuotaSnapshot.self,
                    from: Data(contentsOf: URL(fileURLWithPath: fixture)))
                return reading(snapshot, now: now)
            }
            try Task.checkCancellation()
            let result: ProviderFetchResult
            do {
                result = try await fetch(environment)
            } catch {
                await cleanup()
                throw error
            }
            await cleanup()
            try Task.checkCancellation()
            guard result.strategyID != "antigravity.offline", result.sourceLabel != "offline" else {
                throw QuotaError.offlineOnly
            }
            return reading(project(result.usage, now: now), now: now)
        } catch {
            return failure(previous: previous, now: now, error: error)
        }
    }

    /// The summary's named windows carry their own availability. Their zero
    /// placeholders must never be interpreted as a real untouched allowance.
    static func project(_ snapshot: CodexBarCore.UsageSnapshot, now: Date) -> AntigravityQuotaSnapshot {
        let summary = (snapshot.extraRateWindows ?? []).filter {
            AntigravityStatusSnapshot.isQuotaSummaryWindowID($0.id)
        }
        var windows: [AntigravityQuotaGroupID: [CompactQuota]] = [:]
        if !summary.isEmpty {
            for item in summary {
                guard let group = group(for: item.title) else { continue }
                windows[group, default: []].append(quota(item.window, group: group,
                    label: item.title, known: item.usageKnown, now: now))
            }
        } else {
            // CodexBar's legacy representatives are selected only from models
            // with an explicit remainingFraction. Reset-only models live in
            // extraRateWindows with usageKnown=false, never these representatives.
            for (group, window) in [(AntigravityQuotaGroupID.gemini, snapshot.primary),
                                     (.claudeGPT, snapshot.secondary)] {
                if let window {
                    windows[group, default: []].append(quota(window, group: group,
                        label: group.title, known: !window.isSyntheticPlaceholder, now: now))
                }
            }
            for item in snapshot.extraRateWindows ?? [] where !item.usageKnown {
                guard let group = group(for: item.title), windows[group]?.isEmpty != false else { continue }
                windows[group, default: []].append(quota(item.window, group: group,
                    label: item.title, known: false, now: now))
            }
        }
        let groups = AntigravityQuotaGroupID.allCases.map { group in
            AntigravityQuotaGroup(id: group, windows: windows[group] ?? [])
        }
        let accountID = snapshot.accountEmail(for: .antigravity)
            .flatMap(CodexUsageSupport.nonempty)
            .map { CodexUsageSupport.hash($0.lowercased()) }
        return AntigravityQuotaSnapshot(groups: groups,
            planName: snapshot.loginMethod(for: .antigravity).flatMap(CodexUsageSupport.nonempty),
            accountID: accountID)
    }

    private static func quota(_ window: RateWindow, group: AntigravityQuotaGroupID,
                              label: String, known: Bool, now: Date) -> CompactQuota {
        let isCurrent = window.resetsAt.map { $0 > now } ?? true
        let remaining = known && !window.isSyntheticPlaceholder && window.usedPercent.isFinite && isCurrent
            ? min(max(100 - window.usedPercent, 0), 100) : nil
        let seconds = window.windowMinutes.flatMap { minutes -> Int? in
            guard minutes > 0 else { return nil }
            let (value, overflow) = minutes.multipliedReportingOverflow(by: 60)
            return overflow ? nil : value
        }
        let quotaLabel: String
        switch seconds {
        case 18_000: quotaLabel = "\(group.title) 5h"
        case 604_800: quotaLabel = "\(group.title) Weekly"
        default: quotaLabel = label == group.title ? "\(group.title) quota" : label
        }
        var value = CompactQuota(label: quotaLabel, used: nil, limit: nil,
            remaining: nil, remainingPercent: remaining, resetAt: window.resetsAt,
            windowSeconds: seconds, detail: remaining.map { "\(Int($0.rounded()))% left" } ?? "Quota unavailable")
        value.resetDescription = CodexUsageSupport.nonempty(window.resetDescription)
        return value
    }

    private static func group(for title: String) -> AntigravityQuotaGroupID? {
        let name = title.lowercased()
        if name.contains("gemini") { return .gemini }
        if name.contains("claude") || name.contains("gpt") { return .claudeGPT }
        return nil
    }

    private static func reading(_ snapshot: AntigravityQuotaSnapshot, now: Date) -> UsageValue<AntigravityQuotaSnapshot> {
        let known = snapshot.groups.contains { $0.windows.contains { $0.remainingPercent != nil } }
        return UsageValue(status: known ? .ready : .unavailable, source: .antigravityLocal,
            measuredAt: now, lastAttemptAt: now,
            message: known ? nil : "Antigravity has not reported a current quota for these model groups.", value: snapshot)
    }

    private static func failure(previous: UsageValue<AntigravityQuotaSnapshot>, now: Date,
                                error: Error) -> UsageValue<AntigravityQuotaSnapshot> {
        let auth = isAuthenticationFailure(error)
        let message = message(for: error)
        if !auth, previous.status != .unauthenticated,
           let snapshot = previous.value, let measuredAt = previous.measuredAt,
           now.timeIntervalSince(measuredAt) >= 0,
           now.timeIntervalSince(measuredAt) < maximumCacheAge,
           previous.source == .antigravityLocal || previous.source == .cache {
            return UsageValue(status: .stale, source: .cache, measuredAt: measuredAt,
                lastAttemptAt: now, message: message, value: snapshot)
        }
        return UsageValue(status: auth ? .unauthenticated : .unavailable, source: .none,
            measuredAt: nil, lastAttemptAt: now, message: message, value: nil)
    }

    private static func isAuthenticationFailure(_ error: Error) -> Bool {
        guard let error = error as? AntigravityStatusProbeError else { return false }
        switch error {
        case .authenticationRequired, .accountMismatch: return true
        case .apiError(let message):
            // The local language server also returns 401 for its per-process
            // CSRF challenge. This says nothing about the user's Google login.
            guard !message.localizedCaseInsensitiveContains("csrf") else { return false }
            let code = message.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if ["401", "403", "UNAUTHENTICATED", "PERMISSION_DENIED", "16", "7"].contains(code) { return true }
            return code.range(of: #"^HTTP\s+(401|403)\b"#, options: .regularExpression) != nil
        default: return false
        }
    }

    /// Keep upstream bodies, account identifiers and command lines out of the
    /// persisted user-facing message.
    private static func message(for error: Error) -> String {
        if isAuthenticationFailure(error) {
            return "Antigravity login could not be verified. Open Antigravity or agy to check its current login."
        }
        if error is CancellationError { return "Antigravity quota refresh was cancelled." }
        if let error = error as? AntigravityStatusProbeError {
            switch error {
            case .notRunning:
                return "Antigravity's local service is unavailable. Open Antigravity or make the official agy CLI available."
            case .timedOut: return "Antigravity quota refresh timed out. BeaverMeter will retry automatically."
            case .missingCSRFToken, .portDetectionFailed:
                return "Antigravity's local service is not ready. BeaverMeter will retry automatically."
            case .apiError(let message) where message.localizedCaseInsensitiveContains("csrf"):
                return "Antigravity's local service could not be verified. BeaverMeter will retry automatically."
            default: break
            }
        }
        return "Antigravity quota could not be refreshed. BeaverMeter will retry automatically."
    }

    private enum QuotaError: Error { case offlineOnly }

    private static func fetchLocal(environment: [String: String]) async throws -> ProviderFetchResult {
        let context = localContext(environment: environment)
        let upstream = AntigravityProviderDescriptor.descriptor.fetchPlan.pipeline
        let outcome = await localPipeline(from: upstream, managedCLI: ManagedCLIQuotaStrategy())
            .fetch(context: context, provider: .antigravity)
        if environment["BEAVERMETER_DIAGNOSTICS"] == "1" {
            FileHandle.standardError.write(Data((diagnostics(outcome) + "\n").utf8))
        }
        return try outcome.result.get()
    }

    /// Opt-in diagnostics expose routing and error types, never upstream bodies,
    /// account identifiers, URLs or credential-bearing terminal output.
    static func diagnostics(_ outcome: ProviderFetchOutcome) -> String {
        var parts = outcome.attempts.map {
            "\($0.strategyID):available=\($0.wasAvailable),failed=\($0.errorDescription != nil)"
        }
        if case .failure(let error) = outcome.result {
            let ns = error as NSError
            parts.append("failureType=\(String(reflecting: type(of: error))),code=\(ns.code)")
        }
        return "Antigravity " + parts.joined(separator: " · ")
    }

    static func localContext(environment: [String: String]) -> ProviderFetchContext {
        let browsers = BrowserDetection()
        return ProviderFetchContext(runtime: .cli, sourceMode: .cli, includeCredits: false,
            includeOptionalUsage: false, webTimeout: 8, webDebugDumpHTML: false, verbose: false,
            env: environment, settings: nil, fetcher: UsageFetcher(environment: environment),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browsers, environment: environment,
                                              runtime: .cli, oauthSafeCredentialSourcesOnly: true),
            browserDetection: browsers, costUsageHistoryDays: 1, persistsCLISessions: false)
    }

    static func localPipeline(from upstream: ProviderFetchPipeline,
                              managedCLI: (any ProviderFetchStrategy)? = nil) -> ProviderFetchPipeline {
        // The upstream descriptor's final offline strategy reports conversation
        // counts, not quota. Exclude it before execution so it cannot turn a
        // preceding authentication failure into an apparently successful read.
        let allowed = Set(["antigravity.app-local", "antigravity.cli-https", "antigravity.ide-local"])
        return ProviderFetchPipeline(resolveStrategies: { context in
            await upstream.resolveStrategies(context).filter { allowed.contains($0.id) }.map { strategy in
                if strategy.id == "antigravity.cli-https", let managedCLI { return managedCLI }
                return strategy
            }
        }, resolveFallbackError: { previous, current in
            if let previous, isAuthenticationFailure(previous) { return previous }
            if let previous, (current as? AntigravityStatusProbeError) == .notRunning { return previous }
            return current
        })
    }

    /// Keep the pinned pipeline's ordering while adapting only the owned CLI
    /// transport to the current per-process CSRF protocol.
    private struct ManagedCLIQuotaStrategy: ProviderFetchStrategy {
        let id = "antigravity.cli-csrf"
        let kind = ProviderFetchKind.cli

        func isAvailable(_ context: ProviderFetchContext) async -> Bool {
            AntigravityManagedCLI.isAvailable(environment: context.env)
        }

        func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
            try await AntigravityManagedCLI.fetch(environment: context.env)
        }

        func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
            !(error is CancellationError) && !Task.isCancelled
        }
    }

    private static func cleanupLocal() async {
        // The replacement CLI strategy cleans up its own exact child/group in
        // defer. App/IDE strategies only probe existing services. Do not invoke
        // the dependency's global session reset: it also reaps recorded CLI
        // sessions created by other applications or previous owners.
    }
}
