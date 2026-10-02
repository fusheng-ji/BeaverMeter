import Foundation

extension UsageSnapshot {
    static var monitoringPreview: UsageSnapshot {
        var snapshot = preview
        let now = previewDate
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let days = (-6...0).map { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: now))! }
        func ready<T>(_ value: T) -> UsageValue<T> {
            UsageValue(status: .ready, source: .preview, measuredAt: now, lastAttemptAt: now, message: nil, value: value)
        }
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
                              accountName: "personal@example.test", planName: "Pro"),
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
                              workspaceName: "Research workspace with a longer name", accountName: "personal@example.test", planName: "Business")
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
