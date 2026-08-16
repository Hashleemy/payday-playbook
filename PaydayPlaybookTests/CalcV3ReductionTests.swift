import XCTest
@testable import PaydayPlaybook

/// T-5 — engine reduction and reconciliation.
///
/// Calc v3 must be calc v2 plus R-17…R-24 and nothing else: with no scenario
/// constraints and no extra payments its output is byte-identical apart from
/// the version stamp. The four R-16 identities must survive on every scenario
/// and insight result.
///
/// The v2 → v1 reduction is unchanged by this work and stays pinned by
/// `AvalancheLemParityTests`, which runs in the same suite.
final class CalcV3ReductionTests: XCTestCase {

    private static let stableEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private func bytes(_ result: PlanningResult) throws -> Data {
        try Self.stableEncoder.encode(result)
    }

    // MARK: - Reduction

    func testCalcV3WithoutScenarioOrExtrasIsByteIdenticalToCalcV2() throws {
        var v2Input = try PlanGenerationService.engineInput(from: ScenarioFixtures.snapshot())
        v2Input.calculationVersion = .v2Avalanche
        var v3Input = v2Input
        v3Input.calculationVersion = .v3Scenario

        let v2 = try AvalanchePlanEngine.generatePlan(v2Input)
        var v3 = try AvalanchePlanEngine.generatePlan(v3Input)

        XCTAssertEqual(v2.calculationVersion, .v2Avalanche)
        XCTAssertEqual(v3.calculationVersion, .v3Scenario)

        // The stamp is the only permitted difference.
        v3.calculationVersion = .v2Avalanche
        XCTAssertEqual(try bytes(v3), try bytes(v2),
                       "calc v3 changed the plan without a scenario or an extra payment")
    }

    func testStoredSnapshotWithoutScenarioStampsCalcV2() throws {
        let plain = try PlanGenerationService.generate(from: ScenarioFixtures.snapshot())
        XCTAssertEqual(plain.result.calculationVersion, .v2Avalanche)

        // A snapshot carrying a scenario is stamped v3 even if its stored
        // version column still says 2 — the input decides, not the column.
        let scenario = ScenarioFixtures.snapshot(scenario: ScenarioFixtures.definition(.balanced))
        XCTAssertEqual(try PlanGenerationService.generate(from: scenario).result.calculationVersion,
                       .v3Scenario)

        let extras = ScenarioFixtures.snapshot(extraPayments: [ScenarioFixtures.extraPayment()])
        XCTAssertEqual(try PlanGenerationService.generate(from: extras).result.calculationVersion,
                       .v3Scenario)
    }

    func testZeroAmountExtraPaymentChangesNothing() throws {
        let plain = try PlanGenerationService.generate(from: ScenarioFixtures.snapshot()).result
        let withZero = try PlanGenerationService.generate(
            from: ScenarioFixtures.snapshot(
                extraPayments: [ScenarioFixtures.extraPayment(amount: "0.00")])
        ).result

        XCTAssertEqual(withZero.forecastPayoffDate, plain.forecastPayoffDate)
        XCTAssertEqual(withZero.estimatedTotalInterest, plain.estimatedTotalInterest)
    }

    // MARK: - Determinism (R-22)

    func testRepeatedRunsAreByteIdentical() throws {
        let snapshot = ScenarioFixtures.snapshot(
            scenario: ScenarioFixtures.definition(.moreCushion),
            extraPayments: [
                ScenarioFixtures.extraPayment(1, kind: .recurringPerPaycheck, amount: "75.00"),
                ScenarioFixtures.extraPayment(2, kind: .recurringMonthly, amount: "120.00")
            ]
        )
        let first = try PlanGenerationService.generate(from: snapshot).result
        let second = try PlanGenerationService.generate(from: snapshot).result
        XCTAssertEqual(try bytes(first), try bytes(second))
    }

    func testExtraPaymentOrderInTheInputDoesNotChangeTheResult() throws {
        let a = ScenarioFixtures.extraPayment(1, amount: "300.00")
        let b = ScenarioFixtures.extraPayment(2, amount: "300.00")
        let forward = try PlanGenerationService.generate(
            from: ScenarioFixtures.snapshot(extraPayments: [a, b])).result
        let reversed = try PlanGenerationService.generate(
            from: ScenarioFixtures.snapshot(extraPayments: [b, a])).result
        XCTAssertEqual(try bytes(forward), try bytes(reversed))
    }

    // MARK: - R-16 identities across calc-v3 surfaces

    func testIdentitiesHoldOnEveryScenarioResult() throws {
        let results = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(),
            definitions: ScenarioFixtures.allDefinitions()
        )
        XCTAssertEqual(results.count, 3)
        for result in results {
            let plan = try XCTUnwrap(result.plan, "\(result.kind) should be computable")
            ScenarioFixtures.assertReconciles(plan, "\(result.kind)")
        }
    }

    func testIdentitiesHoldOnEveryInsightProjection() throws {
        let kinds: [ExtraPaymentKind] = [.oneTime, .recurringPerPaycheck, .recurringMonthly]
        for (index, kind) in kinds.enumerated() {
            let extra = ScenarioFixtures.extraPayment(index + 1, kind: kind, amount: "180.00")
            let withExtra = ScenarioFixtures.snapshot(extraPayments: [extra])
            let plan = try PlanGenerationService.generate(from: withExtra).result
            ScenarioFixtures.assertReconciles(plan, "extra \(kind)")
        }
    }

    func testIdentitiesHoldUnderShortfallWithScenarioConstraints() throws {
        // Income that cannot cover the floor top-up, the bill, and the
        // minimums: the scenario must not manufacture retained cash out of a
        // gap, and the row must still reconcile.
        let snapshot = ScenarioFixtures.snapshot(
            takeHome: "400.00",
            startingBalance: "0.00",
            protectedFloor: "1500.00",
            scenario: ScenarioFixtures.definition(.moreCushion)
        )
        let plan = try PlanGenerationService.generate(from: snapshot).result
        ScenarioFixtures.assertReconciles(plan, "shortfall")

        let shortfallRows = plan.paychecks.filter { ($0.shortfall?.gap ?? 0) > 0 }
        XCTAssertFalse(shortfallRows.isEmpty, "the fixture should actually be short")
        for row in shortfallRows {
            XCTAssertEqual(row.scenarioCashRetained, 0,
                           "a shortfall paycheck must not retain scenario cash")
        }
    }

    // MARK: - Snapshot compatibility

    func testCalcV2SnapshotBytesAreUnchangedByTheNewKeys() throws {
        let snapshot = ScenarioFixtures.snapshot()
        let data = try PlanningSnapshotCoder.encode(snapshot)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"scenario\""),
                       "a plain snapshot must not gain a scenario key")
        XCTAssertFalse(json.contains("\"extraPayments\""),
                       "a plain snapshot must not gain an extraPayments key")
        XCTAssertEqual(try PlanningSnapshotCoder.decode(data), snapshot)
    }

    func testScenarioSnapshotRoundTripsThroughTheCoder() throws {
        let snapshot = ScenarioFixtures.snapshot(
            calculationVersion: 3,
            scenario: ScenarioFixtures.definition(
                .moreCushion,
                incomeOverride: StoredIncomeOverride(
                    amount: TestSupport.money("2650.00"),
                    cadence: .semimonthly,
                    monthlyPayDay: nil,
                    semimonthlyPayDay1: 15,
                    semimonthlyPayDay2: 31,
                    effectiveDate: TestSupport.date(2027, 5, 15)
                ),
                extraPaymentCeiling: "400.00"
            ),
            extraPayments: [
                ScenarioFixtures.extraPayment(1, kind: .recurringMonthly, amount: "125.00",
                                              targetDebtID: ScenarioFixtures.debtID(2),
                                              sourceAccountID: ScenarioFixtures.sourceAccountID)
            ]
        )
        let decoded = try PlanningSnapshotCoder.decode(PlanningSnapshotCoder.encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
    }

    func testEngineInputRoundTripsThroughCodable() throws {
        let input = try PlanGenerationService.engineInput(
            from: ScenarioFixtures.snapshot(
                scenario: ScenarioFixtures.definition(.balanced),
                extraPayments: [ScenarioFixtures.extraPayment()]
            )
        )
        let data = try Self.stableEncoder.encode(input)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(PlanningInput.self, from: data), input)
    }

    func testPlanningInputDecodesPayloadsWithoutTheCalcV3Keys() throws {
        // A calc-v2 payload carries neither key. Both must default rather than
        // fail the decode, or older encoded inputs stop round-tripping.
        let input = try PlanGenerationService.engineInput(from: ScenarioFixtures.snapshot())
        let data = try Self.stableEncoder.encode(input)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "scenario")
        object.removeValue(forKey: "extraPayments")
        object.removeValue(forKey: "calculationVersion")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            PlanningInput.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.scenario)
        XCTAssertTrue(decoded.extraPayments.isEmpty)
        XCTAssertEqual(decoded.calculationVersion, .v2Avalanche)
        // Identity only: re-serializing through `JSONSerialization` renders
        // `Decimal` values via `Double`, so amounts are not comparable here.
        // Byte-exact money is the persistence layer's contract, and
        // `PlanningSnapshotCoder` keeps it by encoding money as strings.
        XCTAssertEqual(decoded.debts.map(\.id), input.debts.map(\.id))
        XCTAssertEqual(decoded.debts.map(\.name), input.debts.map(\.name))
    }
}
