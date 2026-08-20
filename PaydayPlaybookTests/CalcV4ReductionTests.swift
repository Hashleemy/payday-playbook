import XCTest
@testable import PaydayPlaybook

/// T-20 (reduction half) — calc v4 must be calc v3 plus the quick-win
/// promotion input and nothing else.
///
/// With `quickWinPromotions` empty, a v4 run is byte-identical to a v3 run
/// apart from the version stamp, and the chain continues: v4 with no scenario
/// and no extras reproduces v2 exactly (v2 → v1 stays pinned by the parity
/// suites). Promotions on an input stamped below v4 are a loud validation
/// error, never a silent ignore. Snapshot bytes without promotions are
/// unchanged, so every stored calc-2/3 plan keeps decoding — and reproducing —
/// exactly as before.
///
/// Every fixture value is invented (V3-12).
final class CalcV4ReductionTests: XCTestCase {

    private static let stableEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private func bytes(_ result: PlanningResult) throws -> Data {
        try Self.stableEncoder.encode(result)
    }

    // MARK: - Reduction chain

    func testCalcV4WithoutPromotionsIsByteIdenticalToCalcV3() throws {
        var v3Input = try PlanGenerationService.engineInput(
            from: ScenarioFixtures.snapshot(scenario: ScenarioFixtures.definition(.balanced))
        )
        v3Input.calculationVersion = .v3Scenario
        var v4Input = v3Input
        v4Input.calculationVersion = .v4BalancedQuickWin

        let v3 = try AvalanchePlanEngine.generatePlan(v3Input)
        var v4 = try AvalanchePlanEngine.generatePlan(v4Input)

        XCTAssertEqual(v3.calculationVersion, .v3Scenario)
        XCTAssertEqual(v4.calculationVersion, .v4BalancedQuickWin)

        // The stamp is the only permitted difference.
        v4.calculationVersion = .v3Scenario
        XCTAssertEqual(try bytes(v4), try bytes(v3),
                       "calc v4 changed the plan without a quick-win promotion")
    }

    func testCalcV4WithoutScenarioOrExtrasIsByteIdenticalToCalcV2() throws {
        var v2Input = try PlanGenerationService.engineInput(from: ScenarioFixtures.snapshot())
        v2Input.calculationVersion = .v2Avalanche
        var v4Input = v2Input
        v4Input.calculationVersion = .v4BalancedQuickWin

        let v2 = try AvalanchePlanEngine.generatePlan(v2Input)
        var v4 = try AvalanchePlanEngine.generatePlan(v4Input)

        XCTAssertEqual(v4.calculationVersion, .v4BalancedQuickWin)
        v4.calculationVersion = .v2Avalanche
        XCTAssertEqual(try bytes(v4), try bytes(v2),
                       "calc v4 with no scenario and no extras must reduce to calc v2 (V2-10)")
    }

    // MARK: - Version inference and the promotion gate

    func testSnapshotStampedFourInfersCalcV4() throws {
        let input = try PlanGenerationService.engineInput(
            from: ScenarioFixtures.snapshot(calculationVersion: 4)
        )
        XCTAssertEqual(input.calculationVersion, .v4BalancedQuickWin)
        XCTAssertEqual(try AvalanchePlanEngine.generatePlan(input).calculationVersion,
                       .v4BalancedQuickWin)
    }

    func testV3StampedSnapshotStillInfersCalcV3() throws {
        // A stored v0.3.0 plan must keep reaching the engine as v3 — the
        // "prior calculation-version plan reproduces the prior result" half
        // of the dispatch contract (the value identity is the reduction
        // above; the stamp identity is this).
        let scenario = ScenarioFixtures.snapshot(
            calculationVersion: 3,
            scenario: ScenarioFixtures.definition(.balanced)
        )
        XCTAssertEqual(try PlanGenerationService.engineInput(from: scenario).calculationVersion,
                       .v3Scenario)
        XCTAssertEqual(try PlanGenerationService.generate(from: scenario).result.calculationVersion,
                       .v3Scenario)
    }

    func testPromotionsOnAV3StampedInputAreALoudValidationError() throws {
        var definition = ScenarioFixtures.definition(.balanced)
        definition.quickWinPromotions = [ScenarioFixtures.debtID(2)]

        var input = try PlanGenerationService.engineInput(
            from: ScenarioFixtures.snapshot(calculationVersion: 4, scenario: definition)
        )
        input.calculationVersion = .v3Scenario
        XCTAssertThrowsError(try AvalanchePlanEngine.generatePlan(input)) { error in
            XCTAssertEqual(error as? AvalanchePlanEngine.PlanningValidationError,
                           .promotionsRequireCalcV4)
        }

        // And through the snapshot path: a v3-stamped snapshot carrying a
        // promotion is rejected, never silently ignored or silently upgraded.
        let snapshot = ScenarioFixtures.snapshot(calculationVersion: 3, scenario: definition)
        XCTAssertThrowsError(try PlanGenerationService.generate(from: snapshot))
    }

    func testPromotionsOnAV4StampedInputAreAccepted() throws {
        var definition = ScenarioFixtures.definition(.balanced)
        definition.quickWinPromotions = [ScenarioFixtures.debtID(2)]
        let result = try PlanGenerationService.generate(
            from: ScenarioFixtures.snapshot(calculationVersion: 4, scenario: definition)
        ).result
        XCTAssertEqual(result.calculationVersion, .v4BalancedQuickWin)
        ScenarioFixtures.assertReconciles(result, "promoted run")
    }

    // MARK: - Promotion mechanics

    func testPromotedDebtLeadsTheAttackAndPayoffOrder() throws {
        var definition = ScenarioFixtures.definition(.balanced)
        definition.quickWinPromotions = [ScenarioFixtures.debtID(2)]
        let promoted = try PlanGenerationService.generate(
            from: ScenarioFixtures.snapshot(calculationVersion: 4, scenario: definition)
        ).result

        XCTAssertEqual(promoted.currentTargetDebtID, ScenarioFixtures.debtID(2),
                       "the promoted debt receives extra principal first")
        XCTAssertEqual(promoted.payoffOrder.first, ScenarioFixtures.debtID(2),
                       "the promoted debt leads the assembled payoff order")
        let firstExtras = promoted.paychecks[0].payments.filter { $0.extra > 0 }
        XCTAssertTrue(
            firstExtras.contains { $0.debtID == ScenarioFixtures.debtID(2) && $0.reasons.contains(.quickWinPromotion) },
            "promoted payments carry the quickWinPromotion reason code (R-27)"
        )
    }

    func testPromotionNeverTouchesMinimumsReservesOrRetention() throws {
        var definition = ScenarioFixtures.definition(.balanced)
        definition.quickWinPromotions = [ScenarioFixtures.debtID(2)]
        let baseline = try PlanGenerationService.generate(
            from: ScenarioFixtures.snapshot(calculationVersion: 4,
                                            scenario: ScenarioFixtures.definition(.balanced))
        ).result
        let promoted = try PlanGenerationService.generate(
            from: ScenarioFixtures.snapshot(calculationVersion: 4, scenario: definition)
        ).result

        // R-25: only the destination of extra principal may move. On the
        // first paycheck the two runs share identical balances, so their
        // funding lanes must agree to the cent.
        let baselineFirst = try XCTUnwrap(baseline.paychecks.first)
        let promotedFirst = try XCTUnwrap(promoted.paychecks.first)
        XCTAssertEqual(promotedFirst.minimumsTotal, baselineFirst.minimumsTotal)
        XCTAssertEqual(promotedFirst.obligationReserveTotal, baselineFirst.obligationReserveTotal)
        XCTAssertEqual(promotedFirst.allowanceReserved, baselineFirst.allowanceReserved)
        XCTAssertEqual(promotedFirst.floorTopUp, baselineFirst.floorTopUp)
        XCTAssertEqual(promotedFirst.scenarioCashRetained, baselineFirst.scenarioCashRetained)
        XCTAssertEqual(promotedFirst.extraTotal, baselineFirst.extraTotal)
        XCTAssertNotEqual(promotedFirst.targetDebtID, baselineFirst.targetDebtID,
                          "the fixture should actually reorder the attack")
        ScenarioFixtures.assertReconciles(promoted, "promoted")
    }

    func testIneligiblePromotionIsANoOpWithAWarning() throws {
        let debts = [
            ScenarioFixtures.debt(1, name: "Aurora Card", balance: "2400.00", apr: "0.2450",
                                  dueDay: 14, limit: "5000.00"),
            ScenarioFixtures.debt(2, name: "Frost Loan", type: .personalLoan, balance: "700.00",
                                  apr: "0.0999", minimum: "60.00", prepayment: .ineligible)
        ]
        var promotedDefinition = ScenarioFixtures.definition(.balanced)
        promotedDefinition.quickWinPromotions = [ScenarioFixtures.debtID(2)]

        let plain = try PlanGenerationService.generate(
            from: ScenarioFixtures.snapshot(calculationVersion: 4, debts: debts,
                                            scenario: ScenarioFixtures.definition(.balanced))
        ).result
        var promoted = try PlanGenerationService.generate(
            from: ScenarioFixtures.snapshot(calculationVersion: 4, debts: debts,
                                            scenario: promotedDefinition)
        ).result

        XCTAssertTrue(promoted.warnings.contains {
            $0.code == .quickWinPromotionIneligible && $0.debtID == ScenarioFixtures.debtID(2)
        }, "an ineligible promotion warns instead of reordering")

        // Apart from that warning, the output is byte-identical: the no-op is
        // genuinely a no-op.
        promoted.warnings.removeAll { $0.code == .quickWinPromotionIneligible }
        XCTAssertEqual(try bytes(promoted), try bytes(plain))
    }

    func testUnknownPromotedIDIsANoOpWithAWarning() throws {
        var definition = ScenarioFixtures.definition(.balanced)
        definition.quickWinPromotions = [UUID(uuidString: "00000000-0000-0000-0009-000000000009")!]
        var promoted = try PlanGenerationService.generate(
            from: ScenarioFixtures.snapshot(calculationVersion: 4, scenario: definition)
        ).result
        let plain = try PlanGenerationService.generate(
            from: ScenarioFixtures.snapshot(calculationVersion: 4,
                                            scenario: ScenarioFixtures.definition(.balanced))
        ).result

        XCTAssertTrue(promoted.warnings.contains { $0.code == .quickWinPromotionIneligible })
        promoted.warnings.removeAll { $0.code == .quickWinPromotionIneligible }
        XCTAssertEqual(try bytes(promoted), try bytes(plain))
    }

    // MARK: - Internal engine option (R-27 performance)

    func testSkippingTheMinimumOnlyComparisonChangesNothingElse() throws {
        let input = try PlanGenerationService.engineInput(
            from: ScenarioFixtures.snapshot(calculationVersion: 4,
                                            scenario: ScenarioFixtures.definition(.balanced))
        )
        var full = try AvalanchePlanEngine.generatePlan(input, includeMinimumOnlyComparison: true)
        let skipped = try AvalanchePlanEngine.generatePlan(input, includeMinimumOnlyComparison: false)

        XCTAssertNotNil(full.minimumOnlyComparison)
        XCTAssertNil(skipped.minimumOnlyComparison)
        // The option's whole scope: the comparison object and its
        // availability notes. The projection itself must be untouched.
        full.minimumOnlyComparison = nil
        full.warnings.removeAll {
            $0.code == .minimumOnlyUnavailable || $0.code == .minimumOnlyNeverFinishes
        }
        XCTAssertEqual(try bytes(full), try bytes(skipped),
                       "the skip option may omit the comparison and nothing else")
    }

    // MARK: - Snapshot compatibility

    func testSnapshotWithoutPromotionsGainsNoKey() throws {
        let snapshot = ScenarioFixtures.snapshot(
            calculationVersion: 3,
            scenario: ScenarioFixtures.definition(.balanced)
        )
        let data = try PlanningSnapshotCoder.encode(snapshot)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"quickWinPromotions\""),
                       "a calc-v3 snapshot must not gain a promotions key")

        let decoded = try PlanningSnapshotCoder.decode(data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.scenario?.quickWinPromotions, [])
    }

    func testPinnedSnapshotRoundTripsThroughTheCoder() throws {
        var definition = ScenarioFixtures.definition(.balanced)
        definition.quickWinPromotions = [ScenarioFixtures.debtID(2)]
        let snapshot = ScenarioFixtures.snapshot(calculationVersion: 4, scenario: definition)

        let decoded = try PlanningSnapshotCoder.decode(PlanningSnapshotCoder.encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.scenario?.quickWinPromotions, [ScenarioFixtures.debtID(2)])
    }

    func testEngineScenarioInputDecodesPayloadsWithoutThePromotionKey() throws {
        let input = try PlanGenerationService.engineInput(
            from: ScenarioFixtures.snapshot(scenario: ScenarioFixtures.definition(.balanced))
        )
        let data = try Self.stableEncoder.encode(input)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"quickWinPromotions\""),
                       "an unpromoted engine payload must not gain the key")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PlanningInput.self, from: data)
        XCTAssertEqual(decoded.scenario?.quickWinPromotions, [])
        XCTAssertEqual(decoded, input)
    }

    // MARK: - Determinism (R-22 extended)

    func testPromotedRunsAreByteIdenticalAcrossRepeats() throws {
        var definition = ScenarioFixtures.definition(.balanced)
        definition.quickWinPromotions = [ScenarioFixtures.debtID(2)]
        let snapshot = ScenarioFixtures.snapshot(calculationVersion: 4, scenario: definition)
        let first = try PlanGenerationService.generate(from: snapshot).result
        let second = try PlanGenerationService.generate(from: snapshot).result
        XCTAssertEqual(try bytes(first), try bytes(second))
    }
}
