import Foundation
import SwiftData

/// Turns the user's saved onboarding rows into a generated plan (V2-10) by
/// bridging the two v0.2.0 planning contracts:
///
///     store rows ──PlanningInputBuilder──▶ StoredPlanInput   (persistence)
///     StoredPlanInput ──engineInput──▶ PlanningInput          (engine call)
///     PlanningInput ──AvalanchePlanEngine──▶ PlanningResult     (rich result)
///     PlanningResult ──resultSnapshot──▶ StoredPlanResult     (row shape)
///     snapshot + rows ──OnboardingProgressService.finish──▶ PlanVersion
///
/// The mapping functions are pure so tests can pin them without a store; the
/// engine itself never sees a `ModelContext`. The full `PlanningResult`
/// (events, warnings, movements) is returned to the UI for the review and
/// reminders screens, and can always be reproduced from the stored snapshot
/// via `regenerate(from:)` — it is deliberately not persisted as a blob.
enum PlanGenerationService {

    /// User-facing generation failures. Every case names the onboarding step
    /// that fixes it — "actionable missing-input failure", never a dead end.
    enum GenerationError: LocalizedError, Equatable {
        case missingIncome
        case missingAccounts
        case missingProfile
        case missingPayDay(cadence: String)
        case samePayDays
        case engineRejected(String)

        var errorDescription: String? {
            switch self {
            case .missingIncome:
                return "Income setup is missing. Add your paycheck in the Income step."
            case .missingAccounts:
                return "No checking account has been set up. Add one in the Accounts step."
            case .missingProfile:
                return "Your goal and guardrails haven't been saved yet. Revisit the Goal step."
            case .missingPayDay(let cadence):
                return "The \(cadence) pay schedule needs its day of the month. Revisit the Income step."
            case .samePayDays:
                return "Twice-a-month paydays need two different days. Revisit the Income step."
            case .engineRejected(let message):
                return message
            }
        }
    }

    /// Everything a caller needs after generation: the deterministic input
    /// snapshot (persisted), the engine's full result (shown), and the row
    /// snapshot (persisted).
    struct GeneratedPlan {
        var input: StoredPlanInput
        var result: PlanningResult
        var rows: StoredPlanResult
    }

    // MARK: - Orchestration

    /// Builds the input from the live store rows, runs the calc-v2 engine,
    /// and maps the result into the persister's row shape. Pure math; nothing
    /// is written — pass the pieces to `OnboardingProgressService.finish`.
    static func generate(
        context: ModelContext,
        asOf: Date
    ) throws -> GeneratedPlan {
        let snapshot: StoredPlanInput
        do {
            snapshot = try PlanningInputBuilder(context: context)
                .build(asOf: DateMath.startOfDay(asOf))
        } catch let error as PlanningInputBuilder.BuilderError {
            switch error {
            case .noIncomeSchedule: throw GenerationError.missingIncome
            case .noAccounts: throw GenerationError.missingAccounts
            case .noProfile: throw GenerationError.missingProfile
            }
        }
        return try generate(from: snapshot)
    }

    /// Runs the engine for an already-built snapshot (also the regeneration
    /// path for insights and calendar owners reading a stored plan).
    static func generate(from snapshot: StoredPlanInput) throws -> GeneratedPlan {
        let engineInput = try engineInput(from: snapshot)
        let result: PlanningResult
        do {
            result = try AvalanchePlanEngine.generatePlan(engineInput)
        } catch let error as AvalanchePlanEngine.PlanningValidationError {
            throw GenerationError.engineRejected(String(describing: error))
        }
        return GeneratedPlan(
            input: snapshot,
            result: result,
            rows: resultSnapshot(from: result, input: snapshot)
        )
    }

    /// Reproduces the engine result for a stored plan version. Returns nil
    /// for plans without a snapshot (Original Plan v1 — its stored schedule
    /// is the truth and must never be regenerated).
    static func regenerate(from plan: PlanVersion) throws -> GeneratedPlan? {
        guard let data = plan.inputSnapshotData else { return nil }
        let snapshot = try PlanningSnapshotCoder.decode(data)
        return try generate(from: snapshot)
    }

    // MARK: - Snapshot → engine input

    /// Maps the persistence snapshot onto the engine's call contract.
    /// The single store→engine conversion. `GeneratedPlanService` delegates
    /// here so the plan the UI renders is built from exactly the same input as
    /// the plan that was persisted. `asOf` overrides the snapshot's own stamp
    /// (used for live previews generated "as of today").
    static func engineInput(from snapshot: StoredPlanInput, asOf: Date? = nil) throws -> PlanningInput {
        let cadence = try planningCadence(from: snapshot)

        var amounts = [PlanningIncomeChange(
            effectiveDate: snapshot.nextPayday,
            amount: snapshot.baseTakeHome
        )]
        amounts.append(contentsOf: snapshot.incomeChanges.map {
            PlanningIncomeChange(effectiveDate: $0.effectiveDate, amount: $0.amount)
        })

        // Calc v3 is stamped when the snapshot asks for it *or* carries
        // scenario/extra-payment data, so a caller can never get v3 inputs
        // silently modeled as a v2 result. Calc v4 is stamped only when the
        // snapshot's version column says so — a v3-or-older snapshot whose
        // scenario somehow carries promotions keeps its v3 inference and the
        // engine rejects it (`promotionsRequireCalcV4`), never a silent
        // upgrade and never a silent ignore.
        let version: PlanCalculationVersion
        if snapshot.calculationVersion == 1 {
            version = .v1LegacyBaseline
        } else if snapshot.calculationVersion >= PlanCalculationVersion.v4BalancedQuickWin.rawValue {
            version = .v4BalancedQuickWin
        } else if snapshot.calculationVersion >= 3
                    || snapshot.scenario != nil || !snapshot.extraPayments.isEmpty {
            version = .v3Scenario
        } else {
            version = .v2Avalanche
        }

        return PlanningInput(
            calculationVersion: version,
            asOf: asOf ?? snapshot.asOf ?? DateMath.startOfDay(snapshot.nextPayday),
            income: IncomeInput(
                cadence: cadence,
                firstPayday: snapshot.nextPayday,
                amounts: amounts,
                windfalls: []
            ),
            spending: SpendingInput(
                // The one-time first-check buffer is a legacy-plan artifact;
                // generated plans always carry 0 (the floor top-up emerges
                // from balance vs. floor on its own).
                startingBalance: snapshot.spendingStartingBalance + snapshot.firstCheckBufferAdd,
                protectedFloor: snapshot.protectedFloor,
                allowancePerPaycheck: snapshot.allowanceCap
            ),
            obligations: snapshot.obligations.map {
                ObligationInput(
                    id: $0.id, name: $0.name, amount: $0.amount,
                    cadence: $0.cadence, dueDay: $0.dueDay
                )
            },
            debts: snapshot.debts.enumerated().map { index, debt in
                DebtInput(
                    id: debt.id,
                    name: debt.name,
                    debtType: debt.debtType,
                    balance: debt.currentBalance,
                    apr: debt.apr,
                    promo: nil,
                    minimumPayment: debt.minimumAmount,
                    dueDay: debt.dueDayOfMonth,
                    creditLimit: debt.creditLimit,
                    prepayment: debt.effectivePrepayment,
                    createdOrder: index
                )
            },
            scenario: try snapshot.scenario.map(scenarioInput(from:)),
            extraPayments: snapshot.extraPayments.map { extra in
                ExtraPaymentInput(
                    id: extra.id,
                    kind: extra.kind,
                    amount: extra.amount,
                    effectiveDate: extra.effectiveDate,
                    targetDebtID: extra.targetDebtID,
                    sourceAccountID: extra.sourceAccountID
                )
            }
        )
    }

    /// Stored scenario definition → engine mirror (R-17/R-18). The engine
    /// resolves which constraint applies to which kind; this only translates.
    static func scenarioInput(from definition: StoredScenarioDefinition) throws -> ScenarioInput {
        ScenarioInput(
            kind: definition.kind,
            incomeOverride: try definition.incomeOverride.map { override in
                IncomeOverrideInput(
                    amount: override.amount,
                    cadence: try planningCadence(
                        cadence: override.cadence,
                        monthlyPayDay: override.monthlyPayDay,
                        semimonthlyPayDay1: override.semimonthlyPayDay1,
                        semimonthlyPayDay2: override.semimonthlyPayDay2
                    ),
                    effectiveDate: override.effectiveDate
                )
            },
            minimumProtectedCash: definition.minimumProtectedCash,
            preferredFloor: definition.preferredFloor,
            preferredAllowance: definition.preferredAllowance,
            plannedSavingsPerPaycheck: definition.plannedSavingsPerPaycheck,
            additionalReserve: definition.additionalReserve,
            extraPaymentCeiling: definition.extraPaymentCeiling,
            zeroAllowanceConfirmedAt: definition.zeroAllowanceConfirmedAt,
            effectiveDate: definition.effectiveDate,
            quickWinPromotions: definition.quickWinPromotions
        )
    }

    /// Model cadence + day-of-month columns → the engine's associated-value
    /// cadence. Semimonthly days are normalized to ascending order (paydays
    /// on the 15th and the 1st are the same paydays as the 1st and 15th).
    static func planningCadence(from snapshot: StoredPlanInput) throws -> PlanningPayCadence {
        try planningCadence(
            cadence: snapshot.cadence,
            monthlyPayDay: snapshot.monthlyPayDay,
            semimonthlyPayDay1: snapshot.semimonthlyPayDay1,
            semimonthlyPayDay2: snapshot.semimonthlyPayDay2
        )
    }

    /// The one cadence conversion, shared by the base snapshot and the R-18
    /// income override — a second copy would be free to disagree.
    static func planningCadence(
        cadence: PayCadence,
        monthlyPayDay: Int?,
        semimonthlyPayDay1: Int?,
        semimonthlyPayDay2: Int?
    ) throws -> PlanningPayCadence {
        switch cadence {
        case .weekly:
            return .weekly
        case .biweekly:
            return .biweekly
        case .monthly:
            guard let day = monthlyPayDay else {
                throw GenerationError.missingPayDay(cadence: "monthly")
            }
            return .monthly(day: day)
        case .semimonthly:
            guard let first = semimonthlyPayDay1, let second = semimonthlyPayDay2 else {
                throw GenerationError.missingPayDay(cadence: "twice-a-month")
            }
            guard first != second else { throw GenerationError.samePayDays }
            return .semimonthly(firstDay: min(first, second), secondDay: max(first, second))
        }
    }

    // MARK: - Engine result → persistable rows

    /// Maps the engine's rich result onto the persister's row shape. Money
    /// values pass through untouched; only identifiers are translated
    /// (engine debt UUIDs → stable per-plan display IDs).
    static func resultSnapshot(
        from result: PlanningResult,
        input snapshot: StoredPlanInput
    ) -> StoredPlanResult {
        let displayIDs = Dictionary(uniqueKeysWithValues: snapshot.debts.map { ($0.id, $0.displayID) })

        let paydays = result.paychecks.map { paycheck in
            PlanningPayday(
                sequence: paycheck.sequence,
                date: paycheck.date,
                income: paycheck.income + paycheck.windfall,
                keepInSpending: paycheck.keepInSpending,
                transferToReserves: paycheck.transferToReserves,
                allowance: paycheck.allowanceReserved,
                floorTopUp: paycheck.floorTopUp,
                obligationReserves: paycheck.obligationReserves.map {
                    PlanningObligationReserve(obligationID: $0.obligationID, amount: $0.amount)
                },
                // Calc-v1 row semantics: the planned card payment (what the
                // user actually sends to debts), not the engine's available
                // cash — on the final check the two differ by the leftover.
                debtBudget: paycheck.minimumsTotal + paycheck.extraTotal,
                targetDebtID: paycheck.targetDebtID.flatMap { displayIDs[$0] },
                perDebtBalancesAfter: Dictionary(
                    uniqueKeysWithValues: paycheck.endingBalances.compactMap { point in
                        displayIDs[point.debtID].map { ($0, point.balance) }
                    }
                ),
                totalDebtAfter: paycheck.totalDebtAfter,
                noSpendCeiling: paycheck.spendingCeilingAfter,
                shortfallAmount: paycheck.shortfall?.gap
            )
        }

        let payoffs = result.debtSummaries.compactMap { summary -> PlanningDebtPayoff? in
            guard let date = summary.payoffDate, let displayID = displayIDs[summary.debtID] else {
                return nil
            }
            return PlanningDebtPayoff(debtID: displayID, payoffDate: date)
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
}
