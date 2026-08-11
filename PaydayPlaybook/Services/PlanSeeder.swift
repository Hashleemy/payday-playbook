import Foundation
import SwiftData

/// Idempotently seeds Original Plan v1, debts, the 23-payday schedule,
/// milestones, and notification defaults. All inserts happen in a single
/// save so an interrupted seed never leaves partial rows behind; a partial
/// graph from a crashed earlier attempt is detected and replaced.
struct PlanSeeder {
    struct SeedSummary {
        let planVersion: PlanVersion
        let debtCount: Int
        let paydayCount: Int
        let wasAlreadySeeded: Bool
    }

    /// `applySchemaUpgrade` exists for tests that need a faithful 0.1.x
    /// (schema-1-shaped) store to migrate from; the app always upgrades.
    @discardableResult
    static func seedIfNeeded(
        context: ModelContext,
        bundle: Bundle = .main,
        applySchemaUpgrade: Bool = true
    ) throws -> SeedSummary {
        if let existing = try existingBaseline(context: context),
           try isComplete(existing, context: context) {
            return SeedSummary(
                planVersion: existing,
                debtCount: PlanContract.debtCount,
                paydayCount: PlanContract.paydayCount,
                wasAlreadySeeded: true
            )
        }

        // Load and validate the seed BEFORE deleting any partial graph so a
        // bad resource can never leave pending deletions behind.
        let seed = try SeedPlanLoader.load(bundle: bundle)
        if let existing = try existingBaseline(context: context) {
            // Interrupted earlier seed: remove the partial graph and reseed.
            try removePlanGraph(existing, context: context)
        }
        let plan = try insert(seed: seed, context: context)
        // Bring the freshly seeded v1-shaped graph up to schema 2 (accounts,
        // obligations, reserve rows, stamps) in the same save, so template
        // loads land complete and a 0.1.x-style seed never persists half-old.
        if applySchemaUpgrade {
            try MigrationService.applyLogicalUpgrade(context: context)
        }
        try context.save()
        return SeedSummary(
            planVersion: plan,
            debtCount: PlanContract.debtCount,
            paydayCount: PlanContract.paydayCount,
            wasAlreadySeeded: false
        )
    }

    static func existingBaseline(context: ModelContext) throws -> PlanVersion? {
        // Keyed on the contract name, not the isOriginalBaseline flag:
        // onboarding-generated plans carry that flag too (§4.9 / A-04), and a
        // generated plan must never be mistaken for the seeded template —
        // isComplete would fail on its shape and removePlanGraph would
        // destroy the user's own plan.
        let templateName = PlanContract.planName
        let descriptor = FetchDescriptor<PlanVersion>(
            predicate: #Predicate { $0.name == templateName }
        )
        return try context.fetch(descriptor).first
    }

    /// The plan every reader should display: the active one, falling back to
    /// the template for a migrated install.
    ///
    /// Deliberately distinct from `existingBaseline`, which is template-only
    /// so the seeder can never touch an onboarding-generated plan. Screens
    /// asking "what is the user's plan?" must use this — a generated plan is
    /// named "Plan v1" and would be invisible to a template-keyed lookup.
    static func currentPlan(context: ModelContext) throws -> PlanVersion? {
        let plans = try context.fetch(FetchDescriptor<PlanVersion>())
        return plans.first(where: \.isActive)
            ?? plans.first(where: { $0.name == PlanContract.planName })
            ?? plans.sorted { $0.createdAt < $1.createdAt }.first
    }

    static func isComplete(_ plan: PlanVersion, context: ModelContext) throws -> Bool {
        let planID = plan.id
        let paydayCount = try context.fetchCount(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
        )
        let debtCount = try context.fetchCount(FetchDescriptor<DebtAccount>())
        let incomeRuleCount = try context.fetchCount(
            FetchDescriptor<IncomeRule>(predicate: #Predicate { $0.planVersionID == planID })
        )
        return paydayCount == PlanContract.paydayCount
            && debtCount >= PlanContract.debtCount
            && incomeRuleCount >= 2
    }

    private static func removePlanGraph(_ plan: PlanVersion, context: ModelContext) throws {
        let planID = plan.id
        let paydays = try context.fetch(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
        )
        let paydayIDs = Set(paydays.map(\.id))
        for balance in try context.fetch(FetchDescriptor<PlannedCardBalance>())
        where paydayIDs.contains(balance.paydayPlanItemID) {
            context.delete(balance)
        }
        for reserve in try context.fetch(FetchDescriptor<PlannedObligationReserve>())
        where paydayIDs.contains(reserve.paydayPlanItemID) {
            context.delete(reserve)
        }
        for payday in paydays { context.delete(payday) }
        for rule in try context.fetch(
            FetchDescriptor<IncomeRule>(predicate: #Predicate { $0.planVersionID == planID })
        ) {
            context.delete(rule)
        }
        // Only rows the template itself seeded are removed: its debts (keyed
        // by the plan's own avalanche order) and its milestones. Debts or
        // milestones created outside the template graph survive a repair.
        let seedDebtIDs = Set(plan.avalancheOrder)
        for debt in try context.fetch(FetchDescriptor<DebtAccount>())
        where seedDebtIDs.contains(debt.planID) {
            context.delete(debt)
        }
        for milestone in try context.fetch(FetchDescriptor<Milestone>()) {
            let ownsCard = milestone.relatedDebtPlanID.map { seedDebtIDs.contains($0) } ?? false
            let ownsDebtFree = milestone.type == .debtFree
                && milestone.baselineDate == plan.baselinePayoffDate
            if ownsCard || ownsDebtFree || milestone.type == .amountEliminated {
                context.delete(milestone)
            }
        }
        context.delete(plan)
    }

    private static func insert(seed: SeedPlan, context: ModelContext) throws -> PlanVersion {
        let plan = PlanVersion(
            name: seed.planName,
            isOriginalBaseline: true,
            isActive: true,
            firstPayday: try SeedPlanLoader.date(seed.firstPayday, field: "firstPayday"),
            payFrequencyDays: seed.payFrequencyDays,
            startingChecking1: try SeedPlanLoader.decimal(seed.startingChecking1, field: "startingChecking1"),
            protectedBuffer: try SeedPlanLoader.decimal(seed.protectedBuffer, field: "protectedBuffer"),
            allowanceCap: try SeedPlanLoader.decimal(seed.allowanceCap, field: "allowanceCap"),
            firstCheckBufferAdd: try SeedPlanLoader.decimal(seed.firstCheckBufferAdd, field: "firstCheckBufferAdd"),
            carReservePerCheck: try SeedPlanLoader.decimal(seed.carReservePerCheck, field: "carReservePerCheck"),
            trainReservePerCheck: try SeedPlanLoader.decimal(seed.trainReservePerCheck, field: "trainReservePerCheck"),
            calculationVersion: PlanContract.calculationVersion,
            avalancheOrderRaw: seed.avalancheOrder.joined(separator: ","),
            baselinePayoffDate: try SeedPlanLoader.date(seed.baselinePayoffDate, field: "baselinePayoffDate"),
            baselineModeledInterest: try SeedPlanLoader.decimal(seed.baselineModeledInterest, field: "baselineModeledInterest"),
            baselineNoSpendCeiling: try SeedPlanLoader.decimal(seed.baselineNoSpendCeiling, field: "baselineNoSpendCeiling")
        )
        context.insert(plan)

        for rule in seed.incomeRules {
            context.insert(IncomeRule(
                planVersionID: plan.id,
                effectiveDate: try SeedPlanLoader.date(rule.effectiveDate, field: "income rule date"),
                netPaycheckAmount: try SeedPlanLoader.decimal(rule.amount, field: "income rule amount")
            ))
        }

        for debt in seed.debts {
            context.insert(DebtAccount(
                planID: debt.planID,
                displayName: "Card \(debt.planID)",
                startingBalance: try SeedPlanLoader.decimal(debt.startingBalance, field: "debt balance"),
                apr: try SeedPlanLoader.decimal(debt.apr, field: "debt apr"),
                priority: debt.priority
            ))
        }

        for payday in seed.paydays {
            let item = PaydayPlanItem(
                planVersionID: plan.id,
                sequenceNumber: payday.seq,
                date: try SeedPlanLoader.date(payday.date, field: "payday date"),
                plannedIncome: try SeedPlanLoader.decimal(payday.income, field: "payday income"),
                plannedC1Keep: try SeedPlanLoader.decimal(payday.c1Keep, field: "payday c1Keep"),
                plannedBufferAdd: try SeedPlanLoader.decimal(payday.bufferAdd, field: "payday bufferAdd"),
                plannedAllowance: try SeedPlanLoader.decimal(payday.allowance, field: "payday allowance"),
                plannedC2Transfer: try SeedPlanLoader.decimal(payday.c2Transfer, field: "payday c2Transfer"),
                plannedCarReserve: try SeedPlanLoader.decimal(payday.carReserve, field: "payday carReserve"),
                plannedTrainReserve: try SeedPlanLoader.decimal(payday.trainReserve, field: "payday trainReserve"),
                plannedCardBudget: try SeedPlanLoader.decimal(payday.cardBudget, field: "payday cardBudget"),
                plannedTargetDebtID: payday.target,
                plannedDebtAfter: try SeedPlanLoader.decimal(payday.debtAfter, field: "payday debtAfter"),
                plannedC1NoSpendCeiling: try SeedPlanLoader.decimal(payday.noSpendCeiling, field: "payday ceiling")
            )
            context.insert(item)
            for (cardID, balance) in payday.perCard {
                context.insert(PlannedCardBalance(
                    paydayPlanItemID: item.id,
                    debtPlanID: cardID,
                    balanceAfter: try SeedPlanLoader.decimal(balance, field: "per-card balance")
                ))
            }
        }

        for debt in seed.debts {
            context.insert(Milestone(
                type: .cardPaidOff,
                title: "Card \(debt.planID) paid off",
                relatedDebtPlanID: debt.planID,
                baselineDate: try SeedPlanLoader.date(debt.baselinePayoff, field: "debt payoff")
            ))
        }
        for milestone in seed.amountMilestones {
            let threshold = try SeedPlanLoader.decimal(milestone.threshold, field: "milestone threshold")
            context.insert(Milestone(
                type: .amountEliminated,
                title: "\(MoneyFormat.whole(threshold)) eliminated",
                thresholdAmount: threshold,
                baselineDate: try SeedPlanLoader.date(milestone.date, field: "milestone date")
            ))
        }
        context.insert(Milestone(
            type: .debtFree,
            title: "Debt-free",
            baselineDate: try SeedPlanLoader.date(seed.baselinePayoffDate, field: "payoff date")
        ))

        if try context.fetchCount(FetchDescriptor<NotificationPreference>()) == 0 {
            for preference in NotificationPreference.seedDefaults() {
                context.insert(preference)
            }
        }

        if try context.fetchCount(FetchDescriptor<AppSettings>()) == 0 {
            let settings = AppSettings(seedSchemaVersion: seed.schemaVersion)
            context.insert(settings)
        }

        return plan
    }
}
