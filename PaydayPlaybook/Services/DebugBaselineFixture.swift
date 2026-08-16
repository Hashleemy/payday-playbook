#if DEBUG
import Foundation
import SwiftData

/// A wholly invented calc-v1 plan graph, for development and tests only.
///
/// This replaces the bundled template that used to fill this role (V3-12).
/// That template was one real person's finances; anything that needed "a
/// plausible complete plan to look at" got their actual balances, income, and
/// payoff dates along with it. Nothing here describes anyone: the cards, the
/// paycheck, and the bills are made up, and the schedule is *derived* from
/// them by the same calc-v1 engine the app ships, so the graph is internally
/// consistent without anyone having to transcribe a real one.
///
/// Compiled only into Debug builds. A distribution build contains neither
/// this generator nor any plan data — a fresh install has exactly what the
/// user enters and nothing else.
enum DebugBaselineFixture {

    // MARK: - Invented inputs

    /// Cards in avalanche order (highest APR first). Round, obviously
    /// synthetic balances — a fixture that looks like real data invites
    /// someone to treat it as real data.
    ///
    /// Six cards retiring in twenty-three biweekly checks: the same *shape*
    /// the suite has always exercised, so structural assertions still mean
    /// what they meant, with none of the original numbers.
    static let cards: [(planID: String, balance: String, apr: String)] = [
        ("A", "5700.00", "0.2600"),
        ("B", "5850.00", "0.2300"),
        ("C", "6500.00", "0.2000"),
        ("D", "5700.00", "0.1700"),
        ("E", "6150.00", "0.1400"),
        ("F", "6500.00", "0.1100")
    ]

    static let startingSpendingBalance = Decimal(string: "1500.00")!
    static let protectedFloor = Decimal(string: "1500.00")!
    static let allowancePerCheck = Decimal(string: "300.00")!
    static let firstIncome = Decimal(string: "2400.00")!
    static let raisedIncome = Decimal(string: "2500.00")!
    /// The raise lands mid-plan so schedules that straddle it are exercised.
    static let raiseAtSequence = 9

    /// Monthly obligations. Their per-paycheck reserves are derived by R-04
    /// rather than stated, so the fixture cannot disagree with the rule.
    static let carMonthly = Decimal(string: "700.00")!
    static let transitMonthly = Decimal(string: "150.00")!

    static let paychecksPerYear = 26

    static var carReservePerCheck: Decimal {
        ObligationMath.perPaycheckReserve(
            amount: carMonthly, cadence: .monthly, paychecksPerYear: paychecksPerYear
        )
    }

    static var transitReservePerCheck: Decimal {
        ObligationMath.perPaycheckReserve(
            amount: transitMonthly, cadence: .monthly, paychecksPerYear: paychecksPerYear
        )
    }

    /// A fixed, clearly-future first payday. Tests pin "today" near it so
    /// nothing depends on the wall clock.
    static var firstPayday: Date { DateMath.localDate(year: 2054, month: 8, day: 20) }

    // MARK: - Insertion

    struct Summary {
        let planVersion: PlanVersion
        let debtCount: Int
        let paydayCount: Int
        let wasAlreadyPresent: Bool
    }

    /// Inserts the fixture if no baseline row exists, and saves once.
    ///
    /// `applySchemaUpgrade: false` leaves the graph in its 0.1.x shape, which
    /// is what migration tests need to migrate *from*.
    @discardableResult
    static func insertIfNeeded(
        context: ModelContext,
        applySchemaUpgrade: Bool = true
    ) throws -> Summary {
        if let existing = try PlanRepository.legacyBaseline(context: context),
           try PlanRepository.isStructurallyComplete(existing, context: context) {
            let items = try PlanRepository.planItems(context: context, plan: existing)
            return Summary(
                planVersion: existing,
                debtCount: try context.fetchCount(FetchDescriptor<DebtAccount>()),
                paydayCount: items.count,
                wasAlreadyPresent: true
            )
        }

        let plan = try insert(context: context)
        if applySchemaUpgrade {
            try MigrationService.applyLogicalUpgrade(context: context)
            try MigrationService.applySchema3Upgrade(context: context)
            try MigrationService.stamp(context: context, from: PlanContract.schemaVersion)
        }
        try context.save()
        let items = try PlanRepository.planItems(context: context, plan: plan)
        return Summary(
            planVersion: plan,
            debtCount: cards.count,
            paydayCount: items.count,
            wasAlreadyPresent: false
        )
    }

    // MARK: - Derivation

    /// Runs the shipped calc-v1 engine over the invented inputs and writes the
    /// resulting schedule. Because the schedule is computed rather than
    /// transcribed, per-card balances, payoff dates, and totals agree with the
    /// engine by construction.
    private static func insert(context: ModelContext) throws -> PlanVersion {
        let reserves = carReservePerCheck + transitReservePerCheck

        // Enough paydays to retire the invented balances, with headroom.
        let horizon = 40
        let dates = (0..<horizon).map { index in
            DateMath.addingDays(PlanContract.payFrequencyDays * index, to: firstPayday)
        }
        func income(at sequence: Int) -> Decimal {
            sequence >= raiseAtSequence ? raisedIncome : firstIncome
        }
        func cardBudget(at sequence: Int) -> Decimal {
            (income(at: sequence) - allowancePerCheck - reserves).rounded2
        }

        let enginePaydays = dates.enumerated().map { offset, date in
            DebtCalculationEngine.EnginePayday(
                sequence: offset + 1, date: date, cardBudget: cardBudget(at: offset + 1)
            )
        }
        let engineDebts = cards.map {
            DebtCalculationEngine.EngineDebt(
                planID: $0.planID,
                apr: Decimal(string: $0.apr)!,
                balance: Decimal(string: $0.balance)!
            )
        }
        let projection = DebtCalculationEngine.project(debts: engineDebts, paydays: enginePaydays)
        guard !projection.unfinished, let payoffDate = projection.payoffDate else {
            throw FixtureError.projectionDidNotFinish
        }

        let plan = PlanVersion(
            name: PlanContract.planName,
            isOriginalBaseline: true,
            isActive: true,
            firstPayday: firstPayday,
            payFrequencyDays: PlanContract.payFrequencyDays,
            startingChecking1: startingSpendingBalance,
            protectedBuffer: protectedFloor,
            allowanceCap: allowancePerCheck,
            firstCheckBufferAdd: .zero,
            carReservePerCheck: carReservePerCheck,
            trainReservePerCheck: transitReservePerCheck,
            calculationVersion: PlanContract.calculationVersion,
            avalancheOrderRaw: cards.map(\.planID).joined(separator: ","),
            baselinePayoffDate: payoffDate,
            baselineModeledInterest: projection.totalInterest.rounded2,
            baselineNoSpendCeiling: (startingSpendingBalance
                + allowancePerCheck * Decimal(projection.schedule.count)).rounded2
        )
        context.insert(plan)

        context.insert(IncomeRule(
            planVersionID: plan.id, effectiveDate: firstPayday, netPaycheckAmount: firstIncome
        ))
        context.insert(IncomeRule(
            planVersionID: plan.id,
            effectiveDate: dates[raiseAtSequence - 1],
            netPaycheckAmount: raisedIncome
        ))

        for (index, card) in cards.enumerated() {
            context.insert(DebtAccount(
                planID: card.planID,
                displayName: "Card \(card.planID)",
                startingBalance: Decimal(string: card.balance)!,
                apr: Decimal(string: card.apr)!,
                priority: index + 1
            ))
        }

        for outcome in projection.schedule {
            let item = PaydayPlanItem(
                planVersionID: plan.id,
                sequenceNumber: outcome.sequence,
                date: outcome.date,
                plannedIncome: income(at: outcome.sequence),
                // R-16: every dollar of income is either kept in spending or
                // moved to reserves. The floor is already met, so the amount
                // kept is exactly the allowance and the rest moves across.
                plannedC1Keep: allowancePerCheck,
                plannedBufferAdd: .zero,
                plannedAllowance: allowancePerCheck,
                plannedC2Transfer: (income(at: outcome.sequence) - allowancePerCheck).rounded2,
                plannedCarReserve: carReservePerCheck,
                plannedTrainReserve: transitReservePerCheck,
                plannedCardBudget: cardBudget(at: outcome.sequence),
                plannedTargetDebtID: outcome.targetPlanID ?? "",
                plannedDebtAfter: outcome.totalDebtAfter.rounded2,
                // R-10: the ceiling is what the balance would reach if no
                // allowance were ever spent, so it climbs by the kept amount
                // every check rather than staying flat.
                plannedC1NoSpendCeiling: (startingSpendingBalance
                    + allowancePerCheck * Decimal(outcome.sequence)).rounded2
            )
            context.insert(item)
            for card in cards {
                context.insert(PlannedCardBalance(
                    paydayPlanItemID: item.id,
                    debtPlanID: card.planID,
                    balanceAfter: (outcome.balancesAfter[card.planID] ?? .zero).rounded2
                ))
            }
        }

        for card in cards {
            context.insert(Milestone(
                type: .cardPaidOff,
                title: "Card \(card.planID) paid off",
                relatedDebtPlanID: card.planID,
                baselineDate: projection.perCardPayoffDates[card.planID]
            ))
        }
        // Amount-eliminated milestones every $5,000, dated to the first check
        // whose remaining balance falls below the threshold.
        let startingTotal = engineDebts.reduce(Decimal.zero) { $0 + $1.balance }
        var threshold = Decimal(5000)
        while threshold < startingTotal {
            let remainingAtThreshold = startingTotal - threshold
            if let crossing = projection.schedule.first(where: {
                $0.totalDebtAfter.rounded2 <= remainingAtThreshold
            }) {
                context.insert(Milestone(
                    type: .amountEliminated,
                    title: "\(MoneyFormat.whole(threshold)) eliminated",
                    thresholdAmount: threshold,
                    baselineDate: crossing.date
                ))
            }
            threshold += 5000
        }

        context.insert(Milestone(type: .debtFree, title: "Debt-free", baselineDate: payoffDate))

        if try context.fetchCount(FetchDescriptor<NotificationPreference>()) == 0 {
            for preference in NotificationPreference.seedDefaults() {
                context.insert(preference)
            }
        }
        if try context.fetchCount(FetchDescriptor<AppSettings>()) == 0 {
            context.insert(AppSettings(seedSchemaVersion: PlanContract.schemaVersion))
        }

        return plan
    }

    enum FixtureError: Error, Equatable {
        /// The invented balances outlast the payday horizon — the fixture's
        /// own numbers are inconsistent and need adjusting, not the engine.
        case projectionDidNotFinish
    }
}
#endif
