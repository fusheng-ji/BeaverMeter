import Foundation
import XCTest

final class UsageSnapshotTests: XCTestCase {
    func testVersionSevenSnapshotRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded = try XCTUnwrap(UsageSnapshot.decode(encoder.encode(UsageSnapshot.preview)))

        XCTAssertEqual(decoded.schemaVersion, 7)
        XCTAssertEqual(decoded.codexTokens.value?.totalTokens, 100_000)
        XCTAssertEqual(decoded.claudeTokens.value?.cacheReadTokens, 190_000)
        XCTAssertEqual(decoded.claudeQuota.value?.windowSeconds, 18_000)
        XCTAssertEqual(decoded.cursorCosts.value?.recentEvents.count, 3)
        XCTAssertNil(decoded.cursorQuota.value?.used)
        XCTAssertEqual(decoded.deepseekUsage.value?.monthTokens, 2_400_000)
    }

    func testVersionFiveSnapshotKeepsProviderValuesWithoutClaude() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(UsageSnapshot.preview)) as? [String: Any]
        )
        object["schemaVersion"] = 5
        object["claudeTokens"] = nil
        object["claudeQuota"] = nil

        let decoded = try XCTUnwrap(UsageSnapshot.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(decoded.schemaVersion, 7)
        XCTAssertEqual(decoded.codexTokens.value?.totalTokens, 100_000)
        XCTAssertEqual(decoded.deepseekUsage.value?.monthTokens, 2_400_000)
        XCTAssertEqual(decoded.claudeTokens.status, .unavailable)
        XCTAssertNil(decoded.claudeQuota.value)
    }

    func testVersionSixSnapshotKeepsValuesAndDefaultsMonitoringFields() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(UsageSnapshot.preview)) as? [String: Any])
        object["schemaVersion"] = 6
        for field in ["codexAccounts", "codexHistory", "claudeHistory", "claudeResetCards"] { object[field] = nil }
        let decoded = try XCTUnwrap(UsageSnapshot.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(decoded.schemaVersion, 7)
        XCTAssertEqual(decoded.codexTokens, UsageSnapshot.preview.codexTokens)
        XCTAssertEqual(decoded.claudeQuota, UsageSnapshot.preview.claudeQuota)
        XCTAssertNil(decoded.codexHistory.value)
        XCTAssertNil(decoded.codexAccounts.value)
        XCTAssertEqual(decoded.claudeResetCards.status, .unavailable)
    }

    func testMonitoringSnapshotRoundTripsWithoutCredentials() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(UsageSnapshot.monitoringPreview)
        let decoded = try XCTUnwrap(UsageSnapshot.decode(data))
        XCTAssertEqual(decoded.codexAccounts.value?.count, 2)
        XCTAssertEqual(decoded.codexHistory.value?.days.count, 7)
        XCTAssertEqual(decoded.claudeResetCards.value?.availableCount, 3)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("access_token"))
        XCTAssertFalse(text.contains("refresh_token"))
    }

    func testResetCardExpirationsNeverInventMissingInventory() {
        let now = Date(timeIntervalSince1970: 1000)
        let inventory = ResetCardInventory(availableCount: 4, observedAt: now, batches: [
            ResetCardBatch(id: "soon", count: 1, startsAt: nil, expiresAt: now.addingTimeInterval(60)),
            ResetCardBatch(id: "unknown", count: 1, startsAt: nil, expiresAt: nil)
        ])
        XCTAssertEqual(inventory.count(at: now), 4)
        XCTAssertEqual(inventory.count(at: now.addingTimeInterval(60)), 3)
        XCTAssertEqual(inventory.availableBatches(at: now.addingTimeInterval(60)).map(\.id), ["unknown"])
        let incomplete = ResetCardInventory(availableCount: 2, observedAt: now, batches: [])
        XCTAssertEqual(incomplete.count(at: now.addingTimeInterval(100000)), 2)
    }

    func testLegacySnapshotVersionsAreRejected() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(UsageSnapshot.preview)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        for version in 2...4 {
            object["schemaVersion"] = version
            let legacyData = try JSONSerialization.data(withJSONObject: object)
            XCTAssertNil(UsageSnapshot.decode(legacyData), "schema v\(version) should be rejected")
        }
    }

    func testCachedAgeAndStatusAreExplicit() {
        let measured = Date(timeIntervalSince1970: 1_000)
        let cached = UsageValue(
            status: UsageDataStatus.stale,
            source: UsageDataSource.cache,
            measuredAt: measured,
            lastAttemptAt: Date(timeIntervalSince1970: 2_000),
            message: "offline",
            value: CodexTokenTotals(totalTokens: 10, inputTokens: 8, cachedInputTokens: 3, outputTokens: 2, reasoningTokens: 1, sessionCount: 1)
        )
        XCTAssertTrue(cached.isStale)
        XCTAssertEqual(cached.age(at: Date(timeIntervalSince1970: 12_000)), 11_000)
    }

    func testTokenFormattingIsCompact() {
        XCTAssertEqual(UsageFormatting.tokens(400), "400")
        XCTAssertEqual(UsageFormatting.tokens(400_000), "400K")
        XCTAssertEqual(UsageFormatting.tokens(nil), "—")
    }

    func testQuotaPercentageIsClamped() {
        XCTAssertEqual(UsageFormatting.clampedPercent(-4), 0)
        XCTAssertEqual(UsageFormatting.clampedPercent(42.5), 42.5)
        XCTAssertEqual(UsageFormatting.clampedPercent(104), 100)
        XCTAssertNil(UsageFormatting.clampedPercent(nil))
    }

    func testResetCountdownFormatting() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(UsageFormatting.resetCountdown(nil, relativeTo: now), "Reset unavailable")
        XCTAssertEqual(UsageFormatting.resetCountdown(now, relativeTo: now), "Reset pending")
        XCTAssertEqual(UsageFormatting.resetCountdown(now.addingTimeInterval(6 * 86_400 + 13 * 3_600), relativeTo: now), "Resets in 6d 13h")
        XCTAssertEqual(UsageFormatting.resetCountdown(now.addingTimeInterval(2 * 3_600 + 17 * 60), relativeTo: now), "Resets in 2h 17m")
    }

    func testStaleAgeFormatting() {
        let now = Date(timeIntervalSince1970: 20_000)
        XCTAssertEqual(UsageFormatting.cacheAge(now.addingTimeInterval(-4 * 3_600), relativeTo: now), "Stale · 4h old")
    }

    func testDeepSeekBrowserTokenParsing() throws {
        XCTAssertEqual(
            DeepSeekCredentialStore.token(fromLocalStorageValue: #"{"value":"demo.jwt.token"}"#),
            "demo.jwt.token"
        )
        XCTAssertEqual(
            DeepSeekCredentialStore.token(fromLocalStorageValue: #""plain.jwt.token""#),
            "plain.jwt.token"
        )
        XCTAssertNil(DeepSeekCredentialStore.token(fromLocalStorageValue: "  \n  "))
        XCTAssertNil(DeepSeekCredentialStore.token(fromLocalStorageValue: "token\u{0000}value"))
    }

    func testDeepSeekPrimaryBalanceUsesFirstValidCurrency() throws {
        let selected = try XCTUnwrap(
            UsageFormatting.firstValidMoney([
                DeepSeekMoney(currency: "   ", amount: 99),
                DeepSeekMoney(currency: "EUR", amount: 12.5),
                DeepSeekMoney(currency: "USD", amount: 8)
            ])
        )
        XCTAssertEqual(selected.currency, "EUR")
        XCTAssertEqual(selected.amount, 12.5)
    }

    func testDeepSeekEmptyBalanceDoesNotInventQuota() {
        XCTAssertNil(UsageFormatting.firstValidMoney([]))
        XCTAssertEqual(UsageFormatting.money(nil), "—")
        XCTAssertNil(UsageSnapshot.unavailable.deepseekUsage.value)
        XCTAssertEqual(UsageSnapshot.unavailable.deepseekUsage.status, .unavailable)
    }

    func testDeepSeekStaleValueRetainsBalance() {
        let value = UsageValue(
            status: UsageDataStatus.stale,
            source: UsageDataSource.cache,
            measuredAt: Date(timeIntervalSince1970: 1_000),
            lastAttemptAt: Date(timeIntervalSince1970: 2_000),
            message: "offline",
            value: DeepSeekUsageTotals(
                monthTokens: 10,
                monthRequests: 1,
                monthCosts: [DeepSeekMoney(currency: "USD", amount: 0.5)],
                balances: [DeepSeekMoney(currency: "USD", amount: 9.5)],
                grantedBalances: [],
                totalCosts: []
            )
        )
        XCTAssertEqual(value.status, .stale)
        XCTAssertEqual(value.value?.balances.first?.amount, 9.5)
        XCTAssertEqual(UsageFormatting.cacheAge(value.measuredAt, relativeTo: Date(timeIntervalSince1970: 15_400)), "Stale · 4h old")
    }
}
