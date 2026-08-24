import Foundation

/// Answers "what if I pay extra?" (V3-04) without touching anything.
protocol ExtraPaymentInsightCalculating {
    func insight(from input: StoredPlanInput, extra: StoredExtraPayment) throws -> ExtraPaymentInsight
}

/// R-20/R-21. Runs the same projection twice — once as saved, once with the
/// extra payment modeled — through the one store→engine bridge, so every
/// number reconciles to the core engine to the cent by construction rather
/// than by an independent formula.
///
/// The result is a preview: nothing is written, persisted, or activated
/// (R-15/V3-15).
struct ExtraPaymentInsightService: ExtraPaymentInsightCalculating {

    init() {}

    func insight(from input: StoredPlanInput, extra: StoredExtraPayment) throws -> ExtraPaymentInsight {
        try Self.insight(from: input, extra: extra)
    }

    static func insight(
        from snapshot: StoredPlanInput,
        extra: StoredExtraPayment
    ) throws -> ExtraPaymentInsight {
        _ = try PlanGenerationService.planningCadence(from: snapshot)

        let audit = ScenarioInputAudit(snapshot: snapshot)
        var missing = audit.missingInputs
        if extra.amount.rounded2 <= 0 {
            missing.append(ScenarioMissingInput(
                field: .extraPaymentAmount,
                message: "Enter how much extra you want to pay."
            ))
        }
        if let targetID = extra.targetDebtID, !snapshot.debts.contains(where: { $0.id == targetID }) {
            missing.append(ScenarioMissingInput(
                field: .extraPaymentTarget,
                message: "The debt this extra payment points at is no longer in your setup. Choose another, or let the app pick.",
                debtID: targetID
            ))
        }
        guard missing.isEmpty else {
            return unavailable(extra: extra, missingInputs: missing, warnings: audit.warnings)
        }

        let before = try PlanGenerationService.generate(from: snapshot).result
        var withExtra = snapshot
        withExtra.calculationVersion = PlanCalculationVersion.v4BalancedQuickWin.rawValue
        withExtra.extraPayments = snapshot.extraPayments + [extra]
        let after = try PlanGenerationService.generate(from: withExtra).result

        // Both tracks must finish before any "saved" figure is claimed — an
        // unfinished projection has no comparable total (the R-16 precedent).
        let bothFinished = before.forecastPayoffDate != nil && after.forecastPayoffDate != nil
        let daysSaved = bothFinished
            ? max(DateMath.days(from: after.forecastPayoffDate!, to: before.forecastPayoffDate!), 0)
            : nil
        let periodsSaved = bothFinished ? max(before.paycheckCount - after.paycheckCount, 0) : nil
        let interestSaved = bothFinished
            ? (before.estimatedTotalInterest - after.estimatedTotalInterest).rounded2
            : nil

        let landingDate = landingPayday(in: after, onOrAfter: extra.effectiveDate)
        let resolvedTarget = resolveTarget(extra: extra, after: after, landingDate: landingDate)

        return ExtraPaymentInsight(
            extraPaymentID: extra.id,
            kind: extra.kind,
            amount: extra.amount.rounded2,
            effectiveDate: DateMath.startOfDay(extra.effectiveDate),
            targetDebtID: resolvedTarget,
            targetWasAutomatic: extra.targetDebtID == nil,
            payoffDateBefore: before.forecastPayoffDate,
            payoffDateAfter: after.forecastPayoffDate,
            daysSaved: daysSaved,
            periodsSaved: periodsSaved,
            interestBefore: before.estimatedTotalInterest,
            interestAfter: after.estimatedTotalInterest,
            interestSaved: interestSaved,
            totalPaid: totalPaid(after),
            totalPaidBefore: totalPaid(before),
            projectedPrincipalReduction: principalReduction(before: before, after: after, on: landingDate),
            downstreamChanges: downstreamChanges(before: before, after: after),
            missingInputs: [],
            assumptions: after.assumptions,
            warnings: after.warnings + audit.warnings
                + cashWarnings(snapshot: snapshot, extra: extra, before: before)
        )
    }

    // MARK: - Derived figures

    private static func totalPaid(_ plan: PlanningResult) -> Decimal {
        plan.debtSummaries.reduce(Decimal.zero) { $0 + $1.totalPaid }.rounded2
    }

    /// The payday that receives the money — the same "first payday on or after
    /// the date" rule the engine schedules it with.
    private static func landingPayday(in plan: PlanningResult, onOrAfter date: Date) -> Date? {
        let effective = DateMath.startOfDay(date)
        return plan.paychecks.first { $0.date >= effective }?.date ?? plan.paychecks.first?.date
    }

    /// Debt outstanding on the landing payday, before minus after: the
    /// principal effect once that period's modeled interest has accrued.
    private static func principalReduction(
        before: PlanningResult,
        after: PlanningResult,
        on landingDate: Date?
    ) -> Decimal {
        guard let landingDate,
              let beforeRow = before.paychecks.first(where: { $0.date == landingDate }),
              let afterRow = after.paychecks.first(where: { $0.date == landingDate }) else { return 0 }
        return max((beforeRow.totalDebtAfter - afterRow.totalDebtAfter).rounded2, 0)
    }

    /// The debt the money actually reached first. A named target that the
    /// engine had to skip (R-07) is not reported as the target — the warning
    /// says why, and this names where the money really went.
    private static func resolveTarget(
        extra: StoredExtraPayment,
        after: PlanningResult,
        landingDate: Date?
    ) -> UUID? {
        guard let landingDate,
              let row = after.paychecks.first(where: { $0.date == landingDate }) else {
            return nil
        }
        if let named = extra.targetDebtID,
           row.payments.contains(where: { $0.debtID == named && $0.extra > 0 }) {
            return named
        }
        return row.targetDebtID
    }

    private static func downstreamChanges(
        before: PlanningResult,
        after: PlanningResult
    ) -> [ExtraPaymentDownstreamChange] {
        let afterByID = Dictionary(uniqueKeysWithValues: after.debtSummaries.map { ($0.debtID, $0) })
        let beforeRank = Dictionary(uniqueKeysWithValues: before.payoffOrder.enumerated().map { ($1, $0) })
        let afterRank = Dictionary(uniqueKeysWithValues: after.payoffOrder.enumerated().map { ($1, $0) })

        return before.debtSummaries.compactMap { summary -> ExtraPaymentDownstreamChange? in
            guard let updated = afterByID[summary.debtID] else { return nil }
            let rankBefore = beforeRank[summary.debtID] ?? 0
            let rankAfter = afterRank[summary.debtID] ?? 0
            let dateChanged = summary.payoffDate != updated.payoffDate
            guard dateChanged || rankBefore != rankAfter else { return nil }
            let daysChanged: Int?
            if let from = summary.payoffDate, let to = updated.payoffDate {
                daysChanged = DateMath.days(from: from, to: to)
            } else {
                daysChanged = nil
            }
            return ExtraPaymentDownstreamChange(
                debtID: summary.debtID,
                name: summary.name,
                payoffDateBefore: summary.payoffDate,
                payoffDateAfter: updated.payoffDate,
                daysChanged: daysChanged,
                payoffOrderBefore: rankBefore,
                payoffOrderAfter: rankAfter
            )
        }
    }

    // MARK: - Cash warnings (R-21)

    /// The engine models a single spending pool, so it cannot verify a named
    /// account's balance. It says so, and it compares the amount against the
    /// cash the plan actually projects above the protected floor rather than
    /// staying silent.
    private static func cashWarnings(
        snapshot: StoredPlanInput,
        extra: StoredExtraPayment,
        before: PlanningResult
    ) -> [PlanningNote] {
        var notes: [PlanningNote] = []
        let lowestCash = before.cashBufferPath.min() ?? snapshot.spendingStartingBalance
        if lowestCash.rounded2 < snapshot.protectedFloor.rounded2 {
            notes.append(PlanningNote(
                code: .protectedFloorAtRisk,
                message: "Your plan already dips to \(MoneyFormat.string(lowestCash)), under your \(MoneyFormat.string(snapshot.protectedFloor)) protected floor. Paying extra from that account would push it lower."
            ))
        }
        guard extra.sourceAccountID != nil else { return notes }
        notes.append(PlanningNote(
            code: .sourceAccountNotVerified,
            message: "This estimate does not check the balance of the account you chose; it models one pool of cash. Confirm the money is there before you send it."
        ))
        let headroom = (lowestCash - snapshot.protectedFloor).rounded2
        if extra.amount.rounded2 > headroom {
            notes.append(PlanningNote(
                code: .insufficientAvailableCash,
                message: "\(MoneyFormat.string(extra.amount)) is more than the \(MoneyFormat.string(max(headroom, 0))) this plan projects above your protected floor."
            ))
        }
        return notes
    }

    private static func unavailable(
        extra: StoredExtraPayment,
        missingInputs: [ScenarioMissingInput],
        warnings: [PlanningNote]
    ) -> ExtraPaymentInsight {
        ExtraPaymentInsight(
            extraPaymentID: extra.id,
            kind: extra.kind,
            amount: extra.amount.rounded2,
            effectiveDate: DateMath.startOfDay(extra.effectiveDate),
            targetDebtID: extra.targetDebtID,
            targetWasAutomatic: extra.targetDebtID == nil,
            payoffDateBefore: nil, payoffDateAfter: nil,
            daysSaved: nil, periodsSaved: nil,
            interestBefore: 0, interestAfter: 0, interestSaved: nil,
            totalPaid: 0, totalPaidBefore: 0,
            projectedPrincipalReduction: 0,
            downstreamChanges: [],
            missingInputs: missingInputs,
            assumptions: [],
            warnings: warnings
        )
    }
}
