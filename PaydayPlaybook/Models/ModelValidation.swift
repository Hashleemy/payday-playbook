import Foundation

/// Model-level validation for schema-2 inputs. Pure functions, no SwiftData:
/// callers validate before insert/update so invalid rows never persist.
/// Messages are calm and specific (soul principle 5) — screens surface them
/// inline without losing input.
enum ModelValidationError: LocalizedError, Equatable {
    case emptyName
    case negativeAmount(field: String)
    case zeroOrNegativeAmount(field: String)
    case invalidDay(Int)
    case missingMinimum(DebtType)
    case creditLimitOnNonCard(DebtType)
    case lastFourInvalid
    case noRoles
    case duplicateSemimonthlyDays
    case payDateInPast

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "A name is needed."
        case .negativeAmount(let field):
            return "\(field) can't be negative."
        case .zeroOrNegativeAmount(let field):
            return "\(field) needs to be more than zero."
        case .invalidDay(let day):
            return "Day \(day) isn't a valid day of the month (1–31)."
        case .missingMinimum(let type):
            return "\(type.displayName) needs its contractual payment amount."
        case .creditLimitOnNonCard(let type):
            return "\(type.displayName) doesn't carry a credit limit."
        case .lastFourInvalid:
            return "Only the last four digits, never a full account number."
        case .noRoles:
            return "Pick at least one role for this account."
        case .duplicateSemimonthlyDays:
            return "Twice-a-month paydays need two different days."
        case .payDateInPast:
            return "The next payday needs to be today or later."
        }
    }
}

enum ModelValidation {

    // MARK: - Cash accounts (V2-03)

    static func validateCashAccount(
        name: String,
        currentBalance: Decimal,
        roles: Set<AccountRole>
    ) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelValidationError.emptyName
        }
        guard currentBalance >= 0 else {
            throw ModelValidationError.negativeAmount(field: "The balance")
        }
        guard !roles.isEmpty else {
            throw ModelValidationError.noRoles
        }
    }

    // MARK: - Debts (V2-04, V2-05)

    /// Per-type rules from MVP_LAYOUT §4.7: installment debts require an
    /// entered minimum (A-06); only cards carry a limit; APR may be 0%;
    /// last-four is at most four digits — never a full number (V2-17).
    static func validateDebt(
        type: DebtType,
        displayName: String,
        currentBalance: Decimal,
        originalPrincipal: Decimal?,
        apr: Decimal,
        minimumAmount: Decimal?,
        creditLimit: Decimal?,
        dueDayOfMonth: Int?,
        lastFour: String?
    ) throws {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelValidationError.emptyName
        }
        guard currentBalance >= 0 else {
            throw ModelValidationError.negativeAmount(field: "The balance")
        }
        if let originalPrincipal {
            guard originalPrincipal >= 0 else {
                throw ModelValidationError.negativeAmount(field: "The original principal")
            }
        }
        guard apr >= 0 else {
            throw ModelValidationError.negativeAmount(field: "The APR")
        }
        if type.requiresEnteredMinimum {
            guard let minimumAmount, minimumAmount > 0 else {
                throw ModelValidationError.missingMinimum(type)
            }
        } else if let minimumAmount {
            guard minimumAmount >= 0 else {
                throw ModelValidationError.negativeAmount(field: "The minimum payment")
            }
        }
        if let creditLimit {
            guard type.supportsCreditLimit else {
                throw ModelValidationError.creditLimitOnNonCard(type)
            }
            guard creditLimit > 0 else {
                throw ModelValidationError.zeroOrNegativeAmount(field: "The credit limit")
            }
        }
        if let dueDayOfMonth {
            try validateDayOfMonth(dueDayOfMonth)
        }
        if let lastFour, !lastFour.isEmpty {
            guard lastFour.count <= 4, lastFour.allSatisfy(\.isNumber) else {
                throw ModelValidationError.lastFourInvalid
            }
        }
    }

    // MARK: - Obligations (V2-07)

    static func validateObligation(
        name: String,
        amount: Decimal,
        dueDay: Int?
    ) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelValidationError.emptyName
        }
        guard amount > 0 else {
            throw ModelValidationError.zeroOrNegativeAmount(field: "The amount")
        }
        if let dueDay {
            try validateDayOfMonth(dueDay)
        }
    }

    // MARK: - Income (V2-06)

    static func validateIncomeSchedule(
        cadence: PayCadence,
        takeHome: Decimal,
        monthlyDay: Int?,
        semimonthlyFirstDay: Int?,
        semimonthlySecondDay: Int?
    ) throws {
        guard takeHome > 0 else {
            throw ModelValidationError.zeroOrNegativeAmount(field: "The take-home amount")
        }
        switch cadence {
        case .monthly:
            try validateDayOfMonth(monthlyDay ?? 0)
        case .semimonthly:
            try validateDayOfMonth(semimonthlyFirstDay ?? 0)
            try validateDayOfMonth(semimonthlySecondDay ?? 0)
        case .weekly, .biweekly:
            break
        }
    }

    // MARK: - Shared

    /// Days are stored 1–31; months shorter than the stored day clamp to
    /// their last day per R-11 (so 31 means "last day" everywhere).
    static func validateDayOfMonth(_ day: Int) throws {
        guard (1...31).contains(day) else {
            throw ModelValidationError.invalidDay(day)
        }
    }
}
