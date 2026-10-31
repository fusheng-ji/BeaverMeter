import Foundation
import XCTest

final class WidgetSpacingPolicyTests: XCTestCase {
    func testApprovedInsetsAndGapsAcrossEveryCapacity() {
        let cases: [(ProviderWidgetSize, CGFloat, CGFloat, [(CGFloat, CGFloat)])] = [
            (.small, 10, 4, [(12, 10), (8, 8)]),
            (.medium, 12, 6, [(12, 10), (10, 10), (10, 10), (8, 8)]),
            (.large, 16, 8, [(16, 12), (12, 10), (12, 10), (10, 8), (10, 8), (10, 8)]),
            (.extraLarge, 16, 8, [(16, 14), (12, 12), (12, 12), (12, 12), (12, 10), (12, 10)])
        ]
        for (size, outer, gap, insets) in cases {
            XCTAssertEqual(insets.count, WidgetComposition.capacity(for: size))
            for (index, inset) in insets.enumerated() {
                let policy = WidgetSpacingPolicy(size: size, cardCount: index + 1)
                XCTAssertEqual(policy.outerPadding, outer)
                XCTAssertEqual(policy.cardSpacing, gap)
                XCTAssertEqual(policy.horizontalPadding, inset.0)
                XCTAssertEqual(policy.verticalPadding, inset.1)
            }
        }
    }

    func testInsetsDoNotShrinkForProvidersSubscriptionsOrUndersizedCards() {
        for size in ProviderWidgetSize.allCases {
            for count in 1...WidgetComposition.capacity(for: size) {
                let policy = WidgetSpacingPolicy(size: size, cardCount: count)
                for provider in MeterProvider.allCases {
                    for subscription in [false, true] {
                        for cardSize in [CGSize.zero, CGSize(width: 10, height: 6), CGSize(width: 324, height: 75)] {
                            let plan = WidgetContentPlan(provider: provider, size: size, providerCount: count,
                                cardSize: cardSize, hasSubscription: subscription)
                            XCTAssertEqual(plan.horizontalPadding, policy.horizontalPadding)
                            XCTAssertEqual(plan.verticalPadding, policy.verticalPadding)
                            XCTAssertGreaterThanOrEqual(plan.horizontalPadding, 8)
                            XCTAssertGreaterThanOrEqual(plan.verticalPadding, 8)
                            XCTAssertEqual(plan.safeContentSize.width, max(0, cardSize.width - 2 * policy.horizontalPadding))
                            XCTAssertEqual(plan.safeContentSize.height, max(0, cardSize.height - 2 * policy.verticalPadding))
                        }
                    }
                }
            }
        }
    }

    func testSafeContentGeometryAtCanonicalNativeWidgetSizes() {
        let families: [(ProviderWidgetSize, CGSize)] = [
            (.small, CGSize(width: 174, height: 174)), (.medium, CGSize(width: 352, height: 174)),
            (.large, CGSize(width: 352, height: 352)), (.extraLarge, CGSize(width: 710, height: 352))
        ]
        for (size, widgetSize) in families {
            for count in 1...WidgetComposition.capacity(for: size) {
                let policy = WidgetSpacingPolicy(size: size, cardCount: count)
                let rows = WidgetComposition.rows(cardCount: count, size: size)
                let columns = rows.map(\.count).max()!
                let cardSize = CGSize(
                    width: (widgetSize.width - policy.outerPadding * 2 - CGFloat(columns - 1) * policy.cardSpacing) / CGFloat(columns),
                    height: (widgetSize.height - policy.outerPadding * 2 - CGFloat(rows.count - 1) * policy.cardSpacing) / CGFloat(rows.count))
                for provider in MeterProvider.allCases {
                    let plan = WidgetContentPlan(provider: provider, size: size, providerCount: count,
                                                 cardSize: cardSize, hasSubscription: true)
                    XCTAssertGreaterThan(plan.contentWidth, 0)
                    XCTAssertGreaterThan(plan.contentHeight, 0)
                    XCTAssertEqual(plan.contentWidth + plan.horizontalPadding * 2, cardSize.width, accuracy: 0.0001)
                    XCTAssertEqual(plan.contentHeight + plan.verticalPadding * 2, cardSize.height, accuracy: 0.0001)
                    XCTAssertLessThanOrEqual(plan.sideIdentityColumnWidth + plan.sideColumnSpacing, plan.contentWidth)
                    XCTAssertEqual(plan.sideIdentityColumnWidth + plan.sideColumnSpacing + plan.sideMetricColumnWidth,
                                   plan.contentWidth, accuracy: 0.0001)
                }
            }
        }
        let denseSmall = WidgetContentPlan(provider: .antigravity, size: .small, providerCount: 2,
                                          cardSize: CGSize(width: 154, height: 75), hasSubscription: true)
        XCTAssertEqual(denseSmall.safeContentSize, CGSize(width: 138, height: 59))
        XCTAssertEqual(denseSmall.sideIdentityColumnWidth, 52)
        XCTAssertEqual(denseSmall.sideMetricColumnWidth, 80)
        let denseLarge = WidgetContentPlan(provider: .codex, size: .large, providerCount: 6,
                                          cardSize: CGSize(width: 156, height: 304.0 / 3), hasSubscription: true)
        XCTAssertEqual(denseLarge.safeContentSize.width, 136)
        XCTAssertEqual(denseLarge.safeContentSize.height, 256.0 / 3, accuracy: 0.0001)
    }

    func testHiddenSubscriptionReleasesItsActualHeaderLine() {
        for size in ProviderWidgetSize.allCases {
            for count in 1...WidgetComposition.capacity(for: size) {
                let plan = WidgetContentPlan(provider: .antigravity, size: size, providerCount: count,
                    cardSize: CGSize(width: 335, height: 156), hasSubscription: true)
                XCTAssertEqual(plan.identityHeaderHeight(showsSubscription: true)
                               - plan.identityHeaderHeight(showsSubscription: false),
                               plan.subscriptionSize * 1.25, accuracy: 0.0001)
                XCTAssertGreaterThan(plan.identityHeaderHeight(showsSubscription: false), plan.logoSize)
                if plan.layout != .dashboard {
                    XCTAssertEqual(plan.identityHeaderHeight, plan.identityHeaderHeight(showsSubscription: true))
                } else {
                    XCTAssertEqual(plan.identityHeaderHeight, plan.dashboardQuotaHeight)
                }
            }
        }
    }

    func testInvalidCountsUseNearestLegalSpacingWithoutChangingCapacities() {
        for size in ProviderWidgetSize.allCases {
            XCTAssertEqual(WidgetSpacingPolicy(size: size, cardCount: 0).cardCount, 1)
            XCTAssertEqual(WidgetSpacingPolicy(size: size, cardCount: -10).cardCount, 1)
            XCTAssertEqual(WidgetSpacingPolicy(size: size, cardCount: 100).cardCount,
                           WidgetComposition.capacity(for: size))
        }
    }
}
