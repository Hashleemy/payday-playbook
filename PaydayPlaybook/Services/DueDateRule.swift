import Foundation

/// User-selectable weekend handling for a due date (V2-11).
///
/// A due date stays on its exact calendar day unless the user picks a shift
/// rule — the app never silently moves a date off a weekend. Holiday shifting
/// is deliberately unsupported: iOS provides no holiday calendar, and a wrong
/// holiday guess is worse than none.
enum DueDateShiftRule: String, Codable, CaseIterable, Identifiable {
    /// Default: the due date is the calendar day, weekend or not.
    case exactDay
    /// Saturday/Sunday occurrences move back to Friday.
    case previousWeekday
    /// Saturday/Sunday occurrences move forward to Monday.
    case nextWeekday

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .exactDay: return "Exact day (never shift)"
        case .previousWeekday: return "Weekend → previous Friday"
        case .nextWeekday: return "Weekend → next Monday"
        }
    }
}

/// Due-date occurrence math shared by the calendar, the notification
/// scheduler, and the dashboards (V2-11, R-11).
///
/// One rule set for every consumer:
/// - Day 29/30/31 maps to the month's last valid day when the month is
///   shorter (delegated to `PayScheduleGenerator.clampedDate`, the single
///   R-11 implementation in the codebase).
/// - All math is calendar-component based in the user's current calendar, so
///   the *local* date is preserved across time-zone moves and DST
///   transitions — a "due on the 15th" stays the 15th on the wall calendar.
/// - Weekend shifting only happens under an explicit `DueDateShiftRule`.
enum DueDateRule {

    /// The stored due-day range. 29–31 are legal and clamp per R-11;
    /// the 0.1.x editor's 1–28 restriction is lifted in v0.2.0.
    static let validDays = 1...31

    /// The occurrence of `dueDay` in the month containing `monthReference`,
    /// clamped to the month's last valid day, with the shift rule applied.
    static func occurrence(dueDay: Int, inMonthOf monthReference: Date, shift: DueDateShiftRule = .exactDay) -> Date {
        let components = DateMath.calendar.dateComponents([.year, .month], from: monthReference)
        let clamped = PayScheduleGenerator.clampedDate(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: dueDay
        )
        return applyShift(clamped, rule: shift)
    }

    /// All occurrences of a monthly `dueDay` inside the half-open window
    /// `[start, end)`, clamped per R-11, then shifted per rule. A shift can
    /// move an occurrence across the window edge; the filter runs after the
    /// shift so what the user sees is what fires.
    static func occurrences(dueDay: Int, from start: Date, to end: Date, shift: DueDateShiftRule = .exactDay) -> [Date] {
        let windowStart = DateMath.startOfDay(start)
        let windowEnd = DateMath.startOfDay(end)
        guard windowStart < windowEnd else { return [] }
        // Over-scan by a few days on both edges: a ±2-day weekend shift can
        // pull an outside occurrence in or push an inside one out.
        let scanStart = DateMath.addingDays(-4, to: windowStart)
        let scanEnd = DateMath.addingDays(4, to: windowEnd)
        return PayScheduleGenerator.dueDates(day: dueDay, from: scanStart, to: scanEnd)
            .map { applyShift($0, rule: shift) }
            .filter { $0 >= windowStart && $0 < windowEnd }
    }

    /// The next occurrence (after shifting) on or after `date`.
    static func nextOccurrence(dueDay: Int, onOrAfter date: Date, shift: DueDateShiftRule = .exactDay) -> Date {
        let floor = DateMath.startOfDay(date)
        // Two months is always enough: every month contains one occurrence,
        // and a shift moves it at most two days.
        let horizon = DateMath.addingDays(70, to: floor)
        return occurrences(dueDay: dueDay, from: floor, to: horizon, shift: shift).first
            ?? occurrence(dueDay: dueDay, inMonthOf: horizon, shift: shift)
    }

    /// True when `dueDay` does not exist in the month of `date` (Feb 30, …),
    /// meaning the rendered occurrence was clamped to the month's last day.
    static func isClamped(dueDay: Int, inMonthOf date: Date) -> Bool {
        PayScheduleGenerator.dayNeedsClamping(dueDay, inMonthOf: date)
    }

    /// Applies a weekend shift rule. Gregorian weekday numbers: 1 = Sunday,
    /// 7 = Saturday. `exactDay` returns the date untouched.
    static func applyShift(_ date: Date, rule: DueDateShiftRule) -> Date {
        guard rule != .exactDay else { return date }
        let weekday = DateMath.calendar.component(.weekday, from: date)
        switch (rule, weekday) {
        case (.previousWeekday, 7): return DateMath.addingDays(-1, to: date)  // Sat → Fri
        case (.previousWeekday, 1): return DateMath.addingDays(-2, to: date)  // Sun → Fri
        case (.nextWeekday, 7): return DateMath.addingDays(2, to: date)       // Sat → Mon
        case (.nextWeekday, 1): return DateMath.addingDays(1, to: date)       // Sun → Mon
        default: return date
        }
    }

    /// One-line audit entry for a due-date edit (MVP_LAYOUT §9: the edit
    /// "appends an audit note to the item").
    static func auditNote(field: String, from oldValue: Int?, to newValue: Int?, on date: Date) -> String {
        let old = oldValue.map(String.init) ?? "none"
        let new = newValue.map(String.init) ?? "none"
        return "\(DateMath.mediumString(date)): \(field) \(old) → \(new)"
    }
}
