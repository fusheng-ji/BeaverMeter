import CodexBarCore
import Foundation

enum TokenHistoryCollector {
    struct CodexReading {
        let history: UsageValue<TokenHistory<CodexTokenTotals>>
        let remoteToday: CodexRemoteUsageCollector.Result?
    }

    static func dates(now: Date, calendar: Calendar) throws -> [Date] {
        let today = calendar.startOfDay(for: now)
        return try (-6...0).map {
            guard let day = calendar.date(byAdding: .day, value: $0, to: today) else {
                throw CocoaError(.coderReadCorrupt)
            }
            return day
        }
    }

    static func dateKey(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func codex(
        previous: UsageValue<TokenHistory<CodexTokenTotals>>, configuration: CodexAccountConfiguration,
        now: Date, directory: URL, environment: [String: String], calendar: Calendar = .current
    ) async -> CodexReading {
        let sourceID = CodexUsageSupport.hash((configuration.homes.sorted() + [
            environment["CODEX_REMOTE_SSH_HOST"] ?? "", environment["CODEX_REMOTE_ROOT"] ?? "",
            environment["CODEX_REMOTE_PYTHON"] ?? ""
        ]).joined(separator: "\u{0}"))
        var remoteToday: CodexRemoteUsageCollector.Result?
        do {
            if let fixture = environment["CODEX_HISTORY_FIXTURE"] {
                let history = try readFixture(TokenHistory<CodexTokenTotals>.self, path: fixture)
                return CodexReading(history: value(history, now: now, complete: true, message: nil), remoteToday: nil)
            }
            if environment["CODEX_TOKEN_FIXTURE"] != nil {
                return CodexReading(history: .unavailable("No seven-day Codex history fixture provided."), remoteToday: nil)
            }
            let days = try dates(now: now, calendar: calendar)
            let dayWindow = try CodexDayWindow(now: now, calendar: calendar)
            let remote = CodexRemoteUsageCollector.collect(
                environment: environment, now: now, calendar: calendar,
                cacheURL: directory.appendingPathComponent("codex-history-remote-v3.json"), historyDays: 7
            )
            remoteToday = .init(configured: remote.configured, complete: remote.complete,
                                usageByResponseHash: remote.usageByResponseHash.filter {
                                    $0.value.timestamp.map(dayWindow.contains) == true
                                }, message: remote.message)
            var complete = remote.complete && configuration.message == nil
            var messages = [configuration.message, remote.message].compactMap { $0 }
            var modern: [String: CodexResponseUsage] = [:]
            var legacyExtras = days.map { _ in CodexTokenTotals.zero }
            var legacySessionIDs: Set<String> = []
            var hasSource = remote.configured
            for home in configuration.homes {
                let root = URL(fileURLWithPath: home)
                guard FileManager.default.fileExists(atPath: root.path) else {
                    complete = false
                    messages.append("A configured Codex log directory is unavailable.")
                    continue
                }
                hasSource = true
                let homeID = CodexUsageSupport.hash(home)
                let scan = try CodexUsageRecordScanner.collect(
                    codexHomePath: home, now: now, calendar: calendar,
                    cacheURL: directory.appendingPathComponent("codex-history-\(homeID)-v3.json"), historyDays: 7
                )
                complete = complete && scan.complete
                if let message = scan.message { messages.append(message) }
                for (id, record) in scan.usageByResponseHash where modern[id] == nil { modern[id] = record }
                do {
                    let legacy: [String: CodexTokenTotals]
                    if let fixture = environment["CODEX_LEGACY_TOKEN_FIXTURE"] {
                        legacy = [dateKey(now, calendar: calendar): try readFixture(CodexTokenTotals.self, path: fixture)]
                    } else {
                        let snapshot = try await CostUsageFetcher(
                            cacheRoot: directory.appendingPathComponent("codex-history-cost-\(homeID)"), calendar: calendar
                        ).loadTokenSnapshot(
                            provider: .codex, now: now, forceRefresh: true, codexHomePath: home, historyDays: 7,
                            allowPricingRefresh: false, refreshPricingInBackground: false, includePiSessions: false
                        )
                        complete = complete && snapshot.historyCoverageIsEstablished
                        let sessionIDs = Set(snapshot.sessions.map(\.sessionID))
                        // The legacy API exposes daily counters, not response IDs. Shared
                        // legacy sessions cannot safely be added twice; modern records above
                        // still deduplicate exactly. Flag partial legacy coverage explicitly.
                        if !legacySessionIDs.isDisjoint(with: sessionIDs) {
                            complete = false
                            messages.append("Overlapping legacy Codex sessions were excluded; legacy history may be incomplete.")
                            continue
                        }
                        legacySessionIDs.formUnion(sessionIDs)
                        legacy = try Dictionary(snapshot.daily.map { entry in
                            (entry.date, try codexTotals(entry))
                        }, uniquingKeysWith: { first, _ in first })
                    }
                    for (index, day) in days.enumerated() {
                        let records = scan.usageByResponseHash.filter {
                            $0.value.timestamp.map { calendar.isDate($0, inSameDayAs: day) } == true
                        }
                        let local = try totals(records)
                        if let old = legacy[dateKey(day, calendar: calendar)], old.totalTokens > local.totalTokens {
                            // Reconcile before adding other sources; never add a legacy
                            // report to the same home's full modern counters.
                            legacyExtras[index] = try CodexTokenAggregation.adding(legacyExtras[index], difference(old, local))
                        }
                    }
                } catch {
                    complete = false
                    messages.append("Legacy Codex history could not be refreshed.")
                }
            }
            guard hasSource else {
                return CodexReading(history: .unavailable("Run Codex once so local session logs are available."),
                                    remoteToday: remoteToday)
            }
            for (id, record) in remote.usageByResponseHash where modern[id] == nil { modern[id] = record }
            var daily: [TokenHistoryDay<CodexTokenTotals>] = []
            for (index, day) in days.enumerated() {
                let records = modern.filter {
                    $0.value.timestamp.map { calendar.isDate($0, inSameDayAs: day) } == true
                }
                var reading = try CodexTokenAggregation.adding(totals(records), legacyExtras[index])
                if let old = matching(previous.value, sourceID: sourceID, day: day, calendar: calendar),
                   old.totalTokens > reading.totalTokens {
                    reading = old
                    complete = false
                    messages.append("History retains the last same-source daily reading while scans recover.")
                }
                daily.append(TokenHistoryDay(date: day, totals: reading))
            }
            let total = try daily.reduce(CodexTokenTotals.zero) { try CodexTokenAggregation.adding($0, $1.totals) }
            let history = TokenHistory(sourceID: sourceID, timeZoneIdentifier: calendar.timeZone.identifier,
                                       days: daily, totals: total)
            return CodexReading(history: value(history, now: now, complete: complete,
                                               message: messages.isEmpty ? nil : Array(Set(messages)).sorted().joined(separator: " ")),
                                remoteToday: remoteToday)
        } catch {
            return CodexReading(history: fallback(previous, sourceID: sourceID, now: now, calendar: calendar),
                                remoteToday: remoteToday)
        }
    }

    static func claude(
        previous: UsageValue<TokenHistory<ClaudeTokenTotals>>, now: Date, directory: URL,
        environment: [String: String], calendar: Calendar = .current
    ) async -> UsageValue<TokenHistory<ClaudeTokenTotals>> {
        let sourceID = CodexUsageSupport.hash(environment["CLAUDE_CONFIG_DIR"]
            ?? "default-claude-transcripts")
        do {
            if let fixture = environment["CLAUDE_HISTORY_FIXTURE"] {
                return value(try readFixture(TokenHistory<ClaudeTokenTotals>.self, path: fixture),
                             now: now, complete: true, message: nil)
            }
            if environment["CLAUDE_TOKEN_FIXTURE"] != nil { return .unavailable("No seven-day Claude history fixture provided.") }
            guard ClaudeTokenCollector.projectsRootExists(environment: environment) else {
                return .unavailable("Run Claude Code once so local session logs are available.")
            }
            let snapshot = try await CostUsageFetcher(cacheRoot: directory, calendar: calendar).loadTokenSnapshot(
                provider: .claude, environment: environment, now: now, forceRefresh: true, historyDays: 7,
                allowPricingRefresh: false, refreshPricingInBackground: false, includePiSessions: false
            )
            var complete = snapshot.historyCoverageIsEstablished
            var daily: [TokenHistoryDay<ClaudeTokenTotals>] = []
            for day in try dates(now: now, calendar: calendar) {
                let entry = snapshot.daily.first { $0.date == dateKey(day, calendar: calendar) }
                var reading = try ClaudeTokenCollector.totals(from: entry)
                if let old = matching(previous.value, sourceID: sourceID, day: day, calendar: calendar),
                   old.totalTokens > reading.totalTokens { reading = old; complete = false }
                daily.append(TokenHistoryDay(date: day, totals: reading))
            }
            let total = try daily.reduce(ClaudeTokenTotals.zero) { try adding($0, $1.totals) }
            return value(TokenHistory(sourceID: sourceID, timeZoneIdentifier: calendar.timeZone.identifier,
                                      days: daily, totals: total), now: now, complete: complete,
                         message: complete ? nil : "Indexing Claude transcripts; seven-day history includes cached readings where available.")
        } catch {
            return fallback(previous, sourceID: sourceID, now: now, calendar: calendar)
        }
    }

    static func adding(_ lhs: ClaudeTokenTotals, _ rhs: ClaudeTokenTotals) throws -> ClaudeTokenTotals {
        let cost: Double? = if let a = lhs.costUSD, let b = rhs.costUSD { a + b }
            else if lhs.totalTokens == 0 { rhs.costUSD }
            else if rhs.totalTokens == 0 { lhs.costUSD } else { nil }
        return ClaudeTokenTotals(
            totalTokens: try CodexUsageSupport.adding(lhs.totalTokens, rhs.totalTokens),
            inputTokens: try CodexUsageSupport.adding(lhs.inputTokens, rhs.inputTokens),
            cacheCreationTokens: try CodexUsageSupport.adding(lhs.cacheCreationTokens, rhs.cacheCreationTokens),
            cacheReadTokens: try CodexUsageSupport.adding(lhs.cacheReadTokens, rhs.cacheReadTokens),
            outputTokens: try CodexUsageSupport.adding(lhs.outputTokens, rhs.outputTokens), costUSD: cost
        )
    }

    private static func codexTotals(_ entry: CostUsageDailyReport.Entry) throws -> CodexTokenTotals {
        let input = max(0, entry.inputTokens ?? 0), output = max(0, entry.outputTokens ?? 0)
        return CodexTokenTotals(totalTokens: try CodexUsageSupport.adding(input, output), inputTokens: input,
                                cachedInputTokens: max(0, entry.cacheReadTokens ?? 0), outputTokens: output,
                                reasoningTokens: max(0, entry.reasoningTokens ?? 0), sessionCount: 0)
    }

    private static func difference(_ legacy: CodexTokenTotals, _ modern: CodexTokenTotals) -> CodexTokenTotals {
        // Use the excess total once. Component deltas can differ when a parser's
        // coverage differs; split the excess so input + output remains the total.
        let excess = legacy.totalTokens - modern.totalTokens
        let input = min(excess, max(0, legacy.inputTokens - modern.inputTokens))
        let output = excess - input
        return CodexTokenTotals(totalTokens: excess, inputTokens: input,
                                cachedInputTokens: min(input, max(0, legacy.cachedInputTokens - modern.cachedInputTokens)),
                                outputTokens: output,
                                reasoningTokens: min(output, max(0, legacy.reasoningTokens - modern.reasoningTokens)), sessionCount: 0)
    }

    static func totals(_ records: [String: CodexResponseUsage]) throws -> CodexTokenTotals {
        try CodexUsageRecordScanner.totals(for: records, sessionHashes: Set(records.values.map(\.sessionHash))) ?? .zero
    }

    private static func matching<T>(_ history: TokenHistory<T>?, sourceID: String, day: Date, calendar: Calendar) -> T? {
        guard history?.sourceID == sourceID, history?.timeZoneIdentifier == calendar.timeZone.identifier else { return nil }
        return history?.days.first { $0.date == day }?.totals
    }

    private static func value<T>(_ history: TokenHistory<T>, now: Date, complete: Bool, message: String?) -> UsageValue<TokenHistory<T>> {
        UsageValue(status: complete ? .ready : .stale, source: .codexBarLocal, measuredAt: now,
                   lastAttemptAt: now, message: message, value: history)
    }

    private static func fallback<T>(_ previous: UsageValue<TokenHistory<T>>, sourceID: String,
                                    now: Date, calendar: Calendar) -> UsageValue<TokenHistory<T>> {
        guard previous.value?.sourceID == sourceID, previous.value?.coversToday(at: now, calendar: calendar) == true else {
            return .unavailable("Seven-day history could not be refreshed for the current sources and dates.")
        }
        return CollectorSupport.stale(previous: previous, attemptedAt: now, status: .error,
                                      message: "Seven-day history could not be refreshed.")
    }

    private static func readFixture<T: Decodable>(_ type: T.Type, path: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}

extension ClaudeTokenTotals {
    static let zero = ClaudeTokenTotals(totalTokens: 0, inputTokens: 0, cacheCreationTokens: 0,
                                       cacheReadTokens: 0, outputTokens: 0, costUSD: 0)
}
