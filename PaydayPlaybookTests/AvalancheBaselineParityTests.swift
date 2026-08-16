import XCTest
@testable import PaydayPlaybook

/// V2-10 / required v0.2 test 3: the calc-v2 generator and the frozen calc-v1
/// engine must agree, check by check, when fed equivalent inputs — and the
/// legacy engine must keep producing its result untouched (mission test 17).
///
/// The inputs are `PlanningFixtures.baselineInput()`, which is invented. The
/// parity property is about the two engines agreeing with *each other*, so
/// the expectations are derived from the calc-v1 run rather than transcribed
/// from a document; that is both privacy-safe and a stronger check, since a
/// transcription can drift from what either engine actually computes.
final class AvalancheBaselineParityTests: XCTestCase {

    private func baselineResult() throws -> PlanningResult {
        try AvalanchePlanEngine.generatePlan(PlanningFixtures.baselineInput())
    }

    // MARK: - R-04 smoothing

    func testObligationSmoothingMatchesFixtureReserves() {
        // round2(700 × 12 ÷ 26) and round2(150 × 12 ÷ 26).
        XCTAssertEqual(
            AvalanchePlanEngine.smoothedReserve(
                amount: TestSupport.money("700.00"), cadence: .monthly, payCadence: .biweekly),
            TestSupport.money("323.08")
        )
        XCTAssertEqual(
            AvalanchePlanEngine.smoothedReserve(
                amount: TestSupport.money("150.00"), cadence: .monthly, payCadence: .biweekly),
            TestSupport.money("69.23")
        )
    }

    // R-04 across the other cadences, to the cent.
    func testObligationSmoothingOtherCadences() {
        func reserve(_ amount: String, _ cadence: ObligationCadence, _ pay: PlanningPayCadence) -> Decimal {
            AvalanchePlanEngine.smoothedReserve(
                amount: TestSupport.money(amount), cadence: cadence, payCadence: pay)
        }
        XCTAssertEqual(reserve("700.00", .monthly, .monthly(day: 1)), TestSupport.money("700.00"))
        XCTAssertEqual(reserve("700.00", .monthly, .weekly), TestSupport.money("161.54"))
        XCTAssertEqual(reserve("700.00", .monthly, .semimonthly(firstDay: 1, secondDay: 15)),
                       TestSupport.money("350.00"))
        XCTAssertEqual(reserve("400.00", .quarterly, .biweekly), TestSupport.money("61.54"))
        XCTAssertEqual(reserve("1200.00", .annual, .biweekly), TestSupport.money("46.15"))
        XCTAssertEqual(reserve("100.00", .weekly, .biweekly), TestSupport.money("200.00"))
        XCTAssertEqual(reserve("50.00", .biweekly, .weekly), TestSupport.money("25.00"))
    }

    /// Inverse R-04 is what migration uses to recover a bill from a stored
    /// per-check reserve, so the round-trip must close on these cadences.
    func testInverseSmoothingRoundTripsForFixtureReserves() {
        for reserve in [DebugBaselineFixture.carReservePerCheck,
                        DebugBaselineFixture.transitReservePerCheck] {
            XCTAssertTrue(
                ObligationMath.roundTripReproduces(
                    reserve: reserve, cadence: .monthly, paychecksPerYear: 26
                ),
                "inverse R-04 must reproduce the stored per-check reserve exactly"
            )
        }
    }

    // MARK: - Headline values

    func testHeadlineValuesMatchTheLegacyEngine() throws {
        let v2 = try baselineResult()
        let v1 = PlanningFixtures.baselineLegacyProjection()

        XCTAssertEqual(v2.calculationVersion, .v2Avalanche)
        XCTAssertEqual(v2.totalStartingPrincipal, TestSupport.money("36400.00"))
        XCTAssertEqual(v2.paycheckCount, v1.paychecksUsed)
        XCTAssertEqual(v2.forecastPayoffDate, v1.payoffDate)
        XCTAssertEqual(v2.estimatedTotalInterest, v1.totalInterest)
        XCTAssertFalse(v2.notPayableAsConfigured)
    }

    func testPerDebtPayoffDatesMatchTheLegacyEngine() throws {
        let v2 = try baselineResult()
        let v1 = PlanningFixtures.baselineLegacyProjection()
        let byID = Dictionary(uniqueKeysWithValues: v2.debtSummaries.map { ($0.debtID, $0) })

        for letter in ["A", "B", "C", "D", "E", "F"] {
            XCTAssertEqual(
                byID[PlanningFixtures.debtID(letter)]?.payoffDate,
                v1.perCardPayoffDates[letter],
                "payoff date for \(letter)"
            )
        }
        // Avalanche order is APR-descending, which is the fixture's own order.
        XCTAssertEqual(
            v2.payoffOrder,
            ["A", "B", "C", "D", "E", "F"].map(PlanningFixtures.debtID),
            "recommended payoff order"
        )
        XCTAssertEqual(v2.currentTargetDebtID, PlanningFixtures.debtID("A"))
    }

    // MARK: - Allocation shape

    /// The floor is already met on the first check, so there is no top-up and
    /// the whole non-allowance remainder goes to reserves and cards.
    func testFirstCheckAllocationsAreInternallyConsistent() throws {
        let result = try baselineResult()
        let first = try XCTUnwrap(result.paychecks.first)

        XCTAssertEqual(first.date, TestSupport.date(2054, 8, 20))
        XCTAssertEqual(first.income, TestSupport.money("2400.00"))
        XCTAssertEqual(first.allowanceReserved, TestSupport.money("300.00"))
        XCTAssertEqual(first.floorTopUp, 0, "starting balance already meets the floor")
        XCTAssertEqual(first.keepInSpending, TestSupport.money("300.00"))
        XCTAssertEqual(
            first.obligationReserveTotal,
            DebugBaselineFixture.carReservePerCheck + DebugBaselineFixture.transitReservePerCheck
        )
        // R-16: income is fully accounted for.
        XCTAssertEqual(
            first.keepInSpending + first.transferToReserves,
            first.income,
            "every dollar of income is either kept or moved"
        )
        XCTAssertEqual(first.minimumsTotal + first.extraTotal, first.debtBudget)
        XCTAssertEqual(first.unassignedCash, 0)
        XCTAssertEqual(first.targetDebtID, PlanningFixtures.debtID("A"))
    }

    /// Budget steps up exactly once, at the raise, and no further top-ups occur.
    func testBudgetStepsAtTheRaise() throws {
        let result = try baselineResult()
        let reserves = DebugBaselineFixture.carReservePerCheck
            + DebugBaselineFixture.transitReservePerCheck
        let beforeRaise = (TestSupport.money("2400.00") - TestSupport.money("300.00") - reserves).rounded2
        let afterRaise = (TestSupport.money("2500.00") - TestSupport.money("300.00") - reserves).rounded2

        for check in result.paychecks {
            let expected = check.date < TestSupport.date(2054, 12, 10) ? beforeRaise : afterRaise
            XCTAssertEqual(check.debtBudget, expected, "budget on check \(check.sequence)")
            XCTAssertEqual(check.floorTopUp, 0, "floor is met from the start")
        }
    }

    /// Targets follow avalanche order and never move backwards.
    func testAttackTargetsFollowAvalancheOrder() throws {
        let result = try baselineResult()
        let order = ["A", "B", "C", "D", "E", "F"].map(PlanningFixtures.debtID)
        var lastIndex = 0
        for check in result.paychecks {
            let target = try XCTUnwrap(check.targetDebtID)
            let index = try XCTUnwrap(order.firstIndex(of: target))
            XCTAssertGreaterThanOrEqual(
                index, lastIndex,
                "target moved back up the avalanche order on check \(check.sequence)"
            )
            lastIndex = index
        }
    }

    func testFinalCheckClearsTheDebtAndCeilingClimbsByTheKeptAmount() throws {
        let result = try baselineResult()
        let last = try XCTUnwrap(result.paychecks.last)

        XCTAssertEqual(last.totalDebtAfter, 0)
        XCTAssertGreaterThan(last.unassignedCash, 0, "the final check over-funds the last balance")
        for (index, check) in result.paychecks.enumerated().dropFirst() {
            XCTAssertEqual(
                check.spendingCeilingAfter,
                result.paychecks[index - 1].spendingCeilingAfter + check.keepInSpending
            )
        }
    }

    // MARK: - Engine parity

    /// The strongest guarantee: every calc-v2 total matches the frozen
    /// calc-v1 engine check by check — dates, interest, budget, and balances.
    func testMatchesLegacyEngineCheckByCheck() throws {
        let v2 = try baselineResult()
        let v1 = PlanningFixtures.baselineLegacyProjection()

        XCTAssertEqual(v2.paycheckCount, v1.paychecksUsed)
        XCTAssertEqual(v2.forecastPayoffDate, v1.payoffDate)
        XCTAssertEqual(v2.estimatedTotalInterest, v1.totalInterest)

        let letterByID = Dictionary(
            uniqueKeysWithValues: ["A", "B", "C", "D", "E", "F"].map { (PlanningFixtures.debtID($0), $0) }
        )
        for (v2Check, v1Check) in zip(v2.paychecks, v1.schedule) {
            XCTAssertEqual(v2Check.date, v1Check.date, "check \(v2Check.sequence) date")
            XCTAssertEqual(v2Check.totalDebtAfter, v1Check.totalDebtAfter,
                           "check \(v2Check.sequence) total debt")
            XCTAssertEqual(v2Check.interestAccrued, v1Check.interestAccrued,
                           "check \(v2Check.sequence) interest")
            XCTAssertEqual(v2Check.minimumsTotal + v2Check.extraTotal, v1Check.budgetUsed,
                           "check \(v2Check.sequence) budget used")
            for balance in v2Check.endingBalances {
                let letter = try XCTUnwrap(letterByID[balance.debtID])
                XCTAssertEqual(balance.balance, v1Check.balancesAfter[letter],
                               "check \(v2Check.sequence) balance for \(letter)")
            }
        }
    }

    /// Mission test 17: the legacy engine is untouched and its version stamps
    /// still read as they always did.
    func testLegacyEngineAndVersionStampsIntact() {
        let result = PlanningFixtures.baselineLegacyProjection()
        XCTAssertFalse(result.unfinished)
        XCTAssertNotNil(result.payoffDate)
        XCTAssertGreaterThan(result.totalInterest, 0)
        XCTAssertEqual(result.perCardPayoffDates.count, 6)

        XCTAssertEqual(PlanContract.calculationVersion, 1)
        XCTAssertEqual(PlanCalculationVersion.v1LegacyBaseline.rawValue, 1)
        XCTAssertEqual(PlanCalculationVersion.v2Avalanche.rawValue, 2)
    }

    func testMinimumOnlyComparisonShowsSavings() throws {
        let result = try baselineResult()
        let comparison = try XCTUnwrap(result.minimumOnlyComparison)
        if comparison.unfinished {
            XCTAssertNil(comparison.interestSaved)
        } else {
            let saved = try XCTUnwrap(comparison.interestSaved)
            XCTAssertGreaterThan(saved, 0)
            XCTAssertGreaterThan(comparison.totalInterest, result.estimatedTotalInterest)
        }
    }
}
