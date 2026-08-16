import Foundation
import SwiftData

/// Presentation-layer bridge between the persistence contract (Agent 2's
/// `StoredPlanInput`/`StoredPlanResult`, `PlanningInputBuilder`,
/// `PlanPersister`) and the calc-v2 engine contract (Agent 3's
/// `PlanningInput`/`PlanningResult`, `AvalanchePlanEngine`).
///
/// Three-truths rule (R-15): the engine result regenerated from a plan's
/// stored input snapshot is the *baseline* truth; `reforecastResult` overlays
/// authoritative snapshots and returns a `.reforecast`-kind result that is
/// never persisted over the plan; actuals come only from user entries.
struct GeneratedPlanService {
    let context: ModelContext
    let dateProvider: DateProviding

    init(context: ModelContext, dateProvider: DateProviding) {
        self.context = context
        self.dateProvider = dateProvider
    }

    enum ServiceError: LocalizedError, Equatable {
        case planHasNoSnapshot
        case snapshotCorrupted

        var errorDescription: String? {
            switch self {
            case .planHasNoSnapshot:
                return "This plan predates generated planning and has no stored inputs."
            case .snapshotCorrupted:
                return "This plan's stored inputs could not be read."
            }
        }
    }

    // MARK: - Stored snapshot → engine input

    /// Store snapshot → engine input.
    ///
    /// Delegates to `PlanGenerationService.engineInput`, which is the single
    /// conversion used when a plan is generated and persisted. This service
    /// previously kept its own copy, written before the snapshot carried a
    /// tri-state `prepayment` or an `asOf` stamp, so it silently disagreed
    /// with the persisted plan in four ways: it flattened `.unknown`
    /// prepayment to eligible, ignored `stored.asOf`, defaulted missing
    /// semimonthly pay days instead of failing, and did not normalise
    /// reversed semimonthly days. Each of those made the plan the user *sees*
    /// differ from the plan that was *saved*.
    static func engineInput(from stored: StoredPlanInput, asOf: Date? = nil) throws -> PlanningInput {
        try PlanGenerationService.engineInput(from: stored, asOf: asOf)
    }

    // MARK: - Engine result → stored rows format

    /// Maps the engine result onto the row-shaped DTO `PlanPersister`
    /// consumes. `income` carries deposits plus explicitly assigned windfalls
    /// so the stored row keeps the engine's reconciliation identity
    /// (`income == keepInSpending + transferToReserves`).
    static func storedResult(from result: PlanningResult, input stored: StoredPlanInput) -> StoredPlanResult {
        let displayIDs = Dictionary(uniqueKeysWithValues: stored.debts.map { ($0.id, $0.displayID) })
        let idsByUUID: (UUID) -> String = { displayIDs[$0] ?? $0.uuidString }

        let paydays = result.paychecks.map { check in
            PlanningPayday(
                sequence: check.sequence,
                date: check.date,
                income: check.income + check.windfall,
                keepInSpending: check.keepInSpending,
                transferToReserves: check.transferToReserves,
                allowance: check.allowanceReserved,
                floorTopUp: check.floorTopUp,
                obligationReserves: check.obligationReserves.map {
                    PlanningObligationReserve(obligationID: $0.obligationID, amount: $0.amount)
                },
                debtBudget: check.debtBudget,
                targetDebtID: check.targetDebtID.map(idsByUUID),
                perDebtBalancesAfter: Dictionary(
                    uniqueKeysWithValues: check.endingBalances.map { (idsByUUID($0.debtID), $0.balance) }
                ),
                totalDebtAfter: check.totalDebtAfter,
                noSpendCeiling: check.spendingCeilingAfter,
                shortfallAmount: check.shortfall?.gap
            )
        }

        let payoffs: [PlanningDebtPayoff] = result.debtSummaries.compactMap { summary in
            summary.payoffDate.map {
                PlanningDebtPayoff(debtID: idsByUUID(summary.debtID), payoffDate: $0)
            }
        }

        return StoredPlanResult(
            calculationVersion: result.calculationVersion.rawValue,
            paydays: paydays,
            payoffDate: result.forecastPayoffDate,
            totalEstimatedInterest: result.estimatedTotalInterest,
            paycheckCount: result.paycheckCount,
            debtPayoffs: payoffs,
            cappedAtPaycheckLimit: result.notPayableAsConfigured
        )
    }

    // MARK: - Preview / regeneration

    /// A generated plan preview: the engine result plus the stored-input
    /// snapshot it came from. Display-only until `activate` is called.
    struct PlanPreview {
        let storedInput: StoredPlanInput
        let result: PlanningResult
    }

    /// Generates a preview from the *current* live rows (accounts, income,
    /// obligations, debts, profile). Nothing is persisted.
    func previewFromCurrentInputs() throws -> PlanPreview {
        let stored = try PlanningInputBuilder(context: context).build()
        let result = try AvalanchePlanEngine.generatePlan(
            try Self.engineInput(from: stored, asOf: DateMath.startOfDay(dateProvider.now))
        )
        return PlanPreview(storedInput: stored, result: result)
    }

    /// Re-runs the engine on an *adjusted copy* of a stored input for
    /// what-if display ("with a $2,000 floor you'd finish …"). The active
    /// plan is never touched — callers must label output as a preview.
    static func whatIfResult(
        storedInput: StoredPlanInput,
        protectedFloor: Decimal? = nil,
        allowanceCap: Decimal? = nil
    ) throws -> PlanningResult {
        var adjusted = storedInput
        if let protectedFloor { adjusted.protectedFloor = protectedFloor }
        if let allowanceCap { adjusted.allowanceCap = allowanceCap }
        return try AvalanchePlanEngine.generatePlan(try engineInput(from: adjusted))
    }

    /// Decodes a plan's stored input snapshot.
    static func storedInput(for plan: PlanVersion) throws -> StoredPlanInput {
        guard let data = plan.inputSnapshotData else { throw ServiceError.planHasNoSnapshot }
        do {
            return try PlanningSnapshotCoder.decode(data)
        } catch {
            throw ServiceError.snapshotCorrupted
        }
    }

    /// Regenerates the baseline engine result for a modern-engine plan from
    /// its stored snapshot. Deterministic: identical input → identical result,
    /// so this is a faithful read of the immutable baseline, not a
    /// recalculation of it. Returns nil for calc-v1 plans (their stored rows
    /// are the truth).
    func baselineResult(for plan: PlanVersion) throws -> PlanningResult? {
        guard plan.calculationVersion >= PlanContract.minimumModernCalculationVersion else { return nil }
        let stored = try Self.storedInput(for: plan)
        return try AvalanchePlanEngine.generatePlan(try Self.engineInput(from: stored))
    }

    // MARK: - Reforecast (calc v2)

    /// Builds the actual-state overlay from authoritative balance snapshots
    /// and runs the engine's reforecast. The result has `kind == .reforecast`
    /// and is never persisted over the plan (R-15).
    func reforecastResult(for plan: PlanVersion) throws -> PlanningResult? {
        guard plan.calculationVersion >= PlanContract.minimumModernCalculationVersion else { return nil }
        let stored = try Self.storedInput(for: plan)
        let today = DateMath.startOfDay(dateProvider.now)

        let debtIDs = Set(stored.debts.map(\.id))
        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
            .filter { snapshot in
                guard snapshot.isAuthoritative, let debtID = snapshot.debtAccountID else { return false }
                return debtIDs.contains(debtID) && DateMath.startOfDay(snapshot.effectiveDate) <= today
            }
            .sorted { ($0.effectiveDate, $0.createdAt) < ($1.effectiveDate, $1.createdAt) }

        let balances = snapshots.compactMap { snapshot -> BalanceAuthority? in
            guard let debtID = snapshot.debtAccountID else { return nil }
            return BalanceAuthority(
                debtID: debtID,
                balance: snapshot.amount,
                effectiveDate: DateMath.startOfDay(snapshot.effectiveDate)
            )
        }

        let actuals = ActualState(asOf: today, balances: balances, spendingBalance: nil)
        return try AvalanchePlanEngine.reforecast(
            try Self.engineInput(from: stored),
            actuals: actuals
        )
    }

    // MARK: - Activation (F-13: new version, never an edit)

    /// The next free user-plan name: "Plan v1", "Plan v2", … (A-04 naming).
    /// `PlanPersister`'s idempotency guard is name-based, so activation must
    /// always choose a name no `PlanVersion` row already has.
    static func nextPlanName(context: ModelContext) throws -> String {
        let names = Set(try context.fetch(FetchDescriptor<PlanVersion>()).map(\.name))
        var number = 1
        while names.contains("Plan v\(number)") { number += 1 }
        return "Plan v\(number)"
    }

    /// Persists a previewed plan as a brand-new `PlanVersion` and makes it
    /// active. Existing versions keep every row untouched (only their
    /// `isActive` flag yields). The first-ever plan of an install is its
    /// immutable baseline; later activations are non-baseline versions.
    @discardableResult
    func activate(_ preview: PlanPreview) throws -> PlanVersion {
        let name = try Self.nextPlanName(context: context)
        let hasAnyPlan = try context.fetchCount(FetchDescriptor<PlanVersion>()) > 0
        let plan = try PlanPersister(context: context).insertPlanGraph(
            named: name,
            input: preview.storedInput,
            result: Self.storedResult(from: preview.result, input: preview.storedInput),
            isOriginalBaseline: !hasAnyPlan,
            now: dateProvider.now
        )
        try context.save()
        return plan
    }
}
