import XCTest

final class WidgetCardStatusTests: XCTestCase {
    private let now = UsageSnapshot.previewDate

    func testQuotaAndTokenFailuresChooseHighestSeverityInEitherOrder() {
        let scenarios: [(UsagePreviewScenario, UsageStatusPresentation.Severity)] = [
            (.normal, .normal), (.unavailable, .warning), (.error, .critical)
        ]
        for (left, leftSeverity) in scenarios {
            for (right, rightSeverity) in scenarios {
                let quota = UsageStatusPresentation(left.snapshot.codexQuota, relativeTo: now)
                let tokens = CodexDailyTokenPresentation(right.snapshot.codexTokens, relativeTo: now).status
                let combined = WidgetCardStatus(quota, supplemental: tokens)
                let expected: UsageStatusPresentation.Severity = leftSeverity == .critical || rightSeverity == .critical
                    ? .critical : leftSeverity == .warning || rightSeverity == .warning ? .warning : .normal
                XCTAssertEqual(combined.severity, expected)
                XCTAssertEqual(combined.icon, expected == .normal ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                XCTAssertEqual(combined.severity, WidgetCardStatus(tokens, supplemental: quota).severity)
                XCTAssertTrue(combined.detail.contains(quota.detail))
                XCTAssertTrue(combined.detail.contains(tokens.detail))
            }
        }
    }

    func testRemoteFailureAndOldCacheKeepValueAndDetailedReason() {
        let snapshot = UsagePreviewScenario.remoteUnavailable.snapshot
        let quota = UsageStatusPresentation(snapshot.codexQuota, relativeTo: now)
        let tokens = CodexDailyTokenPresentation(snapshot.codexTokens, relativeTo: now)
        XCTAssertEqual(tokens.value, "100K")
        let combined = WidgetCardStatus(quota, supplemental: tokens.status)
        XCTAssertEqual(combined.severity, .warning)
        XCTAssertTrue(combined.detail.contains("cached remote usage"))
        let old = UsageStatusPresentation(snapshot.codexTokens, relativeTo: now.addingTimeInterval(3 * 3600))
        XCTAssertEqual(WidgetCardStatus(quota, supplemental: old).severity, .critical)
    }

    func testZeroIsHealthyAndMissingDataIsAnException() {
        let zero = WidgetCardStatus(UsageStatusPresentation(UsagePreviewScenario.zero.snapshot.codexQuota, relativeTo: now))
        let missing = WidgetCardStatus(UsageStatusPresentation(UsagePreviewScenario.unavailable.snapshot.codexQuota, relativeTo: now))
        XCTAssertEqual(zero.severity, .normal)
        XCTAssertEqual(missing.severity, .warning)
        let signedOut = WidgetCardStatus(UsageStatusPresentation(UsagePreviewScenario.signedOut.snapshot.deepseekUsage,
                                                                relativeTo: now))
        XCTAssertEqual(signedOut.severity, .warning)
    }
}
