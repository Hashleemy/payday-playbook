import Foundation
import SwiftData

/// Kind of debt (V2-04). The type drives which fields are required and how
/// minimums are handled: credit cards may estimate a blank minimum (R-06);
/// installment types require an entered one.
enum DebtType: String, Codable, CaseIterable, Identifiable {
    case creditCard
    case personalLoan
    case autoLoan
    case studentLoan
    case medicalDebt
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .creditCard: return "Credit card"
        case .personalLoan: return "Personal loan"
        case .autoLoan: return "Car note / auto loan"
        case .studentLoan: return "Student loan"
        case .medicalDebt: return "Medical debt"
        case .other: return "Other"
        }
    }

    /// Installment debts require a user-entered minimum (A-06); only credit
    /// cards fall back to the R-06 estimator.
    var requiresEnteredMinimum: Bool { self != .creditCard }

    /// Only credit cards carry a credit limit (and a utilization display).
    var supportsCreditLimit: Bool { self == .creditCard }
}

/// Lifecycle state of a debt, derived — the paid state comes from balances
/// (actual track), never from a stored flag that could drift.
enum DebtStatus: String {
    case active
    case paidOff
    case archived
}

@Model
final class DebtAccount {
    var id: UUID
    /// Stable plan identifier from the seeded plan: "A" through "F".
    var planID: String
    var displayName: String
    /// Optional last four digits only. Full account numbers are never stored.
    var lastFour: String?
    var startingBalance: Decimal
    var apr: Decimal
    /// User-entered current minimum payment; nil means use the baseline estimate.
    var minimumAmount: Decimal?
    var dueDayOfMonth: Int?
    var priority: Int
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date
    /// V2-04. Migrated 0.1.x rows default to `.creditCard` — they were cards.
    var debtTypeRaw: String = DebtType.creditCard.rawValue
    /// V2-05. Optional; nil means unknown — never fabricated by migration.
    /// Percent-paid display falls back to `startingBalance` when nil, exactly
    /// as 0.1.x computed it.
    var originalPrincipal: Decimal?
    /// V2-05. Credit cards only; nil means unknown, and no utilization shows.
    var creditLimit: Decimal?
    /// V2-05 / R-07. Ineligible debts receive minimums only.
    var isExtraPrincipalEligible: Bool = true
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

    var debtType: DebtType {
        get { DebtType(rawValue: debtTypeRaw) ?? .creditCard }
        set { debtTypeRaw = newValue.rawValue }
    }

    /// Denominator for percent-paid display (never allocation).
    var principalBasis: Decimal {
        originalPrincipal ?? startingBalance
    }

    /// R-12: utilization for display/insights only; nil without a limit.
    func utilization(currentBalance: Decimal) -> Decimal? {
        guard debtType == .creditCard, let creditLimit, creditLimit > 0 else { return nil }
        return currentBalance / creditLimit
    }

    func status(isPaidOff: Bool) -> DebtStatus {
        if isArchived { return .archived }
        return isPaidOff ? .paidOff : .active
    }

    init(
        id: UUID = UUID(),
        planID: String,
        displayName: String,
        lastFour: String? = nil,
        startingBalance: Decimal,
        apr: Decimal,
        minimumAmount: Decimal? = nil,
        dueDayOfMonth: Int? = nil,
        priority: Int,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        debtType: DebtType = .creditCard,
        originalPrincipal: Decimal? = nil,
        creditLimit: Decimal? = nil,
        isExtraPrincipalEligible: Bool = true
    ) {
        self.id = id
        self.planID = planID
        self.displayName = displayName
        self.lastFour = lastFour
        self.startingBalance = startingBalance
        self.apr = apr
        self.minimumAmount = minimumAmount
        self.dueDayOfMonth = dueDayOfMonth
        self.priority = priority
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.debtTypeRaw = debtType.rawValue
        self.originalPrincipal = originalPrincipal
        self.creditLimit = creditLimit
        self.isExtraPrincipalEligible = isExtraPrincipalEligible
    }
}
