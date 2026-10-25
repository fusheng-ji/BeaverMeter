import XCTest

final class RuntimePerformanceTests: XCTestCase {
    private struct Clock {
        var now: TimeInterval = 0
        mutating func advance(_ seconds: TimeInterval) { now += seconds }
    }

    func testOnlyCompletedAwakeWorkAtOrAboveOneHundredMillisecondsIsReported() {
        var clock = Clock()
        var tracker = MainRunLoopBusyTracker()
        XCTAssertNil(tracker.observe(.beforeWaiting, at: clock.now, enabled: true))
        XCTAssertNil(tracker.observe(.afterWaiting, at: clock.now, enabled: true))
        clock.advance(0.099)
        XCTAssertNil(tracker.observe(.beforeWaiting, at: clock.now, enabled: true))

        // A fresh fake-clock origin avoids rounding changing the boundary test.
        clock = Clock()
        XCTAssertNil(tracker.observe(.afterWaiting, at: clock.now, enabled: true))
        clock.advance(0.1)
        XCTAssertEqual(tracker.observe(.beforeWaiting, at: clock.now, enabled: true), 100)
        XCTAssertNil(tracker.observe(.beforeWaiting, at: clock.now + 1, enabled: true))
    }

    func testLongSleepGapIsExcludedFromNextAwakeInterval() {
        var clock = Clock()
        var tracker = MainRunLoopBusyTracker()
        XCTAssertNil(tracker.observe(.afterWaiting, at: clock.now, enabled: true))
        clock.advance(0.025)
        XCTAssertNil(tracker.observe(.beforeWaiting, at: clock.now, enabled: true))
        clock.advance(12 * 60 * 60)
        XCTAssertNil(tracker.observe(.afterWaiting, at: clock.now, enabled: true))
        clock.advance(0.05)
        XCTAssertNil(tracker.observe(.beforeWaiting, at: clock.now, enabled: true))

        clock.advance(20)
        XCTAssertNil(tracker.observe(.afterWaiting, at: clock.now, enabled: true))
        clock.advance(0.25)
        XCTAssertEqual(tracker.observe(.beforeWaiting, at: clock.now, enabled: true), 250)
    }

    func testDisabledTrackingClearsTheUnfinishedInterval() {
        var tracker = MainRunLoopBusyTracker()
        XCTAssertNil(tracker.observe(.afterWaiting, at: 0, enabled: true))
        XCTAssertNil(tracker.observe(.beforeWaiting, at: 10, enabled: false))
        XCTAssertNil(tracker.observe(.beforeWaiting, at: 20, enabled: true))
        XCTAssertNil(tracker.observe(.afterWaiting, at: 21, enabled: false))
        XCTAssertNil(tracker.observe(.beforeWaiting, at: 22, enabled: true))
        XCTAssertNil(tracker.observe(.afterWaiting, at: 23, enabled: true))
        XCTAssertEqual(tracker.observe(.beforeWaiting, at: 23.5, enabled: true), 500)
    }

    func testResetDiscardsAnUnfinishedInterval() {
        var tracker = MainRunLoopBusyTracker()
        XCTAssertNil(tracker.observe(.afterWaiting, at: 0, enabled: true))
        tracker.reset()
        XCTAssertNil(tracker.observe(.beforeWaiting, at: 10, enabled: true))
        XCTAssertNil(tracker.observe(.afterWaiting, at: 11, enabled: true))
        XCTAssertEqual(tracker.observe(.beforeWaiting, at: 11.25, enabled: true), 250)
    }

    func testClockAnomaliesCannotProduceBusySamplesOrPreserveOldIntervals() {
        var tracker = MainRunLoopBusyTracker()
        XCTAssertNil(tracker.observe(.afterWaiting, at: 10, enabled: true))
        XCTAssertNil(tracker.observe(.beforeWaiting, at: 9, enabled: true))
        XCTAssertNil(tracker.observe(.beforeWaiting, at: 20, enabled: true))
        XCTAssertNil(tracker.observe(.afterWaiting, at: 21, enabled: true))
        XCTAssertNil(tracker.observe(.beforeWaiting, at: .infinity, enabled: true))
        XCTAssertNil(tracker.observe(.beforeWaiting, at: 30, enabled: true))
        XCTAssertNil(tracker.observe(.afterWaiting, at: .nan, enabled: true))
        XCTAssertNil(tracker.observe(.beforeWaiting, at: 31, enabled: true))
    }

    func testLaterWakeBoundaryReplacesAnIncompleteEarlierInterval() {
        var tracker = MainRunLoopBusyTracker()
        XCTAssertNil(tracker.observe(.afterWaiting, at: 0, enabled: true))
        XCTAssertNil(tracker.observe(.afterWaiting, at: 20, enabled: true))
        XCTAssertEqual(tracker.observe(.beforeWaiting, at: 20.25, enabled: true), 250)
    }
}
