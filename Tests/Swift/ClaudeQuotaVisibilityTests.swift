import Foundation
import XCTest

final class ClaudeQuotaVisibilityTests: XCTestCase {
    private let now = UsageSnapshot.previewDate

    func testAuthenticationWinsOverLegacyCachedValuesInStatusAndWidget() {
        let original = UsageSnapshot.preview.claudeQuota
        let denied = UsageValue(status: .unauthenticated, source: .cache, measuredAt: now,
                                lastAttemptAt: now, message: "Sign in again.", value: original.value)
        XCTAssertEqual(UsageStatusPresentation(denied, relativeTo: now).label, "Sign in")
        XCTAssertNil(ClaudeQuotaVisibility.quota(denied, relativeTo: now).value)
        var snapshot = UsageSnapshot.preview
        snapshot = replacingClaude(snapshot, quota: denied)
        let card = WidgetProviderPresentation(snapshot: snapshot, provider: .claude, referenceDate: now)
        XCTAssertEqual(card.value, "—")
        XCTAssertTrue(card.valueDescription.contains("Sign in"))
        XCTAssertFalse(card.valueDescription.contains("84%"))
    }

    func testCacheDeadlineUsesMeasurementNotLastAttemptAndIncludesReadySnapshots() {
        for status in [UsageDataStatus.ready, .stale] {
            for age in [1799.0, 1800.0, 86400.0] {
                let reading = UsageValue(status: status, source: .accountAPI,
                    measuredAt: now.addingTimeInterval(-age), lastAttemptAt: now,
                    message: nil, value: UsageSnapshot.preview.claudeQuota.value)
                XCTAssertEqual(ClaudeQuotaVisibility.quota(reading, relativeTo: now).value == nil, age >= 1800)
            }
        }
    }

    func testResetWindowsAreRemovedWithoutInventingNewAllowance() {
        let expired = quota(label: "Claude 5h", percent: 12, reset: now, seconds: 18000)
        let weekly = quota(label: "Claude Week", percent: 67, reset: now.addingTimeInterval(100), seconds: 604800)
        var summary = expired
        summary.windows = [expired, weekly]
        let reading = UsageValue(status: .stale, source: .cache, measuredAt: now.addingTimeInterval(-10),
                                  lastAttemptAt: now, message: "Offline", value: summary)
        let visible = ClaudeQuotaVisibility.quota(reading, relativeTo: now)
        XCTAssertEqual(visible.value?.remainingPercent, 67)
        XCTAssertEqual(visible.value?.windows?.map(\.label), ["Claude Week"])
        XCTAssertNil(ClaudeQuotaVisibility.quota(reading, relativeTo: now.addingTimeInterval(100)).value)
    }

    func testUnknownMeasurementIsHiddenAndPreviewIsDeterministic() {
        let original = UsageSnapshot.preview.claudeQuota
        let unknown = UsageValue(status: .stale, source: .cache, measuredAt: nil,
                                 lastAttemptAt: now, message: nil, value: original.value)
        XCTAssertNil(ClaudeQuotaVisibility.quota(unknown, relativeTo: now).value)
        XCTAssertEqual(ClaudeQuotaVisibility.quota(original, relativeTo: now.addingTimeInterval(86400)), original)
    }

    func testCardsDistinguishExpiredCacheFromRealZero() {
        let zero = ResetCardInventory(availableCount: 0, observedAt: now, batches: [])
        let recent = UsageValue(status: .ready, source: .accountAPI, measuredAt: now,
                                lastAttemptAt: now, message: nil, value: zero)
        XCTAssertEqual(ClaudeQuotaVisibility.resetCards(recent, relativeTo: now).value?.availableCount, 0)
        XCTAssertNil(ClaudeQuotaVisibility.resetCards(recent, relativeTo: now.addingTimeInterval(1800)).value)
        let signedOut = UsageValue(status: .unauthenticated, source: .cache, measuredAt: now,
                                   lastAttemptAt: now, message: "Sign in", value: zero)
        XCTAssertNil(ClaudeQuotaVisibility.resetCards(signedOut, relativeTo: now).value)
        let unknown: UsageValue<ResetCardInventory> = .unavailable("Inventory unavailable")
        XCTAssertNil(ClaudeQuotaVisibility.resetCards(unknown, relativeTo: now).value)
    }

    func testVisibleResetInventoryKeepsActiveBatchesAndExpiryForMenuDetails() {
        let soon = now.addingTimeInterval(60)
        let later = now.addingTimeInterval(120)
        let inventory = ResetCardInventory(availableCount: 5, observedAt: now, batches: [
            ResetCardBatch(id: "unknown", count: 1, startsAt: nil, expiresAt: nil),
            ResetCardBatch(id: "later", count: 1, startsAt: nil, expiresAt: later),
            ResetCardBatch(id: "already-expired", count: 1, startsAt: nil, expiresAt: now.addingTimeInterval(-1)),
            ResetCardBatch(id: "at-reference", count: 1, startsAt: nil, expiresAt: now),
            ResetCardBatch(id: "exhausted", count: 0, startsAt: nil, expiresAt: soon),
            ResetCardBatch(id: "soon", count: 2, startsAt: nil, expiresAt: soon)
        ])
        let reading = UsageValue(status: .ready, source: .accountAPI, measuredAt: now,
                                 lastAttemptAt: now, message: nil, value: inventory)
        let visible = ClaudeQuotaVisibility.resetCards(reading, relativeTo: now).value
        XCTAssertEqual(visible, inventory)
        XCTAssertEqual(visible?.count(at: now), 5)
        XCTAssertEqual(visible?.availableBatches(at: now).map(\.id), ["soon", "later", "unknown"])
        XCTAssertEqual(visible?.availableBatches(at: now).first?.expiresAt, soon)

        let afterExpiry = now.addingTimeInterval(60)
        let retained = ClaudeQuotaVisibility.resetCards(reading, relativeTo: afterExpiry).value
        XCTAssertEqual(retained?.count(at: afterExpiry), 3)
        XCTAssertEqual(retained?.availableBatches(at: afterExpiry).map(\.id), ["later", "unknown"])
    }

    func testWidgetExpirationEntriesCoverResetAndMeasurementDeadlines() {
        var value = quota(label: "Claude 5h", percent: 12, reset: now.addingTimeInterval(10), seconds: 18000)
        value.windows = [value, quota(label: "Claude Week", percent: 80,
                                      reset: now.addingTimeInterval(86400), seconds: 604800)]
        let reading = UsageValue(status: .ready, source: .accountAPI, measuredAt: now,
                                 lastAttemptAt: now, message: nil, value: value)
        let cards = UsageValue(status: .ready, source: .accountAPI, measuredAt: now.addingTimeInterval(-10),
                               lastAttemptAt: now, message: nil,
                               value: ResetCardInventory(availableCount: 0, observedAt: now, batches: []))
        let dates = ClaudeQuotaVisibility.expirationDates(quota: reading, cards: cards, after: now)
        XCTAssertEqual(dates, [now.addingTimeInterval(10), now.addingTimeInterval(1790), now.addingTimeInterval(1800)])
        XCTAssertNil(ClaudeQuotaVisibility.quota(reading, relativeTo: dates.last!).value)
        XCTAssertEqual(ClaudeQuotaVisibility.expirationDates(quota: UsageSnapshot.preview.claudeQuota,
            cards: UsageSnapshot.preview.claudeResetCards, after: now), [])
    }

    func testSameSecondAuthenticationChangeIsAdoptedWithoutAllowingOlderSnapshots() {
        let original = UsageSnapshot.preview
        let signedOut: UsageValue<CompactQuota> = .unavailable("Sign in again")
        let changed = replacingClaude(original, quota: signedOut)
        XCTAssertTrue(changed.supersedes(original))
        XCTAssertFalse(original.supersedes(original))
        let older = replacingClaude(original, quota: signedOut, generatedAt: now.addingTimeInterval(-1))
        XCTAssertFalse(older.supersedes(original))
    }

    private func quota(label: String, percent: Double, reset: Date, seconds: Int) -> CompactQuota {
        CompactQuota(label: label, used: nil, limit: nil, remaining: nil, remainingPercent: percent,
                     resetAt: reset, windowSeconds: seconds, detail: "")
    }

    private func replacingClaude(_ snapshot: UsageSnapshot, quota: UsageValue<CompactQuota>, generatedAt: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(schemaVersion: snapshot.schemaVersion, generatedAt: generatedAt ?? snapshot.generatedAt,
            codexTokens: snapshot.codexTokens, cursorCosts: snapshot.cursorCosts, cursorQuota: snapshot.cursorQuota,
            codexQuota: snapshot.codexQuota, claudeTokens: snapshot.claudeTokens, claudeQuota: quota,
            deepseekUsage: snapshot.deepseekUsage, codexAccounts: snapshot.codexAccounts,
            codexHistory: snapshot.codexHistory, claudeHistory: snapshot.claudeHistory,
            claudeResetCards: snapshot.claudeResetCards)
    }
}
