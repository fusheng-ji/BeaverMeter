import Foundation

enum UsagePreviewScenario: String, CaseIterable {
    case normal, stale, unavailable, signedOut, error, refreshError, zero, largeValues, remoteUnavailable, longList
    case oneService, codexClaudeOnly, withoutCursor, rateLimited, longWindows
    case missingHistory, previousDay, claudeSignedOut, claudeExpiredCache

    /// Service switches for layouts with fewer than four services.
    var providerSettings: ProviderSettings {
        var settings = ProviderSettings.default
        switch self {
        case .oneService:
            settings[.codex] = .hidden
            settings[.cursor] = .hidden
            settings[.deepseek] = .hidden
        case .codexClaudeOnly:
            settings[.cursor] = .hidden
            settings[.deepseek] = .hidden
        case .withoutCursor:
            settings[.cursor] = .hidden
        default:
            break
        }
        return settings
    }

    var snapshot: UsageSnapshot {
        let base = UsageSnapshot.monitoringPreview
        let now = UsageSnapshot.previewDate
        switch self {
        case .normal, .oneService, .codexClaudeOnly, .withoutCursor: return base
        case .refreshError: return base
        case .rateLimited, .longWindows:
            var quota = base.claudeQuota.value!
            if self == .longWindows {
                var window = quota.otherWindows.last!
                window = CompactQuota(label: "Claude Very Long Model Display Name Week", used: nil, limit: nil,
                                      remaining: nil, remainingPercent: window.remainingPercent,
                                      resetAt: window.resetAt, windowSeconds: window.windowSeconds, detail: window.detail)
                let windows = quota.windows ?? []
                quota.windows = Array(windows.prefix(2)) + [window] + Array(windows.dropFirst(2))
            }
            let limited = self == .rateLimited
            let message = limited ? "Rate limited by Anthropic. Retry after Oct 2, 6:30 PM." : nil
            return UsageSnapshot(schemaVersion: base.schemaVersion, generatedAt: now,
                                 codexTokens: base.codexTokens, cursorCosts: base.cursorCosts, cursorQuota: base.cursorQuota,
                                 codexQuota: base.codexQuota, claudeTokens: base.claudeTokens,
                                 claudeQuota: UsageValue(status: limited ? .stale : .ready, source: limited ? .cache : .preview,
                                                        measuredAt: limited ? now.addingTimeInterval(-600) : now,
                                                        lastAttemptAt: now, message: message, value: quota),
                                 deepseekUsage: base.deepseekUsage,
                                 codexAccounts: base.codexAccounts,
                                 codexHistory: base.codexHistory, claudeHistory: base.claudeHistory,
                                 claudeResetCards: UsageValue(status: limited ? .stale : .ready, source: limited ? .cache : .preview,
                                                             measuredAt: now.addingTimeInterval(-600), lastAttemptAt: now,
                                                             message: message, value: UsageSnapshot.monitoringPreview.claudeResetCards.value))
        case .stale: return .widgetStalePreview
        case .signedOut: return .widgetDeepSeekSignedOutPreview
        case .claudeSignedOut, .claudeExpiredCache:
            let signedOut = self == .claudeSignedOut
            let message = signedOut ? "Claude sign-in expired and could not be renewed. Sign in again."
                : "Claude quota could not be refreshed."
            return UsageSnapshot(schemaVersion: base.schemaVersion, generatedAt: now,
                codexTokens: base.codexTokens, cursorCosts: base.cursorCosts, cursorQuota: base.cursorQuota,
                codexQuota: base.codexQuota, claudeTokens: base.claudeTokens,
                claudeQuota: UsageValue(status: signedOut ? .unauthenticated : .stale,
                    source: signedOut ? .none : .cache, measuredAt: now.addingTimeInterval(-1800),
                    lastAttemptAt: now, message: message, value: signedOut ? nil : base.claudeQuota.value),
                deepseekUsage: base.deepseekUsage, codexAccounts: base.codexAccounts,
                codexHistory: base.codexHistory, claudeHistory: base.claudeHistory,
                claudeResetCards: UsageValue(status: signedOut ? .unauthenticated : .stale,
                    source: signedOut ? .none : .cache, measuredAt: now.addingTimeInterval(-1800),
                    lastAttemptAt: now, message: message, value: signedOut ? nil : base.claudeResetCards.value))
        case .unavailable, .error:
            let status: UsageDataStatus = self == .error ? .error : .unavailable
            let message = self == .error ? "Could not refresh. Previous data was preserved." : "No usage data is available yet."
            return UsageSnapshot(
                schemaVersion: UsageSnapshot.currentSchemaVersion, generatedAt: now,
                codexTokens: empty(status, message: message), cursorCosts: empty(status, message: message),
                cursorQuota: empty(status, message: message), codexQuota: empty(status, message: message),
                claudeTokens: empty(status, message: message), claudeQuota: empty(status, message: message),
                deepseekUsage: empty(status, message: message)
            )
        case .remoteUnavailable:
            return replacing(base, codexTokens: UsageValue(
                status: .stale, source: .cache, measuredAt: now.addingTimeInterval(-120), lastAttemptAt: now,
                message: "Remote Codex is unavailable. Today's cached remote usage is included.",
                value: base.codexTokens.value
            ))
        case .zero:
            return replacing(base, codexTokens: UsageValue(
                status: .ready, source: .preview, measuredAt: now, lastAttemptAt: now,
                message: nil,
                value: CodexTokenTotals(totalTokens: 0, inputTokens: 0, cachedInputTokens: 0,
                                        outputTokens: 0, reasoningTokens: 0, sessionCount: 0)
            ))
        case .largeValues:
            return replacing(.widgetDeepSeekLongValuePreview, codexTokens: UsageValue(
                status: .ready, source: .preview, measuredAt: now, lastAttemptAt: now, message: nil,
                value: CodexTokenTotals(totalTokens: 9_876_543_210, inputTokens: 9_800_000_000,
                                       cachedInputTokens: 7_654_321_000, outputTokens: 76_543_210,
                                       reasoningTokens: 12_345_678, sessionCount: 128)
            ))
        case .longList:
            return replacing(base, cursorCosts: UsageValue(
                status: .ready, source: .preview, measuredAt: now, lastAttemptAt: now, message: nil,
                value: CursorCostTotals(todayCostUSD: 0.42, recentEvents: (0..<20).map { index in
                    CursorCostEvent(id: "preview-\(index)", occurredAt: now.addingTimeInterval(Double(-index * 180)),
                                    model: index.isMultiple(of: 2) ? "claude-long-model-name-thinking-preview" : "gpt-5.6",
                                    costUSD: 0.021, tokenCount: 120_000 + index, kind: "On-demand")
                })
            ))
        case .missingHistory:
            var snapshot = base
            snapshot.codexHistory = empty(.unavailable, message: "No seven-day Codex history yet.")
            snapshot.claudeHistory = empty(.unavailable, message: "No seven-day Claude history yet.")
            return snapshot
        case .previousDay:
            // A preview source bypasses the daily expiry policy, so cached
            // readings deliberately use yesterday's date and a real cache source.
            let measuredAt = now.addingTimeInterval(-86_400)
            let message = "Today's usage is awaiting refresh; the previous reading is from yesterday."
            var snapshot = replacing(base,
                codexTokens: UsageValue(status: .stale, source: .cache, measuredAt: measuredAt,
                                        lastAttemptAt: now, message: message, value: base.codexTokens.value),
                claudeTokens: UsageValue(status: .stale, source: .cache, measuredAt: measuredAt,
                                         lastAttemptAt: now, message: message, value: base.claudeTokens.value))
            snapshot.codexHistory = previousDayHistory(base.codexHistory)
            snapshot.claudeHistory = previousDayHistory(base.claudeHistory)
            return snapshot
        }
    }

    private func empty<Value>(_ status: UsageDataStatus, message: String) -> UsageValue<Value> {
        UsageValue(status: status, source: .none, measuredAt: nil, lastAttemptAt: UsageSnapshot.previewDate,
                   message: message, value: nil)
    }

    private func replacing(_ base: UsageSnapshot, codexTokens: UsageValue<CodexTokenTotals>? = nil,
                           cursorCosts: UsageValue<CursorCostTotals>? = nil,
                           claudeTokens: UsageValue<ClaudeTokenTotals>? = nil) -> UsageSnapshot {
        UsageSnapshot(schemaVersion: base.schemaVersion, generatedAt: base.generatedAt,
                      codexTokens: codexTokens ?? base.codexTokens, cursorCosts: cursorCosts ?? base.cursorCosts,
                      cursorQuota: base.cursorQuota, codexQuota: base.codexQuota,
                      claudeTokens: claudeTokens ?? base.claudeTokens, claudeQuota: base.claudeQuota,
                      deepseekUsage: base.deepseekUsage, codexAccounts: base.codexAccounts,
                      codexHistory: codexTokens?.value.map { updatingCodexToday(base.codexHistory, totals: $0) }
                          ?? base.codexHistory,
                      claudeHistory: base.claudeHistory,
                      claudeResetCards: base.claudeResetCards)
    }

    /// Keep the chart's final day and aggregate consistent with zero/large-value
    /// Today fixtures while retaining all six preceding history days.
    private func updatingCodexToday(_ data: UsageValue<TokenHistory<CodexTokenTotals>>,
                                    totals: CodexTokenTotals) -> UsageValue<TokenHistory<CodexTokenTotals>> {
        guard let history = data.value, let lastDay = history.days.last else { return data }
        let days = Array(history.days.dropLast()) + [TokenHistoryDay(date: lastDay.date, totals: totals)]
        let aggregate = CodexTokenTotals(
            totalTokens: days.reduce(0) { $0 + $1.totals.totalTokens },
            inputTokens: days.reduce(0) { $0 + $1.totals.inputTokens },
            cachedInputTokens: days.reduce(0) { $0 + $1.totals.cachedInputTokens },
            outputTokens: days.reduce(0) { $0 + $1.totals.outputTokens },
            reasoningTokens: days.reduce(0) { $0 + $1.totals.reasoningTokens },
            sessionCount: days.reduce(0) { $0 + $1.totals.sessionCount })
        return UsageValue(status: data.status, source: data.source, measuredAt: data.measuredAt,
                          lastAttemptAt: data.lastAttemptAt, message: data.message,
                          value: TokenHistory(sourceID: history.sourceID, timeZoneIdentifier: history.timeZoneIdentifier,
                                              days: days, totals: aggregate))
    }

    private func previousDayHistory<T: DailyTokenTotals>(_ data: UsageValue<TokenHistory<T>>) -> UsageValue<TokenHistory<T>> {
        let history = data.value.map { history in
            TokenHistory(sourceID: history.sourceID, timeZoneIdentifier: history.timeZoneIdentifier,
                         days: history.days.map { TokenHistoryDay(date: $0.date.addingTimeInterval(-86_400), totals: $0.totals) },
                         totals: history.totals)
        }
        return UsageValue(status: .stale, source: .cache,
                          measuredAt: UsageSnapshot.previewDate.addingTimeInterval(-86_400),
                          lastAttemptAt: UsageSnapshot.previewDate,
                          message: "Seven-day history is awaiting today's refresh.", value: history)
    }
}

extension UsageSnapshot {
    static var widgetStalePreview: UsageSnapshot {
        let base = monitoringPreview
        let measuredAt = previewDate.addingTimeInterval(-4 * 3_600)
        return UsageSnapshot(
            schemaVersion: currentSchemaVersion,
            generatedAt: previewDate,
            codexTokens: UsageValue(
                status: .stale, source: .cache, measuredAt: measuredAt, lastAttemptAt: previewDate,
                message: "Remote Codex is unavailable. Today's cached usage is included.", value: base.codexTokens.value
            ),
            cursorCosts: base.cursorCosts,
            cursorQuota: UsageValue(
                status: .stale,
                source: .cache,
                measuredAt: measuredAt,
                lastAttemptAt: previewDate,
                message: "Network unavailable.",
                value: base.cursorQuota.value
            ),
            codexQuota: UsageValue(
                status: .stale,
                source: .cache,
                measuredAt: measuredAt,
                lastAttemptAt: previewDate,
                message: "Network unavailable.",
                value: base.codexQuota.value
            ),
            claudeTokens: UsageValue(
                status: .stale, source: .cache, measuredAt: measuredAt, lastAttemptAt: previewDate,
                message: "Indexing Claude sessions; today's total may increase on the next refresh.",
                value: base.claudeTokens.value
            ),
            claudeQuota: UsageValue(
                status: .stale,
                source: .cache,
                measuredAt: measuredAt,
                lastAttemptAt: previewDate,
                message: "Network unavailable.",
                value: base.claudeQuota.value
            ),
            deepseekUsage: UsageValue(
                status: .stale,
                source: .cache,
                measuredAt: measuredAt,
                lastAttemptAt: previewDate,
                message: "Network unavailable.",
                value: base.deepseekUsage.value
            ),
            codexAccounts: base.codexAccounts,
            codexHistory: base.codexHistory, claudeHistory: base.claudeHistory,
            claudeResetCards: base.claudeResetCards
        )
    }

    static var widgetNoResetPreview: UsageSnapshot {
        let cursor = preview.cursorQuota.value
        let codex = preview.codexQuota.value
        return UsageSnapshot(
            schemaVersion: currentSchemaVersion,
            generatedAt: previewDate,
            codexTokens: preview.codexTokens,
            cursorCosts: preview.cursorCosts,
            cursorQuota: UsageValue(
                status: .ready,
                source: .cursorDashboard,
                measuredAt: previewDate,
                lastAttemptAt: previewDate,
                message: nil,
                value: cursor.map {
                    CompactQuota(
                        label: $0.label,
                        used: $0.used,
                        limit: $0.limit,
                        remaining: $0.remaining,
                        remainingPercent: $0.remainingPercent,
                        resetAt: nil,
                        windowSeconds: $0.windowSeconds,
                        detail: $0.detail
                    )
                }
            ),
            codexQuota: UsageValue(
                status: .ready,
                source: .accountAPI,
                measuredAt: previewDate,
                lastAttemptAt: previewDate,
                message: nil,
                value: codex.map {
                    CompactQuota(
                        label: $0.label,
                        used: $0.used,
                        limit: $0.limit,
                        remaining: $0.remaining,
                        remainingPercent: $0.remainingPercent,
                        resetAt: nil,
                        windowSeconds: $0.windowSeconds,
                        detail: $0.detail
                    )
                }
            ),
            claudeTokens: preview.claudeTokens,
            claudeQuota: UsageValue(
                status: .ready,
                source: .accountAPI,
                measuredAt: previewDate,
                lastAttemptAt: previewDate,
                message: nil,
                value: preview.claudeQuota.value.map {
                    CompactQuota(
                        label: $0.label,
                        used: $0.used,
                        limit: $0.limit,
                        remaining: $0.remaining,
                        remainingPercent: $0.remainingPercent,
                        resetAt: nil,
                        windowSeconds: $0.windowSeconds,
                        detail: $0.detail
                    )
                }
            ),
            deepseekUsage: preview.deepseekUsage
        )
    }

    static var widgetDeepSeekSignedOutPreview: UsageSnapshot {
        replacingDeepSeek(
            UsageValue(
                status: .unauthenticated,
                source: .none,
                measuredAt: nil,
                lastAttemptAt: previewDate,
                message: "Connect DeepSeek in your browser.",
                value: nil
            )
        )
    }

    static var widgetDeepSeekErrorPreview: UsageSnapshot {
        replacingDeepSeek(
            UsageValue(
                status: .error,
                source: .none,
                measuredAt: nil,
                lastAttemptAt: previewDate,
                message: "DeepSeek returned an unexpected response.",
                value: nil
            )
        )
    }

    static var widgetDeepSeekLongValuePreview: UsageSnapshot {
        replacingDeepSeek(
            UsageValue(
                status: .ready,
                source: .preview,
                measuredAt: previewDate,
                lastAttemptAt: previewDate,
                message: nil,
                value: DeepSeekUsageTotals(
                    monthTokens: 987_654_321,
                    monthRequests: 123_456,
                    monthCosts: [DeepSeekMoney(currency: "EUR", amount: 123_456.789),
                                 DeepSeekMoney(currency: "USD", amount: 1.24),
                                 DeepSeekMoney(currency: "CNY", amount: 2.30)],
                    balances: [DeepSeekMoney(currency: "EUR", amount: 1_234_567.89),
                               DeepSeekMoney(currency: "USD", amount: 18.76),
                               DeepSeekMoney(currency: "CNY", amount: 128.50)],
                    grantedBalances: [DeepSeekMoney(currency: "EUR", amount: 125.50),
                                      DeepSeekMoney(currency: "USD", amount: 3),
                                      DeepSeekMoney(currency: "CNY", amount: 8)],
                    totalCosts: [DeepSeekMoney(currency: "EUR", amount: 765_432.10),
                                 DeepSeekMoney(currency: "USD", amount: 7.80),
                                 DeepSeekMoney(currency: "CNY", amount: 44.30)]
                )
            )
        )
    }

    private static func replacingDeepSeek(_ value: UsageValue<DeepSeekUsageTotals>) -> UsageSnapshot {
        let base = UsageSnapshot.monitoringPreview
        return UsageSnapshot(
            schemaVersion: base.schemaVersion,
            generatedAt: base.generatedAt,
            codexTokens: base.codexTokens,
            cursorCosts: base.cursorCosts,
            cursorQuota: base.cursorQuota,
            codexQuota: base.codexQuota,
            claudeTokens: base.claudeTokens,
            claudeQuota: base.claudeQuota,
            deepseekUsage: value,
            codexAccounts: base.codexAccounts,
            codexHistory: base.codexHistory,
            claudeHistory: base.claudeHistory,
            claudeResetCards: base.claudeResetCards
        )
    }
}
