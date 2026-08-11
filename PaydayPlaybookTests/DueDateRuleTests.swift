import XCTest
@testable import PaydayPlaybook

/// V2-11 due-date rules: 29/30/31 → last-valid-day mapping, weekend shift
/// rules (opt-in only), prospective occurrence windows, and DST-adjacent
/// stability. One shared implementation feeds the calendar, the scheduler,
/// and the dashboard.
final class DueDateRuleTests: XCTestCase {

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        DateMath.localDate(year: year, month: month, day: day)
    }

    private func components(_ date: Date) -> (year: Int, month: Int, day: Int) {
        let c = DateMath.calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year!, c.month!, c.day!)
    }

    // MARK: - Short-month clamping (R-11)

    func testDay31ClampsToLastValidDayOfEveryMonth() {
        XCTAssertEqual(DueDateRule.occurrence(dueDay: 31, inMonthOf: day(2027, 2, 10)), day(2027, 2, 28))
        XCTAssertEqual(DueDateRule.occurrence(dueDay: 31, inMonthOf: day(2028, 2, 10)), day(2028, 2, 29)) // leap
        XCTAssertEqual(DueDateRule.occurrence(dueDay: 31, inMonthOf: day(2026, 9, 1)), day(2026, 9, 30))
        XCTAssertEqual(DueDateRule.occurrence(dueDay: 31, inMonthOf: day(2026, 10, 1)), day(2026, 10, 31))
    }

    func testDay29And30ClampOnlyWhenTheMonthIsShorter() {
        XCTAssertEqual(DueDateRule.occurrence(dueDay: 29, inMonthOf: day(2027, 2, 1)), day(2027, 2, 28))
        XCTAssertEqual(DueDateRule.occurrence(dueDay: 29, inMonthOf: day(2028, 2, 1)), day(2028, 2, 29))
        XCTAssertEqual(DueDateRule.occurrence(dueDay: 30, inMonthOf: day(2027, 2, 1)), day(2027, 2, 28))
        XCTAssertEqual(DueDateRule.occurrence(dueDay: 30, inMonthOf: day(2026, 11, 1)), day(2026, 11, 30))
    }

    func testIsClampedReportsShortMonths() {
        XCTAssertTrue(DueDateRule.isClamped(dueDay: 31, inMonthOf: day(2027, 2, 1)))
        XCTAssertTrue(DueDateRule.isClamped(dueDay: 30, inMonthOf: day(2027, 2, 1)))
        XCTAssertFalse(DueDateRule.isClamped(dueDay: 31, inMonthOf: day(2027, 1, 1)))
        XCTAssertFalse(DueDateRule.isClamped(dueDay: 15, inMonthOf: day(2027, 2, 1)))
    }

    // MARK: - Occurrence windows

    func testOccurrencesAcrossShortMonthsHaveNoDuplicatesAndStayOrdered() {
        let result = DueDateRule.occurrences(dueDay: 31, from: day(2027, 1, 1), to: day(2027, 5, 1))
        XCTAssertEqual(result, [day(2027, 1, 31), day(2027, 2, 28), day(2027, 3, 31), day(2027, 4, 30)])
        XCTAssertEqual(Set(result).count, result.count)
    }

    func testOccurrenceWindowIsHalfOpen() {
        let result = DueDateRule.occurrences(dueDay: 15, from: day(2026, 8, 15), to: day(2026, 9, 15))
        XCTAssertEqual(result, [day(2026, 8, 15)])
    }

    func testEmptyOrInvertedWindowYieldsNothing() {
        XCTAssertTrue(DueDateRule.occurrences(dueDay: 15, from: day(2026, 8, 1), to: day(2026, 8, 1)).isEmpty)
        XCTAssertTrue(DueDateRule.occurrences(dueDay: 15, from: day(2026, 9, 1), to: day(2026, 8, 1)).isEmpty)
    }

    func testNextOccurrenceOnTheDueDayIsTheSameDay() {
        XCTAssertEqual(DueDateRule.nextOccurrence(dueDay: 15, onOrAfter: day(2026, 8, 15)), day(2026, 8, 15))
        XCTAssertEqual(DueDateRule.nextOccurrence(dueDay: 15, onOrAfter: day(2026, 8, 16)), day(2026, 9, 15))
    }

    // MARK: - Weekend shift rules (opt-in only)

    // Aug 15 2026 is a Saturday; Aug 16 2026 is a Sunday.
    func testExactDayNeverShiftsOffWeekends() {
        XCTAssertEqual(DueDateRule.applyShift(day(2026, 8, 15), rule: .exactDay), day(2026, 8, 15))
        XCTAssertEqual(DueDateRule.applyShift(day(2026, 8, 16), rule: .exactDay), day(2026, 8, 16))
    }

    func testPreviousWeekdayShiftsSaturdayAndSundayToFriday() {
        XCTAssertEqual(DueDateRule.applyShift(day(2026, 8, 15), rule: .previousWeekday), day(2026, 8, 14))
        XCTAssertEqual(DueDateRule.applyShift(day(2026, 8, 16), rule: .previousWeekday), day(2026, 8, 14))
        // Weekdays are untouched.
        XCTAssertEqual(DueDateRule.applyShift(day(2026, 8, 17), rule: .previousWeekday), day(2026, 8, 17))
    }

    func testNextWeekdayShiftsSaturdayAndSundayToMonday() {
        XCTAssertEqual(DueDateRule.applyShift(day(2026, 8, 15), rule: .nextWeekday), day(2026, 8, 17))
        XCTAssertEqual(DueDateRule.applyShift(day(2026, 8, 16), rule: .nextWeekday), day(2026, 8, 17))
        XCTAssertEqual(DueDateRule.applyShift(day(2026, 8, 14), rule: .nextWeekday), day(2026, 8, 14))
    }

    func testShiftAcrossAMonthBoundary() {
        // Nov 1 2026 is a Sunday; previous weekday lands in October.
        XCTAssertEqual(
            DueDateRule.occurrence(dueDay: 1, inMonthOf: day(2026, 11, 15), shift: .previousWeekday),
            day(2026, 10, 30)
        )
    }

    func testOccurrenceWindowFiltersAfterShifting() {
        // Day 1, Nov 2026 (Sunday) with previousWeekday shifts to Oct 30 —
        // outside a November-only window, so it must not be reported there…
        let november = DueDateRule.occurrences(
            dueDay: 1, from: day(2026, 11, 1), to: day(2026, 12, 1), shift: .previousWeekday
        )
        XCTAssertTrue(november.isEmpty)
        // …and an October window must include the shifted date.
        let october = DueDateRule.occurrences(
            dueDay: 1, from: day(2026, 10, 1), to: day(2026, 11, 1), shift: .previousWeekday
        )
        XCTAssertTrue(october.contains(day(2026, 10, 30)))
    }

    // MARK: - DST-adjacent stability

    // US DST: spring-forward Mar 8 2026, fall-back Nov 1 2026. The intended
    // local calendar day must be preserved regardless of the offset change.
    func testOccurrencesKeepTheirLocalDayAcrossDSTTransitions() {
        for dueDay in [1, 8, 15, 31] {
            let result = DueDateRule.occurrences(dueDay: dueDay, from: day(2026, 2, 1), to: day(2026, 4, 15))
            for date in result {
                let c = components(date)
                let daysInMonth = DateMath.calendar.range(of: .day, in: .month, for: date)!.count
                XCTAssertEqual(c.day, min(dueDay, daysInMonth), "due day drifted at \(date)")
                XCTAssertEqual(date, DateMath.startOfDay(date), "occurrence not a local start-of-day")
            }
        }
        let fallBack = DueDateRule.occurrences(dueDay: 1, from: day(2026, 10, 15), to: day(2026, 11, 15))
        XCTAssertEqual(fallBack, [day(2026, 11, 1)])
    }

    // MARK: - Audit note

    func testAuditNoteRecordsBothDirections() {
        let note = DueDateRule.auditNote(field: "due day", from: 12, to: 15, on: day(2026, 8, 11))
        XCTAssertTrue(note.contains("12"))
        XCTAssertTrue(note.contains("15"))
        let cleared = DueDateRule.auditNote(field: "due day", from: 12, to: nil, on: day(2026, 8, 11))
        XCTAssertTrue(cleared.contains("none"))
    }

    func testAppendDueDateAuditAccumulatesOnTheItem() {
        let debt = DebtAccount(planID: "A", displayName: "Card A", startingBalance: 100, apr: 0.2, priority: 1)
        debt.appendDueDateAudit("first")
        debt.appendDueDateAudit("second")
        XCTAssertEqual(debt.dueDateAuditLog, "first\nsecond")
        let obligation = RecurringObligation(name: "Rent", amount: 1200, cadence: .monthly)
        obligation.appendDueDateAudit("first")
        XCTAssertEqual(obligation.dueDateAuditLog, "first")
    }

    func testShiftRuleRoundTripsThroughRawStorage() {
        let debt = DebtAccount(planID: "A", displayName: "Card A", startingBalance: 100, apr: 0.2, priority: 1)
        XCTAssertEqual(debt.dueDateShiftRule, .exactDay)
        debt.dueDateShiftRule = .nextWeekday
        XCTAssertEqual(debt.dueDateShiftRuleRaw, "nextWeekday")
        debt.dueDateShiftRule = .exactDay
        XCTAssertNil(debt.dueDateShiftRuleRaw, "exactDay stores nil so migrated rows and defaults are identical")
    }
}
