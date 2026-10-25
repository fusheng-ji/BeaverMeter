import Foundation
import XCTest

final class WidgetProviderPresentationTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-26T12:00:00Z")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }
    private var totals: CodexTokenTotals {
        CodexTokenTotals(totalTokens: 100, inputTokens: 80, cachedInputTokens: 60,
                         outputTokens: 20, reasoningTokens: 10, sessionCount: 3)
    }
    private var dates: [Date] {
        (-6...0).map { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: now))! }
    }

    private func reading<T: Codable & Hashable & Sendable>(
        _ value: T?, at date: Date? = nil, status: UsageDataStatus = .ready,
        source: UsageDataSource = .accountAPI
    ) -> UsageValue<T> {
        UsageValue(status: status, source: source, measuredAt: date ?? now,
                   lastAttemptAt: now, message: nil, value: value)
    }

    private func quota(_ percent: Double?, label: String = "Codex 5h", seconds: Int = 18_000,
                       windows: [CompactQuota]? = nil, planName: String? = nil) -> CompactQuota {
        CompactQuota(planName: planName, label: label, used: nil, limit: nil, remaining: nil, remainingPercent: percent,
                     resetAt: now.addingTimeInterval(3_600), windowSeconds: seconds,
                     detail: "Quota fixture", windows: windows)
    }

    private func account(_ name: String, quota: UsageValue<CompactQuota>, cards: ResetCardInventory? = nil,
                         cardReading: UsageValue<ResetCardInventory>? = nil, planName: String? = "Pro") -> CodexAccountUsage {
        CodexAccountUsage(id: name, homeID: name, displayName: name, quota: quota,
                          resetCards: cardReading ?? cards.map { reading($0) } ?? .unavailable("No cards"),
                          workspaceName: name, planName: planName)
    }

    private func history(_ dates: [Date]? = nil, timeZone: String? = nil,
                         status: UsageDataStatus = .ready,
                         todayTotals: CodexTokenTotals? = nil) -> UsageValue<TokenHistory<CodexTokenTotals>> {
        let totals = todayTotals ?? self.totals
        let days = (dates ?? self.dates).map { date in
            TokenHistoryDay(date: date, totals: calendar.isDate(date, inSameDayAs: now)
                            ? totals : CodexTokenTotals(totalTokens: 0, inputTokens: 0, cachedInputTokens: 0,
                                                       outputTokens: 0, reasoningTokens: 0, sessionCount: 0))
        }
        return reading(TokenHistory(sourceID: "all-configured-logs", timeZoneIdentifier: timeZone ?? calendar.timeZone.identifier,
                                    days: days, totals: totals), status: status, source: .codexBarLocal)
    }

    private func snapshot(
        codexTokens: UsageValue<CodexTokenTotals>? = nil, claudeTokens: UsageValue<ClaudeTokenTotals>? = nil,
        codexQuota: UsageValue<CompactQuota>? = nil, claudeQuota: UsageValue<CompactQuota>? = nil,
        cursorQuota: UsageValue<CompactQuota>? = nil,
        cursorCosts: UsageValue<CursorCostTotals>? = nil, deepseek: UsageValue<DeepSeekUsageTotals>? = nil,
        accounts: [CodexAccountUsage]? = nil, codexHistory: UsageValue<TokenHistory<CodexTokenTotals>>? = nil,
        claudeHistory: UsageValue<TokenHistory<ClaudeTokenTotals>>? = nil,
        claudeCards: UsageValue<ResetCardInventory>? = nil
    ) -> UsageSnapshot {
        let base = UsageSnapshot.preview
        return UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion, generatedAt: now,
            codexTokens: codexTokens ?? reading(totals, source: .codexBarLocal),
            cursorCosts: cursorCosts ?? base.cursorCosts, cursorQuota: cursorQuota ?? base.cursorQuota,
            codexQuota: codexQuota ?? reading(quota(75)),
            claudeTokens: claudeTokens ?? base.claudeTokens, claudeQuota: claudeQuota ?? base.claudeQuota,
            deepseekUsage: deepseek ?? base.deepseekUsage,
            codexAccounts: accounts.map { reading($0) } ?? .unavailable("No accounts"),
            codexHistory: codexHistory ?? .unavailable("No history"),
            claudeHistory: claudeHistory ?? .unavailable("No history"),
            claudeResetCards: claudeCards ?? .unavailable("No cards")
        )
    }

    private func present(_ snapshot: UsageSnapshot, _ provider: MeterProvider) -> WidgetProviderPresentation {
        WidgetProviderPresentation(snapshot: snapshot, provider: provider, referenceDate: now, calendar: calendar)
    }

    func testCodexUsesOnlyFirstWorkspacesQuotaWindows() {
        let weekly = quota(35, label: "Codex Week", seconds: 604_800)
        let primary = quota(80, windows: [quota(80), weekly])
        let cards = ResetCardInventory(availableCount: 2, observedAt: now, batches: [])
        let accounts = [account("Personal", quota: reading(primary), cards: cards),
                        account("Work", quota: reading(quota(5)))]
        let model = present(snapshot(codexQuota: reading(quota(10)), accounts: accounts), .codex)
        XCTAssertEqual(model.value, "80%")
        XCTAssertEqual(model.compactValue, "80%")
        XCTAssertEqual(model.period, "5h")
        XCTAssertEqual(model.windows.map(\.percent), ["35%"])
        XCTAssertEqual(model.windows.map(\.label), ["Weekly"])
        XCTAssertTrue(model.valueDescription.contains("Personal"))
        XCTAssertFalse(model.valueDescription.contains("Reset cards"))
        XCTAssertEqual(accounts.first?.resetCards.value?.count(at: now), 2)
        XCTAssertFalse(model.valueDescription.contains("Work"))
    }

    func testOrdinaryCodexCardPreservesTopLevelFallbackWithoutBorrowingSecondAccount() {
        let cards = ResetCardInventory(availableCount: 0, observedAt: now, batches: [])
        let accounts = [account("Signed out", quota: .unavailable("Sign in"), cards: cards),
                        account("Other", quota: reading(quota(99)))]
        let model = present(snapshot(codexQuota: reading(quota(12)), accounts: accounts), .codex)
        XCTAssertEqual(model.value, "12%")
        XCTAssertTrue(model.windows.isEmpty)
        XCTAssertEqual(accounts.first?.resetCards.value?.count(at: now), 0)
        XCTAssertFalse(model.valueDescription.contains("Other"))
    }

    func testExplicitCodexAccountNeverFallsBackOnQuotaFailure() {
        let cards = ResetCardInventory(availableCount: 1, observedAt: now, batches: [
            ResetCardBatch(id: "own", count: 1, startsAt: nil, expiresAt: now.addingTimeInterval(3_600))])
        let failed = account("Failed", quota: .unavailable("Sign in"), cards: cards)
        let model = WidgetProviderPresentation(codexAccount: failed, referenceDate: now, calendar: calendar)
        XCTAssertEqual(model.value, "—")
        XCTAssertNil(model.reset)
        XCTAssertTrue(model.windows.isEmpty)
        XCTAssertEqual(failed.resetCards.value?.count(at: now), 1)
        XCTAssertFalse(model.valueDescription.contains("Reset cards"))
        XCTAssertEqual(model.status.severity, .warning)
    }

    func testExplicitCodexPlanUsesNormalizedAccountMetadataThenItsOwnQuota() {
        for (accountPlan, quotaPlan, expected) in [
            (" \nTeam\t", "Quota Plus", "Team"),
            (nil, " \nPlus\t", "Plus"),
            (" \n\t", "Pro", "Pro"),
            (nil, " \n\t", nil)
        ] as [(String?, String?, String?)] {
            let own = account("Personal", quota: reading(quota(60, planName: quotaPlan)), planName: accountPlan)
            let model = WidgetProviderPresentation(codexAccount: own, referenceDate: now)
            XCTAssertEqual(model.planName, expected)
            if let expected { XCTAssertTrue(model.valueDescription.contains(" · \(expected) · ")) }
        }
    }

    func testExplicitWorkspacePlanSurvivesQuotaFailureWithoutBorrowingOtherSources() {
        let known = account("Known", quota: reading(nil, status: .error), planName: " Enterprise ")
        let knownModel = WidgetProviderPresentation(codexAccount: known, referenceDate: now)
        XCTAssertEqual(knownModel.planName, "Enterprise")
        XCTAssertEqual(knownModel.value, "—")
        XCTAssertEqual(knownModel.status.severity, .critical)
        XCTAssertTrue(knownModel.valueDescription.contains("Enterprise"))

        let missing = account("Personal Plus", quota: .unavailable("Sign in"), planName: nil)
        let sibling = account("Other", quota: reading(quota(10, planName: "Sibling quota")), planName: "Sibling account")
        let source = snapshot(codexQuota: reading(quota(99, planName: "Ambient")), accounts: [missing, sibling])
        let explicit = WidgetProviderPresentation(codexAccount: source.codexAccounts.value![0], referenceDate: now)
        XCTAssertNil(explicit.planName)
        XCTAssertEqual(explicit.value, "—")
        XCTAssertFalse(explicit.valueDescription.contains("Ambient"))
        XCTAssertFalse(explicit.valueDescription.contains("Sibling"))
    }

    func testOrdinaryCodexPlanUsesFirstAccountThenSelectedQuotaWithExistingAmbientFallback() {
        let ambient = reading(quota(75, planName: "Ambient"))
        let ownQuota = reading(quota(60, planName: "Own quota"))
        for (first, expected, value) in [
            (account("First", quota: ownQuota, planName: " Registry "), "Registry", "60%"),
            (account("First", quota: ownQuota, planName: nil), "Own quota", "60%"),
            (account("First", quota: ownQuota, planName: " \n"), "Own quota", "60%"),
            (account("First", quota: .unavailable("Sign in"), planName: " Registry "), "Registry", "75%"),
            (account("First", quota: .unavailable("Sign in"), planName: nil), "Ambient", "75%")
        ] {
            let model = present(snapshot(codexQuota: ambient, accounts: [first]), .codex)
            XCTAssertEqual(model.planName, expected)
            XCTAssertEqual(model.value, value)
        }
        XCTAssertEqual(present(snapshot(codexQuota: ambient), .codex).planName, "Ambient")

        let nameless = account("First", quota: reading(quota(60)), planName: nil)
        let sibling = account("Second", quota: ownQuota, planName: "Sibling")
        XCTAssertNil(present(snapshot(codexQuota: ambient, accounts: [nameless, sibling]), .codex).planName)
    }

    func testClaudeAndCursorPlansComeOnlyFromNormalizedQuotaMetadata() {
        let weekly = quota(80, label: "Claude Week", seconds: 604_800)
        let claudeQuota = quota(60, label: "Claude 5h", windows: [weekly], planName: " \nMax 20x\t")
        let claude = present(snapshot(claudeQuota: reading(claudeQuota)), .claude)
        XCTAssertEqual(claude.period, "Weekly")
        XCTAssertEqual(claude.planName, "Max 20x")
        XCTAssertTrue(claude.valueDescription.contains("Max 20x"))

        let cursorQuota = CompactQuota(planName: " Ultra ", label: "Cursor Monthly", used: 140, limit: 200,
                                       remaining: 60, remainingPercent: 30, resetAt: now.addingTimeInterval(3_600),
                                       windowSeconds: 31 * 86_400, detail: "Price does not determine the plan")
        let cursor = present(snapshot(cursorQuota: reading(cursorQuota)), .cursor)
        XCTAssertEqual(cursor.planName, "Ultra")
        XCTAssertTrue(cursor.valueDescription.contains("Ultra"))
        XCTAssertFalse(cursor.valueDescription.contains("US$140"))
        XCTAssertNil(present(snapshot(), .deepseek).planName)
    }

    func testMissingAndBlankPlansAreNotInferredFromNamesLabelsOrPrices() {
        let named = account("Personal Plus", quota: reading(quota(60, label: "Pro allowance")), planName: " \n")
        XCTAssertNil(WidgetProviderPresentation(codexAccount: named, referenceDate: now).planName)
        for planName in [nil, "", " \n\t"] as [String?] {
            let claude = quota(60, label: "Claude Max", planName: planName)
            let cursor = CompactQuota(planName: planName, label: "Cursor Ultra", used: 100, limit: 200,
                                      remaining: 100, remainingPercent: 50, resetAt: nil,
                                      windowSeconds: nil, detail: "US$100 / US$200")
            XCTAssertNil(present(snapshot(claudeQuota: reading(claude)), .claude).planName)
            XCTAssertNil(present(snapshot(cursorQuota: reading(cursor)), .cursor).planName)
        }
    }

    func testClaudeLeadsWithAllModelWeeklyAndOnlyKeepsFiveHoursSecondary() {
        let base = UsageSnapshot.preview
        let model = WidgetProviderPresentation(snapshot: base, provider: .claude,
                                               referenceDate: UsageSnapshot.previewDate)
        XCTAssertEqual(model.value, "88%")
        XCTAssertEqual(model.period, "Weekly")
        XCTAssertEqual(model.windows.map(\.label), ["5-hour"])
        XCTAssertEqual(model.windows.map(\.percent), ["72%"])
        XCTAssertEqual(model.reset, UsageFormatting.resetCountdown(base.claudeQuota.value?.windows?[1].resetAt,
                                                                 relativeTo: UsageSnapshot.previewDate))
        XCTAssertEqual(base.claudeQuota.value?.label, "Claude 5h", "The stored quota stays unchanged.")
        XCTAssertFalse(model.valueDescription.contains("Fable"))
    }

    func testSecondaryWindowsExcludeModelWeeksRepeatedPrimaryAndOtherDurations() {
        let modelWeek = quota(1, label: "Claude Fable Week", seconds: 604_800)
        let daily = quota(2, label: "Daily", seconds: 86_400)
        let repeatedPrimary = quota(3, label: "Another 5h", seconds: 18_000)
        let weekly = quota(40, label: "Codex Week", seconds: 604_800)
        let anotherWeekly = quota(50, label: "Another Week", seconds: 604_800)
        let primary = quota(80, windows: [modelWeek, daily, repeatedPrimary, weekly, anotherWeekly])
        let model = present(snapshot(codexQuota: reading(primary)), .codex)
        XCTAssertEqual(model.windows.map(\.label), ["Weekly"])
        XCTAssertEqual(model.windows.map(\.percent), ["40%"])
        let explicit = WidgetProviderPresentation(codexAccount: account("Own", quota: reading(primary)),
                                                  referenceDate: now, calendar: calendar)
        XCTAssertEqual(explicit.windows.map(\.percent), ["40%"])

        let weeklyPrimary = quota(70, label: "Codex Week", seconds: 604_800,
                                  windows: [weekly, anotherWeekly, daily, quota(25), repeatedPrimary])
        XCTAssertEqual(present(snapshot(codexQuota: reading(weeklyPrimary)), .codex).windows.map(\.percent), ["25%"])
        let noPrincipalWindow = quota(80, windows: [modelWeek, daily, repeatedPrimary])
        XCTAssertTrue(present(snapshot(codexQuota: reading(noPrincipalWindow)), .codex).windows.isEmpty)
    }

    func testUnavailableKeyWindowValuesRemainUnknownWithoutInventedResetDate() {
        let weekly = CompactQuota(label: "Codex Week", used: nil, limit: nil, remaining: nil,
                                  remainingPercent: nil, resetAt: nil, windowSeconds: 604_800, detail: "Unknown")
        let model = present(snapshot(codexQuota: reading(quota(0, windows: [weekly]))), .codex)
        XCTAssertEqual(model.value, "0%")
        XCTAssertEqual(model.windows.first?.percent, "—")
        XCTAssertEqual(model.windows.first?.reset, "Reset unavailable")
    }

    func testHiddenActivityFailuresAndOldReadingsCannotPolluteQuotaStatusOrDescriptions() {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let brokenCodex = UsageValue<CodexTokenTotals>(status: .error, source: .cache, measuredAt: yesterday,
                                                     lastAttemptAt: now, message: "hidden activity failure", value: totals)
        let claudeTotals = ClaudeTokenTotals(totalTokens: 999, inputTokens: 1, cacheCreationTokens: 1,
                                             cacheReadTokens: 996, outputTokens: 1, costUSD: 123)
        let brokenClaude = reading(claudeTotals, at: yesterday, status: .error, source: .cache)
        let brokenCosts = reading(CursorCostTotals(todayCostUSD: 123, recentEvents: [
            CursorCostEvent(id: "hidden", occurredAt: yesterday, model: "hidden-model", costUSD: 100,
                            tokenCount: 999, kind: nil)]), at: yesterday, status: .error, source: .cache)
        let snapshot = snapshot(codexTokens: brokenCodex, claudeTokens: brokenClaude, cursorCosts: brokenCosts,
                                codexHistory: history(status: .error))
        for provider in [MeterProvider.codex, .claude, .cursor] {
            let model = present(snapshot, provider)
            XCTAssertEqual(model.status.severity, .normal)
            XCTAssertFalse(model.status.detail.contains("hidden activity failure"))
            for removed in ["Sessions", "Today", "API estimate", "7d", "Month cost", "hidden-model", "123.00"] {
                XCTAssertFalse(model.valueDescription.contains(removed), "\(provider): \(removed)")
            }
        }
    }

    func testQuotaReadFailureStillControlsStatusWhileActivityIsHealthy() {
        let model = present(snapshot(codexQuota: reading(quota(40), status: .error)), .codex)
        XCTAssertEqual(model.value, "40%")
        XCTAssertEqual(model.status.severity, .critical)
    }

    func testHiddenResetCardFailuresCannotPolluteQuotaStatusOrDescription() {
        let zero = ResetCardInventory(availableCount: 0, observedAt: now, batches: [])
        let unknown: UsageValue<ResetCardInventory> = .unavailable("No card feature")
        let stale = reading(zero, status: .stale, source: .cache)
        let error = UsageValue<ResetCardInventory>(status: .error, source: .accountAPI, measuredAt: now,
            lastAttemptAt: now, message: "hidden card failure", value: nil)
        let signedOut = reading(zero, status: .unauthenticated, source: .cache)
        for cards in [unknown, stale, error, signedOut] {
            let own = account("Own", quota: reading(quota(80)), cardReading: cards)
            let models = [present(snapshot(accounts: [own]), .codex),
                          WidgetProviderPresentation(codexAccount: own, referenceDate: now),
                          present(snapshot(claudeCards: cards), .claude)]
            for model in models {
                XCTAssertEqual(model.status.severity, .normal)
                XCTAssertFalse(model.status.detail.contains("hidden card failure"))
                XCTAssertFalse(model.valueDescription.contains("hidden card failure"))
                XCTAssertFalse(model.valueDescription.contains("Reset cards"))
            }
        }
    }

    func testQuotaFailuresControlStatusIndependentlyOfHiddenCardReadings() {
        for status in [UsageDataStatus.stale, .error, .unauthenticated] {
            let cards = ResetCardInventory(availableCount: 2, observedAt: now, batches: [])
            let failedQuota = reading(quota(40), status: status, source: status == .stale ? .cache : .accountAPI)
            let own = account("Own", quota: failedQuota, cards: cards)
            let explicit = WidgetProviderPresentation(codexAccount: own, referenceDate: now)
            let ordinary = present(snapshot(accounts: [own]), .codex)
            let claude = present(snapshot(claudeQuota: failedQuota, claudeCards: reading(cards)), .claude)
            let expected = UsageStatusPresentation(failedQuota, relativeTo: now).severity
            XCTAssertEqual(explicit.status.severity, expected)
            XCTAssertEqual(ordinary.status.severity, expected)
            XCTAssertEqual(claude.status.severity, expected)
        }
    }

    func testCursorOnlyProjectsMonthlyRemainingAndReset() {
        let quota = CompactQuota(label: "Cursor Monthly", used: 20, limit: 100, remaining: 80,
                                 remainingPercent: 80, resetAt: now.addingTimeInterval(86_400),
                                 windowSeconds: 31 * 86_400, detail: "Plan and activity must stay hidden")
        let source = snapshot(cursorQuota: reading(quota))
        let model = present(source, .cursor)
        XCTAssertEqual(model.value, "$80.00")
        XCTAssertEqual(model.period, "Monthly")
        XCTAssertEqual(model.reset, "Resets in 1d 0h")
        XCTAssertTrue(model.windows.isEmpty)
        XCTAssertFalse(model.valueDescription.contains("Plan"))
        XCTAssertFalse(model.valueDescription.contains("US$20"))
        XCTAssertFalse(model.valueDescription.contains("US$100"))
        XCTAssertEqual(source.cursorQuota.value?.used, 20)
        XCTAssertEqual(source.cursorQuota.value?.limit, 100)
    }

    func testCursorUnknownAmountsStayUnknownAndKnownZeroIsShown() {
        let zero = CompactQuota(label: "Cursor", used: 0, limit: 0, remaining: 0,
                                remainingPercent: nil, resetAt: nil, windowSeconds: nil, detail: "")
        let model = present(snapshot(cursorQuota: reading(zero)), .cursor)
        XCTAssertEqual(model.value, "$0.00")
        XCTAssertNil(model.reset)
        let unknown = CompactQuota(label: "Cursor", used: 0, limit: nil, remaining: .nan,
                                   remainingPercent: nil, resetAt: nil, windowSeconds: nil, detail: "")
        let missing = present(snapshot(cursorQuota: reading(unknown)), .cursor)
        XCTAssertEqual(missing.value, "—")
        XCTAssertEqual(missing.compactValue, "—")
    }

    func testDeepSeekOnlyUsesFirstValidCurrencyBalanceWithoutSummingOrActivity() {
        let usage = DeepSeekUsageTotals(monthTokens: 999, monthRequests: 999,
                                        monthCosts: [DeepSeekMoney(currency: "USD", amount: 1_234.5)],
                                        balances: [DeepSeekMoney(currency: "", amount: 1),
                                                   DeepSeekMoney(currency: "EUR", amount: .infinity),
                                                   DeepSeekMoney(currency: "USD", amount: 12_345),
                                                   DeepSeekMoney(currency: "CNY", amount: 600)],
                                        grantedBalances: [DeepSeekMoney(currency: "USD", amount: 3)],
                                        totalCosts: [DeepSeekMoney(currency: "USD", amount: 70)])
        let model = present(snapshot(deepseek: reading(usage)), .deepseek)
        XCTAssertEqual(model.value, "$12,345.00")
        XCTAssertEqual(model.compactValue, "$12.3K")
        XCTAssertEqual(model.period, "Balance")
        XCTAssertEqual(model.status.severity, .normal)
        XCTAssertNil(model.reset)
        XCTAssertTrue(model.windows.isEmpty)
        for removed in ["CNY", "600", "Granted", "Total cost", "Month", "999", "1,234.50"] {
            XCTAssertFalse(model.valueDescription.contains(removed), removed)
        }
    }

    func testCompactMoneyPreservesCurrencyForThousandsMillionsAndBillions() {
        for (currency, amount, expected) in [("USD", 12_345.0, "$12.3K"),
                                              ("EUR", 1_234_567.0, "€1.2M"),
                                              ("CNY", 1_234_567_890.0, "CN¥1.2B")] {
            let usage = DeepSeekUsageTotals(monthTokens: nil, monthRequests: nil, monthCosts: [],
                                            balances: [DeepSeekMoney(currency: currency, amount: amount)],
                                            grantedBalances: [], totalCosts: [])
            let model = present(snapshot(deepseek: reading(usage)), .deepseek)
            XCTAssertEqual(model.compactValue, expected)
            XCTAssertNotEqual(model.value, model.compactValue)
            XCTAssertTrue(model.valueDescription.contains(model.value))
        }
    }

    func testNarrowMoneyFallbackReducesPrecisionWithoutChangingTheExactValue() {
        let usage = DeepSeekUsageTotals(monthTokens: nil, monthRequests: nil, monthCosts: [],
                                        balances: [DeepSeekMoney(currency: "USD", amount: 690.20)],
                                        grantedBalances: [], totalCosts: [])
        let model = present(snapshot(deepseek: reading(usage)), .deepseek)
        XCTAssertEqual(model.value, "$690.20")
        XCTAssertEqual(model.compactValue, "$690")
        XCTAssertTrue(model.valueDescription.contains("$690.20"))
    }

    func testHiddenResetInventoryAndExpiryRemainInTheirSourceSnapshots() {
        let firstExpiry = now.addingTimeInterval(86_400)
        let otherExpiry = now.addingTimeInterval(3_600)
        let firstCards = ResetCardInventory(availableCount: 2, observedAt: now, batches: [
            ResetCardBatch(id: "personal-card", count: 2, startsAt: nil, expiresAt: firstExpiry)])
        let otherCards = ResetCardInventory(availableCount: 9, observedAt: now, batches: [
            ResetCardBatch(id: "other-card", count: 9, startsAt: nil, expiresAt: otherExpiry)])
        let source = snapshot(accounts: [account("Personal", quota: reading(quota(60)), cards: firstCards),
                                         account("Work", quota: reading(quota(20)), cards: otherCards)],
                              claudeCards: reading(firstCards))
        for provider in MeterProvider.allCases {
            let model = present(source, provider)
            XCTAssertFalse(model.valueDescription.contains("Reset cards"))
            XCTAssertFalse(model.valueDescription.contains("expiry"))
            XCTAssertFalse(model.valueDescription.contains("personal-card"))
            XCTAssertFalse(model.valueDescription.contains("other-card"))
        }
        XCTAssertEqual(source.codexAccounts.value?.map { $0.resetCards.value?.count(at: now) }, [2, 9])
        XCTAssertEqual(source.codexAccounts.value?.first?.resetCards.value?.availableBatches(at: now).first?.expiresAt,
                       firstExpiry)
        XCTAssertEqual(source.codexAccounts.value?.last?.resetCards.value?.availableBatches(at: now).first?.expiresAt,
                       otherExpiry)
        XCTAssertEqual(source.claudeResetCards.value, firstCards)
    }

    func testResetInventoryPresenceAndExpiryNeverChangeQuotaDescriptions() {
        let inventories = [
            ResetCardInventory(availableCount: 0, observedAt: now, batches: []),
            ResetCardInventory(availableCount: 2, observedAt: now, batches: []),
            ResetCardInventory(availableCount: 1, observedAt: now.addingTimeInterval(-600), batches: [
                ResetCardBatch(id: "expired", count: 1, startsAt: nil, expiresAt: now.addingTimeInterval(-300))]),
            ResetCardInventory(availableCount: 1, observedAt: now, batches: [
                ResetCardBatch(id: "future", count: 1, startsAt: nil, expiresAt: now.addingTimeInterval(3_600))])
        ]
        let codexWithoutCards = present(snapshot(accounts: [account("Personal", quota: reading(quota(60)))]), .codex)
        let claudeWithoutCards = present(snapshot(), .claude)
        for cards in inventories {
            let codex = present(snapshot(accounts: [account("Personal", quota: reading(quota(60)), cards: cards)]), .codex)
            let claude = present(snapshot(claudeCards: reading(cards)), .claude)
            XCTAssertEqual(codex.valueDescription, codexWithoutCards.valueDescription)
            XCTAssertEqual(claude.valueDescription, claudeWithoutCards.valueDescription)
            XCTAssertEqual(codex.reset, codexWithoutCards.reset)
            XCTAssertEqual(claude.reset, claudeWithoutCards.reset)
        }
    }

    func testUnknownMoneyAndQuotaStayUnknownWhileKnownZeroIsRendered() {
        let unknownUsage = DeepSeekUsageTotals(monthTokens: nil, monthRequests: nil, monthCosts: [],
                                               balances: [], grantedBalances: [], totalCosts: [])
        let unknown = present(snapshot(deepseek: reading(unknownUsage)), .deepseek)
        XCTAssertEqual(unknown.value, "—")
        XCTAssertEqual(unknown.compactValue, "—")
        XCTAssertEqual(present(snapshot(codexQuota: reading(quota(nil))), .codex).value, "—")
        XCTAssertEqual(present(snapshot(codexQuota: reading(quota(0))), .codex).value, "0%")
        for (percent, expected) in [(Double.nan, "—"), (Double.infinity, "—"),
                                    (-1.0, "0%"), (101.0, "100%"), (74.6, "75%")] {
            XCTAssertEqual(present(snapshot(codexQuota: reading(quota(percent))), .codex).value, expected)
        }

        let zeroUsage = DeepSeekUsageTotals(monthTokens: 0, monthRequests: 0, monthCosts: [],
                                            balances: [DeepSeekMoney(currency: "USD", amount: 0)],
                                            grantedBalances: [], totalCosts: [])
        let zero = present(snapshot(deepseek: reading(zeroUsage)), .deepseek)
        XCTAssertEqual(zero.value, "$0.00")
        XCTAssertEqual(zero.compactValue, "$0.00")
    }
}
