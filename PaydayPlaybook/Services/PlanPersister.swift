import Foundation
import SwiftData

/// Maps between the storage-independent planning DTOs and the SwiftData
/// store: builds `PlanInputSnapshot` from current rows, and persists a
/// `PlanResultSnapshot` as an immutable `PlanVersion` graph.
///
/// The calculation engine (Agent 3) sees only the DTOs — never a context.

// MARK: - Store → PlanInputSnapshot

struct PlanningInputBuilder {
    let context: ModelContext

    enum BuilderError: LocalizedError, Equatable {
        case noIncomeSchedule
        case noAccounts
        case noProfile

        var errorDescription: String? {
            switch self {
            case .noIncomeSchedule: return "Income setup is missing."
            case .noAccounts: return "No checking account has been set up."
            case .noProfile: return "Goals and guardrails haven't been set up."
            }
        }
    }

    init(context: ModelContext) {
        self.context = context
    }

    /// Assembles the generator input from the live onboarding/settings rows.
    /// Every value is the user's own; nothing is defaulted silently.
    func build(calculationVersion: Int = PlanContract.currentCalculationVersion) throws -> PlanInputSnapshot {
        guard let schedule = try context.fetch(
            FetchDescriptor<IncomeSchedule>(predicate: #Predicate { !$0.isArchived })
        ).first else {
            throw BuilderError.noIncomeSchedule
        }
        let accounts = CashAccountRepository(context: context)
        guard let spending = try accounts.spendingAccount() else {
            throw BuilderError.noAccounts
        }
        guard let profile = try context.fetch(FetchDescriptor<UserGoalProfile>()).first else {
            throw BuilderError.noProfile
        }

        let scheduleID = schedule.id
        let changes = try context.fetch(
            FetchDescriptor<IncomeChange>(predicate: #Predicate { $0.scheduleID == scheduleID })
        ).sorted { $0.effectiveDate < $1.effectiveDate }

        let obligations = try context.fetch(
            FetchDescriptor<RecurringObligation>(predicate: #Predicate { !$0.isArchived })
        ).sorted { ($0.createdAt, $0.name) < ($1.createdAt, $1.name) }

        let debts = try context.fetch(
            FetchDescriptor<DebtAccount>(predicate: #Predicate { !$0.isArchived })
        ).sorted { ($0.priority, $0.createdAt) < ($1.priority, $1.createdAt) }

        return PlanInputSnapshot(
            calculationVersion: calculationVersion,
            cadence: schedule.cadence,
            monthlyPayDay: schedule.monthlyDay,
            semimonthlyPayDay1: schedule.semimonthlyFirstDay,
            semimonthlyPayDay2: schedule.semimonthlySecondDay,
            nextPayday: schedule.anchorPayday,
            baseTakeHome: schedule.baseTakeHome,
            incomeChanges: changes.map {
                PlanningIncomeChange(effectiveDate: $0.effectiveDate, amount: $0.newTakeHome)
            },
            spendingStartingBalance: spending.currentBalance,
            protectedFloor: profile.protectedFloor,
            allowanceCap: profile.allowanceCap,
            firstCheckBufferAdd: .zero,
            obligations: obligations.map {
                PlanningObligation(
                    id: $0.id, name: $0.name, amount: $0.amount,
                    cadence: $0.cadence, dueDay: $0.dueDay
                )
            },
            debts: debts.map {
                PlanningDebt(
                    id: $0.id, displayID: $0.planID, name: $0.displayName,
                    debtType: $0.debtType, currentBalance: $0.startingBalance,
                    apr: $0.apr, minimumAmount: $0.minimumAmount,
                    isExtraPrincipalEligible: $0.isExtraPrincipalEligible,
                    creditLimit: $0.creditLimit, dueDayOfMonth: $0.dueDayOfMonth,
                    originalPrincipal: $0.originalPrincipal
                )
            },
            paycheckCap: PlanInputSnapshot.defaultPaycheckCap,
            timeZoneID: TimeZone.current.identifier
        )
    }
}

// MARK: - PlanResultSnapshot → store

struct PlanPersister {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Inserts the full plan graph WITHOUT saving — callers own the
    /// transaction so plan + settings + progress commit together (§4.0).
    ///
    /// Idempotent: if a plan version with this name already exists, it is
    /// returned untouched and nothing is inserted — finishing onboarding
    /// twice cannot create duplicate plans, items, or milestones.
    @discardableResult
    func insertPlanGraph(
        named name: String,
        input: PlanInputSnapshot,
        result: PlanResultSnapshot,
        isOriginalBaseline: Bool,
        now: Date = Date()
    ) throws -> PlanVersion {
        let existing = try context.fetch(
            FetchDescriptor<PlanVersion>(predicate: #Predicate { $0.name == name })
        )
        if let plan = existing.first {
            return plan
        }

        let avalancheOrder = orderedDisplayIDs(input: input, result: result)
        let lastPayday = result.paydays.last

        let plan = PlanVersion(
            name: name,
            createdAt: now,
            isOriginalBaseline: isOriginalBaseline,
            isActive: true,
            firstPayday: result.paydays.first?.date ?? input.nextPayday,
            payFrequencyDays: input.cadence.fixedDayInterval ?? 0,
            startingChecking1: input.spendingStartingBalance,
            protectedBuffer: input.protectedFloor,
            allowanceCap: input.allowanceCap,
            firstCheckBufferAdd: input.firstCheckBufferAdd,
            carReservePerCheck: .zero,
            trainReservePerCheck: .zero,
            calculationVersion: result.calculationVersion,
            timeZoneID: input.timeZoneID,
            avalancheOrderRaw: avalancheOrder.joined(separator: ","),
            baselinePayoffDate: result.payoffDate ?? lastPayday?.date ?? input.nextPayday,
            baselineModeledInterest: result.totalEstimatedInterest,
            baselineNoSpendCeiling: lastPayday?.noSpendCeiling ?? input.spendingStartingBalance
        )
        plan.payCadence = input.cadence
        plan.monthlyPayDay = input.monthlyPayDay
        plan.semimonthlyPayDay1 = input.semimonthlyPayDay1
        plan.semimonthlyPayDay2 = input.semimonthlyPayDay2
        plan.incomeAccountID = try CashAccountRepository(context: context).defaultIncomeAccount()?.id
        plan.generatedFromProfile = true
        plan.inputSnapshotData = try PlanningSnapshotCoder.encode(input)
        context.insert(plan)

        // Any previously active plan yields to the new one; its rows are
        // never edited beyond the active flag (baselines stay immutable).
        for other in try context.fetch(FetchDescriptor<PlanVersion>())
        where other.id != plan.id && other.isActive {
            other.isActive = false
        }

        // Income timeline frozen into the plan.
        context.insert(IncomeRule(
            planVersionID: plan.id,
            effectiveDate: result.paydays.first?.date ?? input.nextPayday,
            netPaycheckAmount: input.baseTakeHome
        ))
        for change in input.incomeChanges {
            context.insert(IncomeRule(
                planVersionID: plan.id,
                effectiveDate: change.effectiveDate,
                netPaycheckAmount: change.amount
            ))
        }

        // Paydays, per-debt balances, and obligation reserves.
        for payday in result.paydays {
            let item = PaydayPlanItem(
                planVersionID: plan.id,
                sequenceNumber: payday.sequence,
                date: payday.date,
                plannedIncome: payday.income,
                plannedC1Keep: payday.keepInSpending,
                plannedBufferAdd: payday.floorTopUp,
                plannedAllowance: payday.allowance,
                plannedC2Transfer: payday.transferToReserves,
                plannedCarReserve: .zero,
                plannedTrainReserve: .zero,
                plannedCardBudget: payday.debtBudget,
                plannedTargetDebtID: payday.targetDebtID ?? "",
                plannedDebtAfter: payday.totalDebtAfter,
                plannedC1NoSpendCeiling: payday.noSpendCeiling
            )
            item.shortfallAmount = payday.shortfallAmount
            context.insert(item)
            for (debtID, balance) in payday.perDebtBalancesAfter {
                context.insert(PlannedCardBalance(
                    paydayPlanItemID: item.id, debtPlanID: debtID, balanceAfter: balance
                ))
            }
            for reserve in payday.obligationReserves {
                context.insert(PlannedObligationReserve(
                    paydayPlanItemID: item.id,
                    obligationID: reserve.obligationID,
                    amount: reserve.amount
                ))
            }
        }

        // Baseline milestones.
        let debtNames = Dictionary(uniqueKeysWithValues: input.debts.map { ($0.displayID, $0.name) })
        for payoff in result.debtPayoffs {
            context.insert(Milestone(
                type: .cardPaidOff,
                title: "\(debtNames[payoff.debtID] ?? payoff.debtID) paid off",
                relatedDebtPlanID: payoff.debtID,
                baselineDate: payoff.payoffDate
            ))
        }
        if let payoffDate = result.payoffDate {
            context.insert(Milestone(type: .debtFree, title: "Debt-free", baselineDate: payoffDate))
        }

        return plan
    }

    /// R-08 presentation order: APR descending, ties by lower balance, then
    /// input (creation) order; 0% APR last. The engine applies the same rule —
    /// this keeps `avalancheOrderRaw` consistent for display.
    private func orderedDisplayIDs(input: PlanInputSnapshot, result: PlanResultSnapshot) -> [String] {
        let indexed = input.debts.enumerated()
        return indexed.sorted { lhs, rhs in
            let (li, ld) = lhs, (ri, rd) = rhs
            if ld.apr != rd.apr {
                if ld.apr == 0 { return false }
                if rd.apr == 0 { return true }
                return ld.apr > rd.apr
            }
            if ld.currentBalance != rd.currentBalance { return ld.currentBalance < rd.currentBalance }
            return li < ri
        }.map(\.element.displayID)
    }
}
