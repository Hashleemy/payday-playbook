import XCTest
@testable import PaydayPlaybook

/// Required mission tests 9 and 10: payday generation for all four cadences
/// across short months, leap years, and DST transitions, plus due-day
/// clamping for days 29/30/31.
final class PayScheduleGeneratorTests: XCTestCase {

    // Weekly generation across the US DST fall-back (Nov 1, 2026): every gap
    // stays exactly 7 calendar days.
    func testWeeklyAcrossFallDST() {
        let dates = PayScheduleGenerator.paydays(
            cadence: .weekly, anchor: TestSupport.date(2026, 10, 23), count: 4)
        XCTAssertEqual(dates, [
            TestSupport.date(2026, 10, 23), TestSupport.date(2026, 10, 30),
            TestSupport.date(2026, 11, 6), TestSupport.date(2026, 11, 13)
        ])
        for index in 1..<dates.count {
            XCTAssertEqual(DateMath.days(from: dates[index - 1], to: dates[index]), 7)
        }
    }

    // Biweekly across the spring-forward transition (Mar 14, 2027).
    func testBiweeklyAcrossSpringDST() {
        let dates = PayScheduleGenerator.paydays(
            cadence: .biweekly, anchor: TestSupport.date(2027, 3, 4), count: 3)
        XCTAssertEqual(dates, [
            TestSupport.date(2027, 3, 4), TestSupport.date(2027, 3, 18),
            TestSupport.date(2027, 4, 1)
        ])
        for index in 1..<dates.count {
            XCTAssertEqual(DateMath.days(from: dates[index - 1], to: dates[index]), 14)
        }
    }

    // Semimonthly on the 1st and 15th, across a year boundary.
    func testSemimonthlyFirstAndFifteenth() {
        let dates = PayScheduleGenerator.paydays(
            cadence: .semimonthly(firstDay: 1, secondDay: 15),
            anchor: TestSupport.date(2026, 12, 1), count: 5)
        XCTAssertEqual(dates, [
            TestSupport.date(2026, 12, 1), TestSupport.date(2026, 12, 15),
            TestSupport.date(2027, 1, 1), TestSupport.date(2027, 1, 15),
            TestSupport.date(2027, 2, 1)
        ])
    }

    // Semimonthly "15th and last day" (encoded as day 31) clamps in short
    // months — including February — and recovers in longer months.
    func testSemimonthlyFifteenthAndLastDay() {
        let dates = PayScheduleGenerator.paydays(
            cadence: .semimonthly(firstDay: 15, secondDay: 31),
            anchor: TestSupport.date(2027, 1, 15), count: 6)
        XCTAssertEqual(dates, [
            TestSupport.date(2027, 1, 15), TestSupport.date(2027, 1, 31),
            TestSupport.date(2027, 2, 15), TestSupport.date(2027, 2, 28),
            TestSupport.date(2027, 3, 15), TestSupport.date(2027, 3, 31)
        ])
    }

    // Leap year: day 31 clamps to Feb 29 in 2028, Feb 28 in 2027.
    func testMonthlyDay31AcrossLeapYear() {
        let dates2027 = PayScheduleGenerator.paydays(
            cadence: .monthly(day: 31), anchor: TestSupport.date(2027, 1, 31), count: 4)
        XCTAssertEqual(dates2027, [
            TestSupport.date(2027, 1, 31), TestSupport.date(2027, 2, 28),
            TestSupport.date(2027, 3, 31), TestSupport.date(2027, 4, 30)
        ])
        let dates2028 = PayScheduleGenerator.paydays(
            cadence: .monthly(day: 31), anchor: TestSupport.date(2028, 1, 31), count: 2)
        XCTAssertEqual(dates2028, [
            TestSupport.date(2028, 1, 31), TestSupport.date(2028, 2, 29)
        ])
    }

    // Required mission test 10: due day 29/30/31 maps to the last valid day.
    func testDueDayClampingWindows() {
        XCTAssertEqual(
            PayScheduleGenerator.dueDates(
                day: 31,
                from: TestSupport.date(2027, 2, 1), to: TestSupport.date(2027, 3, 1)),
            [TestSupport.date(2027, 2, 28)]
        )
        XCTAssertEqual(
            PayScheduleGenerator.dueDates(
                day: 29,
                from: TestSupport.date(2028, 2, 1), to: TestSupport.date(2028, 3, 1)),
            [TestSupport.date(2028, 2, 29)]
        )
        XCTAssertEqual(
            PayScheduleGenerator.dueDates(
                day: 30,
                from: TestSupport.date(2027, 4, 15), to: TestSupport.date(2027, 5, 15)),
            [TestSupport.date(2027, 4, 30)]
        )
        // Empty and inverted windows are safe.
        XCTAssertEqual(
            PayScheduleGenerator.dueDates(
                day: 15,
                from: TestSupport.date(2027, 4, 16), to: TestSupport.date(2027, 4, 20)),
            []
        )
        XCTAssertEqual(
            PayScheduleGenerator.dueDates(
                day: 15,
                from: TestSupport.date(2027, 4, 20), to: TestSupport.date(2027, 4, 10)),
            []
        )
    }

    // Previous-occurrence anchors for first-check interest accrual.
    func testPreviousOccurrence() {
        XCTAssertEqual(
            PayScheduleGenerator.previousOccurrence(
                cadence: .biweekly, before: TestSupport.date(2026, 8, 20)),
            TestSupport.date(2026, 8, 6)
        )
        XCTAssertEqual(
            PayScheduleGenerator.previousOccurrence(
                cadence: .monthly(day: 31), before: TestSupport.date(2027, 3, 31)),
            TestSupport.date(2027, 2, 28)
        )
        XCTAssertEqual(
            PayScheduleGenerator.previousOccurrence(
                cadence: .semimonthly(firstDay: 1, secondDay: 15),
                before: TestSupport.date(2027, 1, 1)),
            TestSupport.date(2026, 12, 15)
        )
    }

    // A month where both semimonthly days clamp to the same date yields a
    // single payday, not a duplicate.
    func testSemimonthlyClampCollision() {
        let dates = PayScheduleGenerator.paydays(
            cadence: .semimonthly(firstDay: 30, secondDay: 31),
            anchor: TestSupport.date(2027, 1, 30), count: 4)
        XCTAssertEqual(dates, [
            TestSupport.date(2027, 1, 30), TestSupport.date(2027, 1, 31),
            TestSupport.date(2027, 2, 28), TestSupport.date(2027, 3, 30)
        ])
    }
}
