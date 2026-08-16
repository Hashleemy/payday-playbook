import Foundation
import SwiftData

/// Anything that carries an editable due rule: today a `DebtAccount` or a
/// `RecurringObligation` (V3-07).
///
/// The two models spell the day field differently (`dueDayOfMonth` vs
/// `dueDay`) for historical reasons, and both are owned elsewhere. This
/// protocol is the adapter, so the editor UI, the audit log, and the
/// reconciler have exactly one notion of "the due rule" and there is no
/// second, silently-diverging copy of the edit logic per screen — the
/// duplicated-bridge failure this release is explicitly avoiding.
protocol DueRuleSubject: AnyObject {
    /// Stable entity identity. Notification identifiers and deep links key on
    /// this, never on a row position or a plan letter.
    var dueRuleSubjectID: UUID { get }
    /// User-entered label. Used for on-screen headings only — never written
    /// into an identifier, an audit note, or lock-screen copy (V3-13).
    var dueRuleDisplayName: String { get }
    /// Copy naming what this subject is, for the editor's disclosure text.
    var dueRuleSubjectNoun: String { get }

    var dueRule: DueRule { get set }
    var dueRuleEffectiveFrom: Date? { get set }
    var dueRuleUpdatedAt: Date { get set }

    func appendDueRuleAudit(_ note: String)
}

extension DebtAccount: DueRuleSubject {
    var dueRuleSubjectID: UUID { id }
    var dueRuleDisplayName: String { displayName }
    var dueRuleSubjectNoun: String { "debt" }

    var dueRule: DueRule {
        get { DueRule(dueDay: dueDayOfMonth, shift: dueDateShiftRule) }
        set {
            dueDayOfMonth = newValue.dueDay
            dueDateShiftRule = newValue.shift
        }
    }

    var dueRuleEffectiveFrom: Date? {
        get { dueDayEffectiveFrom }
        set { dueDayEffectiveFrom = newValue }
    }

    var dueRuleUpdatedAt: Date {
        get { updatedAt }
        set { updatedAt = newValue }
    }

    func appendDueRuleAudit(_ note: String) { appendDueDateAudit(note) }
}

extension RecurringObligation: DueRuleSubject {
    var dueRuleSubjectID: UUID { id }
    var dueRuleDisplayName: String { name }
    var dueRuleSubjectNoun: String { "bill" }

    var dueRule: DueRule {
        get { DueRule(dueDay: dueDay, shift: dueDateShiftRule) }
        set {
            dueDay = newValue.dueDay
            dueDateShiftRule = newValue.shift
        }
    }

    var dueRuleEffectiveFrom: Date? {
        get { dueDayEffectiveFrom }
        set { dueDayEffectiveFrom = newValue }
    }

    var dueRuleUpdatedAt: Date {
        get { updatedAt }
        set { updatedAt = newValue }
    }

    func appendDueRuleAudit(_ note: String) { appendDueDateAudit(note) }
}

/// The single prospective due-rule mutation path (V3-07, MVP_LAYOUT §9).
///
/// Every entry point — the consolidated Bills & Debts setup page, the debt
/// detail editor, and the obligation due-dates settings screen — routes its
/// save through `apply`, so all three produce the same audit trail, the same
/// effective date, and the same calendar/notification consequences. A screen
/// that mutated the fields itself would be the second implementation, and
/// the two would disagree the first time one of them changed.
enum DueRuleEditService {

    enum ValidationError: LocalizedError, Equatable {
        case dayOutOfRange

        var errorDescription: String? {
            switch self {
            case .dayOutOfRange:
                return "Enter a due day between 1 and 31, or leave it blank."
            }
        }
    }

    /// What the save actually did, so the caller can decide whether a
    /// reconcile is even needed and what to tell the user.
    struct Outcome: Equatable {
        /// False when the submitted rule matched the stored one. An unchanged
        /// save must not stamp a new effective date: that would blank out the
        /// item's already-rendered history for no reason.
        var didChange: Bool
        var previousRule: DueRule
        var newRule: DueRule
        /// Set when the new rule's day does not exist in every month, so the
        /// editor can disclose the clamp rather than let it surprise the user.
        var clampDisclosure: String?

        var needsReconcile: Bool { didChange }
    }

    /// Parses the editor's free-text day field. Blank means "no due day",
    /// which is a legal rule: the item keeps its per-paycheck reserve and
    /// simply gets no marker and no reminder.
    static func parseDueDay(_ text: String) throws -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let day = Int(trimmed), DueDateRule.validDays.contains(day) else {
            throw ValidationError.dayOutOfRange
        }
        return day
    }

    /// Applies a due rule prospectively and saves.
    ///
    /// Prospective means two things, and both matter for V3-07:
    /// 1. `dueRuleEffectiveFrom` is stamped to today, so the calendar stops
    ///    redrawing *past* months with a rule that was not in force then —
    ///    completed and historical events do not move.
    /// 2. The change is stamped for **either** field. The v0.2.0 editors only
    ///    stamped it when the day number changed, which let a weekend-shift
    ///    change silently move every already-rendered past occurrence by up
    ///    to two days. A shift rule is part of the rule.
    ///
    /// Reconciling the notification schedule is deliberately *not* done here:
    /// the scheduler is main-actor and permission-aware, and the caller must
    /// await it before dismissing its editor. `Outcome.needsReconcile` says
    /// whether that is required.
    @discardableResult
    static func apply(
        _ requested: DueRule,
        to subject: any DueRuleSubject,
        now: Date,
        context: ModelContext
    ) throws -> Outcome {
        let previous = subject.dueRule.normalized
        let next = requested.normalized

        guard previous != next else {
            return Outcome(
                didChange: false,
                previousRule: previous,
                newRule: next,
                clampDisclosure: clampDisclosure(for: next, now: now)
            )
        }

        // Audit before mutating, so the note is written from the values that
        // were actually stored rather than from what the view believed.
        if previous.dueDay != next.dueDay {
            subject.appendDueRuleAudit(DueDateRule.auditNote(
                field: "due day", from: previous.dueDay, to: next.dueDay, on: now
            ))
        }
        if previous.shift != next.shift {
            subject.appendDueRuleAudit(DueDateRule.auditNote(
                field: "weekend rule",
                from: previous.shift.rawValue,
                to: next.shift.rawValue,
                on: now
            ))
        }

        subject.dueRule = next
        subject.dueRuleEffectiveFrom = DateMath.startOfDay(now)
        subject.dueRuleUpdatedAt = now
        try context.save()

        return Outcome(
            didChange: true,
            previousRule: previous,
            newRule: next,
            clampDisclosure: clampDisclosure(for: next, now: now)
        )
    }

    /// Plain-language disclosure for a day that does not exist every month
    /// (R-11). Returns nil for days 1–28, which never clamp.
    ///
    /// The copy names the next month that actually clamps, because "the last
    /// day of shorter months" is abstract and "February 28" is not.
    static func clampDisclosure(for rule: DueRule, now: Date) -> String? {
        guard let day = rule.dueDay, day > 28 else { return nil }
        let today = DateMath.startOfDay(now)
        // A 14-month scan always contains a February, which is the shortest
        // month and therefore always clamps a day above 28.
        var cursor = today
        for _ in 0..<14 {
            if DueDateRule.isClamped(dueDay: day, inMonthOf: cursor) {
                let landing = DueDateRule.occurrence(dueDay: day, inMonthOf: cursor, shift: rule.shift)
                return "Day \(day) doesn't exist in every month. The next short month uses its last day instead — \(DateMath.mediumString(landing))."
            }
            cursor = DateMath.calendar.date(byAdding: .month, value: 1, to: cursor) ?? cursor
        }
        return nil
    }
}
