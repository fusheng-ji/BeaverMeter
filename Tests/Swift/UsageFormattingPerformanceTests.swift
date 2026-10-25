import Foundation
import XCTest

final class UsageFormattingPerformanceTests: XCTestCase {
    func testUSDGoldenValuesKeepPrecisionSignsAndSpecialValues() {
        for (value, expected): (Double, String) in [
            (0, "$0.00"), (-0.0, "-$0.00"), (0.00001, "$0.00"),
            (-12.34567, "-$12.3457"), (999_999_999.87654, "$999,999,999.8765"),
            (.nan, "NaN"), (.infinity, "+∞"), (-.infinity, "-∞")
        ] {
            XCTAssertEqual(UsageFormatting.usd(value), expected)
        }
        XCTAssertEqual(UsageFormatting.usd(nil), "—")
        XCTAssertEqual(UsageFormatting.money(nil), "—")
    }

    func testAlternatingPrecisionDoesNotContaminateOtherConfigurations() {
        let values: [Double] = [0, -0.0, 12.34567, -999.99999, .nan, .infinity]
        for _ in 0..<3 {
            for (minimum, maximum) in [(2, 4), (0, 0), (4, 4), (1, 3), (0, 6), (5, 2)] {
                for value in values {
                    XCTAssertEqual(UsageFormatting.usd(value, minimumDigits: minimum, maximumDigits: maximum),
                                   legacyUSD(value, minimum: minimum, maximum: maximum))
                }
            }
        }
    }

    func testUSDCodeKeepsGroupingAndIntegralFractionRule() {
        XCTAssertEqual(UsageFormatting.usdCode(1_200), "US$1,200")
        XCTAssertEqual(UsageFormatting.usdCode(12.5), "US$12.50")
        for value: Double in [0, -0.0, -1_234.567, 0.00001, 9_999_999.999, .nan, .infinity, -.infinity] {
            let formatter = NumberFormatter()
            formatter.locale = UsageFormatting.locale
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = value.rounded() == value ? 0 : 2
            formatter.maximumFractionDigits = 2
            formatter.groupingSeparator = ","
            let expected = "US$" + (formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value))
            XCTAssertEqual(UsageFormatting.usdCode(value), expected)
        }
    }

    func testCurrencyChurnKeepsSymbolsFractionsAndFallbacks() {
        let codes = ["USD", "CNY", "EUR", "JPY", "GBP", "CAD", "CHF", "KRW", "KWD", "", "unknown"]
            + (0..<64).map { "X\($0)" }
        for code in codes + codes.reversed() {
            for amount: Double in [0, -1_234.56789, 0.00001, .nan, .infinity] {
                let money = DeepSeekMoney(currency: code, amount: amount)
                XCTAssertEqual(UsageFormatting.money(money), legacyMoney(money), "currency: \(code)")
            }
        }
    }

    func testRelativeAgeMatchesFreshFormatterAcrossCalendarChanges() {
        // NSTimeZone.default affects this test process only; no system preference is written.
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        let dates = ISO8601DateFormatter()
        let offsets: [TimeInterval] = [-400 * 86_400, -90_000, -3_600, -1, 0, 1, 3_600, 90_000, 400 * 86_400]
        for zone in ["UTC", "Europe/Berlin", "America/Los_Angeles", "Pacific/Kiritimati"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            for text in ["2026-03-29T01:30:00Z", "2026-10-25T01:30:00Z"] {
                let now = dates.date(from: text)!
                for offset in offsets {
                    let date = now.addingTimeInterval(offset)
                    XCTAssertEqual(UsageFormatting.relativeAge(date, relativeTo: now),
                                   legacyRelative(date, relativeTo: now), "zone: \(zone), offset: \(offset)")
                }
            }
        }
        XCTAssertEqual(UsageFormatting.relativeAge(nil), "never updated")
    }

    func testResetPreservesPendingAndFutureWording() {
        XCTAssertNil(UsageFormatting.reset(nil))
        XCTAssertEqual(UsageFormatting.reset(.distantPast), "reset pending")
        let future = Date.now.addingTimeInterval(10 * 86_400 + 3_600)
        XCTAssertEqual(UsageFormatting.reset(future), "resets " + legacyRelative(future, relativeTo: .now))
    }

    func testConcurrentMixedConfigurationsKeepIndependentOutput() {
        let codes = ["USD", "CNY", "EUR", "JPY", "CAD", "CHF", "KWD"]
        let now = Date(timeIntervalSince1970: 1_790_078_400)
        let date = now.addingTimeInterval(-7_200)
        let expectedAge = legacyRelative(date, relativeTo: now)
        let expectedMoney = codes.map { legacyMoney(DeepSeekMoney(currency: $0, amount: -1_234.56789)) }
        let expectedUSD = (0..<6).map { legacyUSD(12.34567, minimum: $0, maximum: $0) }
        let failures = FailureRecorder()
        DispatchQueue.concurrentPerform(iterations: 512) { index in
            let currency = index % codes.count
            let digits = index % expectedUSD.count
            let actual = [UsageFormatting.money(DeepSeekMoney(currency: codes[currency], amount: -1_234.56789)),
                          UsageFormatting.usd(12.34567, minimumDigits: digits, maximumDigits: digits),
                          UsageFormatting.usdCode(1_234), UsageFormatting.relativeAge(date, relativeTo: now)]
            let expected = [expectedMoney[currency], expectedUSD[digits], "US$1,234", expectedAge]
            if actual != expected { failures.record("iteration \(index): \(actual) != \(expected)") }
        }
        XCTAssertTrue(failures.messages.isEmpty, failures.messages.joined(separator: "\n"))
    }

    // Fresh formatters reproduce the pre-cache behavior and serve as compatibility
    // oracles for locale-specific symbols, precision edge cases and calendar rules.
    private func legacyUSD(_ value: Double, minimum: Int, maximum: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = UsageFormatting.locale
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "$"
        formatter.minimumFractionDigits = minimum
        formatter.maximumFractionDigits = maximum
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    private func legacyMoney(_ value: DeepSeekMoney) -> String {
        let formatter = NumberFormatter()
        formatter.locale = UsageFormatting.locale
        formatter.numberStyle = .currency
        formatter.currencyCode = value.currency
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return formatter.string(from: NSNumber(value: value.amount))
            ?? "\(value.currency) \(String(format: "%.2f", value.amount))"
    }

    private func legacyRelative(_ date: Date, relativeTo now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = UsageFormatting.locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private final class FailureRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var failures: [String] = []
        var messages: [String] {
            lock.lock()
            defer { lock.unlock() }
            return failures
        }
        func record(_ message: String) {
            lock.lock()
            defer { lock.unlock() }
            if failures.count < 8 { failures.append(message) }
        }
    }
}
