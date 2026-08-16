import Foundation

/// Calculation-version-2 avalanche plan generator (rules R-01…R-16).
///
/// Pure functions only: no SwiftUI, no SwiftData, no clock access — identical
/// inputs always produce identical outputs. All money is `Decimal`.
///
/// Rounding contract: balances and interest carry full precision internally
/// (the same mechanics as the frozen calc-v1 `DebtCalculationEngine`, so the
/// legacy baseline reproduces exactly under equivalent inputs). Emitted
/// row values are rounded to cents with cascading penny allocation so every
/// `PaycheckPlan` reconciles to the cent by construction:
///
///     income + windfall == keepInSpending + transferToReserves
///     debtBudget + shortfall.gap == minimumsTotal + extraTotal + unassignedCash
///     Σ payments == minimumsTotal + extraTotal
enum AvalanchePlanEngine {

    /// R-01 horizon cap (assumption A-05): generation stops after this many
    /// paychecks and flags the plan "not payable as configured".
    static let horizonCap = 600

    /// R-06 card-minimum estimator constants (shared with calc v1).
    static let minimumFloorPer14Days = Decimal(string: "17.50")!
    static let minimumRate = Decimal(string: "0.005")!

    enum PlanningValidationError: Error, Equatable, CustomStringConvertible {
        case negativeAmount(String)
        case noIncome
        case invalidCadence(String)
        case invalidDueDay(String)

        var description: String {
            switch self {
            case .negativeAmount(let what): return "Negative amount not allowed: \(what)"
            case .noIncome: return "At least one income amount is required"
            case .invalidCadence(let what): return "Invalid pay cadence: \(what)"
            case .invalidDueDay(let what): return "Invalid due day: \(what)"
            }
        }
    }

    // MARK: - Public API

    /// Generates the immutable recommended plan from onboarding inputs.
    static func generatePlan(_ input: PlanningInput) throws -> PlanningResult {
        try validate(input)
        let normalized = normalize(input)
        let outcome = runProjection(normalized, extraEnabled: true, actuals: nil)
        let comparison = minimumOnlyComparison(normalized, against: outcome, actuals: nil)
        return assemble(kind: .plan, input: normalized, outcome: outcome, comparison: comparison)
    }

    /// Projects forward from authoritative actual state. The original plan is
    /// a separate value and is never modified — reforecasts are always a new
    /// `PlanningResult` with `kind == .reforecast`.
    static func reforecast(_ input: PlanningInput, actuals: ActualState) throws -> PlanningResult {
        try validate(input)
        for authority in actuals.balances where authority.balance < 0 {
            throw PlanningValidationError.negativeAmount("authoritative balance")
        }
        let normalized = normalize(input)
        let outcome = runProjection(normalized, extraEnabled: true, actuals: actuals)
        let comparison = minimumOnlyComparison(normalized, against: outcome, actuals: actuals)
        return assemble(kind: .reforecast, input: normalized, outcome: outcome,
                        comparison: comparison, actuals: actuals)
    }

    /// R-04 obligation smoothing: per-paycheck reserve, rounded to cents.
    static func smoothedReserve(amount: Decimal, cadence: ObligationCadence,
                                payCadence: PlanningPayCadence) -> Decimal {
        (amount * Decimal(cadence.occurrencesPerYear) / Decimal(payCadence.paychecksPerYear)).rounded2
    }

    // MARK: - Validation & normalization

    static func validate(_ input: PlanningInput) throws {
        func nonNegative(_ value: Decimal, _ what: String) throws {
            if value < 0 { throw PlanningValidationError.negativeAmount(what) }
        }
        guard !input.income.amounts.isEmpty else { throw PlanningValidationError.noIncome }
        for change in input.income.amounts { try nonNegative(change.amount, "income amount") }
        for windfall in input.income.windfalls { try nonNegative(windfall.amount, "windfall") }
        try nonNegative(input.spending.startingBalance, "spending starting balance")
        try nonNegative(input.spending.protectedFloor, "protected floor")
        try nonNegative(input.spending.allowancePerPaycheck, "allowance")
        for obligation in input.obligations {
            try nonNegative(obligation.amount, "obligation \(obligation.name)")
            if let day = obligation.dueDay, !(1...31).contains(day) {
                throw PlanningValidationError.invalidDueDay("obligation \(obligation.name)")
            }
        }
        for debt in input.debts {
            try nonNegative(debt.balance, "debt \(debt.name) balance")
            try nonNegative(debt.apr, "debt \(debt.name) APR")
            if let minimum = debt.minimumPayment { try nonNegative(minimum, "debt \(debt.name) minimum") }
            if let limit = debt.creditLimit { try nonNegative(limit, "debt \(debt.name) credit limit") }
            if let promo = debt.promo { try nonNegative(promo.apr, "debt \(debt.name) promo APR") }
            if let day = debt.dueDay, !(1...31).contains(day) {
                throw PlanningValidationError.invalidDueDay("debt \(debt.name)")
            }
        }
        switch input.income.cadence {
        case .weekly, .biweekly:
            break
        case .monthly(let day):
            guard (1...31).contains(day) else {
                throw PlanningValidationError.invalidCadence("monthly day \(day)")
            }
        case .semimonthly(let first, let second):
            guard (1...31).contains(first), (1...31).contains(second), first < second else {
                throw PlanningValidationError.invalidCadence("semimonthly days \(first)/\(second)")
            }
        }
    }

    /// Rounds all money inputs to cents and normalizes dates to start-of-day
    /// so sub-cent or sub-day noise can never make two equal plans diverge.
    private static func normalize(_ input: PlanningInput) -> PlanningInput {
        var normalized = input
        normalized.asOf = DateMath.startOfDay(input.asOf)
        normalized.income.firstPayday = DateMath.startOfDay(input.income.firstPayday)
        normalized.income.amounts = input.income.amounts
            .map { PlanningIncomeChange(effectiveDate: DateMath.startOfDay($0.effectiveDate), amount: $0.amount.rounded2) }
            .sorted { $0.effectiveDate < $1.effectiveDate }
        normalized.income.windfalls = input.income.windfalls
            .map { Windfall(date: DateMath.startOfDay($0.date), amount: $0.amount.rounded2) }
            .sorted { $0.date < $1.date }
        normalized.spending.startingBalance = input.spending.startingBalance.rounded2
        normalized.spending.protectedFloor = input.spending.protectedFloor.rounded2
        normalized.spending.allowancePerPaycheck = input.spending.allowancePerPaycheck.rounded2
        normalized.obligations = input.obligations.map { obligation in
            var copy = obligation
            copy.amount = obligation.amount.rounded2
            return copy
        }
        normalized.debts = input.debts.map { debt in
            var copy = debt
            copy.balance = debt.balance.rounded2
            copy.minimumPayment = debt.minimumPayment?.rounded2
            copy.creditLimit = debt.creditLimit?.rounded2
            if let promo = debt.promo {
                copy.promo = PromoAPR(apr: promo.apr, expirationDate: DateMath.startOfDay(promo.expirationDate))
            }
            return copy
        }
        return normalized
    }

    // MARK: - Working state

    private struct WorkingDebt {
        let input: DebtInput
        /// Balance at the start of this projection (authoritative for
        /// reforecasts, the input balance for plans).
        let initialBalance: Decimal
        var balance: Decimal
        var interestAccrued: Decimal = 0
        var totalPaid: Decimal = 0
        var payoffDate: Date?
        let startedPaid: Bool
        /// Reforecast: date interest accrual starts for the first projected
        /// paycheck (authoritative snapshot date), nil for the plan track.
        var firstAccrualStart: Date?

        var isActive: Bool { balance.rounded2 > 0 }
        var extraEligible: Bool { input.prepayment == .eligible }
    }

    private struct Outcome {
        var paychecks: [PaycheckPlan] = []
        var payoffDate: Date?
        var totalInterestExact: Decimal = 0
        var debts: [WorkingDebt] = []
        var events: [PlanEvent] = []
        var warnings: [PlanningNote] = []
        var notPayable = false
        var hasUnassignedCash = false
        var shortfallSequences: [Int] = []
        var startingPrincipal: Decimal = 0
        var firstTargetDebtID: UUID?
    }

    // MARK: - Projection core

    private static let eventDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private static func dateKey(_ date: Date) -> String { eventDateFormatter.string(from: date) }

    /// Deterministic priority: effective APR descending, due day ascending
    /// (debts without a due day last), current principal ascending, creation
    /// order, then UUID string. (Extends R-08 with the due-day key per the
    /// v0.2 engine mission; 0% APR debts naturally sort last.)
    private static func prioritySorted(_ indices: [Int], debts: [WorkingDebt], on date: Date) -> [Int] {
        indices.sorted { a, b in
            let da = debts[a], db = debts[b]
            let aprA = da.input.effectiveAPR(on: date)
            let aprB = db.input.effectiveAPR(on: date)
            if aprA != aprB { return aprA > aprB }
            switch (da.input.dueDay, db.input.dueDay) {
            case let (x?, y?) where x != y: return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            default: break
            }
            if da.balance != db.balance { return da.balance < db.balance }
            if da.input.createdOrder != db.input.createdOrder {
                return da.input.createdOrder < db.input.createdOrder
            }
            return da.input.id.uuidString < db.input.id.uuidString
        }
    }

    private static func incomeAmount(on date: Date, amounts: [PlanningIncomeChange]) -> Decimal {
        var amount = amounts.first?.amount ?? 0
        for change in amounts where change.effectiveDate <= date {
            amount = change.amount
        }
        return amount
    }

    /// R-06 card-minimum estimate for an accrual period of `days` days.
    private static func estimatedCardMinimum(postInterestBalance: Decimal, days: Int) -> Decimal {
        let scaledFloor = minimumFloorPer14Days * Decimal(days) / Decimal(14)
        return max(scaledFloor, postInterestBalance * minimumRate)
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private static func runProjection(
        _ input: PlanningInput,
        extraEnabled: Bool,
        actuals: ActualState?
    ) -> Outcome {
        var outcome = Outcome()
        var warningKeys = Set<String>()
        func warn(_ code: PlanningNoteCode, _ message: String, debtID: UUID? = nil) {
            let key = "\(code.rawValue)|\(debtID?.uuidString ?? "")"
            guard warningKeys.insert(key).inserted else { return }
            outcome.warnings.append(PlanningNote(code: code, message: message, debtID: debtID))
        }

        // Working debts, with authoritative balances applied for reforecasts.
        // A debt listed more than once resolves to its latest effective date
        // (ties: the later array entry) — callers may pass update history.
        var authorities: [UUID: BalanceAuthority] = [:]
        for authority in actuals?.balances ?? [] {
            if let existing = authorities[authority.debtID],
               existing.effectiveDate > authority.effectiveDate { continue }
            authorities[authority.debtID] = authority
        }
        // Stale debts (no snapshot) keep the plan-start balance with interest
        // estimated from the plan's own accrual anchor, per the DTO contract.
        let planAccrualAnchor = PayScheduleGenerator.previousOccurrence(
            cadence: input.income.cadence, before: input.income.firstPayday)
        outcome.debts = input.debts.map { debt in
            var working = WorkingDebt(
                input: debt,
                initialBalance: debt.balance,
                balance: debt.balance,
                payoffDate: nil,
                startedPaid: debt.balance.rounded2 <= 0,
                firstAccrualStart: nil
            )
            if let authority = authorities[debt.id] {
                working = WorkingDebt(
                    input: debt,
                    initialBalance: authority.balance.rounded2,
                    balance: authority.balance.rounded2,
                    payoffDate: nil,
                    startedPaid: authority.balance.rounded2 <= 0,
                    firstAccrualStart: DateMath.startOfDay(authority.effectiveDate)
                )
            } else if actuals != nil && debt.balance.rounded2 > 0 {
                working.firstAccrualStart = planAccrualAnchor
                warn(.staleBalanceInput,
                     "\(debt.name) has no balance update; the forecast still uses its plan-start balance.",
                     debtID: debt.id)
            }
            return working
        }
        outcome.startingPrincipal = outcome.debts.reduce(Decimal.zero) { $0 + $1.balance }

        // Full payday timeline; reforecasts skip paydays on/before asOf but
        // keep the original sequence numbers.
        let allPaydays = PayScheduleGenerator.paydays(
            cadence: input.income.cadence,
            anchor: input.income.firstPayday,
            count: horizonCap + 1
        )
        let cutoff = actuals.map { DateMath.startOfDay($0.asOf) }
        let startIndex = cutoff.map { asOf in allPaydays.firstIndex { $0 > asOf } ?? allPaydays.count } ?? 0
        guard startIndex < allPaydays.count - 1 else {
            if outcome.debts.contains(where: { $0.isActive }) {
                outcome.notPayable = true
                warn(.horizonCapReached,
                     "The debts are not paid off within \(horizonCap) paychecks as configured.")
            }
            return outcome
        }

        // Missing installment minimums are a setup problem, warned once.
        for debt in outcome.debts where debt.isActive {
            if debt.input.debtType != .creditCard && debt.input.minimumPayment == nil {
                warn(.installmentMinimumMissing,
                     "\(debt.input.name) needs its contractual payment amount; the plan assumes $0 until it is entered.",
                     debtID: debt.input.id)
            }
            switch debt.input.prepayment {
            case .unknown:
                warn(.prepaymentEligibilityUnknown,
                     "Confirm whether \(debt.input.name) allows extra principal without penalty. Until then it receives minimums only.",
                     debtID: debt.input.id)
            case .ineligible:
                warn(.prepaymentProhibited,
                     "\(debt.input.name) does not accept extra principal; it receives minimums only.",
                     debtID: debt.input.id)
            case .eligible:
                break
            }
            if let day = debt.input.dueDay, day >= 29 {
                warn(.dueDayClamped,
                     "\(debt.input.name)'s due day \(day) falls back to the last day of shorter months.",
                     debtID: debt.input.id)
            }
        }
        // Due dates between plan start and the first payday cannot be funded
        // by a payday and need handling outside the plan.
        let planStart = cutoff ?? input.asOf
        for debt in outcome.debts where debt.isActive {
            if let day = debt.input.dueDay,
               !PayScheduleGenerator.dueDates(day: day, from: planStart, to: allPaydays[startIndex]).isEmpty {
                warn(.dueDateBeforeFirstPayday,
                     "\(debt.input.name) has a due date before the first payday; cover that payment from cash on hand.",
                     debtID: debt.input.id)
            }
        }

        // Spending ceiling: an actual balance snapshot wins; without one, a
        // reforecast keeps the *planned* no-spend path (so floor top-ups the
        // plan already made are not charged again), derived from the plan
        // track's ceiling at the cutoff date.
        var spendingCeiling: Decimal
        if let actuals {
            if let actual = actuals.spendingBalance {
                spendingCeiling = actual.rounded2
            } else {
                let planned = runProjection(input, extraEnabled: extraEnabled, actuals: nil)
                spendingCeiling = planned.paychecks.last { $0.date <= (cutoff ?? input.asOf) }?
                    .spendingCeilingAfter ?? input.spending.startingBalance.rounded2
            }
        } else {
            spendingCeiling = input.spending.startingBalance.rounded2
        }
        var pendingWindfalls = input.income.windfalls.filter { windfall in
            cutoff.map { windfall.date > $0 } ?? true
        }

        var checkIndex = startIndex
        while checkIndex < min(startIndex + horizonCap, allPaydays.count - 1) {
            guard outcome.debts.contains(where: { $0.isActive }) else { break }
            let payday = allPaydays[checkIndex]
            let nextPayday = allPaydays[checkIndex + 1]
            let sequence = checkIndex + 1
            let previousPayday = checkIndex == 0
                ? PayScheduleGenerator.previousOccurrence(cadence: input.income.cadence, before: payday)
                : allPaydays[checkIndex - 1]
            let accrualDays = max(DateMath.days(from: previousPayday, to: payday), 0)
            let isFirstProjectedCheck = checkIndex == startIndex

            // 1. Interest accrual at each debt's effective APR (R-02); a
            //    reforecast's first check accrues from each authoritative
            //    snapshot date instead of the previous payday.
            var interestThisCheck = Decimal.zero
            for index in outcome.debts.indices where outcome.debts[index].isActive {
                var days = accrualDays
                if isFirstProjectedCheck, let start = outcome.debts[index].firstAccrualStart {
                    days = max(DateMath.days(from: start, to: payday), 0)
                }
                let apr = outcome.debts[index].input.effectiveAPR(on: payday)
                guard apr > 0, days > 0 else { continue }
                let interest = outcome.debts[index].balance * apr * Decimal(days) / Decimal(365)
                outcome.debts[index].balance += interest
                outcome.debts[index].interestAccrued += interest
                interestThisCheck += interest
            }
            outcome.totalInterestExact += interestThisCheck

            // 2. Income, windfalls, allowance, floor top-up, obligations.
            let income = incomeAmount(on: payday, amounts: input.income.amounts)
            var windfall = Decimal.zero
            while let first = pendingWindfalls.first, first.date <= payday {
                windfall += first.amount
                pendingWindfalls.removeFirst()
            }
            var allowance = input.spending.allowancePerPaycheck
            let floorTopUp = max(input.spending.protectedFloor - spendingCeiling, 0)
            let obligationReserves = input.obligations.map { obligation in
                ObligationReserve(
                    obligationID: obligation.id,
                    amount: smoothedReserve(amount: obligation.amount,
                                            cadence: obligation.cadence,
                                            payCadence: input.income.cadence)
                )
            }
            let obligationTotal = obligationReserves.reduce(Decimal.zero) { $0 + $1.amount }

            // 3. Minimum payments, scheduled by due date (funded from the
            //    last payday on/before each due date), applied in priority
            //    order at full precision.
            let priorityAll = prioritySorted(
                outcome.debts.indices.filter { outcome.debts[$0].isActive },
                debts: outcome.debts, on: payday
            )
            struct MinimumPlan {
                let index: Int
                let exactAmount: Decimal
                let dueDate: Date?
                let estimated: Bool
            }
            var minimumPlans: [MinimumPlan] = []
            for index in priorityAll {
                let debt = outcome.debts[index]
                var exact = Decimal.zero
                var dueDate: Date?
                var estimated = false
                if let day = debt.input.dueDay {
                    let occurrences = PayScheduleGenerator.dueDates(day: day, from: payday, to: nextPayday)
                    guard !occurrences.isEmpty else { continue }
                    dueDate = occurrences[0]
                    for _ in occurrences {
                        if let entered = debt.input.minimumPayment {
                            exact += entered
                        } else if debt.input.debtType == .creditCard {
                            exact += estimatedCardMinimum(postInterestBalance: debt.balance, days: accrualDays)
                            estimated = true
                        }
                    }
                } else if let entered = debt.input.minimumPayment {
                    exact = entered
                } else if debt.input.debtType == .creditCard {
                    exact = estimatedCardMinimum(postInterestBalance: debt.balance, days: accrualDays)
                    estimated = true
                }
                exact = min(exact, debt.balance)
                guard exact > 0 else { continue }
                minimumPlans.append(MinimumPlan(index: index, exactAmount: exact, dueDate: dueDate, estimated: estimated))
            }
            let minimumsExact = minimumPlans.reduce(Decimal.zero) { $0 + $1.exactAmount }

            // 4. Shortfall handling (R-09): extra→0 is implicit; reduce the
            //    allowance toward zero; any residual gap is explicit and
            //    assumed covered by outside funds — never silent negative cash.
            let required = floorTopUp + obligationTotal + minimumsExact
            let available = income + windfall - allowance
            var shortfall: PaycheckShortfall?
            if available < required {
                let deficit = (required - available).rounded2
                let allowanceReduced = min(allowance, max(deficit, 0))
                allowance -= allowanceReduced
                let gap = max((deficit - allowanceReduced).rounded2, 0)
                let explanation = gap > 0
                    ? "This paycheck is \(MoneyFormat.string(gap)) short of the floor, obligations, and minimums even with the allowance at $0. It needs outside funds and attention."
                    : "This paycheck used \(MoneyFormat.string(allowanceReduced)) of the allowance to cover the floor, obligations, and minimums."
                // The floor/obligation/minimums split of the gap is filled in
                // at emission, once the rounded transfer is known.
                shortfall = PaycheckShortfall(gap: gap, allowanceReduced: allowanceReduced,
                                              floorGap: 0, obligationGap: 0, minimumsGap: gap,
                                              explanation: explanation)
                if gap > 0 {
                    warn(.shortfallOutsideFunds,
                         "Paycheck \(sequence) needs \(MoneyFormat.string(gap)) of outside funds to cover the floor, obligations, and minimums.")
                    outcome.shortfallSequences.append(sequence)
                }
            }

            // The floor top-up actually funded is capped by the cash present
            // after the (possibly reduced) allowance, so a transfer can never
            // go negative; any unfunded floor need is already inside the gap.
            let fundedFloorTopUp = min(floorTopUp, max(income + windfall - allowance, 0))

            // Apply minimums at full precision.
            for plan in minimumPlans {
                let payment = min(plan.exactAmount, outcome.debts[plan.index].balance)
                outcome.debts[plan.index].balance -= payment
                if outcome.debts[plan.index].balance.rounded2 <= 0,
                   outcome.debts[plan.index].payoffDate == nil,
                   !outcome.debts[plan.index].startedPaid {
                    outcome.debts[plan.index].payoffDate = payday
                }
            }

            // 5. Extra principal to the highest effective-APR eligible debt,
            //    rolling within the same paycheck on payoff (R-05/R-07/R-08).
            var extraExact = shortfall == nil ? max(available - required, 0) : 0
            if !extraEnabled { extraExact = 0 }
            var extraByIndex: [Int: Decimal] = [:]
            var targetDebtID: UUID?
            var rolloverNames: [String] = []
            if extraExact > 0 {
                let eligible = prioritySorted(
                    outcome.debts.indices.filter { outcome.debts[$0].isActive && outcome.debts[$0].extraEligible },
                    debts: outcome.debts, on: payday
                )
                var remaining = extraExact
                for index in eligible {
                    guard remaining > 0 else { break }
                    guard outcome.debts[index].isActive else { continue }
                    if targetDebtID == nil {
                        targetDebtID = outcome.debts[index].input.id
                    } else {
                        rolloverNames.append(outcome.debts[index].input.name)
                    }
                    let attack = min(remaining, outcome.debts[index].balance)
                    outcome.debts[index].balance -= attack
                    remaining -= attack
                    extraByIndex[index, default: 0] += attack
                    if outcome.debts[index].balance.rounded2 <= 0,
                       outcome.debts[index].payoffDate == nil,
                       !outcome.debts[index].startedPaid {
                        outcome.debts[index].payoffDate = payday
                    }
                }
                extraExact -= remaining // what was actually placed
                if remaining > 0 && extraEnabled {
                    warn(.noEligibleExtraTarget,
                         "Some payoff money has no eligible debt to go to; it stays in reserves until eligibility is confirmed.")
                }
            }
            if outcome.firstTargetDebtID == nil { outcome.firstTargetDebtID = targetDebtID }

            // 6. Emission with cascading penny allocation so the row
            //    reconciles exactly:
            //    income + windfall == keep + transfer, and (outside shortfall)
            //    debtBudget == minimumsTotal + extraTotal + unassignedCash.
            let allowanceEmit = allowance.rounded2
            let floorTopUpEmit = fundedFloorTopUp.rounded2
            let keepEmit = allowanceEmit + floorTopUpEmit
            let transferEmit = income + windfall - keepEmit
            let debtBudgetEmit = max(transferEmit - obligationTotal, 0)
            let minimumsTotalEmit = minimumsExact.rounded2
            // Derive the extra total so minimums + extra equals the rounded
            // total-payments figure, then unassigned closes the row exactly.
            let paymentsTotalEmit = (minimumsExact + extraExact).rounded2
            let extraTotalEmit = paymentsTotalEmit - minimumsTotalEmit
            // Split any shortfall gap into its floor / obligation / minimums
            // portions: only the minimums portion flows through the debt
            // budget, so gap money earmarked for the floor or obligations can
            // never surface as phantom "unassigned" cash.
            let gapEmit = shortfall?.gap ?? 0
            let floorGapEmit = min(max((floorTopUp - fundedFloorTopUp).rounded2, 0), gapEmit)
            let obligationFundedEmit = min(max(transferEmit, 0), obligationTotal)
            let obligationGapEmit = min(max((obligationTotal - obligationFundedEmit).rounded2, 0),
                                        gapEmit - floorGapEmit)
            let minimumsGapEmit = max(gapEmit - floorGapEmit - obligationGapEmit, 0)
            shortfall?.floorGap = floorGapEmit
            shortfall?.obligationGap = obligationGapEmit
            shortfall?.minimumsGap = minimumsGapEmit
            let unassignedEmit = max(debtBudgetEmit + minimumsGapEmit - minimumsTotalEmit - extraTotalEmit, 0)
            if unassignedEmit > 0 && extraEnabled && shortfall == nil
                && outcome.debts.contains(where: { $0.isActive }) {
                outcome.hasUnassignedCash = true
            }

            var payments: [PlannedPayment] = []
            var minimumRemainder = minimumsTotalEmit
            for (offset, plan) in minimumPlans.enumerated() {
                let debt = outcome.debts[plan.index]
                let isLast = offset == minimumPlans.count - 1
                let rounded = isLast ? minimumRemainder : min(plan.exactAmount.rounded2, minimumRemainder)
                minimumRemainder -= rounded
                var reasons: [ReasonCode] = [plan.dueDate == nil ? .minimumPerPaycheck : .minimumDueByDate]
                if plan.estimated { reasons.append(.estimatedMinimum) }
                payments.append(PlannedPayment(
                    debtID: debt.input.id,
                    minimum: rounded,
                    extra: 0,
                    fundsDueDate: plan.dueDate,
                    reasons: reasons
                ))
            }
            // Stable order: amount descending, then input position — a
            // Dictionary's hash-seeded key order must never leak into output.
            let extraOrder = extraByIndex.keys.sorted { a, b in
                let amountA = extraByIndex[a] ?? 0
                let amountB = extraByIndex[b] ?? 0
                if amountA != amountB { return amountA > amountB }
                return a < b
            }
            var extraRemainder = extraTotalEmit
            for (offset, index) in extraOrder.enumerated() {
                let debt = outcome.debts[index]
                let isLast = offset == extraOrder.count - 1
                let rounded = isLast ? extraRemainder : min((extraByIndex[index] ?? 0).rounded2, extraRemainder)
                extraRemainder -= rounded
                var reasons: [ReasonCode] = [.avalancheHighestEffectiveAPR]
                if debt.input.id != targetDebtID { reasons.append(.rolloverAfterPayoff) }
                if let promo = debt.input.promo {
                    reasons.append(payday < promo.expirationDate ? .promoRateActive : .promoRateExpired)
                }
                if windfall > 0 { reasons.append(.windfallApplied) }
                if let position = payments.firstIndex(where: { $0.debtID == debt.input.id }) {
                    payments[position].extra += rounded
                    payments[position].reasons.append(contentsOf: reasons)
                } else {
                    payments.append(PlannedPayment(
                        debtID: debt.input.id, minimum: 0, extra: rounded,
                        fundsDueDate: nil, reasons: reasons
                    ))
                }
            }
            for index in outcome.debts.indices {
                let debt = outcome.debts[index]
                if debt.payoffDate == payday,
                   let position = payments.firstIndex(where: { $0.debtID == debt.input.id }) {
                    payments[position].reasons.append(.debtPaidOff)
                }
                let paid = payments.first { $0.debtID == debt.input.id }.map { $0.minimum + $0.extra } ?? 0
                outcome.debts[index].totalPaid += paid
            }

            spendingCeiling += keepEmit

            let endingBalances = outcome.debts.map {
                DebtBalancePoint(debtID: $0.input.id, balance: max($0.balance.rounded2, 0))
            }
            let totalAfterExact = outcome.debts.reduce(Decimal.zero) { $0 + $1.balance }

            var movements: [String] = []
            movements.append(
                "Deposit \(MoneyFormat.string(income + windfall)); keep \(MoneyFormat.string(keepEmit)) in spending; move \(MoneyFormat.string(transferEmit)) to reserves."
            )
            if obligationTotal > 0 {
                movements.append("Reserve \(MoneyFormat.string(obligationTotal)) for essential obligations.")
            }
            if minimumsTotalEmit > 0 {
                movements.append("Pay \(MoneyFormat.string(minimumsTotalEmit)) in minimums across \(minimumPlans.count) debt\(minimumPlans.count == 1 ? "" : "s").")
            }
            if let targetDebtID,
               let target = outcome.debts.first(where: { $0.input.id == targetDebtID }) {
                let apr = target.input.effectiveAPR(on: payday) * 100
                movements.append("Send \(MoneyFormat.string(extraTotalEmit)) extra to \(target.input.name) — highest effective APR (\(apr.rounded2)%).")
            }
            for name in rolloverNames {
                movements.append("Freed-up payment capacity rolled to \(name) in the same paycheck.")
            }
            if let shortfall { movements.append(shortfall.explanation) }
            if unassignedEmit > 0 {
                movements.append("\(MoneyFormat.string(unassignedEmit)) has no eligible debt to attack and stays in reserves.")
            }

            outcome.paychecks.append(PaycheckPlan(
                sequence: sequence,
                date: payday,
                accrualDays: accrualDays,
                income: income,
                windfall: windfall,
                allowanceReserved: allowanceEmit,
                floorTopUp: floorTopUpEmit,
                keepInSpending: keepEmit,
                transferToReserves: transferEmit,
                obligationReserves: obligationReserves,
                obligationReserveTotal: obligationTotal,
                debtBudget: debtBudgetEmit,
                payments: payments,
                minimumsTotal: minimumsTotalEmit,
                extraTotal: extraTotalEmit,
                targetDebtID: targetDebtID,
                interestAccrued: interestThisCheck.rounded2,
                endingBalances: endingBalances,
                totalDebtAfter: max(totalAfterExact.rounded2, 0),
                unassignedCash: unassignedEmit,
                spendingCeilingAfter: spendingCeiling,
                shortfall: shortfall,
                movements: movements
            ))

            // Events for this paycheck.
            outcome.events.append(PlanEvent(
                identifier: "payday-\(sequence)", date: payday, kind: .payday,
                debtID: nil, obligationID: nil, amount: income + windfall,
                title: "Payday — \(MoneyFormat.string(income + windfall)) deposit",
                reasons: []
            ))
            for plan in minimumPlans {
                guard let dueDate = plan.dueDate else { continue }
                let debt = outcome.debts[plan.index]
                outcome.events.append(PlanEvent(
                    identifier: "due-\(dateKey(dueDate))-\(debt.input.id.uuidString)",
                    date: dueDate, kind: .minimumDue,
                    debtID: debt.input.id, obligationID: nil,
                    amount: plan.exactAmount.rounded2,
                    title: "\(debt.input.name) minimum due",
                    reasons: [.minimumDueByDate]
                ))
            }
            for debt in outcome.debts where debt.payoffDate == payday {
                outcome.events.append(PlanEvent(
                    identifier: "payoff-\(debt.input.id.uuidString)",
                    date: payday, kind: .debtPayoff,
                    debtID: debt.input.id, obligationID: nil, amount: nil,
                    title: "\(debt.input.name) paid off",
                    reasons: [.debtPaidOff]
                ))
            }
            if let shortfall, shortfall.gap > 0 {
                outcome.events.append(PlanEvent(
                    identifier: "shortfall-\(sequence)", date: payday, kind: .shortfallAlert,
                    debtID: nil, obligationID: nil, amount: shortfall.gap,
                    title: "Needs attention — \(MoneyFormat.string(shortfall.gap)) short this paycheck",
                    reasons: [.shortfallNeedsAttention]
                ))
            }

            if outcome.debts.allSatisfy({ $0.balance.rounded2 <= 0 }) {
                outcome.payoffDate = payday
                outcome.events.append(PlanEvent(
                    identifier: "plan-complete", date: payday, kind: .planComplete,
                    debtID: nil, obligationID: nil, amount: nil,
                    title: "All debts paid off",
                    reasons: [.debtPaidOff]
                ))
                break
            }
            checkIndex += 1
        }

        if outcome.payoffDate == nil && outcome.debts.contains(where: { $0.isActive }) {
            outcome.notPayable = true
            warn(.horizonCapReached,
                 "The debts are not paid off within \(horizonCap) paychecks as configured.")
        }

        // Obligation due-date calendar events across the plan span.
        if let firstPaycheck = outcome.paychecks.first, let lastPaycheck = outcome.paychecks.last {
            let end = DateMath.addingDays(1, to: lastPaycheck.date)
            for obligation in input.obligations {
                guard let day = obligation.dueDay else { continue }
                for dueDate in PayScheduleGenerator.dueDates(day: day, from: firstPaycheck.date, to: end) {
                    outcome.events.append(PlanEvent(
                        identifier: "obligation-\(dateKey(dueDate))-\(obligation.id.uuidString)",
                        date: dueDate, kind: .obligationDue,
                        debtID: nil, obligationID: obligation.id,
                        amount: obligation.amount,
                        title: "\(obligation.name) due",
                        reasons: [.obligationReserve]
                    ))
                }
            }
        }
        outcome.events.sort { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.identifier < rhs.identifier
        }
        return outcome
    }

    // MARK: - Minimum-only comparison

    /// Runs the minimums-only track when the inputs can support the claim
    /// (every active non-card debt needs an entered minimum). Returns nil —
    /// never a guess — when they cannot.
    private static func minimumOnlyComparison(
        _ input: PlanningInput,
        against recommended: Outcome,
        actuals: ActualState?
    ) -> (comparison: MinimumOnlyComparison?, notes: [PlanningNote]) {
        let activeDebts = input.debts.filter { $0.balance.rounded2 > 0 }
        guard !activeDebts.isEmpty else { return (nil, []) }
        let unsupported = activeDebts.filter { $0.debtType != .creditCard && $0.minimumPayment == nil }
        guard unsupported.isEmpty else {
            let names = unsupported.map(\.name).sorted().joined(separator: ", ")
            return (nil, [PlanningNote(
                code: .minimumOnlyUnavailable,
                message: "Interest-saved versus minimums-only cannot be estimated until the contractual payment is entered for: \(names)."
            )])
        }
        let outcome = runProjection(input, extraEnabled: false, actuals: actuals)
        var notes: [PlanningNote] = []
        var interestSaved: Decimal?
        var daysSaved: Int?
        let unfinished = outcome.payoffDate == nil
        if unfinished {
            notes.append(PlanningNote(
                code: .minimumOnlyNeverFinishes,
                message: "Minimum payments alone do not retire these debts within \(horizonCap) paychecks."
            ))
        }
        if let minOnlyPayoff = outcome.payoffDate, let planPayoff = recommended.payoffDate {
            interestSaved = max((outcome.totalInterestExact - recommended.totalInterestExact).rounded2, 0)
            daysSaved = max(DateMath.days(from: planPayoff, to: minOnlyPayoff), 0)
        }
        let comparison = MinimumOnlyComparison(
            payoffDate: outcome.payoffDate,
            paycheckCount: outcome.paychecks.count,
            totalInterest: outcome.totalInterestExact.rounded2,
            interestSaved: interestSaved,
            daysSaved: daysSaved,
            unfinished: unfinished
        )
        return (comparison, notes)
    }

    // MARK: - Result assembly

    private static func assemble(
        kind: PlanKind,
        input: PlanningInput,
        outcome: Outcome,
        comparison: (comparison: MinimumOnlyComparison?, notes: [PlanningNote]),
        actuals: ActualState? = nil
    ) -> PlanningResult {
        // Payoff order: projected payoff sequence; unfinished debts follow in
        // priority order at plan start.
        let startDate = outcome.paychecks.first?.date ?? input.income.firstPayday
        let startPriority = prioritySorted(
            Array(outcome.debts.indices), debts: outcome.debts, on: startDate
        )
        let priorityRank = Dictionary(uniqueKeysWithValues: startPriority.enumerated().map { ($1, $0) })
        let payoffOrder = outcome.debts.indices.sorted { a, b in
            switch (outcome.debts[a].payoffDate, outcome.debts[b].payoffDate) {
            case let (x?, y?) where x != y: return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return (priorityRank[a] ?? 0) < (priorityRank[b] ?? 0)
            }
        }.map { outcome.debts[$0].input.id }

        let summaries = outcome.debts.map { debt in
            DebtPlanSummary(
                debtID: debt.input.id,
                name: debt.input.name,
                debtType: debt.input.debtType,
                startingBalance: debt.initialBalance.rounded2,
                apr: debt.input.apr,
                payoffDate: debt.payoffDate,
                totalPaid: debt.totalPaid.rounded2,
                interestPaid: debt.interestAccrued.rounded2,
                receivesExtraPrincipal: debt.extraEligible
            )
        }

        let utilization: [CreditUtilization] = input.debts
            .filter { $0.debtType == .creditCard }
            .map { debt in
                let current = (actuals?.balances.first { $0.debtID == debt.id }?.balance ?? debt.balance).rounded2
                guard let limit = debt.creditLimit, limit > 0 else {
                    return CreditUtilization(
                        debtID: debt.id, balance: current,
                        creditLimit: debt.creditLimit, utilization: nil, level: .unknown
                    )
                }
                var ratio = current / limit
                var rounded = Decimal()
                NSDecimalRound(&rounded, &ratio, 4, .plain)
                let level: UtilizationLevel = rounded >= Decimal(string: "0.9")! ? .critical
                    : rounded >= Decimal(string: "0.3")! ? .elevated : .ok
                return CreditUtilization(
                    debtID: debt.id, balance: current,
                    creditLimit: limit, utilization: rounded, level: level
                )
            }

        var warnings = outcome.warnings + comparison.notes
        for debt in input.debts where debt.debtType == .creditCard && debt.balance.rounded2 > 0 {
            if debt.creditLimit == nil {
                warnings.append(PlanningNote(
                    code: .creditLimitMissing,
                    message: "Add \(debt.name)'s credit limit to see utilization.",
                    debtID: debt.id
                ))
            } else if debt.creditLimit == 0 {
                warnings.append(PlanningNote(
                    code: .creditLimitZero,
                    message: "\(debt.name)'s credit limit is $0; utilization is not shown.",
                    debtID: debt.id
                ))
            }
        }

        var assumptions: [PlanningNote] = [
            PlanningNote(code: .estimateOnly,
                         message: "Interest is a simple estimate (balance × APR × days ÷ 365). Actual issuer interest, posting dates, and statement minimums will differ."),
            PlanningNote(code: .paymentsPostOnPayday,
                         message: "Payments are modeled as posting on the payday that funds them."),
            PlanningNote(code: .year365,
                         message: "Interest uses a 365-day year, including leap years.")
        ]
        if input.debts.contains(where: { $0.promo != nil }) {
            assumptions.append(PlanningNote(
                code: .promoNotProrated,
                message: "Promotional APRs apply to whole accrual periods; the standard rate starts with the first payday on or after expiration."
            ))
        }
        if input.debts.contains(where: { $0.creditLimit != nil }) {
            assumptions.append(PlanningNote(
                code: .utilizationDisplayOnly,
                message: "Utilization is informational; it never changes how payments are allocated."
            ))
        }

        var recommendationReasons: [ReasonCode] = [.avalancheHighestEffectiveAPR]
        var explanations = [
            "Minimum payments are covered first, then every remaining dollar attacks the debt with the highest effective APR. This minimizes estimated interest and reaches payoff as early as possible."
        ]
        if let targetID = outcome.firstTargetDebtID,
           let target = input.debts.first(where: { $0.id == targetID }) {
            let apr = target.effectiveAPR(on: startDate) * 100
            explanations.append("Current target: \(target.name) at \(apr.rounded2)% effective APR.")
            if let promo = target.promo, startDate < promo.expirationDate {
                recommendationReasons.append(.promoRateActive)
            }
        }
        if input.debts.contains(where: { $0.prepayment == .unknown && $0.balance.rounded2 > 0 }) {
            recommendationReasons.append(.prepaymentUnknown)
            explanations.append("Debts with unconfirmed prepayment terms receive minimums only until you confirm extra principal is allowed.")
        }
        if kind == .reforecast {
            recommendationReasons.append(.authoritativeBalance)
            explanations.append("This forecast starts from your latest entered balances. The original plan is unchanged.")
        }

        return PlanningResult(
            calculationVersion: .v2Avalanche,
            kind: kind,
            generatedAsOf: actuals.map { DateMath.startOfDay($0.asOf) } ?? input.asOf,
            totalStartingPrincipal: input.debts.reduce(Decimal.zero) { $0 + $1.balance }.rounded2,
            totalRemainingPrincipal: outcome.startingPrincipal.rounded2,
            payoffOrder: payoffOrder,
            currentTargetDebtID: outcome.firstTargetDebtID,
            recommendationReasons: recommendationReasons,
            recommendationExplanations: explanations,
            paychecks: outcome.paychecks,
            paycheckCount: outcome.paychecks.count,
            forecastPayoffDate: outcome.payoffDate,
            debtSummaries: summaries,
            estimatedTotalInterest: outcome.totalInterestExact.rounded2,
            estimatedRemainingInterest: outcome.totalInterestExact.rounded2,
            minimumOnlyComparison: comparison.comparison,
            utilization: utilization,
            cashBufferPath: outcome.paychecks.map(\.spendingCeilingAfter),
            hasUnassignedCash: outcome.hasUnassignedCash,
            events: outcome.events,
            warnings: warnings,
            assumptions: assumptions,
            notPayableAsConfigured: outcome.notPayable
        )
    }
}
