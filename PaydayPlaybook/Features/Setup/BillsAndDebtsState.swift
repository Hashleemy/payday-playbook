import Foundation
import SwiftData

/// The summary and warning state for the consolidated Bills & Debts page
/// (V3-08). One assembly, shared by the onboarding step and the Settings page,
/// so the two surfaces can never disagree about what is missing.
struct BillsAndDebtsState {
    struct BillRow: Identifiable, Equatable {
        var id: UUID
        var name: String
        var amount: Decimal
        var cadence: ObligationCadence
        var dueDay: Int?
        var isEssential: Bool
        var perPaycheckReserve: Decimal
        var accountName: String?
        /// Fields this row still needs, in the user's words.
        var warnings: [String]

        var detailText: String {
            var parts = [cadence.displayName]
            if let dueDay { parts.append("due the \(SetupDayField.dayLabel(dueDay))") }
            if let accountName { parts.append("from \(accountName)") }
            return parts.joined(separator: " · ")
        }

        var accessibilityLabel: String {
            var parts = [
                name,
                MoneyFormat.string(amount),
                detailText,
                "\(MoneyFormat.string(perPaycheckReserve)) set aside per paycheck"
            ]
            if !isEssential { parts.append("Not essential, left out of the plan's reserves") }
            parts.append(contentsOf: warnings.map { "Missing: \($0)" })
            return parts.joined(separator: ", ")
        }
    }

    struct DebtRow: Identifiable, Equatable {
        var id: UUID
        var name: String
        var debtType: DebtType
        var balance: Decimal
        var apr: Decimal
        var minimumAmount: Decimal?
        var minimumIsEstimated: Bool
        var dueDay: Int?
        var isExtraPrincipalEligible: Bool
        var prepayment: PrepaymentEligibility
        var warnings: [String]

        var detailText: String {
            var parts = [debtType.displayName, "\(SetupPercentField.percentString(apr))% APR"]
            if let minimumAmount {
                parts.append("\(minimumIsEstimated ? "est. " : "")min \(MoneyFormat.string(minimumAmount))")
            } else {
                parts.append("min estimated")
            }
            if let dueDay { parts.append("due the \(SetupDayField.dayLabel(dueDay))") }
            return parts.joined(separator: " · ")
        }

        var accessibilityLabel: String {
            var parts = [name, MoneyFormat.string(balance), detailText]
            if !isExtraPrincipalEligible {
                parts.append(
                    prepayment == .ineligible
                        ? "Extra principal not allowed"
                        : "Extra principal on hold until you confirm"
                )
            }
            parts.append(contentsOf: warnings.map { "Missing: \($0)" })
            return parts.joined(separator: ", ")
        }
    }

    var bills: [BillRow] = []
    var debts: [DebtRow] = []
    var archivedBillCount = 0
    var archivedDebtCount = 0

    /// Summary header figures (§5.2 item 1).
    var billTotal: Decimal = .zero
    var billReservePerPaycheck: Decimal = .zero
    var debtMinimumTotal: Decimal = .zero
    var debtPrincipalTotal: Decimal = .zero
    /// The pay cadence the reserve preview is smoothed against, so the page
    /// can say which cadence it assumed when income is not entered yet.
    var payCadence: PayCadence = .biweekly
    var incomeEntered = false

    var incompleteCount: Int {
        bills.filter { !$0.warnings.isEmpty }.count + debts.filter { !$0.warnings.isEmpty }.count
    }

    var isEmpty: Bool { bills.isEmpty && debts.isEmpty }
}

// MARK: - Loader

struct BillsAndDebtsLoader {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func load() throws -> BillsAndDebtsState {
        var state = BillsAndDebtsState()

        let schedule = try IncomeRepository(context: context).activeSchedule()
        state.incomeEntered = schedule != nil
        // Biweekly until income is entered, matching the v0.2.0 obligations
        // step so the per-paycheck preview does not jump when the two screens
        // merged into one.
        state.payCadence = schedule?.cadence ?? .biweekly
        let paychecksPerYear = state.payCadence.paychecksPerYear

        let accountNames = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<CashAccount>()).map { ($0.id, $0.name) }
        )

        let obligations = try context.fetch(FetchDescriptor<RecurringObligation>())
        state.archivedBillCount = obligations.filter(\.isArchived).count
        state.bills = obligations
            .filter { !$0.isArchived }
            .sorted { ($0.sortOrder, $0.createdAt, $0.name) < ($1.sortOrder, $1.createdAt, $1.name) }
            .map { obligation in
                BillsAndDebtsState.BillRow(
                    id: obligation.id,
                    name: obligation.name,
                    amount: obligation.amount,
                    cadence: obligation.cadence,
                    dueDay: obligation.dueDay,
                    isEssential: obligation.isEssential,
                    perPaycheckReserve: ObligationMath.perPaycheckReserve(
                        amount: obligation.amount,
                        cadence: obligation.cadence,
                        paychecksPerYear: paychecksPerYear
                    ),
                    accountName: obligation.accountID.flatMap { accountNames[$0] },
                    warnings: Self.warnings(for: obligation)
                )
            }

        let debts = try context.fetch(FetchDescriptor<DebtAccount>())
        state.archivedDebtCount = debts.filter(\.isArchived).count
        state.debts = debts
            .filter { !$0.isArchived }
            .sorted { ($0.priority, $0.createdAt) < ($1.priority, $1.createdAt) }
            .map { debt in
                BillsAndDebtsState.DebtRow(
                    id: debt.id,
                    name: debt.displayName,
                    debtType: debt.debtType,
                    balance: debt.startingBalance,
                    apr: debt.apr,
                    minimumAmount: debt.minimumAmount,
                    minimumIsEstimated: debt.minimumAmount == nil,
                    dueDay: debt.dueDayOfMonth,
                    isExtraPrincipalEligible: debt.isExtraPrincipalEligible,
                    prepayment: debt.prepayment,
                    warnings: Self.warnings(for: debt)
                )
            }

        state.billTotal = state.bills.reduce(Decimal.zero) { $0 + $1.amount }.rounded2
        // Only essential bills are reserved from a paycheck (V2-07); the rest
        // are the user's own record and never enter the generator.
        state.billReservePerPaycheck = state.bills
            .filter(\.isEssential)
            .reduce(Decimal.zero) { $0 + $1.perPaycheckReserve }
            .rounded2
        state.debtPrincipalTotal = state.debts.reduce(Decimal.zero) { $0 + $1.balance }.rounded2
        state.debtMinimumTotal = state.debts
            .reduce(Decimal.zero) { $0 + ($1.minimumAmount ?? .zero) }
            .rounded2
        return state
    }

    // MARK: Missing fields

    /// Missing-field warnings phrased as the thing the user would go and find,
    /// never as a fault. These mirror `SetupCompletenessService`'s non-blocking
    /// gaps so a row's inline warning and the review list say the same thing.
    static func warnings(for obligation: RecurringObligation) -> [String] {
        var warnings: [String] = []
        if obligation.dueDay == nil {
            warnings.append("the day of the month it's due")
        }
        if obligation.amount <= 0 {
            warnings.append("the amount")
        }
        return warnings
    }

    static func warnings(for debt: DebtAccount) -> [String] {
        var warnings: [String] = []
        if debt.debtTypeConfirmedAt == nil {
            warnings.append("what kind of debt it is")
        }
        if debt.minimumAmount == nil, debt.debtType.requiresEnteredMinimum {
            warnings.append("its contractual payment")
        }
        if debt.dueDayOfMonth == nil {
            warnings.append("its due day")
        }
        if debt.debtType == .creditCard, debt.creditLimit == nil, !debt.creditLimitMarkedUnknown {
            warnings.append("the credit limit")
        }
        // V4-01: only debt types with a real original principal are ever told
        // they still need one — a revolving card has no such concept.
        if debt.debtType.usesOriginalPrincipal, debt.originalPrincipal == nil {
            warnings.append("the original amount")
        }
        if debt.debtType != .creditCard, debt.prepayment == .unknown {
            warnings.append("whether extra principal is allowed")
        }
        return warnings
    }
}
