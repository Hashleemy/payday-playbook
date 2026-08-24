import XCTest
import SwiftData
@testable import PaydayPlaybook

/// T-20 — the Balanced quick-win selector (V4-03, R-25/R-26/R-27).
///
/// Covers candidate enumeration and the pre-filter's over-inclusion proof,
/// each guardrail at its exact boundary, the full lexicographic tie chain,
/// determinism, rationale figures reconciling to the engine runs they cite,
/// preview purity, apply-time pinning, and regeneration reproducing the
/// applied selection without the selector.
///
/// Every fixture value is invented (V3-12).
final class BalancedStrategySelectorTests: XCTestCase {

    private static let stableEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private func bytes<T: Encodable>(_ value: T) throws -> Data {
        try Self.stableEncoder.encode(value)
    }

    // MARK: - Fixtures

    /// Entered minimums and no due days everywhere, so per-paycheck minimums
    /// are constant and the freed-minimum arithmetic is exact to the cent.
    ///
    /// Frost (23.00%) sits just under Aurora (24.00%): promoting it redirects
    /// ~$860 for a few paychecks at a ~1% APR differential, a couple of
    /// dollars of extra interest against a several-hundred-dollar baseline —
    /// inside G2. `frostAPR` lowered to 15% widens the differential to ~9%,
    /// pushing the delta well past 1% of baseline interest — outside G2.
    private func quickWinDebts(frostAPR: String = "0.2300", withLimits: Bool = true) -> [PlanningDebt] {
        [
            ScenarioFixtures.debt(1, name: "Aurora Card", balance: "8000.00", apr: "0.2400",
                                  minimum: "160.00", limit: withLimits ? "12000.00" : nil),
            ScenarioFixtures.debt(2, name: "Comet Auto Loan", type: .autoLoan, balance: "9000.00",
                                  apr: "0.0700", minimum: "200.00"),
            ScenarioFixtures.debt(3, name: "Frost Loan", type: .personalLoan, balance: "900.00",
                                  apr: frostAPR, minimum: "45.00")
        ]
    }

    private func quickWinSnapshot(frostAPR: String = "0.2300", withLimits: Bool = true) -> StoredPlanInput {
        ScenarioFixtures.snapshot(debts: quickWinDebts(frostAPR: frostAPR, withLimits: withLimits))
    }

    private var balancedDefinition: StoredScenarioDefinition {
        ScenarioFixtures.definition(.balanced)
    }

    /// The pure-avalanche Balanced baseline (B0) for a snapshot, computed the
    /// same way the selector computes it — so rationale figures can be
    /// reconciled against independent engine runs.
    private func baselineRun(_ snapshot: StoredPlanInput) throws -> PlanningResult {
        var b0 = snapshot
        b0.calculationVersion = PlanCalculationVersion.v4BalancedQuickWin.rawValue
        b0.scenario = balancedDefinition
        return try PlanGenerationService.generate(from: b0).result
    }

    private func promotedRun(_ snapshot: StoredPlanInput, promoting id: UUID) throws -> PlanningResult {
        var definition = balancedDefinition
        definition.quickWinPromotions = [id]
        var pinned = snapshot
        pinned.calculationVersion = PlanCalculationVersion.v4BalancedQuickWin.rawValue
        pinned.scenario = definition
        return try PlanGenerationService.generate(from: pinned).result
    }

    // MARK: - Selection outcomes

    func testAdmissibleQuickWinIsSelected() throws {
        let selection = try BalancedStrategySelector.select(
            snapshot: quickWinSnapshot(), definition: balancedDefinition
        )

        XCTAssertEqual(selection.rationale.selection, .quickWin)
        XCTAssertEqual(selection.rationale.promotedDebtID, ScenarioFixtures.debtID(3))
        XCTAssertEqual(selection.rationale.promotedDebtName, "Frost Loan")
        XCTAssertEqual(selection.pinnedPromotions, [ScenarioFixtures.debtID(3)])
        XCTAssertEqual(selection.result.currentTargetDebtID, ScenarioFixtures.debtID(3))
        XCTAssertNotNil(selection.result.minimumOnlyComparison,
                        "the returned winner must be a full engine run")
        XCTAssertTrue(selection.assumptionNotes.contains { $0.code == .quickWinSelected })
        ScenarioFixtures.assertReconciles(selection.result, "quick-win winner")
    }

    func testQuickWinRespectsTheGuardrailsItClaims() throws {
        let snapshot = quickWinSnapshot()
        let selection = try BalancedStrategySelector.select(
            snapshot: snapshot, definition: balancedDefinition
        )
        let baseline = try baselineRun(snapshot)

        // G1: payoff may slip at most one paycheck.
        XCTAssertLessThanOrEqual(
            selection.result.paycheckCount,
            baseline.paycheckCount + PlanContract.balancedQuickWinMaxDelayPaychecks
        )
        // G2: interest delta inside min(1% of baseline, $50).
        let delta = selection.result.estimatedTotalInterest - baseline.estimatedTotalInterest
        XCTAssertLessThanOrEqual(delta, min(
            PlanContract.balancedQuickWinMaxExtraInterestRate * baseline.estimatedTotalInterest,
            PlanContract.balancedQuickWinMaxExtraInterestCap
        ))
        // G3: the first account payoff strictly advances.
        let winnerFirst = try XCTUnwrap(BalancedStrategySelector.firstPayoffDate(of: selection.result))
        let baselineFirst = try XCTUnwrap(BalancedStrategySelector.firstPayoffDate(of: baseline))
        XCTAssertLessThan(winnerFirst, baselineFirst)
        // The promoted debt clears within the horizon.
        let cleared = try XCTUnwrap(
            selection.result.debtSummaries.first { $0.debtID == ScenarioFixtures.debtID(3) }?.payoffDate
        )
        let horizonDate = try XCTUnwrap(
            selection.result.paychecks.prefix(PlanContract.balancedQuickWinHorizonPaychecks).last?.date
        )
        XCTAssertLessThanOrEqual(cleared, horizonDate)
    }

    func testBadTradeoffKeepsTheAvalancheTarget() throws {
        // Same shape, but the small loan's APR is far below the card's: the
        // redirected dollars cost more than G2 allows, so Balanced stays the
        // strict avalanche — byte-identically.
        let snapshot = quickWinSnapshot(frostAPR: "0.1500")
        let selection = try BalancedStrategySelector.select(
            snapshot: snapshot, definition: balancedDefinition
        )

        XCTAssertEqual(selection.rationale.selection, .avalanche)
        XCTAssertNil(selection.rationale.promotedDebtID)
        XCTAssertGreaterThan(selection.rationale.candidatesConsidered, 0,
                             "the small loan is a candidate; the guardrails reject it")
        XCTAssertEqual(selection.rationale.interestDeltaVsAvalanche, 0)
        XCTAssertEqual(selection.rationale.payoffDelayPaychecks, 0)
        XCTAssertTrue(selection.pinnedPromotions.isEmpty)
        XCTAssertEqual(try bytes(selection.result), try bytes(baselineRun(snapshot)),
                       "rejecting every candidate must reproduce the pre-v0.4.0 Balanced exactly")
    }

    func testNoSmallDebtMeansNoCandidatesAndPureAvalanche() throws {
        let snapshot = ScenarioFixtures.snapshot(debts: [
            ScenarioFixtures.debt(1, name: "Aurora Card", balance: "8000.00", apr: "0.2400",
                                  minimum: "160.00", limit: "12000.00"),
            ScenarioFixtures.debt(2, name: "Comet Auto Loan", type: .autoLoan, balance: "9000.00",
                                  apr: "0.0700", minimum: "200.00")
        ])
        let selection = try BalancedStrategySelector.select(
            snapshot: snapshot, definition: balancedDefinition
        )
        XCTAssertEqual(selection.rationale.selection, .avalanche)
        XCTAssertEqual(selection.rationale.candidatesConsidered, 0)
        XCTAssertEqual(selection.result.currentTargetDebtID, ScenarioFixtures.debtID(1),
                       "strict avalanche: the higher APR stays the target")
    }

    func testFastestSafeIsUntouchedByTheSelector() throws {
        // The mathematically aggressive baseline stays pure R-08: highest APR
        // first, no promotion, no rationale.
        let results = try ScenarioCalculationService.scenarios(
            from: quickWinSnapshot(),
            definitions: ScenarioFixtures.allDefinitions()
        )
        let fastest = try XCTUnwrap(results.first { $0.kind == .fastestSafe })
        XCTAssertEqual(fastest.plan?.currentTargetDebtID, ScenarioFixtures.debtID(1))
        XCTAssertNil(fastest.balancedRationale)
        let cushion = try XCTUnwrap(results.first { $0.kind == .moreCushion })
        XCTAssertEqual(cushion.plan?.currentTargetDebtID, ScenarioFixtures.debtID(1))
        XCTAssertNil(cushion.balancedRationale)
    }

    // MARK: - Freed minimum flows onward (mission test 4)

    func testClearedQuickWinReleasesItsMinimumIntoExtraPrincipal() throws {
        let snapshot = quickWinSnapshot()
        let selection = try BalancedStrategySelector.select(
            snapshot: snapshot, definition: balancedDefinition
        )
        let baseline = try baselineRun(snapshot)
        let winner = selection.result

        let frost = ScenarioFixtures.debtID(3)
        let clearedOn = try XCTUnwrap(
            winner.debtSummaries.first { $0.debtID == frost }?.payoffDate
        )
        // Every minimum is entered and no debt has a due day, so per-paycheck
        // minimums are constant: after the quick win clears, the winner's rows
        // stop funding Frost's $45 and send exactly that much more as extra —
        // same debt budget, to the cent.
        let frostMinimum = TestSupport.money("45.00")
        for sequence in 2...3 {
            let winnerRow = try XCTUnwrap(winner.paychecks.first { $0.sequence == sequence })
            let baselineRow = try XCTUnwrap(baseline.paychecks.first { $0.sequence == sequence })
            XCTAssertGreaterThan(winnerRow.date, clearedOn)
            XCTAssertNil(winnerRow.payments.first { $0.debtID == frost },
                         "a cleared debt receives nothing")
            XCTAssertNotNil(baselineRow.payments.first { $0.debtID == frost && $0.minimum > 0 },
                            "the baseline is still funding the minimum here")
            XCTAssertEqual(winnerRow.minimumsTotal, baselineRow.minimumsTotal - frostMinimum)
            XCTAssertEqual(winnerRow.extraTotal, baselineRow.extraTotal + frostMinimum)
            XCTAssertEqual(winnerRow.debtBudget, baselineRow.debtBudget)
        }
        XCTAssertEqual(selection.rationale.releasedMinimumPerPaycheck, frostMinimum)
    }

    // MARK: - Guardrail boundaries (exact)

    func testDelayGuardrailBoundary() {
        XCTAssertTrue(BalancedStrategySelector.delayGuardrailSatisfied(
            candidatePaycheckCount: 40, baselinePaycheckCount: 40))
        XCTAssertTrue(BalancedStrategySelector.delayGuardrailSatisfied(
            candidatePaycheckCount: 41, baselinePaycheckCount: 40))
        XCTAssertFalse(BalancedStrategySelector.delayGuardrailSatisfied(
            candidatePaycheckCount: 42, baselinePaycheckCount: 40))
        XCTAssertTrue(BalancedStrategySelector.delayGuardrailSatisfied(
            candidatePaycheckCount: 38, baselinePaycheckCount: 40))
    }

    func testInterestGuardrailRateBoundary() {
        // 1% of $1,000.00 = $10.00 — below the $50 cap, so the rate binds.
        let baseline = TestSupport.money("1000.00")
        XCTAssertTrue(BalancedStrategySelector.interestGuardrailSatisfied(
            candidateInterest: TestSupport.money("1010.00"), baselineInterest: baseline))
        XCTAssertFalse(BalancedStrategySelector.interestGuardrailSatisfied(
            candidateInterest: TestSupport.money("1010.01"), baselineInterest: baseline))
        XCTAssertTrue(BalancedStrategySelector.interestGuardrailSatisfied(
            candidateInterest: TestSupport.money("900.00"), baselineInterest: baseline))
    }

    func testInterestGuardrailCapBoundary() {
        // 1% of $10,000.00 = $100 — the $50 cap binds instead.
        let baseline = TestSupport.money("10000.00")
        XCTAssertTrue(BalancedStrategySelector.interestGuardrailSatisfied(
            candidateInterest: TestSupport.money("10050.00"), baselineInterest: baseline))
        XCTAssertFalse(BalancedStrategySelector.interestGuardrailSatisfied(
            candidateInterest: TestSupport.money("10050.01"), baselineInterest: baseline))
    }

    func testInterestGuardrailZeroBaselineAdmitsOnlyZeroDelta() {
        // min(1% × 0, $50) = 0: a zero-interest baseline admits no added
        // interest at all — G2 never manufactures headroom.
        XCTAssertTrue(BalancedStrategySelector.interestGuardrailSatisfied(
            candidateInterest: .zero, baselineInterest: .zero))
        XCTAssertFalse(BalancedStrategySelector.interestGuardrailSatisfied(
            candidateInterest: TestSupport.money("0.01"), baselineInterest: .zero))
    }

    func testFirstPayoffGuardrailIsStrict() {
        let earlier = TestSupport.date(2027, 4, 9)
        let later = TestSupport.date(2027, 5, 7)
        XCTAssertTrue(BalancedStrategySelector.firstPayoffGuardrailSatisfied(
            candidateFirstPayoff: earlier, baselineFirstPayoff: later))
        XCTAssertFalse(BalancedStrategySelector.firstPayoffGuardrailSatisfied(
            candidateFirstPayoff: later, baselineFirstPayoff: earlier))
        XCTAssertFalse(BalancedStrategySelector.firstPayoffGuardrailSatisfied(
            candidateFirstPayoff: earlier, baselineFirstPayoff: earlier),
            "a tie is not an advance — G3 is strict")
        XCTAssertTrue(BalancedStrategySelector.firstPayoffGuardrailSatisfied(
            candidateFirstPayoff: earlier, baselineFirstPayoff: nil),
            "B0 clears nothing and the candidate does")
        XCTAssertFalse(BalancedStrategySelector.firstPayoffGuardrailSatisfied(
            candidateFirstPayoff: nil, baselineFirstPayoff: nil))
    }

    // MARK: - Lexicographic selection, every tie level (mission test 7)

    private func stats(
        _ index: Int,
        firstPayoff: Date,
        interest: String,
        debtFree: Date?,
        rank: Int
    ) -> BalancedStrategySelector.CandidateStats {
        BalancedStrategySelector.CandidateStats(
            debtID: ScenarioFixtures.debtID(index),
            debtName: "Debt \(index)",
            firstPayoffDate: firstPayoff,
            estimatedTotalInterest: TestSupport.money(interest),
            debtFreeDate: debtFree,
            attackRank: rank
        )
    }

    func testSelectionOrderResolvesAtEachLevelInTurn() {
        let d1 = TestSupport.date(2027, 4, 9)
        let d2 = TestSupport.date(2027, 4, 23)
        let d3 = TestSupport.date(2028, 1, 14)

        // Level 1: earliest first payoff.
        XCTAssertTrue(BalancedStrategySelector.precedes(
            stats(1, firstPayoff: d1, interest: "900.00", debtFree: d3, rank: 5),
            stats(2, firstPayoff: d2, interest: "100.00", debtFree: d3, rank: 0)))
        // Level 2: lowest estimated interest.
        XCTAssertTrue(BalancedStrategySelector.precedes(
            stats(1, firstPayoff: d1, interest: "500.00", debtFree: d3, rank: 5),
            stats(2, firstPayoff: d1, interest: "500.01", debtFree: d3, rank: 0)))
        // Level 3: earliest debt-free date; a finished plan precedes an
        // unfinished one.
        XCTAssertTrue(BalancedStrategySelector.precedes(
            stats(1, firstPayoff: d1, interest: "500.00", debtFree: d2, rank: 5),
            stats(2, firstPayoff: d1, interest: "500.00", debtFree: d3, rank: 0)))
        XCTAssertTrue(BalancedStrategySelector.precedes(
            stats(1, firstPayoff: d1, interest: "500.00", debtFree: d3, rank: 5),
            stats(2, firstPayoff: d1, interest: "500.00", debtFree: nil, rank: 0)))
        // Level 4: earliest R-08 rank at plan start.
        XCTAssertTrue(BalancedStrategySelector.precedes(
            stats(1, firstPayoff: d1, interest: "500.00", debtFree: d3, rank: 1),
            stats(2, firstPayoff: d1, interest: "500.00", debtFree: d3, rank: 2)))
        // Level 5: UUID string — total order, no unstable tie remains.
        let a = stats(1, firstPayoff: d1, interest: "500.00", debtFree: d3, rank: 1)
        let b = stats(2, firstPayoff: d1, interest: "500.00", debtFree: d3, rank: 1)
        XCTAssertEqual(BalancedStrategySelector.precedes(a, b),
                       a.debtID.uuidString < b.debtID.uuidString)
        XCTAssertFalse(BalancedStrategySelector.precedes(a, a))
    }

    // MARK: - R-25 pre-filter over-inclusion proof

    func testPreFilterExcludesOnlyDebtsThatTrulyCannotRetireInTime() throws {
        let snapshot = quickWinSnapshot()
        let baseline = try baselineRun(snapshot)

        // The big auto loan sits far above the optimistic bound…
        let cometBound = BalancedStrategySelector.optimisticPayoffBound(
            for: ScenarioFixtures.debtID(2), in: baseline
        )
        XCTAssertGreaterThan(TestSupport.money("9000.00"), cometBound)

        // …and force-simulating its promotion proves the exclusion honest:
        // even with every extra dollar, it does not retire inside the horizon.
        let forced = try promotedRun(snapshot, promoting: ScenarioFixtures.debtID(2))
        let payoff = forced.debtSummaries.first { $0.debtID == ScenarioFixtures.debtID(2) }?.payoffDate
        let horizonDate = try XCTUnwrap(
            forced.paychecks.prefix(PlanContract.balancedQuickWinHorizonPaychecks).last?.date
        )
        XCTAssertTrue(payoff == nil || payoff! > horizonDate,
                      "the interest-ignoring bound may only over-include, never exclude a true candidate")

        // The small loan passes the same bound — the pre-filter kept it.
        let frostBound = BalancedStrategySelector.optimisticPayoffBound(
            for: ScenarioFixtures.debtID(3), in: baseline
        )
        XCTAssertLessThanOrEqual(TestSupport.money("900.00"), frostBound)
    }

    // MARK: - Rationale figures reconcile to their engine runs (mission test 6)

    func testRationaleFiguresMatchIndependentEngineRuns() throws {
        let snapshot = quickWinSnapshot()
        let selection = try BalancedStrategySelector.select(
            snapshot: snapshot, definition: balancedDefinition
        )
        let baseline = try baselineRun(snapshot)
        let winner = try promotedRun(snapshot, promoting: ScenarioFixtures.debtID(3))

        XCTAssertEqual(try bytes(selection.result), try bytes(winner),
                       "the selection is exactly the pinned promotion's engine run")
        XCTAssertEqual(selection.rationale.interestDeltaVsAvalanche,
                       winner.estimatedTotalInterest - baseline.estimatedTotalInterest)
        XCTAssertEqual(selection.rationale.payoffDelayPaychecks,
                       winner.paycheckCount - baseline.paycheckCount)
        let winnerFirst = try XCTUnwrap(BalancedStrategySelector.firstPayoffDate(of: winner))
        let baselineFirst = try XCTUnwrap(BalancedStrategySelector.firstPayoffDate(of: baseline))
        XCTAssertEqual(selection.rationale.firstPayoffAdvanceDays,
                       DateMath.days(from: winnerFirst, to: baselineFirst))
        if selection.rationale.interestDeltaVsAvalanche > 0 {
            XCTAssertTrue(selection.warningNotes.contains { $0.code == .quickWinCostsMoreInterest },
                          "a costlier quick win must disclose its amount")
        }
    }

    // MARK: - Determinism (mission tests 5 and 7)

    func testSelectionIsDeterministicAcrossRepeatedRuns() throws {
        let snapshot = quickWinSnapshot()
        let first = try BalancedStrategySelector.select(snapshot: snapshot, definition: balancedDefinition)
        let second = try BalancedStrategySelector.select(snapshot: snapshot, definition: balancedDefinition)
        XCTAssertEqual(first.rationale, second.rationale)
        XCTAssertEqual(try bytes(first.result), try bytes(second.result))

        let scenariosFirst = try ScenarioCalculationService.scenarios(
            from: snapshot, definitions: ScenarioFixtures.allDefinitions())
        let scenariosSecond = try ScenarioCalculationService.scenarios(
            from: snapshot, definitions: ScenarioFixtures.allDefinitions())
        XCTAssertEqual(try bytes(scenariosFirst), try bytes(scenariosSecond))
    }

    // MARK: - Unknown limits never fabricate a benefit (mission test 8)

    func testUnknownCreditLimitsDoNotChangeTheSelectionOrItsStory() throws {
        let with = try BalancedStrategySelector.select(
            snapshot: quickWinSnapshot(withLimits: true), definition: balancedDefinition)
        let without = try BalancedStrategySelector.select(
            snapshot: quickWinSnapshot(withLimits: false), definition: balancedDefinition)

        XCTAssertEqual(with.rationale, without.rationale,
                       "utilization is never a selection input; missing limits change nothing")
        for explanation in without.rationale.explanations {
            XCTAssertFalse(explanation.localizedCaseInsensitiveContains("utilization"),
                           "no utilization claim without data")
        }
    }

    // MARK: - The scenario surface carries the rationale

    func testScenarioResultCarriesTheRationaleAndItsNotes() throws {
        let results = try ScenarioCalculationService.scenarios(
            from: quickWinSnapshot(), definitions: ScenarioFixtures.allDefinitions())
        let balanced = try XCTUnwrap(results.first { $0.kind == .balanced })
        let rationale = try XCTUnwrap(balanced.balancedRationale)
        XCTAssertEqual(rationale.selection, .quickWin)
        XCTAssertFalse(rationale.explanations.isEmpty)
        XCTAssertTrue(balanced.assumptions.contains { $0.code == .quickWinSelected })
        XCTAssertEqual(balanced.deltaVsBalanced?.interestDelta, 0,
                       "cross-scenario deltas stay measured against the selected Balanced")
        XCTAssertEqual(balanced.plan?.calculationVersion, .v4BalancedQuickWin)
    }

    // MARK: - Preview purity and apply-time pinning (mission tests 11–13)

    @MainActor
    func testPreviewWritesNothingAndApplyPinsThePromotion() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let snapshot = quickWinSnapshot()

        let results = try ScenarioCalculationService.scenarios(
            from: snapshot, definitions: ScenarioFixtures.allDefinitions())
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), 0,
                       "previewing runs the selector and persists nothing (R-15/V3-15)")

        let balanced = try XCTUnwrap(results.first { $0.kind == .balanced })
        let service = ScenarioPlanActivationService(context: context)
        let plan = try service.apply(
            result: balanced, definition: balancedDefinition, baseInput: snapshot
        )

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), 1)
        XCTAssertEqual(plan.calculationVersion, 4)
        XCTAssertEqual(plan.scenarioKind, .scenario)
        XCTAssertEqual(plan.effectiveDate, balancedDefinition.effectiveDate,
                       "applying keeps the future-effective plan-version model")

        // The pinned promotion is in the snapshot, so regeneration re-runs
        // the engine — never the selector — and reproduces the applied plan.
        let stored = try GeneratedPlanService.storedInput(for: plan)
        XCTAssertEqual(stored.scenario?.quickWinPromotions, [ScenarioFixtures.debtID(3)])
        XCTAssertEqual(stored.calculationVersion, 4)

        let regenerated = try XCTUnwrap(PlanGenerationService.regenerate(from: plan))
        XCTAssertEqual(try bytes(regenerated.result), try bytes(try XCTUnwrap(balanced.plan)),
                       "the applied plan reproduces the previewed projection exactly")
    }

    @MainActor
    func testEverySurfaceResolvesTheSameTargetFromTheSameSnapshot() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let snapshot = quickWinSnapshot()

        let results = try ScenarioCalculationService.scenarios(
            from: snapshot, definitions: ScenarioFixtures.allDefinitions())
        let balanced = try XCTUnwrap(results.first { $0.kind == .balanced })
        let plan = try ScenarioPlanActivationService(context: context).apply(
            result: balanced, definition: balancedDefinition, baseInput: snapshot
        )

        // One source of truth: the plan screen and Today both read the stored
        // graph, and insights regenerate from the snapshot — all three must
        // name the same promoted target with the same reason metadata.
        let promoted = ScenarioFixtures.debtID(3)
        XCTAssertEqual(balanced.plan?.currentTargetDebtID, promoted)

        let regenerated = try XCTUnwrap(
            GeneratedPlanService(context: context, dateProvider: SystemDateProvider())
                .baselineResult(for: plan)
        )
        XCTAssertEqual(regenerated.currentTargetDebtID, promoted)
        XCTAssertTrue(regenerated.recommendationReasons.contains(.quickWinPromotion))
        XCTAssertEqual(regenerated.payoffOrder.first, promoted)

        let planID = plan.id
        let items = try context.fetch(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
        ).sorted { $0.sequenceNumber < $1.sequenceNumber }
        XCTAssertEqual(items.first?.plannedTargetDebtID, "D3",
                       "the stored plan rows Today reads carry the promoted target")
        XCTAssertEqual(plan.avalancheOrder.first, "D3",
                       "the stored display order leads with the promoted debt")
    }

    // MARK: - Benchmark (R-27 — reported in the agent report)

    func testEightDebtBalancedSelectionBenchmark() throws {
        // Eight fictional debts: several small quick-win candidates so the
        // selector actually simulates a fleet of candidates.
        let debts: [PlanningDebt] = [
            ScenarioFixtures.debt(1, name: "Card A", balance: "7500.00", apr: "0.2799",
                                  minimum: "150.00", limit: "10000.00"),
            ScenarioFixtures.debt(2, name: "Card B", balance: "5200.00", apr: "0.2450",
                                  minimum: "110.00", limit: "8000.00"),
            ScenarioFixtures.debt(3, name: "Card C", balance: "1150.00", apr: "0.2299",
                                  minimum: "40.00", limit: "3000.00"),
            ScenarioFixtures.debt(4, name: "Card D", balance: "800.00", apr: "0.2199",
                                  minimum: "35.00", limit: "2000.00"),
            ScenarioFixtures.debt(5, name: "Loan E", type: .personalLoan, balance: "600.00",
                                  apr: "0.2100", minimum: "55.00"),
            ScenarioFixtures.debt(6, name: "Loan F", type: .personalLoan, balance: "3000.00",
                                  apr: "0.1200", minimum: "90.00"),
            ScenarioFixtures.debt(7, name: "Auto G", type: .autoLoan, balance: "8800.00",
                                  apr: "0.0699", minimum: "230.00"),
            ScenarioFixtures.debt(8, name: "Student H", type: .studentLoan, balance: "6400.00",
                                  apr: "0.0550", minimum: "120.00")
        ]
        let snapshot = ScenarioFixtures.snapshot(takeHome: "3100.00", debts: debts)

        let selectorStart = Date()
        let selection = try BalancedStrategySelector.select(
            snapshot: snapshot, definition: balancedDefinition
        )
        let selectorElapsed = Date().timeIntervalSince(selectorStart)

        let scenariosStart = Date()
        _ = try ScenarioCalculationService.scenarios(
            from: snapshot, definitions: ScenarioFixtures.allDefinitions())
        let scenariosElapsed = Date().timeIntervalSince(scenariosStart)

        print("[benchmark] 8 debts — Balanced selector alone: \(String(format: "%.3f", selectorElapsed))s (candidates simulated: \(selection.rationale.candidatesConsidered)+, selection: \(selection.rationale.selection)); all three scenario cards incl. selector: \(String(format: "%.3f", scenariosElapsed))s")

        // Order-of-magnitude backstop only — simulator jitter is not policed.
        XCTAssertLessThan(selectorElapsed, 30)
        XCTAssertLessThan(scenariosElapsed, 60)
    }
}
