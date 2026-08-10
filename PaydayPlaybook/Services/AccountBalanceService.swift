import Foundation
import SwiftData

/// Derives Checking 1 / Checking 2 state and actual debt balances from the
/// ledger and authoritative snapshots. Planned values and the no-spend
/// ceiling are read from Original Plan v1 and are never mixed into actuals.
struct AccountBalanceService {

    struct Checking1State {
        /// Last confirmed actual balance plus subsequent explicit ledger deltas.
        let actualBalance: Decimal
        /// Date of the confirmation the actual balance is based on, if any.
        let asOfDate: Date?
        let protectedFloor: Decimal
        /// Allowance still available this pay period (cap − recorded spending).
        let allowanceAvailable: Decimal
        let allowanceSpentThisPeriod: Decimal
        /// True once the first payday has occurred (allowance is live).
        let allowanceActive: Bool
        /// Baseline "maximum if no allowance had been spent" for today.
        let noSpendCeiling: Decimal
        var isBelowFloor: Bool { actualBalance < protectedFloor }
    }

    struct Checking2State {
        let totalBalance: Decimal
        let carReserved: Decimal
        let trainReserved: Decimal
        /// Money available for minimums and avalanche payments.
        let availableForDebt: Decimal
        var hasNegativeBucket: Bool {
            totalBalance < 0 || carReserved < 0 || trainReserved < 0 || availableForDebt < 0
        }
    }

    struct DebtBalance {
        let debt: DebtAccount
        let balance: Decimal
        let asOfDate: Date?
        let isPaidOff: Bool
        let percentPaid: Decimal
    }

    let context: ModelContext
    let dateProvider: DateProviding

    init(context: ModelContext, dateProvider: DateProviding) {
        self.context = context
        self.dateProvider = dateProvider
    }

    // MARK: - Checking 1

    func checking1State(plan: PlanVersion, planItems: [PaydayPlanItem]) throws -> Checking1State {
        let today = DateMath.startOfDay(dateProvider.now)
        let allSnapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
        let c1Snapshots = allSnapshots.filter { snapshot in
            snapshot.cashAccount == .checking1
                && snapshot.isAuthoritative
                && DateMath.startOfDay(snapshot.effectiveDate) <= today
        }
        let base = c1Snapshots.max { lhs, rhs in
            if lhs.effectiveDate != rhs.effectiveDate { return lhs.effectiveDate < rhs.effectiveDate }
            return lhs.createdAt < rhs.createdAt
        }
        let baseAmount = base?.amount ?? plan.startingChecking1
        let baseDate = base.map { DateMath.startOfDay($0.effectiveDate) }

        let entries = try context.fetch(FetchDescriptor<LedgerEntry>())
        let relevant = entries.filter { entry in
            let day = DateMath.startOfDay(entry.effectiveDate)
            guard day <= today else { return false }
            guard let base, let baseDate else { return true }
            // Entries dated on the confirmation day are already reflected in the
            // confirmed balance unless they were recorded after it.
            if day == baseDate { return entry.createdAt > base.createdAt }
            return day > baseDate
        }
        var balance = baseAmount
        for entry in relevant {
            if entry.destinationAccount == .checking1 { balance += entry.amount }
            if entry.sourceAccount == .checking1 { balance -= entry.amount }
        }

        // Allowance window: from the most recent payday on/before today.
        let pastPaydays = planItems.filter { DateMath.startOfDay($0.date) <= today }
        let currentPayday = pastPaydays.max { $0.date < $1.date }
        var spent = Decimal.zero
        if let currentPayday {
            let windowStart = DateMath.startOfDay(currentPayday.date)
            spent = entries
                .filter {
                    $0.type == .c1Spending
                        && DateMath.startOfDay($0.effectiveDate) >= windowStart
                        && DateMath.startOfDay($0.effectiveDate) <= today
                }
                .reduce(Decimal.zero) { $0 + $1.amount }
        }
        let available = currentPayday == nil ? Decimal.zero : max(.zero, plan.allowanceCap - spent)

        let ceiling = currentPayday?.plannedC1NoSpendCeiling ?? plan.startingChecking1

        return Checking1State(
            actualBalance: balance.rounded2,
            asOfDate: base?.effectiveDate,
            protectedFloor: plan.protectedBuffer,
            allowanceAvailable: available.rounded2,
            allowanceSpentThisPeriod: spent.rounded2,
            allowanceActive: currentPayday != nil,
            noSpendCeiling: ceiling
        )
    }

    // MARK: - Checking 2

    func checking2State() throws -> Checking2State {
        let today = DateMath.startOfDay(dateProvider.now)
        let entries = try context.fetch(FetchDescriptor<LedgerEntry>())
            .filter { DateMath.startOfDay($0.effectiveDate) <= today }

        var total = Decimal.zero
        var car = Decimal.zero
        var train = Decimal.zero
        for entry in entries {
            if entry.destinationAccount == .checking2 { total += entry.amount }
            if entry.sourceAccount == .checking2 { total -= entry.amount }
            switch entry.type {
            case .carReserveContribution: car += entry.amount
            case .carReserveUse: car -= entry.amount
            case .trainReserveContribution: train += entry.amount
            case .trainReserveUse: train -= entry.amount
            default: break
            }
        }
        let available = total - car - train
        return Checking2State(
            totalBalance: total.rounded2,
            carReserved: car.rounded2,
            trainReserved: train.rounded2,
            availableForDebt: available.rounded2
        )
    }

    // MARK: - Debts

    func debtBalances() throws -> [DebtBalance] {
        let debts = try context.fetch(FetchDescriptor<DebtAccount>())
            .sorted { $0.priority < $1.priority }
        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
        let entries = try context.fetch(FetchDescriptor<LedgerEntry>())
        let today = DateMath.startOfDay(dateProvider.now)

        return debts.map { debt in
            let debtID = debt.id
            let candidates = snapshots.filter { snapshot in
                snapshot.debtAccountID == debtID
                    && snapshot.isAuthoritative
                    && DateMath.startOfDay(snapshot.effectiveDate) <= today
            }
            let authoritative = candidates.max { lhs, rhs in
                if lhs.effectiveDate != rhs.effectiveDate { return lhs.effectiveDate < rhs.effectiveDate }
                return lhs.createdAt < rhs.createdAt
            }
            let baseAmount = authoritative?.amount ?? debt.startingBalance
            let baseDate = authoritative.map { DateMath.startOfDay($0.effectiveDate) }

            var balance = baseAmount
            var latestActivity: Date? = authoritative?.effectiveDate
            for entry in entries where entry.debtAccountID == debtID {
                let day = DateMath.startOfDay(entry.effectiveDate)
                guard day <= today else { continue }
                if let authoritative, let baseDate {
                    if day < baseDate { continue }
                    if day == baseDate && entry.createdAt <= authoritative.createdAt { continue }
                }
                switch entry.type {
                case .cardPayment: balance -= entry.amount
                case .refundReversal: balance += entry.amount
                case .correction: balance += entry.amount
                default: break
                }
                if latestActivity == nil || entry.effectiveDate > latestActivity! {
                    latestActivity = entry.effectiveDate
                }
            }
            balance = max(balance, .zero).rounded2

            let paid = debt.startingBalance - balance
            let percent: Decimal
            if debt.startingBalance > 0 {
                percent = max(.zero, min(Decimal(1), paid / debt.startingBalance))
            } else {
                percent = 1
            }
            return DebtBalance(
                debt: debt,
                balance: balance,
                asOfDate: latestActivity,
                isPaidOff: balance.isZeroMoney,
                percentPaid: percent
            )
        }
    }

    func totalActualDebt() throws -> Decimal {
        try debtBalances().reduce(Decimal.zero) { $0 + $1.balance }.rounded2
    }
}
