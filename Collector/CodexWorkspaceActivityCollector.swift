import Foundation

/// Per-workspace usage requires request-account evidence. Session creators never establish billing scope.
enum CodexWorkspaceActivityCollector {
    /// Small projection of the already-deduplicated scan. No response map or raw identifiers survive.
    struct ScanSummary {
        let referenceDate: Date
        let days: [Date]
        let sourceComponents: [String]
        let configurationMessage: String?
        let complete: Bool
        let modernTotals: [CodexTokenTotals?]
        let scopedTotals: [String: [CodexTokenTotals?]]
        let unattributedDays: Set<Int>
        let hasUnattributedRecords: Bool
        let hasUndatedRecords: Bool
    }

    static func summarize(
        records: [String: CodexResponseUsage], complete: Bool,
        configuration: CodexAccountConfiguration, environment: [String: String],
        now: Date, calendar: Calendar
    ) throws -> ScanSummary {
        let days = try TokenHistoryCollector.dates(now: now, calendar: calendar)
        let indices = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element, $0.offset) })
        var modern = days.map { _ in TokenHistoryCollector.CodexDayAccumulator() }
        var scopes: [String: [TokenHistoryCollector.CodexDayAccumulator]] = [:]
        var unattributedDays: Set<Int> = []
        var hasUnattributedRecords = false
        var hasUndatedRecords = false
        for usage in records.values {
            let scope = usage.verifiedWorkspaceHash
            if scope == nil { hasUnattributedRecords = true }
            guard let timestamp = usage.timestamp else {
                hasUndatedRecords = true
                continue
            }
            guard timestamp <= now, let index = indices[calendar.startOfDay(for: timestamp)] else { continue }
            modern[index].add(usage)
            if let scope {
                scopes[scope, default: days.map { _ in TokenHistoryCollector.CodexDayAccumulator() }][index].add(usage)
            } else {
                unattributedDays.insert(index)
            }
        }
        return ScanSummary(referenceDate: now, days: days,
            sourceComponents: sourceComponents(configuration: configuration, environment: environment, calendar: calendar),
            configurationMessage: configuration.message, complete: complete, modernTotals: modern.map(\.totals),
            scopedTotals: scopes.mapValues { $0.map { $0.recordCount == 0 ? nil : $0.totals } },
            unattributedDays: unattributedDays, hasUnattributedRecords: hasUnattributedRecords,
            hasUndatedRecords: hasUndatedRecords)
    }

    private static func sourceComponents(
        configuration: CodexAccountConfiguration, environment: [String: String], calendar: Calendar
    ) -> [String] {
        let homes = Array(Set(configuration.homes.map {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
        })).sorted()
        return homes + [environment["CODEX_REMOTE_SSH_HOST"] ?? "", environment["CODEX_REMOTE_ROOT"] ?? "",
                        environment["CODEX_REMOTE_PYTHON"] ?? "", calendar.timeZone.identifier]
    }

    static func collect(
        accounts: UsageValue<[CodexAccountUsage]>, previous: UsageValue<[CodexAccountUsage]>,
        configuration: CodexAccountConfiguration, aggregateHistory: UsageValue<TokenHistory<CodexTokenTotals>>,
        remoteHistory: CodexRemoteUsageCollector.Result? = nil,
        scanSummary: ScanSummary? = nil, now: Date, directory: URL,
        environment: [String: String], calendar: Calendar = .current
    ) async -> UsageValue<[CodexAccountUsage]> {
        guard let accountsValue = accounts.value else { return accounts }
        let hasGlobalFixture = environment["CODEX_TOKEN_FIXTURE"] != nil || environment["CODEX_HISTORY_FIXTURE"] != nil
        guard !hasGlobalFixture, accountsValue.contains(where: { $0.workspaceAccountIDHash.map(isHash) == true }) else {
            // Provider-wide fixtures carry no workspace provenance and must bypass all live log IO.
            // Without any trusted account scope there is likewise nothing a scan could attribute.
            let result = accountsValue.map { account -> CodexAccountUsage in
                var account = account
                account.tokens = unavailable(now, "Recorded session usage is not attributable to this workspace.")
                account.history = unavailable(now, "Recorded session history is not attributable to this workspace.")
                return account
            }
            return UsageValue(status: accounts.status, source: accounts.source, measuredAt: accounts.measuredAt,
                              lastAttemptAt: accounts.lastAttemptAt, message: accounts.message, value: result)
        }
        let days: [Date]
        do { days = try TokenHistoryCollector.dates(now: now, calendar: calendar) }
        catch { return accounts }
        let sourceComponents = sourceComponents(configuration: configuration, environment: environment, calendar: calendar)
        let scan: ScanSummary
        if let scanSummary, scanSummary.referenceDate == now, scanSummary.days == days,
           scanSummary.sourceComponents == sourceComponents, scanSummary.configurationMessage == configuration.message {
            scan = scanSummary
        } else {
            // Standalone callers retain the original scanner path. Normal refreshes reuse the
            // global history scan's small summary, so they never decode the same cache twice.
            var records: [String: CodexResponseUsage] = [:]
            var complete = configuration.message == nil
            let homes = Array(Set(configuration.homes.map {
                URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
            })).sorted()
            for home in homes {
                do {
                    let reading = try CodexUsageRecordScanner.collect(codexHomePath: home, now: now, calendar: calendar,
                        cacheURL: directory.appendingPathComponent("codex-history-\(CodexUsageSupport.hash(home))-v3.json"), historyDays: 7)
                    complete = complete && reading.complete
                    merge(reading.usageByResponseHash, into: &records)
                } catch { complete = false }
            }
            if let remoteHistory {
                complete = complete && remoteHistory.complete
                merge(remoteHistory.usageByResponseHash, into: &records)
            } else if CodexUsageSupport.nonempty(environment["CODEX_REMOTE_SSH_HOST"]) != nil {
                // Only the already-collected remote result is accepted; never start another SSH read.
                complete = false
            }
            guard let summary = try? summarize(records: records, complete: complete,
                configuration: configuration, environment: environment, now: now, calendar: calendar) else { return accounts }
            scan = summary
        }
        // Unknown provenance may include an explicit identity conflict. Even if another source
        // failed concurrently, do not revive a cached attribution contradicted by this scan.
        let mayRetainCache = !scan.complete && !scan.hasUnattributedRecords
        let result = accountsValue.map { account -> CodexAccountUsage in
            var account = account
            guard let scope = account.workspaceAccountIDHash, isHash(scope) else {
                account.tokens = unavailable(now, "Recorded session usage is not attributable to this workspace.")
                account.history = unavailable(now, "Recorded session history is not attributable to this workspace.")
                return account
            }
            let sourceID = CodexUsageSupport.hash((["workspace-request-records-v2", scope] + sourceComponents).joined(separator: "\u{0}"))
            let old = previous.value?.first {
                $0.id == account.id && $0.workspaceAccountIDHash == scope
                    && $0.history?.value?.sourceID == sourceID
                    && $0.history?.value?.timeZoneIdentifier == calendar.timeZone.identifier
            }
            let scoped = scan.scopedTotals[scope]
            let scopeObserved = scoped != nil
            let aggregateCurrent = aggregateHistory.status == .ready && !aggregateHistory.isStale
                && aggregateHistory.value?.timeZoneIdentifier == calendar.timeZone.identifier
                && (aggregateHistory.source == .preview || aggregateHistory.measuredAt.map { calendar.isDate($0, inSameDayAs: now) && $0 <= now } == true)
            var historyDays: [TokenHistoryDay<CodexTokenTotals>] = []
            var allDaysComplete = scan.complete && aggregateCurrent && scopeObserved
            var historyUsedCache = false
            var todayValue: CodexTokenTotals?
            var todayComplete = false
            var todayUsedCache = false
            for (index, day) in days.enumerated() {
                let modern = scan.modernTotals[index] ?? .zero
                let aggregate = aggregateHistory.value?.days.first { calendar.isDate($0.date, inSameDayAs: day) }?.totals
                let completeDay = scan.complete && aggregateCurrent && scopeObserved && aggregate == modern
                    && !scan.unattributedDays.contains(index) && !scan.hasUndatedRecords
                var value = scoped?[index]
                // An auth-only directory or an unattributed empty scan is unknown, not zero usage.
                if value?.totalTokens == 0 && !completeDay { value = nil }
                if value == nil && completeDay { value = .zero }
                var usedCache = false
                // Transient source failure may retain only this exact scope/source/day. An attribution
                // conflict from a completed scan must clear old scope values rather than retain them.
                if mayRetainCache, let cached = old?.history?.value?.days.first(where: { calendar.isDate($0.date, inSameDayAs: day) })?.totals,
                   value.map({ cached.totalTokens > $0.totalTokens }) ?? true {
                    value = cached
                    usedCache = true
                }
                allDaysComplete = allDaysComplete && completeDay && !usedCache
                historyUsedCache = historyUsedCache || usedCache
                if let value { historyDays.append(TokenHistoryDay(date: day, totals: value)) }
                if calendar.isDate(day, inSameDayAs: now) {
                    todayValue = value
                    todayComplete = completeDay && !usedCache
                    todayUsedCache = usedCache
                }
            }
            let partialMessage = "Request-attributed usage; coverage is incomplete. Creator-only, unattributed and legacy usage are not included."
            if let todayValue {
                account.tokens = reading(todayValue, complete: todayComplete, now: now,
                    measuredAt: todayUsedCache ? old?.tokens?.measuredAt ?? old?.history?.measuredAt ?? now : now,
                    cached: todayUsedCache,
                    message: todayComplete ? "Request-attributed usage for this workspace." : partialMessage)
            } else {
                account.tokens = unavailable(now, "Request-level account attribution is unavailable for this workspace today.")
            }
            if !historyDays.isEmpty,
               let sum = try? historyDays.reduce(CodexTokenTotals.zero, { try CodexTokenAggregation.adding($0, $1.totals) }) {
                let history = TokenHistory(sourceID: sourceID, timeZoneIdentifier: calendar.timeZone.identifier,
                                           days: historyDays, totals: sum)
                account.history = reading(history, complete: allDaysComplete, now: now,
                    measuredAt: historyUsedCache ? old?.history?.measuredAt ?? now : now,
                    cached: historyUsedCache,
                    message: allDaysComplete ? "Request-attributed usage for this workspace." : partialMessage)
            } else {
                account.history = unavailable(now, "Request-level account attribution is unavailable for this workspace history.")
            }
            return account
        }
        return UsageValue(status: accounts.status, source: accounts.source, measuredAt: accounts.measuredAt,
                          lastAttemptAt: accounts.lastAttemptAt, message: accounts.message, value: result)
    }

    private static func merge(_ incoming: [String: CodexResponseUsage], into records: inout [String: CodexResponseUsage]) {
        for (response, usage) in incoming {
            records[response] = records[response].map { $0.mergingWorkspaceScope(usage) } ?? usage
        }
    }

    private static func reading<T>(_ value: T, complete: Bool, now: Date, measuredAt: Date, cached: Bool, message: String) -> UsageValue<T> {
        UsageValue(status: complete ? .ready : .stale, source: cached ? .cache : .codexBarLocal,
                   measuredAt: measuredAt, lastAttemptAt: now, message: message, value: value)
    }

    private static func unavailable<T>(_ now: Date, _ message: String) -> UsageValue<T> {
        UsageValue(status: .unavailable, source: .none, measuredAt: nil, lastAttemptAt: now, message: message, value: nil)
    }

    private static func isHash(_ value: String) -> Bool {
        CodexUsageSupport.isSHA256(value)
    }
}
