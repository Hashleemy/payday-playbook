import Foundation
import SwiftData

/// Validates payday check-in math and writes completion records atomically.
/// Actual ledger entries are created only from user-confirmed amounts —
/// never inferred from planned values.
struct ReconciliationService {

    enum Issue: Equatable {
        case negativeAmount(field: String)
        case overallocatedIncome(by: Decimal)
        case unallocatedIncome(amount: Decimal)
        case cardPaymentsExceedC2(by: Decimal)
        case missingIncome
        case missingAllocation
        case missingC1Balance

        var message: String {
            switch self {
            case .negativeAmount(let field):
                return "\(field) cannot be negative. Use a refund, reversal, or correction entry instead."
            case .overallocatedIncome(let by):
                return "Allocations exceed income and outside funds by \(MoneyFormat.string(by))."
            case .unallocatedIncome(let amount):
                return "\(MoneyFormat.string(amount)) of this paycheck is not yet allocated."
            case .cardPaymentsExceedC2(let by):
                return "Card payments exceed the money available in Checking 2 by \(MoneyFormat.string(by))."
            case .missingIncome:
                return "Enter the actual take-home amount."
            case .missingAllocation:
                return "Confirm the amounts kept in Checking 1 and moved to Checking 2."
            case .missingC1Balance:
                return "Confirm the current Checking 1 balance."
            }
        }

        /// Blocking issues prevent completion outright; the rest require an
        /// explanation before an unreconciled check can be completed.
        var isBlocking: Bool {
            switch self {
            case .negativeAmount, .missingIncome: return true
            default: return false
            }
        }
    }

    struct DraftAmounts {
        var actualIncome: Decimal?
        var outsideFundsUsed: Decimal
        var actualC1Kept: Decimal?
        var actualC1Balance: Decimal?
        var actualAllowanceSpent: Decimal?
        var actualC2Transfer: Decimal?
        var actualCarReserve: Decimal?
        var actualTrainReserve: Decimal?
        var cardPayments: [String: Decimal]
        /// Optional post-payment balances reported by the user, by plan letter.
        var reportedBalances: [String: Decimal]

        init(
            actualIncome: Decimal? = nil,
            outsideFundsUsed: Decimal = .zero,
            actualC1Kept: Decimal? = nil,
            actualC1Balance: Decimal? = nil,
            actualAllowanceSpent: Decimal? = nil,
            actualC2Transfer: Decimal? = nil,
            actualCarReserve: Decimal? = nil,
            actualTrainReserve: Decimal? = nil,
            cardPayments: [String: Decimal] = [:],
            reportedBalances: [String: Decimal] = [:]
        ) {
            self.actualIncome = actualIncome
            self.outsideFundsUsed = outsideFundsUsed
            self.actualC1Kept = actualC1Kept
            self.actualC1Balance = actualC1Balance
            self.actualAllowanceSpent = actualAllowanceSpent
            self.actualC2Transfer = actualC2Transfer
            self.actualCarReserve = actualCarReserve
            self.actualTrainReserve = actualTrainReserve
            self.cardPayments = cardPayments
            self.reportedBalances = reportedBalances
        }

        var paymentsTotal: Decimal {
            cardPayments.values.reduce(.zero, +)
        }

        /// income + outside funds − kept − transferred.
        var unallocated: Decimal? {
            guard let actualIncome, let actualC1Kept, let actualC2Transfer else { return nil }
            return (actualIncome + outsideFundsUsed - actualC1Kept - actualC2Transfer).rounded2
        }
    }

    /// Validates a draft. `priorC2Available` is Checking 2 money already on
    /// hand for debt before this check's transfer.
    static func validate(_ draft: DraftAmounts, priorC2Available: Decimal = .zero) -> [Issue] {
        var issues: [Issue] = []

        let namedFields: [(String, Decimal?)] = [
            ("Take-home income", draft.actualIncome),
            ("Outside funds", draft.outsideFundsUsed),
            ("Checking 1 kept amount", draft.actualC1Kept),
            ("Allowance spending", draft.actualAllowanceSpent),
            ("Checking 2 transfer", draft.actualC2Transfer),
            ("Car reserve", draft.actualCarReserve),
            ("Train reserve", draft.actualTrainReserve)
        ]
        for (name, value) in namedFields {
            if let value, value.isNegative {
                issues.append(.negativeAmount(field: name))
            }
        }
        for (card, amount) in draft.cardPayments where amount.isNegative {
            issues.append(.negativeAmount(field: "Payment to card \(card)"))
        }

        guard draft.actualIncome != nil else {
            issues.append(.missingIncome)
            return issues
        }

        // Unconfirmed kept/transfer amounts mean the equation cannot be
        // checked — the check-in is unreconciled until they are confirmed.
        if draft.actualC1Kept == nil || draft.actualC2Transfer == nil {
            issues.append(.missingAllocation)
        }

        if draft.actualC1Balance == nil {
            issues.append(.missingC1Balance)
        }

        if let unallocated = draft.unallocated {
            if unallocated.isNegative {
                issues.append(.overallocatedIncome(by: -unallocated))
            } else if unallocated > 0 {
                issues.append(.unallocatedIncome(amount: unallocated))
            }
        }

        // With no confirmed transfer, any recorded payment is unfunded.
        let transferForFunding = draft.actualC2Transfer ?? .zero
        let car = draft.actualCarReserve ?? .zero
        let train = draft.actualTrainReserve ?? .zero
        let availableForCards = transferForFunding - car - train + priorC2Available
        let overspend = (draft.paymentsTotal - availableForCards).rounded2
        if overspend > 0 {
            issues.append(.cardPaymentsExceedC2(by: overspend))
        }

        return issues
    }

    enum CompletionError: LocalizedError {
        case blockingIssues([Issue])
        case unreconciledWithoutExplanation([Issue])

        var errorDescription: String? {
            switch self {
            case .blockingIssues(let issues):
                return issues.map(\.message).joined(separator: " ")
            case .unreconciledWithoutExplanation:
                return "This check-in does not reconcile. Add an explanation before marking it complete."
            }
        }
    }

    struct CompletionResult {
        let checkIn: PaydayCheckIn
        let ledgerEntries: [LedgerEntry]
        let issues: [Issue]
    }

    /// Writes all completion records in one save. Throws without writing
    /// anything if validation fails.
    @discardableResult
    static func completeCheckIn(
        context: ModelContext,
        checkIn: PaydayCheckIn,
        planItem: PaydayPlanItem,
        plan: PlanVersion,
        draft: DraftAmounts,
        debtsByPlanID: [String: DebtAccount],
        priorC2Available: Decimal = .zero,
        exception: String? = nil,
        now: Date = Date()
    ) throws -> CompletionResult {
        let issues = validate(draft, priorC2Available: priorC2Available)

        let blocking = issues.filter(\.isBlocking)
        guard blocking.isEmpty else { throw CompletionError.blockingIssues(blocking) }

        let unreconciled = issues.filter { !$0.isBlocking }
        let trimmedException = exception?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !unreconciled.isEmpty && trimmedException.isEmpty {
            throw CompletionError.unreconciledWithoutExplanation(unreconciled)
        }

        let paydayDate = DateMath.startOfDay(planItem.date)
        var entries: [LedgerEntry] = []

        func add(_ entry: LedgerEntry) {
            entries.append(entry)
            context.insert(entry)
        }

        if let transfer = draft.actualC2Transfer, transfer > 0 {
            add(LedgerEntry(
                effectiveDate: paydayDate, createdAt: now, updatedAt: now,
                type: .c2Transfer, amount: transfer,
                sourceAccount: .external, destinationAccount: .checking2,
                paydayCheckInID: checkIn.id,
                note: "Payday #\(planItem.sequenceNumber) transfer"
            ))
        }
        if let car = draft.actualCarReserve, car > 0 {
            add(LedgerEntry(
                effectiveDate: paydayDate, createdAt: now, updatedAt: now,
                type: .carReserveContribution, amount: car,
                sourceAccount: .checking2, destinationAccount: .checking2,
                paydayCheckInID: checkIn.id,
                note: "Payday #\(planItem.sequenceNumber) car reserve"
            ))
        }
        if let train = draft.actualTrainReserve, train > 0 {
            add(LedgerEntry(
                effectiveDate: paydayDate, createdAt: now, updatedAt: now,
                type: .trainReserveContribution, amount: train,
                sourceAccount: .checking2, destinationAccount: .checking2,
                paydayCheckInID: checkIn.id,
                note: "Payday #\(planItem.sequenceNumber) train reserve"
            ))
        }
        if draft.outsideFundsUsed > 0 {
            // Record-only entry: the reconcile equation means the reported C2
            // transfer already includes outside money, so this entry carries
            // no account movement (a destination would double-count C2).
            add(LedgerEntry(
                effectiveDate: paydayDate, createdAt: now, updatedAt: now,
                type: .windfall, amount: draft.outsideFundsUsed,
                sourceAccount: .external, destinationAccount: nil,
                paydayCheckInID: checkIn.id,
                note: "Outside funds included in payday #\(planItem.sequenceNumber) allocations"
            ))
        }
        if let kept = draft.actualC1Kept {
            let bufferPortion = (kept - plan.allowanceCap).rounded2
            if bufferPortion > 0 {
                add(LedgerEntry(
                    effectiveDate: paydayDate, createdAt: now, updatedAt: now,
                    type: .c1BufferAddition, amount: bufferPortion,
                    sourceAccount: .external, destinationAccount: .checking1,
                    paydayCheckInID: checkIn.id,
                    note: "Buffer addition at payday #\(planItem.sequenceNumber)"
                ))
            }
        }
        if let spent = draft.actualAllowanceSpent, spent > 0 {
            // "Spending since last check" belongs to the pay period that just
            // ended — dating it the day before keeps the new period's
            // allowance window untouched and it is already reflected in the
            // confirmed C1 balance recorded below.
            add(LedgerEntry(
                effectiveDate: DateMath.addingDays(-1, to: paydayDate),
                createdAt: now, updatedAt: now,
                type: .c1Spending, amount: spent,
                sourceAccount: .checking1, destinationAccount: .external,
                paydayCheckInID: checkIn.id,
                note: "Spending reported at payday #\(planItem.sequenceNumber)"
            ))
        }
        for (cardID, amount) in draft.cardPayments.sorted(by: { $0.key < $1.key }) where amount > 0 {
            let debt = debtsByPlanID[cardID]
            add(LedgerEntry(
                effectiveDate: paydayDate, createdAt: now, updatedAt: now,
                type: .cardPayment, amount: amount,
                sourceAccount: .checking2, destinationAccount: .card,
                debtAccountID: debt?.id, debtPlanID: cardID,
                paydayCheckInID: checkIn.id,
                note: "Payday #\(planItem.sequenceNumber) payment"
            ))
        }

        if let confirmed = draft.actualC1Balance {
            context.insert(BalanceSnapshot(
                cashAccount: .checking1,
                effectiveDate: paydayDate,
                amount: confirmed,
                sourceType: .userEntry,
                note: "Confirmed during payday #\(planItem.sequenceNumber) check-in",
                isAuthoritative: true,
                createdAt: now
            ))
        }
        for (cardID, balance) in draft.reportedBalances.sorted(by: { $0.key < $1.key }) {
            guard let debt = debtsByPlanID[cardID], !balance.isNegative else { continue }
            context.insert(BalanceSnapshot(
                debtAccountID: debt.id,
                debtPlanID: cardID,
                effectiveDate: paydayDate,
                amount: balance,
                sourceType: .currentOnlineBalance,
                note: "Reported after payday #\(planItem.sequenceNumber) payments",
                isAuthoritative: true,
                createdAt: now
            ))
        }

        checkIn.actualIncome = draft.actualIncome
        checkIn.outsideFundsUsed = draft.outsideFundsUsed
        checkIn.actualC1Kept = draft.actualC1Kept
        checkIn.actualC1Balance = draft.actualC1Balance
        checkIn.actualAllowanceSpent = draft.actualAllowanceSpent
        checkIn.actualC2Transfer = draft.actualC2Transfer
        checkIn.actualCarReserve = draft.actualCarReserve
        checkIn.actualTrainReserve = draft.actualTrainReserve
        checkIn.unallocatedAmount = draft.unallocated
        checkIn.reconciliationException = trimmedException.isEmpty ? nil : trimmedException
        checkIn.status = unreconciled.isEmpty ? .completed : .needsAttention
        checkIn.completedAt = now
        checkIn.updatedAt = now

        try context.save()
        return CompletionResult(checkIn: checkIn, ledgerEntries: entries, issues: unreconciled)
    }
}
