import Foundation

extension UsageSnapshot {
    static var monitoringPreview: UsageSnapshot {
        let base = preview
        let now = previewDate
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let days = (-6...0).map { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: now))! }
        func ready<T>(_ value: T) -> UsageValue<T> {
            UsageValue(status: .ready, source: .preview, measuredAt: now, lastAttemptAt: now, message: nil, value: value)
        }
        func workspaceTokens(_ count: Int) -> CodexTokenTotals {
            let output = count / 5
            return CodexTokenTotals(totalTokens: count, inputTokens: count - output,
                                    cachedInputTokens: count / 4, outputTokens: output,
                                    reasoningTokens: count / 10, sessionCount: count == 0 ? 0 : 1)
        }
        func workspaceHistory(_ sourceID: String, counts: [Int]) -> TokenHistory<CodexTokenTotals> {
            let readings = zip(days, counts).map { date, count in
                TokenHistoryDay(date: date, totals: workspaceTokens(count))
            }
            let total = readings.reduce(workspaceTokens(0)) { partial, day in
                CodexTokenTotals(totalTokens: partial.totalTokens + day.totals.totalTokens,
                    inputTokens: partial.inputTokens + day.totals.inputTokens,
                    cachedInputTokens: partial.cachedInputTokens + day.totals.cachedInputTokens,
                    outputTokens: partial.outputTokens + day.totals.outputTokens,
                    reasoningTokens: partial.reasoningTokens + day.totals.reasoningTokens,
                    sessionCount: partial.sessionCount + day.totals.sessionCount)
            }
            return TokenHistory(sourceID: sourceID, timeZoneIdentifier: "GMT", days: readings, totals: total)
        }
        let cursorQuota = ready(CompactQuota(label: "Cursor Monthly", used: 99.80, limit: 790,
                                             remaining: 690.20, remainingPercent: nil,
                                             resetAt: now.addingTimeInterval(16 * 86_400),
                                             windowSeconds: 31 * 86_400,
                                             detail: "Demo monthly plan budget"))
        var snapshot = UsageSnapshot(schemaVersion: base.schemaVersion, generatedAt: now,
                                     codexTokens: base.codexTokens, cursorCosts: base.cursorCosts,
                                     cursorQuota: cursorQuota, codexQuota: base.codexQuota,
                                     claudeTokens: base.claudeTokens, claudeQuota: base.claudeQuota,
                                     deepseekUsage: base.deepseekUsage)
        let cards = ResetCardInventory(availableCount: 3, observedAt: now, batches: [
            ResetCardBatch(id: "demo-card-1", count: 1, startsAt: nil, expiresAt: now.addingTimeInterval(10 * 3600)),
            ResetCardBatch(id: "demo-card-2", count: 1, startsAt: nil, expiresAt: now.addingTimeInterval(10 * 86400))
        ])
        let quota = CompactQuota(label: "Codex Week", used: nil, limit: nil, remaining: nil,
                                 remainingPercent: 60, resetAt: now.addingTimeInterval(4 * 86400),
                                 windowSeconds: 604800, detail: "60% left", windows: [
                                    CompactQuota(label: "Codex 5h", used: nil, limit: nil, remaining: nil,
                                                 remainingPercent: 80, resetAt: now.addingTimeInterval(3 * 3600),
                                                 windowSeconds: 18000, detail: "80% left"),
                                    CompactQuota(label: "Codex Week", used: nil, limit: nil, remaining: nil,
                                                 remainingPercent: 60, resetAt: now.addingTimeInterval(4 * 86400),
                                                 windowSeconds: 604800, detail: "60% left")
                                 ])
        snapshot.codexAccounts = ready([
            CodexAccountUsage(id: "demo-personal", homeID: "demo-home-1", displayName: "personal@example.test · Personal",
                              quota: ready(quota), resetCards: ready(cards), workspaceName: "Personal",
                              accountName: "personal@example.test", planName: "Pro",
                              workspaceAccountIDHash: String(repeating: "1", count: 64),
                              tokens: ready(workspaceTokens(48_200)),
                              history: ready(workspaceHistory("demo-personal-sessions", counts: [12_400, 0, 30_800, 18_200, 62_000, 25_600, 48_200]))),
            CodexAccountUsage(id: "demo-work", homeID: "demo-home-2",
                              displayName: "personal@example.test · Research workspace with a longer name",
                              quota: UsageValue(status: .stale, source: .cache, measuredAt: now.addingTimeInterval(-600),
                                                lastAttemptAt: now, message: "Quota refresh failed; previous reading retained.", value:
                                CompactQuota(label: "Codex 5h", used: nil, limit: nil, remaining: nil,
                                    remainingPercent: 30, resetAt: now.addingTimeInterval(2 * 3600),
                                    windowSeconds: 18000, detail: "30% left", windows: [
                                        CompactQuota(label: "Codex 5h", used: nil, limit: nil, remaining: nil,
                                            remainingPercent: 30, resetAt: now.addingTimeInterval(2 * 3600),
                                            windowSeconds: 18000, detail: "30% left"),
                                        CompactQuota(label: "Codex Week", used: nil, limit: nil, remaining: nil,
                                            remainingPercent: 45, resetAt: now.addingTimeInterval(5 * 86400),
                                            windowSeconds: 604800, detail: "45% left")
                                    ])),
                              resetCards: .unavailable("Reset-card information is unavailable for this sign-in."),
                              workspaceName: "Research workspace with a longer name", accountName: "personal@example.test", planName: "Business",
                              workspaceAccountIDHash: String(repeating: "2", count: 64),
                              tokens: ready(workspaceTokens(17_650)),
                              history: ready(workspaceHistory("demo-research-sessions", counts: [2_500, 5_200, 0, 14_700, 6_900, 10_300, 17_650])))
        ])
        snapshot.claudeResetCards = ready(cards)
        let codexDay = snapshot.codexTokens.value!
        let codexWeights = [0, 1, 2, 4, 6, 3, 1]
        let codexWeight = codexWeights.reduce(0, +)
        snapshot.codexHistory = ready(TokenHistory(sourceID: "demo-sources", timeZoneIdentifier: "GMT",
            days: zip(days, codexWeights).map { date, weight in
                TokenHistoryDay(date: date, totals: CodexTokenTotals(
                    totalTokens: codexDay.totalTokens * weight, inputTokens: codexDay.inputTokens * weight,
                    cachedInputTokens: codexDay.cachedInputTokens * weight, outputTokens: codexDay.outputTokens * weight,
                    reasoningTokens: codexDay.reasoningTokens * weight, sessionCount: codexDay.sessionCount * weight))
            },
            totals: CodexTokenTotals(totalTokens: codexDay.totalTokens * codexWeight, inputTokens: codexDay.inputTokens * codexWeight,
                                     cachedInputTokens: codexDay.cachedInputTokens * codexWeight, outputTokens: codexDay.outputTokens * codexWeight,
                                     reasoningTokens: codexDay.reasoningTokens * codexWeight, sessionCount: codexDay.sessionCount * codexWeight)))
        let claudeDay = snapshot.claudeTokens.value!
        let claudeWeights = [4, 1, 0, 2, 3, 6, 1]
        let claudeWeight = claudeWeights.reduce(0, +)
        snapshot.claudeHistory = ready(TokenHistory(sourceID: "demo-transcripts", timeZoneIdentifier: "GMT",
            days: zip(days, claudeWeights).map { date, weight in
                TokenHistoryDay(date: date, totals: ClaudeTokenTotals(
                    totalTokens: claudeDay.totalTokens * weight, inputTokens: claudeDay.inputTokens * weight,
                    cacheCreationTokens: claudeDay.cacheCreationTokens * weight,
                    cacheReadTokens: claudeDay.cacheReadTokens * weight, outputTokens: claudeDay.outputTokens * weight,
                    costUSD: claudeDay.costUSD.map { $0 * Double(weight) }))
            },
            totals: ClaudeTokenTotals(totalTokens: claudeDay.totalTokens * claudeWeight, inputTokens: claudeDay.inputTokens * claudeWeight,
                                      cacheCreationTokens: claudeDay.cacheCreationTokens * claudeWeight,
                                      cacheReadTokens: claudeDay.cacheReadTokens * claudeWeight, outputTokens: claudeDay.outputTokens * claudeWeight,
                                      costUSD: claudeDay.costUSD.map { $0 * Double(claudeWeight) })))
        return snapshot
    }
}
