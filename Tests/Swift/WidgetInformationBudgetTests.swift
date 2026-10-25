import Foundation
import XCTest

final class WidgetInformationBudgetTests: XCTestCase {
    private func plan(_ provider: MeterProvider, _ size: ProviderWidgetSize, count: Int,
                      cardSize: CGSize = CGSize(width: 324, height: 75)) -> WidgetContentPlan {
        WidgetContentPlan(provider: provider, size: size, providerCount: count, cardSize: cardSize)
    }

    func testWideRowColumnsFitAvailableWidthAcrossEveryCapacity() {
        for size in ProviderWidgetSize.allCases {
            for count in 1...WidgetComposition.capacity(for: size) {
                for width: CGFloat in [0, 10, 106.667, 158, 222, 324, 332, 682] {
                    let budget = plan(.codex, size, count: count, cardSize: CGSize(width: width, height: 75))
                    XCTAssertGreaterThanOrEqual(budget.identityColumnWidth, 0)
                    XCTAssertGreaterThanOrEqual(budget.metricColumnWidth, 0)
                    XCTAssertGreaterThanOrEqual(budget.columnSpacing, 0)
                    XCTAssertEqual(budget.identityColumnWidth + budget.metricColumnWidth * 2 + budget.columnSpacing * 2,
                                   budget.contentWidth, accuracy: 0.0001)
                    XCTAssertEqual(budget.mergedMetricWidth,
                                   budget.metricColumnWidth * 2 + budget.columnSpacing, accuracy: 0.0001)
                    XCTAssertGreaterThanOrEqual(budget.sideIdentityColumnWidth, 0)
                    XCTAssertGreaterThanOrEqual(budget.sideMetricColumnWidth, 0)
                    XCTAssertEqual(budget.sideIdentityColumnWidth + budget.sideMetricColumnWidth + budget.sideColumnSpacing,
                                   budget.contentWidth, accuracy: 0.0001)
                }
            }
        }
    }

    func testLargeFourRowsReserveIdentityAndAlignedQuotaColumns() {
        let budget = plan(.codex, .large, count: 4)
        XCTAssertEqual(budget.layout, .wideRow)
        XCTAssertEqual(budget.contentWidth, 300)
        XCTAssertGreaterThanOrEqual(budget.identityColumnWidth, 79)
        XCTAssertGreaterThanOrEqual(budget.metricColumnWidth, 102)
        XCTAssertGreaterThanOrEqual(budget.mergedMetricWidth, 212)
        XCTAssertEqual(budget.valueSize, 26)
        XCTAssertEqual(budget.secondaryValueSize, 18)
        XCTAssertEqual(budget.detailSize, 10)
        XCTAssertLessThanOrEqual(budget.identityHeaderHeight + budget.verticalPadding * 2, budget.cardSize.height)
    }

    func testSmallTwoModuleLimitKeepsAReadableMainValue() {
        let budget = plan(.codex, .small, count: 2, cardSize: CGSize(width: 158, height: 77.5))
        XCTAssertEqual(budget.layout, .compact)
        XCTAssertGreaterThanOrEqual(budget.valueSize, 22)
        XCTAssertTrue(budget.showsPrimaryReset)
        XCTAssertEqual(budget.windowLimit, 1)
    }

    func testKnownSubscriptionsFitDenseCardsWithoutRemovingQuotaWindows() {
        for (size, count, width) in [(ProviderWidgetSize.small, 2, 158.0), (.medium, 4, 163.0)] {
            let budget = WidgetContentPlan(provider: .codex, size: size, providerCount: count,
                                           cardSize: CGSize(width: width, height: 75), hasSubscription: true)
            XCTAssertEqual(budget.layout, .compact)
            XCTAssertEqual(budget.verticalPadding, 6)
            XCTAssertEqual(budget.spacing, 1)
            XCTAssertLessThanOrEqual(budget.valueSize, 20)
            XCTAssertEqual(budget.windowLimit, 1)
            XCTAssertTrue(budget.showsPrimaryReset)
            XCTAssertLessThanOrEqual(budget.identityHeaderHeight + budget.verticalPadding * 2, budget.cardSize.height)
        }
        let hero = WidgetContentPlan(provider: .codex, size: .small, providerCount: 1,
                                     cardSize: CGSize(width: 158, height: 158), hasSubscription: true)
        XCTAssertEqual(hero.verticalPadding, 6)
    }

    func testBothWindowValuesAndPrimaryResetSurviveEveryDensity() {
        for size in ProviderWidgetSize.allCases {
            for count in 1...WidgetComposition.capacity(for: size) {
                for provider in MeterProvider.allCases {
                    let budget = plan(provider, size, count: count)
                    XCTAssertTrue(budget.showsPrimaryReset)
                    XCTAssertEqual(budget.windowLimit, provider == .codex || provider == .claude ? 1 : 0)
                }
            }
        }
    }

    func testSmallIsASummaryAndLargerFamiliesExpandWindowCountdowns() {
        XCTAssertFalse(plan(.codex, .small, count: 1).showsWindowResets)
        XCTAssertFalse(plan(.codex, .small, count: 2).showsWindowResets)
        XCTAssertTrue(plan(.claude, .medium, count: 4).showsWindowResets)
        XCTAssertTrue(plan(.codex, .large, count: 6).showsWindowResets)
        XCTAssertTrue(plan(.claude, .extraLarge, count: 6).showsWindowResets)
    }

    func testExtraLargeFourModulesOmitHistoryWithoutReducingQuotaDetails() {
        let budget = plan(.codex, .extraLarge, count: 4)
        XCTAssertFalse(WidgetContentPlan.showsActivityHistory(size: .extraLarge, providerCount: 4))
        XCTAssertTrue(budget.showsPrimaryReset)
        XCTAssertTrue(budget.showsWindowResets)
        XCTAssertEqual(budget.windowLimit, 1)
    }

    func testHistoryBudgetRemainsUnchangedForOtherSizesAndModuleCounts() {
        let expectedCounts: [(ProviderWidgetSize, [Int])] = [
            (.small, []), (.medium, []), (.large, []), (.extraLarge, [1, 2, 3, 5, 6])
        ]
        for (size, expected) in expectedCounts {
            let actual = (1...WidgetComposition.capacity(for: size)).filter {
                WidgetContentPlan.showsActivityHistory(size: size, providerCount: $0)
            }
            XCTAssertEqual(actual, expected, "\(size)")
        }
    }

    func testExtraLargeFourModulesAlignQuotasAboveAFixedActivityBand() {
        let extraLarge = WidgetContentPlan(provider: .claude, size: .extraLarge, providerCount: 4,
                                           cardSize: CGSize(width: 337, height: 158), hasSubscription: true)
        XCTAssertEqual(extraLarge.layout, .dashboard)
        XCTAssertEqual(extraLarge.valueSize, 32)
        XCTAssertEqual(extraLarge.secondaryValueSize, 26)
        XCTAssertEqual(extraLarge.horizontalPadding, 12)
        XCTAssertEqual(extraLarge.verticalPadding, 12)
        XCTAssertEqual(extraLarge.dashboardIdentityWidth, 84)
        XCTAssertEqual(extraLarge.dashboardMetricWidth, 217)
        XCTAssertEqual(extraLarge.dashboardIdentityWidth + extraLarge.dashboardColumnSpacing
                       + extraLarge.dashboardMetricWidth, extraLarge.contentWidth)
        XCTAssertGreaterThan((extraLarge.dashboardMetricWidth - extraLarge.dashboardColumnSpacing) / 2, 100)
        XCTAssertLessThanOrEqual(extraLarge.identityHeaderHeight, extraLarge.dashboardQuotaHeight)
        XCTAssertEqual(extraLarge.dashboardQuotaHeight + extraLarge.dashboardSectionSpacing
                       + extraLarge.dashboardFooterHeight + extraLarge.verticalPadding * 2, 158)
    }

    func testSixModuleTilesKeepSpaceForIntegratedDetails() {
        let large = WidgetContentPlan(provider: .claude, size: .large, providerCount: 6,
                                      cardSize: CGSize(width: 158, height: 102.667))
        XCTAssertEqual(large.layout, .tile)
        XCTAssertGreaterThanOrEqual(large.valueSize, 24)
        XCTAssertEqual(large.spacing, 2)
        XCTAssertEqual(large.verticalPadding, 4)
    }

    func testLayoutFamiliesFollowApprovedComposition() {
        XCTAssertEqual(plan(.codex, .small, count: 1).layout, .hero)
        XCTAssertEqual(plan(.codex, .small, count: 2).layout, .compact)
        XCTAssertEqual(plan(.codex, .medium, count: 1).layout, .wideRow)
        XCTAssertEqual(plan(.codex, .medium, count: 3).layout, .column)
        XCTAssertEqual(plan(.codex, .medium, count: 4).layout, .compact)
        XCTAssertEqual(plan(.codex, .large, count: 1).layout, .hero)
        for count in 2...4 { XCTAssertEqual(plan(.codex, .large, count: count).layout, .wideRow) }
        XCTAssertEqual(plan(.codex, .large, count: 6).layout, .tile)
        XCTAssertEqual(plan(.codex, .extraLarge, count: 1).layout, .hero)
        XCTAssertEqual(plan(.codex, .extraLarge, count: 3).layout, .tile)
        XCTAssertEqual(plan(.codex, .extraLarge, count: 4).layout, .dashboard)
        XCTAssertEqual(plan(.codex, .extraLarge, count: 5).layout, .tile)
        XCTAssertEqual(plan(.codex, .extraLarge, count: 6).layout, .tile)
    }

    func testTypographyAndPaddingRemainPositiveAcrossApprovedCapacities() {
        for size in ProviderWidgetSize.allCases {
            for count in 1...WidgetComposition.capacity(for: size) {
                for provider in MeterProvider.allCases {
                    let budget = plan(provider, size, count: count)
                    XCTAssertGreaterThan(budget.valueSize, budget.secondaryValueSize)
                    XCTAssertGreaterThanOrEqual(budget.detailSize, 8)
                    XCTAssertGreaterThan(budget.logoSize, 0)
                    XCTAssertGreaterThan(budget.cornerRadius, 0)
                    XCTAssertGreaterThanOrEqual(budget.horizontalPadding, 0)
                    XCTAssertGreaterThanOrEqual(budget.verticalPadding, 0)
                    XCTAssertGreaterThanOrEqual(budget.spacing, 0)
                }
            }
        }
    }
}
