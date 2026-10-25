import Foundation

extension UsageSnapshot {
    static let previewDate = Date(timeIntervalSince1970: 1_790_078_400)

    static let preview: UsageSnapshot = {
        let now = previewDate
        return UsageSnapshot(
            schemaVersion: Self.currentSchemaVersion,
            generatedAt: now,
            codexTokens: UsageValue(
                status: .ready,
                source: .preview,
                measuredAt: now,
                lastAttemptAt: now,
                message: nil,
                value: CodexTokenTotals(
                    totalTokens: 100_000,
                    inputTokens: 90_000,
                    cachedInputTokens: 60_000,
                    outputTokens: 10_000,
                    reasoningTokens: 2_000,
                    sessionCount: 3
                )
            ),
            cursorCosts: UsageValue(
                status: .ready,
                source: .preview,
                measuredAt: now,
                lastAttemptAt: now,
                message: nil,
                value: CursorCostTotals(
                    todayCostUSD: 0.10,
                    recentEvents: [
                        CursorCostEvent(
                            id: "one",
                            occurredAt: now.addingTimeInterval(-180),
                            model: "claude-4.5-sonnet",
                            costUSD: 0.03,
                            tokenCount: 10_000,
                            kind: "Included"
                        ),
                        CursorCostEvent(
                            id: "two",
                            occurredAt: now.addingTimeInterval(-760),
                            model: "gpt-5.6",
                            costUSD: 0.07,
                            tokenCount: 20_000,
                            kind: "On-demand"
                        ),
                        CursorCostEvent(
                            id: "three",
                            occurredAt: now.addingTimeInterval(-1_500),
                            model: "auto",
                            costUSD: 0,
                            tokenCount: 5_000,
                            kind: "Included"
                        )
                    ]
                )
            ),
            cursorQuota: UsageValue(
                status: .ready,
                source: .preview,
                measuredAt: now,
                lastAttemptAt: now,
                message: nil,
                value: CompactQuota(
                    label: "Cursor Monthly",
                    used: nil,
                    limit: nil,
                    remaining: 50,
                    remainingPercent: 50,
                    resetAt: Calendar.current.date(byAdding: .day, value: 1, to: now),
                    windowSeconds: 31 * 86_400,
                    detail: "Demo data · no account values"
                )
            ),
            codexQuota: UsageValue(
                status: .ready,
                source: .preview,
                measuredAt: now,
                lastAttemptAt: now,
                message: nil,
                value: CompactQuota(
                    label: "Codex Week",
                    used: nil,
                    limit: nil,
                    remaining: nil,
                    remainingPercent: 60,
                    resetAt: Calendar.current.date(byAdding: .day, value: 3, to: now),
                    windowSeconds: 604_800,
                    detail: "Demo data · 60% left"
                )
            ),
            claudeTokens: UsageValue(
                status: .ready,
                source: .preview,
                measuredAt: now,
                lastAttemptAt: now,
                message: nil,
                value: ClaudeTokenTotals(
                    totalTokens: 250_000,
                    inputTokens: 20_000,
                    cacheCreationTokens: 30_000,
                    cacheReadTokens: 190_000,
                    outputTokens: 10_000,
                    costUSD: 0.42
                )
            ),
            claudeQuota: UsageValue(
                status: .ready,
                source: .preview,
                measuredAt: now,
                lastAttemptAt: now,
                message: nil,
                value: CompactQuota(
                    label: "Claude 5h",
                    used: nil,
                    limit: nil,
                    remaining: nil,
                    remainingPercent: 72,
                    resetAt: now.addingTimeInterval(2 * 3_600 + 15 * 60),
                    windowSeconds: 18_000,
                    detail: "Demo data · 72% left",
                    windows: [
                        CompactQuota(label: "Claude 5h", used: nil, limit: nil, remaining: nil, remainingPercent: 72,
                                     resetAt: now.addingTimeInterval(2 * 3_600 + 15 * 60), windowSeconds: 18_000,
                                     detail: "72% left"),
                        CompactQuota(label: "Claude Week", used: nil, limit: nil, remaining: nil, remainingPercent: 88,
                                     resetAt: now.addingTimeInterval(3 * 86_400 + 5 * 3_600), windowSeconds: 604_800,
                                     detail: "88% left"),
                        CompactQuota(label: "Claude Fable Week", used: nil, limit: nil, remaining: nil,
                                     remainingPercent: 95, resetAt: now.addingTimeInterval(3 * 86_400 + 5 * 3_600),
                                     windowSeconds: 604_800, detail: "95% left"),
                    ]
                )
            ),
            deepseekUsage: UsageValue(
                status: .ready,
                source: .preview,
                measuredAt: now,
                lastAttemptAt: now,
                message: nil,
                value: DeepSeekUsageTotals(
                    monthTokens: 2_400_000,
                    monthRequests: 128,
                    monthCosts: [DeepSeekMoney(currency: "USD", amount: 1.24)],
                    balances: [DeepSeekMoney(currency: "USD", amount: 18.76)],
                    grantedBalances: [DeepSeekMoney(currency: "USD", amount: 3.00)],
                    totalCosts: [DeepSeekMoney(currency: "USD", amount: 7.80)]
                )
            )
        )
    }()
}
