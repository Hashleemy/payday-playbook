import Foundation
import SwiftData

/// Assembles `PlanViewData` for the Generated Plan screen.
///
/// The three tracks are built from three separate sources and never merged:
/// **baseline** from the plan's own immutable `PaydayPlanItem` rows,
/// **actual** from completed check-ins and ledger entries, **reforecast**
/// from the calc-v2 engine (or the stored `ForecastSnapshot` for calc-v1
/// plans, which the frozen engine owns).
@MainActor
enum PlanViewDataLoader {

    static func load(
        plan: PlanVersion,
        context: ModelContext,
        environment: AppEnvironment
    ) -> PlanViewData {
        var data = PlanViewData()
        data.plan = plan
        data.planName = plan.name
        data.calculationVersion = plan.calculationVersion
        data.isBaseline = plan.isOriginalBaseline
        data.isActive = plan.isActive
        data.generatedFromProfile = plan.generatedFromProfile
        data.generatedAt = plan.createdAt
        data.protectedFloor = plan.protectedBuffer
        data.allowanceCap = plan.allowanceCap

        let planID = plan.id
        let items = (try? context.fetch(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
        ))?.sorted { $0.sequenceNumber < $1.sequenceNumber } ?? []

        let obligations = (try? context.fetch(FetchDescriptor<RecurringObligation>())) ?? []
        let obligationNames = Dictionary(uniqueKeysWithValues: obligations.map { ($0.id, $0.name) })
        let reserveRows = (try? context.fetch(FetchDescriptor<PlannedObligationReserve>())) ?? []
        let reservesByItem = Dictionary(grouping: reserveRows, by: \.paydayPlanItemID)
        let balanceRows = (try? context.fetch(FetchDescriptor<PlannedCardBalance>())) ?? []
        let balancesByItem = Dictionary(grouping: balanceRows, by: \.paydayPlanItemID)
        let debts = (try? context.fetch(FetchDescriptor<DebtAccount>()))?
            .sorted { ($0.priority, $0.createdAt) < ($1.priority, $1.createdAt) } ?? []
        let debtsByPlanID = Dictionary(debts.map { ($0.planID, $0) }, uniquingKeysWith: { first, _ in first })

        // MARK: Inputs summary

        data.cadenceText = plan.payCadence.displayName
        data.firstPaydayText = DateMath.mediumString(plan.firstPayday)

        let incomeRules = (try? context.fetch(
            FetchDescriptor<IncomeRule>(predicate: #Predicate { $0.planVersionID == planID })
        ))?.sorted { $0.effectiveDate < $1.effectiveDate } ?? []
        if let first = incomeRules.first {
            data.takeHomeText = "\(MoneyFormat.string(first.netPaycheckAmount)) per paycheck"
        } else if let firstItem = items.first {
            data.takeHomeText = "\(MoneyFormat.string(firstItem.plannedIncome)) per paycheck"
        }
        data.incomeChangeLines = incomeRules.dropFirst().map {
            "Changes to \(MoneyFormat.string($0.netPaycheckAmount)) on \(DateMath.mediumString($0.effectiveDate))"
        }

        let paychecksPerYear = plan.payCadence.paychecksPerYear
        data.obligationLines = obligations
            .filter { !$0.isArchived }
            .sorted { $0.name < $1.name }
            .map { obligation in
                (
                    name: obligation.name,
                    amount: obligation.amount,
                    cadence: obligation.cadence.displayName,
                    perPaycheck: ObligationMath.perPaycheckReserve(
                        amount: obligation.amount,
                        cadence: obligation.cadence,
                        paychecksPerYear: paychecksPerYear
                    )
                )
            }

        if let accounts = try? CashAccountRepository(context: context).activeAccounts() {
            data.accountLines = accounts.map { account in
                var roles = account.roles.map(\.displayName).sorted()
                if account.isDefaultIncome { roles.append("Default income") }
                return (name: account.name, roles: roles.joined(separator: " · "), balance: account.currentBalance)
            }
        }

        // MARK: Baseline track (stored rows — the immutable truth)

        data.baselineRows = items.map { item in
            let reserves = (reservesByItem[item.id] ?? [])
                .map { (name: obligationNames[$0.obligationID] ?? "Obligation", amount: $0.amount) }
                .sorted { $0.name < $1.name }
            let legacyReserveTotal = item.plannedCarReserve + item.plannedTrainReserve
            let reserveTotal = legacyReserveTotal > 0
                ? legacyReserveTotal
                : reserves.reduce(Decimal.zero) { $0 + $1.amount }
            let legacyLines: [(name: String, amount: Decimal)] = legacyReserveTotal > 0 && reserves.isEmpty
                ? [("Car", item.plannedCarReserve), ("Train pass", item.plannedTrainReserve)]
                : reserves
            return PlanPaycheckRow(
                id: item.id,
                sequence: item.sequenceNumber,
                date: item.date,
                income: item.plannedIncome,
                keepInSpending: item.plannedC1Keep,
                transferToReserves: item.plannedC2Transfer,
                allowance: item.plannedAllowance,
                floorTopUp: item.plannedBufferAdd,
                obligationReserves: legacyLines,
                obligationReserveTotal: reserveTotal,
                minimumsTotal: nil,
                extraTotal: nil,
                debtBudget: item.plannedCardBudget,
                targetLabel: targetLabel(item.plannedTargetDebtID, debts: debtsByPlanID),
                debtAfter: item.plannedDebtAfter,
                endingCash: item.plannedC1NoSpendCeiling,
                shortfall: item.shortfallAmount,
                movements: [],
                isActualRecord: false
            )
        }

        data.paycheckCount = items.count
        data.payoffDate = plan.baselinePayoffDate
        data.totalEstimatedInterest = plan.baselineModeledInterest

        // MARK: Actual track (user entries only)

        data.actualRows = actualRows(
            items: items,
            context: context,
            debts: debtsByPlanID
        )

        // MARK: Recommendation / principal

        let balanceService = environment.balanceService(context: context)
        let liveBalances = (try? balanceService.debtBalances()) ?? []
        let balanceByID = Dictionary(liveBalances.map { ($0.debt.id, $0.balance) }, uniquingKeysWith: { first, _ in first })

        let forecast = try? environment.reforecastService(context: context).latestForecast()
        var payoffByPlanID: [String: Date] = [:]
        for entry in forecast?.perCardPayoffDates ?? [] {
            payoffByPlanID[entry.debtPlanID] = entry.payoffDate
        }
        let milestones = (try? context.fetch(FetchDescriptor<Milestone>())) ?? []
        var baselinePayoffByPlanID: [String: Date] = [:]
        for milestone in milestones where milestone.type == .cardPaidOff {
            if let debtPlanID = milestone.relatedDebtPlanID {
                baselinePayoffByPlanID[debtPlanID] = milestone.baselineDate
            }
        }

        let orderedPlanIDs = plan.avalancheOrder
        let ordered: [DebtAccount] = orderedPlanIDs.compactMap { debtsByPlanID[$0] }
        let remaining = debts.filter { debt in !orderedPlanIDs.contains(debt.planID) }
        data.debtRows = (ordered + remaining).enumerated().map { index, debt in
            let balance = balanceByID[debt.id] ?? debt.startingBalance
            return PlanDebtRow(
                id: debt.id,
                planID: debt.planID,
                name: debt.displayName,
                debtType: debt.debtType,
                apr: debt.apr,
                currentBalance: balance,
                originalPrincipal: debt.originalPrincipal,
                creditLimit: debt.creditLimit,
                utilization: debt.utilization(currentBalance: balance),
                minimum: debt.minimumAmount,
                dueDay: debt.dueDayOfMonth,
                priority: index + 1,
                payoffDate: payoffByPlanID[debt.planID] ?? baselinePayoffByPlanID[debt.planID],
                receivesExtraPrincipal: debt.isExtraPrincipalEligible
            )
        }
        data.totalPrincipalNow = data.debtRows.reduce(Decimal.zero) { $0 + $1.currentBalance }.rounded2
        data.totalStartingPrincipal = debts.reduce(Decimal.zero) { $0 + $1.startingBalance }.rounded2
        let originals = debts.compactMap(\.originalPrincipal)
        if originals.count == debts.count && !debts.isEmpty {
            data.totalOriginalPrincipal = originals.reduce(Decimal.zero, +).rounded2
        }
        data.avalancheExplanation = "Highest APR first. Every minimum is paid, then all remaining money goes to the top debt — this is the order that costs the least interest."

        // MARK: Calc-version-specific analysis

        if plan.calculationVersion >= PlanContract.currentCalculationVersion {
            loadCalcV2(into: &data, plan: plan, context: context, environment: environment, debts: debtsByPlanID)
        } else {
            data.assumptionLines = [
                "Interest is modeled every 14 days as balance × APR ÷ 365, not daily compounding or issuer statement cycles.",
                "Card minimums without an entered amount use the baseline estimate (greater of $17.50 or 0.5% of the balance).",
                "Your issuer's interest, statement minimums, and posting dates will differ. Your entered balances are authoritative."
            ]
            data.minimumOnlyUnavailableReason = "This plan version predates the minimums-only comparison, so there's nothing to compare against. Its stored schedule stays exactly as generated."
            data.scenarioNote = "Scenario previews are available for plans generated in this version of the app."
            if let forecast {
                data.reforecastPayoffDate = forecast.projectedPayoffDate
                data.reforecastInterest = forecast.estimatedRemainingInterest
                data.reforecastRows = []
                data.reforecastUnavailableReason = forecast.summaryExplanation.isEmpty
                    ? "The current estimate is summarized above; this plan version keeps its stored schedule as the paycheck-by-paycheck truth."
                    : forecast.summaryExplanation
            } else {
                data.reforecastUnavailableReason = "No reforecast has been calculated yet. Record a balance or complete a check-in to produce one."
            }
        }

        return data
    }

    // MARK: - Calc v2

    private static func loadCalcV2(
        into data: inout PlanViewData,
        plan: PlanVersion,
        context: ModelContext,
        environment: AppEnvironment,
        debts: [String: DebtAccount]
    ) {
        let service = GeneratedPlanService(context: context, dateProvider: environment.dateProvider)
        let storedInput: StoredPlanInput
        do {
            storedInput = try GeneratedPlanService.storedInput(for: plan)
        } catch {
            data.lowConfidenceNote = "This plan's stored inputs couldn't be read, so assumptions, comparisons, and scenarios are unavailable. The schedule above is still the plan exactly as generated."
            return
        }

        let namesByUUID = Dictionary(storedInput.debts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        guard let baseline = try? service.baselineResult(for: plan) else {
            data.lowConfidenceNote = "The plan's analysis couldn't be recalculated. The stored schedule above is unchanged and remains the truth."
            return
        }

        data.assumptionLines = baseline.assumptions.map(\.message)
        data.warningLines = baseline.warnings.map(\.message)

        if let comparison = baseline.minimumOnlyComparison {
            data.minimumOnlyInterest = comparison.totalInterest
            data.minimumOnlyPayoffDate = comparison.payoffDate
            data.minimumOnlyNeverFinishes = comparison.unfinished
            data.interestSaved = comparison.interestSaved
            data.daysSaved = comparison.daysSaved
            if comparison.unfinished {
                data.minimumOnlyUnavailableReason = "Paying only the minimums never clears these balances inside the projection horizon, so there's no dollar figure to compare — the difference is open-ended."
            } else if comparison.interestSaved == nil {
                data.minimumOnlyUnavailableReason = "One of the two projections doesn't finish inside the horizon, so a savings figure would be a guess. It's withheld."
            }
        } else {
            data.minimumOnlyUnavailableReason = baseline.warnings
                .first { $0.code == .minimumOnlyUnavailable }?.message
                ?? "The minimums-only comparison needs an entered minimum payment on every non-card debt. Add the missing minimums to see it."
        }

        // Reforecast track — a separate estimate, never written to the plan.
        if let reforecast = try? service.reforecastResult(for: plan) {
            data.reforecastPayoffDate = reforecast.forecastPayoffDate
            data.reforecastInterest = reforecast.estimatedRemainingInterest
            data.reforecastRows = reforecast.paychecks.map { check in
                paycheckRow(from: check, namesByUUID: namesByUUID, storedInput: storedInput)
            }
            if reforecast.notPayableAsConfigured {
                data.reforecastUnavailableReason = "As configured, the projection reaches its horizon before every debt is retired."
            }
        } else {
            data.reforecastUnavailableReason = "No reforecast is available for this plan yet."
        }

        // Scenarios — display-only what-ifs (soul: never silently change the plan).
        data.scenarios = scenarios(from: storedInput, baseline: baseline)
        data.scenarioNote = "These are previews only. Nothing here changes your active plan — to adopt one, update the setting and activate a new plan version."
    }

    private static func paycheckRow(
        from check: PaycheckPlan,
        namesByUUID: [UUID: String],
        storedInput: StoredPlanInput
    ) -> PlanPaycheckRow {
        let obligationNames = Dictionary(
            storedInput.obligations.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        return PlanPaycheckRow(
            id: UUID(),
            sequence: check.sequence,
            date: check.date,
            income: check.income + check.windfall,
            keepInSpending: check.keepInSpending,
            transferToReserves: check.transferToReserves,
            allowance: check.allowanceReserved,
            floorTopUp: check.floorTopUp,
            obligationReserves: check.obligationReserves
                .map { (name: obligationNames[$0.obligationID] ?? "Obligation", amount: $0.amount) }
                .sorted { $0.name < $1.name },
            obligationReserveTotal: check.obligationReserveTotal,
            minimumsTotal: check.minimumsTotal,
            extraTotal: check.extraTotal,
            debtBudget: check.debtBudget,
            targetLabel: check.targetDebtID.flatMap { namesByUUID[$0] },
            debtAfter: check.totalDebtAfter,
            endingCash: check.spendingCeilingAfter,
            shortfall: check.shortfall?.gap,
            movements: check.movements,
            isActualRecord: false
        )
    }

    /// Buffer and allowance what-ifs, generated from a copy of the plan's own
    /// inputs. Each is one changed guardrail against the same everything-else.
    private static func scenarios(from storedInput: StoredPlanInput, baseline: PlanningResult) -> [PlanScenario] {
        let hundred = Decimal(100)
        var candidates: [(String, String, Decimal?, Decimal?)] = []

        // Two scenarios, one per guardrail: each is a full engine run, so the
        // set is deliberately small enough to stay responsive on device.
        candidates.append((
            "Allowance \(MoneyFormat.whole(storedInput.allowanceCap + hundred)) per paycheck",
            "\(MoneyFormat.whole(hundred)) more available for you each payday.",
            nil,
            storedInput.allowanceCap + hundred
        ))
        let floorStep = Decimal(500)
        candidates.append((
            "Protected floor \(MoneyFormat.whole(storedInput.protectedFloor + floorStep))",
            "A deeper cash cushion before extra principal goes out.",
            storedInput.protectedFloor + floorStep,
            nil
        ))

        return candidates.compactMap { title, detail, floor, allowance in
            guard let result = try? GeneratedPlanService.whatIfResult(
                storedInput: storedInput,
                protectedFloor: floor,
                allowanceCap: allowance
            ) else { return nil }
            var dayDelta: Int?
            if let scenarioDate = result.forecastPayoffDate, let baseDate = baseline.forecastPayoffDate {
                dayDelta = DateMath.days(from: baseDate, to: scenarioDate)
            }
            return PlanScenario(
                title: title,
                detail: detail,
                payoffDate: result.forecastPayoffDate,
                totalInterest: result.estimatedTotalInterest,
                dayDelta: dayDelta,
                interestDelta: (result.estimatedTotalInterest - baseline.estimatedTotalInterest).rounded2
            )
        }
    }

    // MARK: - Actual track

    /// Rows built only from what the user recorded. A payday with no
    /// completed check-in produces no row — never a planned value in
    /// actual's clothing.
    private static func actualRows(
        items: [PaydayPlanItem],
        context: ModelContext,
        debts: [String: DebtAccount]
    ) -> [PlanPaycheckRow] {
        let checkIns = (try? context.fetch(FetchDescriptor<PaydayCheckIn>())) ?? []
        let byItem = Dictionary(grouping: checkIns, by: \.paydayPlanItemID)
        let entries = (try? context.fetch(FetchDescriptor<LedgerEntry>())) ?? []
        let paymentsByCheckIn = Dictionary(
            grouping: entries.filter { $0.type == .cardPayment && $0.paydayCheckInID != nil },
            by: { $0.paydayCheckInID! }
        )

        return items.compactMap { item in
            guard let checkIn = byItem[item.id]?.first,
                  checkIn.status == .completed || checkIn.status == .needsAttention else { return nil }

            let payments = paymentsByCheckIn[checkIn.id] ?? []
            let paidTotal = payments.reduce(Decimal.zero) { $0 + $1.amount }.rounded2
            let largest = payments.max { $0.amount < $1.amount }
            let reserves: [(name: String, amount: Decimal)] = [
                ("Car", checkIn.actualCarReserve ?? 0),
                ("Train pass", checkIn.actualTrainReserve ?? 0)
            ].filter { $0.amount != 0 }

            return PlanPaycheckRow(
                id: checkIn.id,
                sequence: item.sequenceNumber,
                date: item.date,
                income: checkIn.actualIncome ?? 0,
                keepInSpending: checkIn.actualC1Kept ?? 0,
                transferToReserves: checkIn.actualC2Transfer ?? 0,
                allowance: checkIn.actualAllowanceSpent ?? 0,
                floorTopUp: .zero,
                obligationReserves: reserves,
                obligationReserveTotal: reserves.reduce(Decimal.zero) { $0 + $1.amount },
                minimumsTotal: nil,
                extraTotal: nil,
                debtBudget: paidTotal,
                targetLabel: largest?.debtPlanID.flatMap { targetLabel($0, debts: debts) },
                debtAfter: .zero,
                endingCash: checkIn.actualC1Balance ?? 0,
                shortfall: checkIn.status == .needsAttention ? (checkIn.unallocatedAmount ?? 0) : nil,
                movements: checkIn.reconciliationException.map { [$0] } ?? [],
                isActualRecord: true
            )
        }
    }

    private static func targetLabel(_ planID: String, debts: [String: DebtAccount]) -> String? {
        guard !planID.isEmpty else { return nil }
        guard let debt = debts[planID] else { return planID }
        return debt.displayName
    }
}
