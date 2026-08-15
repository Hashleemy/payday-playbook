import Foundation
import SwiftData

/// Plan-row lookups shared by every screen and service that needs to answer
/// "which plan are we talking about?".
///
/// These lived on `PlanSeeder` until the bundled template was withdrawn
/// (V3-12). They were never seeding logic — the seeder merely happened to own
/// the only fetch that knew how a plan is identified — so they moved here
/// rather than keeping a type named for a job the app no longer does.
enum PlanRepository {

    /// The plan a reader should display: the active one, falling back to a
    /// migrated 0.1.x baseline, then to the oldest row.
    ///
    /// Deliberately distinct from `legacyBaseline`, which matches on the
    /// historical name only. Anything asking "what is the user's plan?" must
    /// use this: a plan generated in onboarding is named `generatedPlanName`
    /// and is invisible to a name-keyed lookup.
    static func currentPlan(context: ModelContext) throws -> PlanVersion? {
        let plans = try context.fetch(FetchDescriptor<PlanVersion>())
        return plans.first(where: \.isActive)
            ?? plans.first(where: { $0.name == PlanContract.planName })
            ?? plans.sorted { $0.createdAt < $1.createdAt }.first
    }

    /// The calc-v1 baseline row carried over from a 0.1.x install, matched by
    /// its historical name.
    ///
    /// Returns nil on every install that onboarded on 0.2.0 or later, which is
    /// the correct answer: those installs have no legacy baseline. Callers
    /// that want "the user's plan" want `currentPlan` instead.
    static func legacyBaseline(context: ModelContext) throws -> PlanVersion? {
        let legacyName = PlanContract.planName
        let descriptor = FetchDescriptor<PlanVersion>(
            predicate: #Predicate { $0.name == legacyName }
        )
        return try context.fetch(descriptor).first
    }

    /// Payday items for a plan, in sequence order.
    static func planItems(context: ModelContext, plan: PlanVersion) throws -> [PaydayPlanItem] {
        let planID = plan.id
        return try context.fetch(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
        ).sorted { $0.sequenceNumber < $1.sequenceNumber }
    }

    // MARK: - Structural integrity

    /// Whether a plan graph is internally consistent enough to migrate.
    ///
    /// The schema-1 check this replaces compared payday and debt counts
    /// against fixed numbers — the founding user's 23 paydays and 6 cards —
    /// which meant a *different* complete plan failed the check and that
    /// user's own half-written plan passed it. These conditions describe the
    /// shape of a finished plan instead of the size of one particular plan,
    /// so they hold for any user and still catch the crashed-partial-seed
    /// signature they were written for: gaps in the payday sequence, debts
    /// named in the avalanche order that no longer exist, and payday rows
    /// missing their per-card balances.
    static func isStructurallyComplete(_ plan: PlanVersion, context: ModelContext) throws -> Bool {
        let items = try planItems(context: context, plan: plan)
        guard !items.isEmpty else { return false }

        // Contiguous sequence numbers 1...n, no gaps and no duplicates.
        let sequences = items.map(\.sequenceNumber)
        guard sequences == Array(1...items.count) else { return false }

        // Every debt the plan attacks still exists.
        let order = plan.avalancheOrder
        guard !order.isEmpty else { return false }
        let existingPlanIDs = Set(try context.fetch(FetchDescriptor<DebtAccount>()).map(\.planID))
        guard Set(order).isSubset(of: existingPlanIDs) else { return false }

        // Each payday carries a projected balance for every attacked debt.
        let itemIDs = Set(items.map(\.id))
        var balancesByItem: [UUID: Set<String>] = [:]
        for balance in try context.fetch(FetchDescriptor<PlannedCardBalance>())
        where itemIDs.contains(balance.paydayPlanItemID) {
            balancesByItem[balance.paydayPlanItemID, default: []].insert(balance.debtPlanID)
        }
        for item in items {
            guard Set(order).isSubset(of: balancesByItem[item.id] ?? []) else { return false }
        }

        // At least one income rule, and the plan actually reaches debt-free.
        let planID = plan.id
        let incomeRules = try context.fetchCount(
            FetchDescriptor<IncomeRule>(predicate: #Predicate { $0.planVersionID == planID })
        )
        guard incomeRules >= 1 else { return false }
        guard let last = items.last, last.plannedDebtAfter.rounded2 <= 0 else { return false }

        return true
    }
}
