import Foundation

/// Computes the three contracted payoff scenarios (V3-05).
///
/// Missing inputs surface *in the results* — one card per definition, carrying
/// what it still needs — rather than as thrown errors. Only an input set the
/// engine cannot be called with at all throws (`GenerationError`), because
/// there is no card to show in that case.
protocol ScenarioCalculating {
    func scenarios(
        from input: StoredPlanInput,
        definitions: [StoredScenarioDefinition]
    ) throws -> [ScenarioResult]
}

/// R-17…R-19, R-22…R-24. Storage-independent: it reads a `StoredPlanInput`,
/// converts it through the one store→engine bridge
/// (`PlanGenerationService.engineInput`), and runs the same
/// `AvalanchePlanEngine` every other plan uses. There is no second payoff
/// algorithm and no third bridge.
///
/// Every output is a preview. Nothing here writes, persists, or activates a
/// plan version (R-15/V3-15).
struct ScenarioCalculationService: ScenarioCalculating {

    init() {}

    func scenarios(
        from input: StoredPlanInput,
        definitions: [StoredScenarioDefinition]
    ) throws -> [ScenarioResult] {
        try Self.scenarios(from: input, definitions: definitions)
    }

    // MARK: - Calculation

    static func scenarios(
        from snapshot: StoredPlanInput,
        definitions: [StoredScenarioDefinition]
    ) throws -> [ScenarioResult] {
        // A snapshot the engine cannot be called with at all is an actionable
        // failure, not a card: there is no honest estimate to render.
        _ = try PlanGenerationService.planningCadence(from: snapshot)

        let audit = ScenarioInputAudit(snapshot: snapshot)

        /// One definition's computed pieces: the projection plus the Balanced
        /// selection rationale and its R-27 notes (empty for the other kinds).
        struct Computed {
            var plan: PlanningResult?
            var rationale: BalancedSelectionRationale? = nil
            var assumptionNotes: [PlanningNote] = []
            var warningNotes: [PlanningNote] = []
        }

        // Pass 1: run every computable definition.
        var computed: [Computed] = []
        for definition in definitions {
            let missing = audit.missingInputs + audit.missingInputs(for: definition)
            guard missing.isEmpty else {
                computed.append(Computed(plan: nil))
                continue
            }
            if definition.kind == .balanced && definition.quickWinPromotions.isEmpty {
                // V4-03: Balanced previews run the quick-win selector. A
                // definition that already carries a pinned promotion skips it
                // — a pinned selection is an instruction, and regeneration
                // must re-run the engine, never the selector (R-27).
                let selection = try BalancedStrategySelector.select(
                    snapshot: snapshot, definition: definition
                )
                computed.append(Computed(
                    plan: selection.result,
                    rationale: selection.rationale,
                    assumptionNotes: selection.assumptionNotes,
                    warningNotes: selection.warningNotes
                ))
            } else {
                var scenarioSnapshot = snapshot
                scenarioSnapshot.calculationVersion = PlanCalculationVersion.v4BalancedQuickWin.rawValue
                scenarioSnapshot.scenario = definition
                computed.append(Computed(plan: try PlanGenerationService.generate(from: scenarioSnapshot).result))
            }
        }

        // Pass 2: summarize, then measure everything against Balanced. Two
        // passes because Balanced may appear anywhere in `definitions`.
        var results = zip(definitions, computed).map { definition, item -> ScenarioResult in
            var result = summary(
                kind: definition.kind,
                plan: item.plan,
                missingInputs: audit.missingInputs + audit.missingInputs(for: definition),
                extraWarnings: audit.warnings,
                snapshot: snapshot
            )
            result.balancedRationale = item.rationale
            result.assumptions.append(contentsOf: item.assumptionNotes)
            result.warnings.append(contentsOf: item.warningNotes)
            return result
        }
        if let balanced = results.first(where: { $0.kind == .balanced && $0.isComputable }) {
            for index in results.indices {
                results[index].deltaVsBalanced = delta(of: results[index], versus: balanced)
            }
        }
        return results
    }

    // MARK: - Card summary (R-19)

    private static func summary(
        kind: ScenarioKind,
        plan: PlanningResult?,
        missingInputs: [ScenarioMissingInput],
        extraWarnings: [PlanningNote],
        snapshot: StoredPlanInput
    ) -> ScenarioResult {
        guard let plan else {
            return ScenarioResult(
                kind: kind, plan: nil, payoffDate: nil, duration: nil,
                totalStartingPrincipal: snapshot.debts.reduce(Decimal.zero) { $0 + $1.currentBalance }.rounded2,
                totalCurrentPrincipal: snapshot.debts.reduce(Decimal.zero) { $0 + $1.currentBalance }.rounded2,
                periodicDebtContribution: 0, cashRetainedPerPaycheck: 0,
                estimatedTotalInterest: 0, totalPaid: 0, minimumEndingCash: nil,
                deltaVsBalanced: nil, assumptions: [], missingInputs: missingInputs,
                warnings: extraWarnings, notPayableAsConfigured: false
            )
        }

        let paycheckCount = max(plan.paychecks.count, 1)
        let toDebt = plan.paychecks.reduce(Decimal.zero) { $0 + $1.minimumsTotal + $1.extraTotal }
        let retained = plan.paychecks.reduce(Decimal.zero) { $0 + $1.keepInSpending }
        let totalPaid = plan.debtSummaries.reduce(Decimal.zero) { $0 + $1.totalPaid }

        return ScenarioResult(
            kind: kind,
            plan: plan,
            payoffDate: plan.forecastPayoffDate,
            duration: duration(of: plan),
            totalStartingPrincipal: plan.totalStartingPrincipal,
            totalCurrentPrincipal: plan.totalRemainingPrincipal,
            periodicDebtContribution: (toDebt / Decimal(paycheckCount)).rounded2,
            cashRetainedPerPaycheck: (retained / Decimal(paycheckCount)).rounded2,
            estimatedTotalInterest: plan.estimatedTotalInterest,
            totalPaid: totalPaid.rounded2,
            // R-23: the low point of the projected spending-pool path.
            minimumEndingCash: plan.cashBufferPath.min(),
            deltaVsBalanced: nil,
            assumptions: plan.assumptions,
            missingInputs: missingInputs,
            warnings: plan.warnings + extraWarnings,
            notPayableAsConfigured: plan.notPayableAsConfigured
        )
    }

    private static func duration(of plan: PlanningResult) -> ScenarioDuration? {
        guard let payoff = plan.forecastPayoffDate, let start = plan.paychecks.first?.date else {
            return nil
        }
        let days = max(DateMath.days(from: start, to: payoff), 0)
        let months = DateMath.calendar.dateComponents([.month], from: start, to: payoff).month ?? 0
        return ScenarioDuration(days: days, paychecks: plan.paycheckCount, months: max(months, 0))
    }

    /// Interest and time against Balanced. Withheld unless both scenarios
    /// actually reached a payoff date — an unfinished projection has no
    /// comparable total (the R-16 minimum-only precedent).
    private static func delta(
        of result: ScenarioResult,
        versus balanced: ScenarioResult
    ) -> ScenarioComparisonDelta? {
        guard result.isComputable,
              let thisPayoff = result.payoffDate,
              let balancedPayoff = balanced.payoffDate else { return nil }
        return ScenarioComparisonDelta(
            interestDelta: (result.estimatedTotalInterest - balanced.estimatedTotalInterest).rounded2,
            timeDelta: DateMath.days(from: balancedPayoff, to: thisPayoff)
        )
    }
}

// MARK: - Honest-input audit (R-24)

/// Names what a scenario or insight still needs, and what it is assuming.
///
/// The rule throughout: withhold rather than guess. A value the snapshot
/// genuinely cannot distinguish from a real user answer (a 0% APR, an empty
/// bill list) becomes a *warning* the user can read and correct, never a
/// silent assumption and never a fabricated number.
struct ScenarioInputAudit {
    let snapshot: StoredPlanInput

    /// Inputs missing regardless of which scenario is being computed.
    var missingInputs: [ScenarioMissingInput] {
        var missing: [ScenarioMissingInput] = []
        let active = snapshot.debts.filter { $0.currentBalance.rounded2 > 0 }
        if active.isEmpty {
            missing.append(ScenarioMissingInput(
                field: .debts,
                message: "Add at least one debt with a balance before comparing payoff plans."
            ))
        }
        // Detectable and blocking: an installment debt with no contractual
        // payment has no honest schedule (R-06/A-06).
        for debt in active where debt.debtType != .creditCard && debt.minimumAmount == nil {
            missing.append(ScenarioMissingInput(
                field: .debtMinimum,
                message: "Enter \(debt.name)'s required monthly payment so its payoff can be estimated.",
                debtID: debt.id
            ))
        }
        if snapshot.baseTakeHome.rounded2 <= 0 && snapshot.incomeChanges.allSatisfy({ $0.amount.rounded2 <= 0 }) {
            missing.append(ScenarioMissingInput(
                field: .income,
                message: "Enter your take-home pay so a payoff date can be estimated."
            ))
        }
        return missing
    }

    /// What this scenario kind needs on top of the base set (R-17).
    func missingInputs(for definition: StoredScenarioDefinition) -> [ScenarioMissingInput] {
        var missing: [ScenarioMissingInput] = []
        switch definition.kind {
        case .fastestSafe:
            if definition.minimumProtectedCash == nil {
                missing.append(ScenarioMissingInput(
                    field: .minimumProtectedCash,
                    message: "Fastest Safe needs the least cash you will keep in checking. Set it in Goal & guardrails."
                ))
            }
            if definition.zeroAllowanceConfirmedAt == nil {
                missing.append(ScenarioMissingInput(
                    field: .zeroAllowanceConfirmation,
                    message: "Fastest Safe sends your whole discretionary allowance to debt. Confirm a $0 allowance before it can be estimated."
                ))
            }
        case .balanced:
            missing.append(contentsOf: plannedSavingsMissing(definition))
        case .moreCushion:
            missing.append(contentsOf: plannedSavingsMissing(definition))
            if definition.additionalReserve == nil && definition.extraPaymentCeiling == nil {
                missing.append(ScenarioMissingInput(
                    field: .cushionConstraint,
                    message: "More Cushion needs either an extra cash reserve to keep each paycheck or a cap on extra debt payments."
                ))
            }
        }
        return missing
    }

    private func plannedSavingsMissing(_ definition: StoredScenarioDefinition) -> [ScenarioMissingInput] {
        guard definition.plannedSavingsPerPaycheck == nil else { return [] }
        return [ScenarioMissingInput(
            field: .plannedSavings,
            message: "Enter how much you plan to save each paycheck — enter $0 if you are not saving yet."
        )]
    }

    /// Things the estimate assumes because the saved data cannot say otherwise.
    var warnings: [PlanningNote] {
        var notes: [PlanningNote] = []
        if snapshot.obligations.isEmpty {
            notes.append(PlanningNote(
                code: .noBillsConfigured,
                message: "No bills are set up, so this estimate reserves nothing for them. Add your bills for a truer picture."
            ))
        }
        for debt in snapshot.debts where debt.currentBalance.rounded2 > 0 && debt.apr.rounded2 <= 0 {
            notes.append(PlanningNote(
                code: .aprMissingOrZero,
                message: "\(debt.name) is modeled at 0% APR. If it actually charges interest, add its rate so the estimate is not optimistic.",
                debtID: debt.id
            ))
        }
        return notes
    }
}
