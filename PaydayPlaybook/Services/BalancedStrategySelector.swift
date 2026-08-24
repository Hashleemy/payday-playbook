import Foundation

/// Balanced (Recommended) target selection over complete engine simulations
/// (V4-03, R-25…R-27).
///
/// The selector never invents a score: it enumerates deterministic quick-win
/// candidates (R-25), admits them through the three guardrails (R-26 G1–G3),
/// and picks by the exact lexicographic order the contract fixes — earliest
/// first payoff, lowest estimated interest, earliest debt-free date, R-08
/// rank, UUID string. Every comparison figure comes from a complete engine
/// run through `PlanGenerationService.engineInput`; there is no forked payoff
/// algorithm and no third store→engine bridge.
///
/// It runs only at preview time, for `.balanced`, and only when the
/// definition carries no pinned promotion. Applying pins the winning
/// promotion into the persisted snapshot (`ScenarioPlanActivationService`),
/// so regeneration re-runs the engine, never this selector — applied plans
/// reproduce forever. Pure and deterministic: identical inputs always select
/// identically (R-22 extended). Foundation only; nothing here persists.
enum BalancedStrategySelector {

    /// What the Balanced preview renders and what applying pins.
    struct Selection {
        /// The winning projection — a complete, full-option engine run
        /// (candidate-only skip runs are never returned).
        var result: PlanningResult
        var rationale: BalancedSelectionRationale
        /// The promotion applying must pin; empty for an avalanche selection.
        var pinnedPromotions: [UUID]
        /// R-27 notes for the scenario card, split the way `ScenarioResult`
        /// carries them.
        var assumptionNotes: [PlanningNote]
        var warningNotes: [PlanningNote]
    }

    /// One candidate's engine-proven comparison figures. Internal so the
    /// guardrail and tie-break tests can exercise exact boundaries without
    /// reverse-engineering fixtures.
    struct CandidateStats: Equatable {
        var debtID: UUID
        var debtName: String
        var firstPayoffDate: Date
        var estimatedTotalInterest: Decimal
        var debtFreeDate: Date?
        /// Position in the R-08 attack order at plan start.
        var attackRank: Int
    }

    // MARK: - Selection

    static func select(
        snapshot: StoredPlanInput,
        definition: StoredScenarioDefinition
    ) throws -> Selection {
        assert(definition.kind == .balanced, "the selector runs only for Balanced")

        // B0: Balanced constraints, no promotions — exactly the pre-v0.4.0
        // Balanced, run once and reused for the pre-filter, every guardrail,
        // and the no-quick-win fallback.
        let baselineSnapshot = stamped(snapshot, definition: definition, promotions: [])
        let baseline = try PlanGenerationService.generate(from: baselineSnapshot).result

        let engineDebts = try PlanGenerationService.engineInput(from: baselineSnapshot).debts
        let attackRank: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: AvalanchePlanEngine
                .attackOrder(debts: engineDebts, on: baseline.paychecks.first?.date ?? snapshot.nextPayday)
                .enumerated()
                .map { ($1, $0) }
        )

        // R-25 step 2: the arithmetic pre-filter, in R-08 order so the
        // simulation order (and therefore any logging or debugging trace) is
        // deterministic. The bound ignores interest, so it can only
        // over-include — no true candidate is ever excluded.
        let preCandidates = snapshot.debts
            .filter { debt in
                debt.currentBalance.rounded2 > 0
                    && debt.effectivePrepayment == .eligible
                    && debt.id != baseline.currentTargetDebtID
                    && debt.currentBalance.rounded2 <= optimisticPayoffBound(for: debt.id, in: baseline)
            }
            .sorted { (attackRank[$0.id] ?? .max, $0.id.uuidString) < (attackRank[$1.id] ?? .max, $1.id.uuidString) }

        // R-25 step 3: full candidate simulations. Candidate runs skip the
        // minimums-only comparison projection (an internal engine option that
        // cannot change stamped outputs) — the winner is re-run in full below.
        var candidates: [CandidateStats] = []
        var admissible: [CandidateStats] = []
        for debt in preCandidates {
            let candidateSnapshot = stamped(snapshot, definition: definition, promotions: [debt.id])
            let projection = try AvalanchePlanEngine.generatePlan(
                try PlanGenerationService.engineInput(from: candidateSnapshot),
                includeMinimumOnlyComparison: false
            )
            guard let cleared = projection.debtSummaries.first(where: { $0.debtID == debt.id })?.payoffDate,
                  let horizonDate = projection.paychecks
                      .prefix(PlanContract.balancedQuickWinHorizonPaychecks).last?.date,
                  cleared <= horizonDate,
                  let firstPayoff = firstPayoffDate(of: projection) else { continue }
            let stats = CandidateStats(
                debtID: debt.id,
                debtName: debt.name,
                firstPayoffDate: firstPayoff,
                estimatedTotalInterest: projection.estimatedTotalInterest,
                debtFreeDate: projection.forecastPayoffDate,
                attackRank: attackRank[debt.id] ?? .max
            )
            candidates.append(stats)

            // R-26 guardrails, each against the one shared baseline.
            let g1 = delayGuardrailSatisfied(
                candidatePaycheckCount: projection.paycheckCount,
                baselinePaycheckCount: baseline.paycheckCount
            ) && !projection.notPayableAsConfigured
            let g2 = interestGuardrailSatisfied(
                candidateInterest: projection.estimatedTotalInterest,
                baselineInterest: baseline.estimatedTotalInterest
            )
            let g3 = firstPayoffGuardrailSatisfied(
                candidateFirstPayoff: firstPayoff,
                baselineFirstPayoff: firstPayoffDate(of: baseline)
            )
            if g1 && g2 && g3 { admissible.append(stats) }
        }

        guard let winner = admissible.min(by: precedes) else {
            // No admissible candidate → B0 is Balanced, exactly the
            // pre-v0.4.0 behavior.
            return avalancheSelection(baseline: baseline, candidatesConsidered: candidates.count)
        }

        // The winning projection is re-run with the full engine options so the
        // returned (and, on apply, persisted) result carries everything a
        // plain Balanced run would — including the minimums-only comparison.
        let winnerSnapshot = stamped(snapshot, definition: definition, promotions: [winner.debtID])
        let result = try PlanGenerationService.generate(from: winnerSnapshot).result
        return quickWinSelection(
            winner: winner,
            result: result,
            baseline: baseline,
            candidatesConsidered: candidates.count
        )
    }

    // MARK: - R-25 pre-filter

    /// Optimistic no-interest payoff bound: everything B0 sends to debt as
    /// extra in its first `balancedQuickWinHorizonPaychecks` paychecks, plus
    /// the minimums B0 already pays this debt in that window.
    static func optimisticPayoffBound(for debtID: UUID, in baseline: PlanningResult) -> Decimal {
        baseline.paychecks
            .prefix(PlanContract.balancedQuickWinHorizonPaychecks)
            .reduce(Decimal.zero) { partial, paycheck in
                let minimum = paycheck.payments.first { $0.debtID == debtID }?.minimum ?? 0
                return partial + paycheck.extraTotal + minimum
            }
    }

    // MARK: - R-26 guardrails

    /// G1: the overall payoff may slip at most
    /// `balancedQuickWinMaxDelayPaychecks` pay periods.
    static func delayGuardrailSatisfied(
        candidatePaycheckCount: Int,
        baselinePaycheckCount: Int
    ) -> Bool {
        candidatePaycheckCount <= baselinePaycheckCount + PlanContract.balancedQuickWinMaxDelayPaychecks
    }

    /// G2: extra estimated interest is capped at
    /// `min(rate × baseline interest, cap)`. A zero-interest baseline
    /// therefore admits only candidates that add no interest at all.
    static func interestGuardrailSatisfied(
        candidateInterest: Decimal,
        baselineInterest: Decimal
    ) -> Bool {
        let allowance = min(
            PlanContract.balancedQuickWinMaxExtraInterestRate * baselineInterest,
            PlanContract.balancedQuickWinMaxExtraInterestCap
        )
        return candidateInterest - baselineInterest <= allowance
    }

    /// G3: the quick win must actually advance the first account payoff —
    /// strictly earlier than B0's, or B0 never clears an account and the
    /// candidate does.
    static func firstPayoffGuardrailSatisfied(
        candidateFirstPayoff: Date?,
        baselineFirstPayoff: Date?
    ) -> Bool {
        guard let candidateFirstPayoff else { return false }
        guard let baselineFirstPayoff else { return true }
        return candidateFirstPayoff < baselineFirstPayoff
    }

    // MARK: - R-26 lexicographic order

    /// Earliest first payoff → lowest estimated interest → earliest debt-free
    /// date → earliest R-08 rank at plan start → UUID string. No weights.
    static func precedes(_ a: CandidateStats, _ b: CandidateStats) -> Bool {
        if a.firstPayoffDate != b.firstPayoffDate { return a.firstPayoffDate < b.firstPayoffDate }
        if a.estimatedTotalInterest != b.estimatedTotalInterest {
            return a.estimatedTotalInterest < b.estimatedTotalInterest
        }
        switch (a.debtFreeDate, b.debtFreeDate) {
        case let (x?, y?) where x != y: return x < y
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        if a.attackRank != b.attackRank { return a.attackRank < b.attackRank }
        return a.debtID.uuidString < b.debtID.uuidString
    }

    // MARK: - Rationale assembly (R-27)

    private static func avalancheSelection(
        baseline: PlanningResult,
        candidatesConsidered: Int
    ) -> Selection {
        let explanation = candidatesConsidered == 0
            ? "No smaller account could be cleared within \(PlanContract.balancedQuickWinHorizonPaychecks) paychecks, so every extra dollar attacks the highest APR first."
            : "Clearing a smaller account first would delay the payoff or add more interest than it is worth, so the highest-APR order stays."
        return Selection(
            result: baseline,
            rationale: BalancedSelectionRationale(
                selection: .avalanche,
                promotedDebtID: nil,
                promotedDebtName: nil,
                candidatesConsidered: candidatesConsidered,
                interestDeltaVsAvalanche: 0,
                payoffDelayPaychecks: 0,
                firstPayoffAdvanceDays: nil,
                releasedMinimumPerPaycheck: nil,
                explanations: [explanation]
            ),
            pinnedPromotions: [],
            assumptionNotes: [],
            warningNotes: []
        )
    }

    private static func quickWinSelection(
        winner: CandidateStats,
        result: PlanningResult,
        baseline: PlanningResult,
        candidatesConsidered: Int
    ) -> Selection {
        let interestDelta = result.estimatedTotalInterest - baseline.estimatedTotalInterest
        let delayPaychecks = result.paycheckCount - baseline.paycheckCount
        let baselineFirstPayoff = firstPayoffDate(of: baseline)
        let advanceDays = baselineFirstPayoff.map {
            DateMath.days(from: winner.firstPayoffDate, to: $0)
        }
        let released = releasedMinimumPerPaycheck(
            promoted: winner.debtID, result: result, baseline: baseline
        )
        let bothFinished = result.forecastPayoffDate != nil && baseline.forecastPayoffDate != nil

        var explanations: [String] = []
        if let advanceDays {
            explanations.append("Clears \(winner.debtName) \(advanceDays) day\(advanceDays == 1 ? "" : "s") sooner than the highest-APR order clears any account.")
        } else {
            explanations.append("Clears \(winner.debtName) early — the highest-APR order clears no account within the modeled horizon.")
        }
        if let released {
            explanations.append("Paying it off frees its \(MoneyFormat.string(released)) minimum payment for the rest of the plan.")
        }
        if bothFinished {
            if delayPaychecks == 0 {
                explanations.append("The projected debt-free date is unchanged.")
            } else if delayPaychecks > 0 {
                explanations.append("The projected debt-free date slips by \(delayPaychecks) paycheck\(delayPaychecks == 1 ? "" : "s") — within the plan's guardrail.")
            } else {
                explanations.append("It also finishes \(-delayPaychecks) paycheck\(delayPaychecks == -1 ? "" : "s") sooner.")
            }
            if interestDelta > 0 {
                explanations.append("Estimated interest is \(MoneyFormat.string(interestDelta)) higher than the strict highest-APR order — within the plan's guardrail.")
            } else if interestDelta < 0 {
                explanations.append("It also saves \(MoneyFormat.string(-interestDelta)) in estimated interest.")
            } else {
                explanations.append("Estimated interest is unchanged.")
            }
        } else {
            // The R-16 precedent: no finish-line or savings claim unless both
            // compared projections actually finished.
            explanations.append("The highest-APR order does not finish within the modeled horizon, so finish-line and interest comparisons are not shown.")
        }

        var assumptionNotes = [PlanningNote(
            code: .quickWinSelected,
            message: "Balanced clears \(winner.debtName) first as a quick win. Every comparison figure comes from complete plan projections.",
            debtID: winner.debtID
        )]
        var warningNotes: [PlanningNote] = []
        if bothFinished && interestDelta > 0 {
            warningNotes.append(PlanningNote(
                code: .quickWinCostsMoreInterest,
                message: "This quick win adds \(MoneyFormat.string(interestDelta)) of estimated interest versus the strict highest-APR order.",
                debtID: winner.debtID
            ))
        }
        if !bothFinished {
            assumptionNotes.append(PlanningNote(
                code: .quickWinSelected,
                message: "Interest and finish-line comparisons are unavailable because a compared projection did not finish within the modeled horizon."
            ))
        }

        return Selection(
            result: result,
            rationale: BalancedSelectionRationale(
                selection: .quickWin,
                promotedDebtID: winner.debtID,
                promotedDebtName: winner.debtName,
                candidatesConsidered: candidatesConsidered,
                interestDeltaVsAvalanche: interestDelta,
                payoffDelayPaychecks: delayPaychecks,
                firstPayoffAdvanceDays: advanceDays,
                releasedMinimumPerPaycheck: released,
                explanations: explanations
            ),
            pinnedPromotions: [winner.debtID],
            assumptionNotes: assumptionNotes,
            warningNotes: warningNotes
        )
    }

    // MARK: - Engine-derived figures

    /// Earliest per-account payoff in a projection; nil when no account is
    /// cleared inside it.
    static func firstPayoffDate(of result: PlanningResult) -> Date? {
        result.debtSummaries.compactMap(\.payoffDate).min()
    }

    /// The minimum B0 still funds for the promoted debt in its first paycheck
    /// after the quick win clears it — the per-paycheck obligation the
    /// promotion releases. Nil when B0 funds none after that date (it was
    /// about to clear the debt itself), which honestly means nothing is
    /// released.
    static func releasedMinimumPerPaycheck(
        promoted: UUID,
        result: PlanningResult,
        baseline: PlanningResult
    ) -> Decimal? {
        guard let clearedOn = result.debtSummaries.first(where: { $0.debtID == promoted })?.payoffDate else {
            return nil
        }
        for paycheck in baseline.paychecks where paycheck.date > clearedOn {
            if let payment = paycheck.payments.first(where: { $0.debtID == promoted }),
               payment.minimum > 0 {
                return payment.minimum
            }
        }
        return nil
    }

    // MARK: - Snapshot plumbing

    /// One place builds the calc-v4 snapshot a selector run uses, so B0, every
    /// candidate, and the winner re-run differ *only* in their promotion list.
    private static func stamped(
        _ snapshot: StoredPlanInput,
        definition: StoredScenarioDefinition,
        promotions: [UUID]
    ) -> StoredPlanInput {
        var scenarioDefinition = definition
        scenarioDefinition.quickWinPromotions = promotions
        var stampedSnapshot = snapshot
        stampedSnapshot.calculationVersion = PlanCalculationVersion.v4BalancedQuickWin.rawValue
        stampedSnapshot.scenario = scenarioDefinition
        return stampedSnapshot
    }
}
