import Foundation
import XCTest

final class AntigravityQuotaVisibilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ label: String, _ remaining: Double?, seconds: Int = 18_000,
                        reset: Date? = nil) -> CompactQuota {
        CompactQuota(label: label, used: nil, limit: nil, remaining: nil,
                     remainingPercent: remaining, resetAt: reset, windowSeconds: seconds,
                     detail: remaining.map { "\(Int($0))% left" } ?? "Unknown")
    }

    private func reading(_ groups: [AntigravityQuotaGroup], status: UsageDataStatus = .ready,
                         measuredAt: Date? = nil) -> UsageValue<AntigravityQuotaSnapshot> {
        UsageValue(status: status, source: status == .stale ? .cache : .antigravityLocal,
                   measuredAt: measuredAt ?? now, lastAttemptAt: now,
                   message: nil, value: .init(groups: groups, planName: "Google AI Pro"))
    }

    func testIndependentGroupsChooseTheirOwnTightestWindowIncludingZero() {
        let data = reading([
            .init(id: .gemini, windows: [window("Gemini 5h", 80), window("Gemini Weekly", 30, seconds: 604_800)]),
            .init(id: .claudeGPT, windows: [window("Claude/GPT 5h", 0), window("Claude/GPT Weekly", 70, seconds: 604_800)])
        ])
        let gemini = AntigravityQuotaVisibility.group(.gemini, in: data, relativeTo: now)
        let claude = AntigravityQuotaVisibility.group(.claudeGPT, in: data, relativeTo: now)
        XCTAssertEqual(gemini.value?.remainingPercent, 30)
        XCTAssertEqual(gemini.value?.windowSeconds, 604_800)
        XCTAssertEqual(claude.value?.remainingPercent, 0)
        XCTAssertEqual(claude.value?.windowSeconds, 18_000)
        XCTAssertEqual(gemini.value?.planName, "Google AI Pro")
        XCTAssertEqual(AntigravityQuotaVisibility.summary(data, relativeTo: now).value?.remainingPercent, 0)
    }

    func testEqualReadingsPreferWeeklyAndUnknownNeverBecomesUntouchedQuota() {
        let data = reading([.init(id: .gemini, windows: [
            window("Gemini 5h", 40), window("Gemini Weekly", 40, seconds: 604_800), window("Unknown", nil)
        ])])
        let projected = AntigravityQuotaVisibility.group(.gemini, in: data, relativeTo: now)
        XCTAssertEqual(projected.value?.windowSeconds, 604_800)
        XCTAssertEqual(projected.value?.windows?.count, 2)
        XCTAssertNil(AntigravityQuotaVisibility.group(.claudeGPT, in: data, relativeTo: now).value)
        XCTAssertEqual(AntigravityQuotaVisibility.group(.claudeGPT, in: data, relativeTo: now).status, .unavailable)
    }

    func testMeasurementDeadlineIsNotExtendedByRepeatedAttempts() {
        let data = reading([.init(id: .gemini, windows: [window("Gemini 5h", 70)])], status: .stale)
        XCTAssertNotNil(AntigravityQuotaVisibility.quota(data, relativeTo: now.addingTimeInterval(1_799)).value)
        XCTAssertNil(AntigravityQuotaVisibility.quota(data, relativeTo: now.addingTimeInterval(1_800)).value)
    }

    func testAuthenticationFailureHidesAnyExistingReadingImmediately() {
        let data = reading([.init(id: .gemini, windows: [window("Gemini 5h", 70)])], status: .unauthenticated)
        let result = AntigravityQuotaVisibility.group(.gemini, in: data, relativeTo: now)
        XCTAssertNil(result.value)
        XCTAssertEqual(result.status, .unauthenticated)
    }

    func testResetWindowIsRemovedAndOtherCurrentWindowRemains() {
        let data = reading([.init(id: .gemini, windows: [
            window("Gemini 5h", 10, reset: now.addingTimeInterval(60)),
            window("Gemini Weekly", 50, seconds: 604_800, reset: now.addingTimeInterval(3_600))
        ])])
        let result = AntigravityQuotaVisibility.group(.gemini, in: data, relativeTo: now.addingTimeInterval(60))
        XCTAssertEqual(result.value?.windowSeconds, 604_800)
        XCTAssertNil(result.value?.windows)
        XCTAssertEqual(AntigravityQuotaVisibility.expirationDates(quota: data, after: now),
                       [now.addingTimeInterval(60), now.addingTimeInterval(1_800)])
    }

    func testResetCaptionSurvivesWithoutInventingDate() {
        var quota = window("Gemini 5h", 80)
        quota.resetDescription = "Refills in about 3 hours"
        let data = reading([.init(id: .gemini, windows: [quota])])
        let result = AntigravityQuotaVisibility.group(.gemini, in: data, relativeTo: now)
        XCTAssertNil(result.value?.resetAt)
        XCTAssertEqual(result.value?.resetDescription, quota.resetDescription)
    }

    func testVersionSevenSnapshotDefaultsNewFieldsWithoutLosingExistingReadings() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(UsageSnapshot.preview)) as? [String: Any])
        object["schemaVersion"] = 7
        object["antigravityQuota"] = nil
        object["antigravityTokens"] = nil
        let snapshot = try XCTUnwrap(UsageSnapshot.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(snapshot.schemaVersion, 8)
        XCTAssertEqual(snapshot.codexQuota, UsageSnapshot.preview.codexQuota)
        XCTAssertEqual(snapshot.claudeQuota, UsageSnapshot.preview.claudeQuota)
        XCTAssertNil(snapshot.antigravityQuota.value)
        XCTAssertNil(snapshot.antigravityTokens.value)
    }

    func testNewSnapshotRoundTripsBothQuotaGroupsAndIndependentToday() throws {
        var snapshot = UsageSnapshot.preview
        snapshot.antigravityQuota = reading([.init(id: .gemini, windows: [window("Gemini 5h", 0)]),
                                             .init(id: .claudeGPT, windows: [])])
        snapshot.antigravityTokens = UsageValue(status: .ready, source: .codexBarLocal, measuredAt: now,
            lastAttemptAt: now, message: nil, value: AntigravityTokenTotals(totalTokens: 125,
                inputTokens: 100, cacheReadTokens: 10, cacheCreationTokens: 5, outputTokens: 7,
                reasoningTokens: 3, requestCount: 1))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let result = try XCTUnwrap(UsageSnapshot.decode(encoder.encode(snapshot)))
        XCTAssertEqual(result.antigravityQuota, snapshot.antigravityQuota)
        XCTAssertEqual(result.antigravityTokens, snapshot.antigravityTokens)
    }
}
