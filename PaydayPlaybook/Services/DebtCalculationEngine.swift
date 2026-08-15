import Foundation

/// Pure-function debt projection engine.
///
/// Convention (validated against the source plan): interest accrues every
/// period as `balance × APR × periodDays / 365` and is carried at full
/// `Decimal` precision; minimums are `max($17.50, 0.5% of the post-interest
/// balance)` capped at the remaining balance; the remaining budget attacks
/// the first active card in avalanche order and rolls to the next card in
/// the same check when a target is paid off. Balances are rounded to cents
/// only at output boundaries.
enum DebtCalculationEngine {

    struct EngineDebt {
        let planID: String
        let apr: Decimal
        var balance: Decimal
        /// User-entered minimum; nil uses the baseline estimate.
        var minimumOverride: Decimal?

        init(planID: String, apr: Decimal, balance: Decimal, minimumOverride: Decimal? = nil) {
            self.planID = planID
            self.apr = apr
            self.balance = balance
            self.minimumOverride = minimumOverride
        }
    }

    struct EnginePayday {
        let sequence: Int
        let date: Date
        let cardBudget: Decimal
    }

    struct CheckOutcome {
        let sequence: Int
        let date: Date
        let interestAccrued: Decimal
        let paymentsByCard: [String: Decimal]
        let balancesAfter: [String: Decimal]
        /// First card that received attack money this check.
        let targetPlanID: String?
        let totalDebtAfter: Decimal
        let budgetUsed: Decimal
    }

    struct ProjectionResult {
        let payoffDate: Date?
        let paychecksUsed: Int
        let totalInterest: Decimal
        let perCardPayoffDates: [String: Date]
        let schedule: [CheckOutcome]
        /// True when the payday list ran out before all balances reached zero.
        let unfinished: Bool
    }

    /// Runs the projection over the supplied paydays, ordered by avalanche priority.
    /// `debts` must already be in avalanche order (highest priority first).
    static func project(
        debts: [EngineDebt],
        paydays: [EnginePayday],
        minimumFloor: Decimal = PlanContract.minimumPaymentFloor,
        minimumRate: Decimal = PlanContract.minimumPaymentRate,
        periodDays: Int = PlanContract.payFrequencyDays
    ) -> ProjectionResult {
        var working = debts
        var schedule: [CheckOutcome] = []
        var totalInterest = Decimal.zero
        var payoffDates: [String: Date] = [:]
        var payoffDate: Date?
        var paychecksUsed = 0
        let daysFactor = Decimal(periodDays) / Decimal(365)
        // Cards retired before this projection started have no future payoff.
        let initiallyPaid = Set(debts.filter { $0.balance.rounded2 <= 0 }.map(\.planID))

        for payday in paydays {
            guard working.contains(where: { $0.balance.rounded2 > 0 }) else { break }
            paychecksUsed += 1
            var interestThisCheck = Decimal.zero
            var payments: [String: Decimal] = [:]

            for index in working.indices where working[index].balance.rounded2 > 0 {
                let interest = working[index].balance * working[index].apr * daysFactor
                working[index].balance += interest
                interestThisCheck += interest
            }
            totalInterest += interestThisCheck

            var remaining = payday.cardBudget

            // Minimums first, on every active card.
            for index in working.indices where working[index].balance.rounded2 > 0 {
                let estimated = max(minimumFloor, working[index].balance * minimumRate)
                var minimum = working[index].minimumOverride ?? estimated
                minimum = min(minimum, working[index].balance, remaining)
                guard minimum > 0 else { continue }
                working[index].balance -= minimum
                remaining -= minimum
                payments[working[index].planID, default: .zero] += minimum
            }

            // Avalanche attack with same-check rollover.
            var target: String?
            for index in working.indices {
                guard remaining > 0 else { break }
                guard working[index].balance.rounded2 > 0 else { continue }
                if target == nil { target = working[index].planID }
                let attack = min(remaining, working[index].balance)
                working[index].balance -= attack
                remaining -= attack
                payments[working[index].planID, default: .zero] += attack
            }

            for debt in working where debt.balance.rounded2 <= 0 {
                if payoffDates[debt.planID] == nil && !initiallyPaid.contains(debt.planID) {
                    payoffDates[debt.planID] = payday.date
                }
            }

            let totalAfter = working.reduce(Decimal.zero) { $0 + $1.balance }
            schedule.append(CheckOutcome(
                sequence: payday.sequence,
                date: payday.date,
                interestAccrued: interestThisCheck.rounded2,
                paymentsByCard: payments.mapValues { $0.rounded2 },
                balancesAfter: Dictionary(uniqueKeysWithValues: working.map { ($0.planID, $0.balance.rounded2) }),
                targetPlanID: target,
                totalDebtAfter: totalAfter.rounded2,
                budgetUsed: (payday.cardBudget - remaining).rounded2
            ))

            if working.allSatisfy({ $0.balance.rounded2 <= 0 }) {
                payoffDate = payday.date
                break
            }
        }

        let unfinished = payoffDate == nil && working.contains(where: { $0.balance.rounded2 > 0 })
        return ProjectionResult(
            payoffDate: payoffDate,
            paychecksUsed: paychecksUsed,
            totalInterest: totalInterest.rounded2,
            perCardPayoffDates: payoffDates,
            schedule: schedule,
            unfinished: unfinished
        )
    }

    // MARK: - Reforecast

    struct ReforecastInput {
        /// Current balances in avalanche order, from authoritative snapshots/ledger.
        let debts: [EngineDebt]
        /// Date the balances are effective (usually today).
        let asOf: Date
        let plan: PlanSettingsSnapshot
        /// Income amounts by effective date, ascending.
        let incomeRules: [(effectiveDate: Date, amount: Decimal)]
        /// Sequence number of the first future payday (for labeling).
        let nextSequence: Int
        /// Date of the next payday to project from.
        let nextPaydayDate: Date
        /// True when the very first check (with its $100 buffer add) is still ahead.
        let includeFirstCheckBuffer: Bool
        let triggerType: ForecastTrigger
        /// Optional context, e.g. "this payday's card contributions were $620 below plan".
        let varianceContext: String?
    }

    /// Plan values needed by the reforecast, decoupled from SwiftData.
    struct PlanSettingsSnapshot {
        let allowanceCap: Decimal
        let firstCheckBufferAdd: Decimal
        let carReservePerCheck: Decimal
        let trainReservePerCheck: Decimal
        let payFrequencyDays: Int
        let baselinePayoffDate: Date

        var fixedReserve: Decimal { carReservePerCheck + trainReservePerCheck }
    }

    struct ReforecastResult {
        let projection: ProjectionResult
        let explanation: String
    }

    /// Projects forward from current actual balances following the plan's
    /// allocation rules. Original Plan v1 data is never touched.
    static func reforecast(_ input: ReforecastInput, maxChecks: Int = 260) -> ReforecastResult {
        var paydays: [EnginePayday] = []
        var date = input.nextPaydayDate
        for offset in 0..<maxChecks {
            let sequence = input.nextSequence + offset
            let income = incomeAmount(on: date, rules: input.incomeRules)
            var keep = input.plan.allowanceCap
            if offset == 0 && input.includeFirstCheckBuffer {
                keep += input.plan.firstCheckBufferAdd
            }
            let budget = income - keep - input.plan.fixedReserve
            paydays.append(EnginePayday(sequence: sequence, date: date, cardBudget: max(budget, .zero)))
            date = DateMath.addingDays(input.plan.payFrequencyDays, to: date)
        }

        let projection = project(debts: input.debts, paydays: paydays)
        let explanation = buildExplanation(projection: projection, input: input)
        return ReforecastResult(projection: projection, explanation: explanation)
    }

    static func incomeAmount(on date: Date, rules: [(effectiveDate: Date, amount: Decimal)]) -> Decimal {
        var amount = rules.first?.amount ?? .zero
        for rule in rules where rule.effectiveDate <= date {
            amount = rule.amount
        }
        return amount
    }

    private static func buildExplanation(projection: ProjectionResult, input: ReforecastInput) -> String {
        guard let payoff = projection.payoffDate else {
            return "The current budget does not retire all balances within the projection window. Estimates only — actual issuer interest will differ."
        }
        let baseline = input.plan.baselinePayoffDate
        let dayDelta = DateMath.days(from: baseline, to: payoff)
        var sentence: String
        if dayDelta == 0 {
            sentence = "Forecast payoff remains \(DateMath.mediumString(payoff)), matching the original plan."
        } else if dayDelta > 0 {
            sentence = "Forecast payoff moved \(dayDelta) day\(dayDelta == 1 ? "" : "s") later than the original plan, to \(DateMath.mediumString(payoff))."
        } else {
            sentence = "Forecast payoff moved \(-dayDelta) day\(dayDelta == -1 ? "" : "s") earlier than the original plan, to \(DateMath.mediumString(payoff))."
        }
        if let context = input.varianceContext, !context.isEmpty {
            sentence += " \(context)"
        }
        sentence += " This is an estimate, not a guarantee."
        return sentence
    }
}
