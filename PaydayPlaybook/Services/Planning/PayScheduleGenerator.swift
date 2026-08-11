import Foundation

/// Deterministic payday timeline generation for all supported cadences
/// (R-01, R-11). All returned dates are local start-of-day; arithmetic is
/// calendar-day based, so DST transitions never shift a payday or change an
/// accrual day count.
enum PayScheduleGenerator {

    /// Clamps a 1…31 day-of-month to the month containing `anchor`'s
    /// year/month shifted by `monthOffset`, per R-11 (Jan 31 → Feb 28/29).
    static func clampedDate(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        let calendar = DateMath.calendar
        guard let firstOfMonth = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: firstOfMonth) else {
            preconditionFailure("Invalid month \(year)-\(month)")
        }
        components.day = min(max(day, 1), range.count)
        guard let date = calendar.date(from: components) else {
            preconditionFailure("Invalid clamped date \(year)-\(month)-\(day)")
        }
        return calendar.startOfDay(for: date)
    }

    /// True when `day` needed clamping in the month of `date`.
    static func dayNeedsClamping(_ day: Int, inMonthOf date: Date) -> Bool {
        let calendar = DateMath.calendar
        guard let range = calendar.range(of: .day, in: .month, for: date) else { return false }
        return day > range.count
    }

    private static func yearMonth(of date: Date) -> (year: Int, month: Int) {
        let components = DateMath.calendar.dateComponents([.year, .month], from: date)
        return (components.year ?? 0, components.month ?? 0)
    }

    private static func shiftMonth(year: Int, month: Int, by offset: Int) -> (year: Int, month: Int) {
        let zeroBased = year * 12 + (month - 1) + offset
        return (zeroBased / 12, zeroBased % 12 + 1)
    }

    /// Generates `count` paydays starting at `anchor` (inclusive).
    ///
    /// For semimonthly/monthly cadences the anchor is snapped forward to the
    /// first configured (clamped) day on/after itself, so a slightly-off
    /// anchor still yields a valid timeline. Weekly/biweekly use the anchor
    /// verbatim.
    static func paydays(cadence: PayCadence, anchor: Date, count: Int) -> [Date] {
        guard count > 0 else { return [] }
        let start = DateMath.startOfDay(anchor)
        switch cadence {
        case .weekly:
            return stride(from: 0, to: count, by: 1).map { DateMath.addingDays(7 * $0, to: start) }
        case .biweekly:
            return stride(from: 0, to: count, by: 1).map { DateMath.addingDays(14 * $0, to: start) }
        case .monthly(let day):
            var result: [Date] = []
            var (year, month) = yearMonth(of: start)
            // The anchor month's occurrence may fall before the anchor; skip it.
            var offset = 0
            while result.count < count {
                let (y, m) = shiftMonth(year: year, month: month, by: offset)
                let date = clampedDate(year: y, month: m, day: day)
                if date >= start { result.append(date) }
                offset += 1
            }
            _ = (year, month)
            return result
        case .semimonthly(let firstDay, let secondDay):
            var result: [Date] = []
            let (year, month) = yearMonth(of: start)
            var offset = 0
            while result.count < count {
                let (y, m) = shiftMonth(year: year, month: month, by: offset)
                for day in [firstDay, secondDay].sorted() {
                    let date = clampedDate(year: y, month: m, day: day)
                    if date >= start && result.count < count {
                        // Clamping can collide the two days (e.g. 30 & 31 in
                        // February); keep a single payday for that month.
                        if result.last != date { result.append(date) }
                    }
                }
                offset += 1
            }
            return result
        }
    }

    /// The cadence occurrence immediately before `date` — used to measure the
    /// first paycheck's interest-accrual period.
    static func previousOccurrence(cadence: PayCadence, before date: Date) -> Date {
        let start = DateMath.startOfDay(date)
        switch cadence {
        case .weekly:
            return DateMath.addingDays(-7, to: start)
        case .biweekly:
            return DateMath.addingDays(-14, to: start)
        case .monthly(let day):
            let (year, month) = yearMonth(of: start)
            var offset = 0
            while offset > -3 {
                let (y, m) = shiftMonth(year: year, month: month, by: offset)
                let candidate = clampedDate(year: y, month: m, day: day)
                if candidate < start { return candidate }
                offset -= 1
            }
            return DateMath.addingDays(-30, to: start)
        case .semimonthly(let firstDay, let secondDay):
            let (year, month) = yearMonth(of: start)
            var candidates: [Date] = []
            for offset in [-1, 0] {
                let (y, m) = shiftMonth(year: year, month: month, by: offset)
                for day in [firstDay, secondDay] {
                    candidates.append(clampedDate(year: y, month: m, day: day))
                }
            }
            return candidates.filter { $0 < start }.max()
                ?? DateMath.addingDays(-15, to: start)
        }
    }

    /// Occurrences of a monthly due day within the half-open window
    /// `[start, end)`, clamped per R-11.
    static func dueDates(day: Int, from start: Date, to end: Date) -> [Date] {
        let windowStart = DateMath.startOfDay(start)
        let windowEnd = DateMath.startOfDay(end)
        guard windowStart < windowEnd else { return [] }
        var result: [Date] = []
        let (year, month) = yearMonth(of: windowStart)
        // Look from one month back (a clamped date can precede the window's
        // month day) through the window's end.
        var offset = -1
        while true {
            let (y, m) = shiftMonth(year: year, month: month, by: offset)
            let date = clampedDate(year: y, month: m, day: day)
            if date >= windowEnd { break }
            if date >= windowStart { result.append(date) }
            offset += 1
        }
        return result
    }
}
