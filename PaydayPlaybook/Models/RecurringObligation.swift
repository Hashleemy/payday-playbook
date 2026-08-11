import Foundation
import SwiftData

/// Cadence of an essential recurring obligation (V2-07).
enum ObligationCadence: String, Codable, CaseIterable, Identifiable {
    case weekly
    case biweekly
    case monthly
    case quarterly
    case semiannual
    case annual

    var id: String { rawValue }

    /// Occurrences per year for the R-04 smoothing rule.
    var occurrencesPerYear: Int {
        switch self {
        case .weekly: return 52
        case .biweekly: return 26
        case .monthly: return 12
        case .quarterly: return 4
        case .semiannual: return 2
        case .annual: return 1
        }
    }

    var displayName: String {
        switch self {
        case .weekly: return "Weekly"
        case .biweekly: return "Every two weeks"
        case .monthly: return "Monthly"
        case .quarterly: return "Quarterly"
        case .semiannual: return "Twice a year"
        case .annual: return "Yearly"
        }
    }
}

/// An essential must-pay recurring expense (rent, car, transit, insurance, …).
/// The per-paycheck reserve is derived via `ObligationMath.perPaycheckReserve`
/// (R-04), never stored here — it is frozen into plan items at generation.
@Model
final class RecurringObligation {
    var id: UUID = UUID()
    var name: String = ""
    var amount: Decimal = Decimal.zero
    var cadenceRaw: String = ObligationCadence.monthly.rawValue
    /// Optional due day-of-month, clamped per R-11 (31 means "last day" in
    /// shorter months by construction of the clamping rule).
    var dueDay: Int?
    /// Cash account the obligation is paid from (usually a reserves account).
    var accountID: UUID?
    var isArchived: Bool = false
    /// Set only by migration for Lem's car/train rows: "car" / "train".
    /// Maps legacy fixed-reserve fields and ledger entry types to this row.
    var legacyKey: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// V2-11: user-selected weekend handling for the due date. Nil means
    /// `.exactDay` — dates never shift unless the user chose a rule.
    var dueDateShiftRuleRaw: String?
    /// V2-11 / MVP_LAYOUT §9: newline-separated audit trail of due-date
    /// edits, appended prospectively; historical rows are never rewritten.
    var dueDateAuditLog: String?
    /// V2-11: the date the current due day took effect. Nil means "always"
    /// — the due day has never been edited, so it describes history too.
    /// Once edited, occurrences before this date are not rendered: the app
    /// does not know what the old due day was and will not invent one.
    var dueDayEffectiveFrom: Date?

    var dueDateShiftRule: DueDateShiftRule {
        get { dueDateShiftRuleRaw.flatMap(DueDateShiftRule.init(rawValue:)) ?? .exactDay }
        set { dueDateShiftRuleRaw = newValue == .exactDay ? nil : newValue.rawValue }
    }

    func appendDueDateAudit(_ note: String) {
        dueDateAuditLog = dueDateAuditLog.map { $0 + "\n" + note } ?? note
    }

    var cadence: ObligationCadence {
        get { ObligationCadence(rawValue: cadenceRaw) ?? .monthly }
        set { cadenceRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        amount: Decimal,
        cadence: ObligationCadence,
        dueDay: Int? = nil,
        accountID: UUID? = nil,
        isArchived: Bool = false,
        legacyKey: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.cadenceRaw = cadence.rawValue
        self.dueDay = dueDay
        self.accountID = accountID
        self.isArchived = isArchived
        self.legacyKey = legacyKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// MVP_LAYOUT §6 names this model `Obligation`; the storage type is
/// `RecurringObligation`. Either name resolves to the same model.
typealias Obligation = RecurringObligation
