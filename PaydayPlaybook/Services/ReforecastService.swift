import Foundation
import SwiftData

/// Bridges stored data into the pure calculation engine and records
/// ForecastSnapshot rows. Original Plan v1 rows are read-only inputs here.
struct ReforecastService {
    let context: ModelContext
    let dateProvider: DateProviding

    init(context: ModelContext, dateProvider: DateProviding) {
        self.context = context
        self.dateProvider = dateProvider
    }

    @discardableResult
    func reforecast(
        trigger: ForecastTrigger,
        varianceContext: String? = nil
    ) throws -> ForecastSnapshot? {
        guard let plan = try PlanSeeder.existingBaseline(context: context) else { return nil }
        // Schedule dates come from the immutable baseline; allocation amounts
        // come from the active plan version when the user has created one.
        let allPlans = try context.fetch(FetchDescriptor<PlanVersion>())
        let activePlan = allPlans.first(where: { $0.isActive && !$0.isOriginalBaseline }) ?? plan
        let planID = plan.id

        let planItems = try context.fetch(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
        ).sorted { $0.sequenceNumber < $1.sequenceNumber }
        let incomeRules = try context.fetch(
            FetchDescriptor<IncomeRule>(predicate: #Predicate { $0.planVersionID == planID })
        ).sorted { $0.effectiveDate < $1.effectiveDate }
        let checkIns = try context.fetch(FetchDescriptor<PaydayCheckIn>())

        let balanceService = AccountBalanceService(context: context, dateProvider: dateProvider)
        let debtBalances = try balanceService.debtBalances()

        let engineDebts = debtBalances.map { item in
            DebtCalculationEngine.EngineDebt(
                planID: item.debt.planID,
                apr: item.debt.apr,
                balance: item.balance,
                minimumOverride: item.debt.minimumAmount
            )
        }

        let today = DateMath.startOfDay(dateProvider.now)
        let completedItemIDs = Set(
            checkIns.filter { $0.status == .completed || $0.status == .needsAttention }
                .map(\.paydayPlanItemID)
        )

        // Next payday: the earliest not-completed one — overdue open paydays
        // stay in the projection since their budget is still expected.
        let nextItem = planItems.first { !completedItemIDs.contains($0.id) }
        _ = today

        let nextDate: Date
        let nextSequence: Int
        if let nextItem {
            nextDate = DateMath.startOfDay(nextItem.date)
            nextSequence = nextItem.sequenceNumber
        } else if let last = planItems.last {
            // Past the planned schedule; continue the biweekly cadence.
            nextDate = DateMath.addingDays(plan.payFrequencyDays, to: DateMath.startOfDay(last.date))
            nextSequence = (planItems.last?.sequenceNumber ?? 0) + 1
        } else {
            return nil
        }

        let firstCheckPending = planItems.first.map { !completedItemIDs.contains($0.id) } ?? false

        let input = DebtCalculationEngine.ReforecastInput(
            debts: engineDebts,
            asOf: today,
            plan: DebtCalculationEngine.PlanSettingsSnapshot(
                allowanceCap: activePlan.allowanceCap,
                firstCheckBufferAdd: activePlan.firstCheckBufferAdd,
                carReservePerCheck: activePlan.carReservePerCheck,
                trainReservePerCheck: activePlan.trainReservePerCheck,
                payFrequencyDays: activePlan.payFrequencyDays,
                baselinePayoffDate: plan.baselinePayoffDate
            ),
            incomeRules: incomeRules.map { ($0.effectiveDate, $0.netPaycheckAmount) },
            nextSequence: nextSequence,
            nextPaydayDate: nextDate,
            includeFirstCheckBuffer: firstCheckPending,
            triggerType: trigger,
            varianceContext: varianceContext
        )

        let result = DebtCalculationEngine.reforecast(input)

        let snapshot = ForecastSnapshot(
            calculatedAt: dateProvider.now,
            sourcePlanVersionID: plan.id,
            triggerType: trigger,
            projectedPayoffDate: result.projection.payoffDate,
            remainingPaychecks: result.projection.paychecksUsed,
            estimatedRemainingInterest: result.projection.totalInterest,
            perCardPayoffDates: result.projection.perCardPayoffDates
                .map { PerCardPayoff(debtPlanID: $0.key, payoffDate: $0.value) }
                .sorted { $0.debtPlanID < $1.debtPlanID },
            summaryExplanation: result.explanation
        )
        context.insert(snapshot)
        try context.save()
        return snapshot
    }

    func latestForecast() throws -> ForecastSnapshot? {
        let snapshots = try context.fetch(FetchDescriptor<ForecastSnapshot>())
        return snapshots.max { $0.calculatedAt < $1.calculatedAt }
    }

    /// Take-home paycheck amount effective on `date`, from stored income rules.
    static func currentIncome(context: ModelContext, on date: Date) throws -> Decimal {
        guard let plan = try PlanSeeder.existingBaseline(context: context) else {
            return PlanContract.firstIncome
        }
        let planID = plan.id
        let rules = try context.fetch(
            FetchDescriptor<IncomeRule>(predicate: #Predicate { $0.planVersionID == planID })
        ).sorted { $0.effectiveDate < $1.effectiveDate }
        return DebtCalculationEngine.incomeAmount(
            on: date,
            rules: rules.map { ($0.effectiveDate, $0.netPaycheckAmount) }
        )
    }
}
