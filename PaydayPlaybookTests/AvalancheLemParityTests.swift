import XCTest
@testable import PaydayPlaybook

/// V2-10 / required v0.2 test 3: the calc-v2 generator, fed Lem-equivalent
/// onboarding inputs, must reproduce every Original Plan v1 headline value —
/// and the legacy calc-v1 engine must keep producing its documented result
/// untouched (required mission test 17).
final class AvalancheLemParityTests: XCTestCase {

    private func lemResult() throws -> PlanningResult {
        try AvalanchePlanEngine.generatePlan(PlanningFixtures.lemInput())
    }

    // R-04 reductions: Lem's exact reserves fall out of the smoothing rule.
    func testObligationSmoothingMatchesLemReserves() {
        XCTAssertEqual(
            AvalanchePlanEngine.smoothedReserve(
                amount: TestSupport.money("726.00"), cadence: .monthly, payCadence: .biweekly),
            TestSupport.money("335.08")
        )
        XCTAssertEqual(
            AvalanchePlanEngine.smoothedReserve(
                amount: TestSupport.money("111.00"), cadence: .monthly, payCadence: .biweekly),
            TestSupport.money("51.23")
        )
    }

    // R-04 across the other cadences, to the cent.
    func testObligationSmoothingOtherCadences() {
        func reserve(_ amount: String, _ cadence: ObligationCadence, _ pay: PayCadence) -> Decimal {
            AvalanchePlanEngine.smoothedReserve(
                amount: TestSupport.money(amount), cadence: cadence, payCadence: pay)
        }
        XCTAssertEqual(reserve("726.00", .monthly, .monthly(day: 1)), TestSupport.money("726.00"))
        XCTAssertEqual(reserve("726.00", .monthly, .weekly), TestSupport.money("167.54"))
        XCTAssertEqual(reserve("726.00", .monthly, .semimonthly(firstDay: 1, secondDay: 15)),
                       TestSupport.money("363.00"))
        XCTAssertEqual(reserve("400.00", .quarterly, .biweekly), TestSupport.money("61.54"))
        XCTAssertEqual(reserve("1200.00", .annual, .biweekly), TestSupport.money("46.15"))
        XCTAssertEqual(reserve("100.00", .weekly, .biweekly), TestSupport.money("200.00"))
        XCTAssertEqual(reserve("50.00", .biweekly, .weekly), TestSupport.money("25.00"))
    }

    // Headline values: 23 checks, Jun 24 2027, $3,461.16 interest,
    // $29,681.61 starting debt.
    func testLemHeadlineValues() throws {
        let result = try lemResult()
        XCTAssertEqual(result.calculationVersion, .v2Avalanche)
        XCTAssertEqual(result.totalStartingPrincipal, TestSupport.money("29681.61"))
        XCTAssertEqual(result.paycheckCount, 23)
        XCTAssertEqual(result.forecastPayoffDate, TestSupport.date(2027, 6, 24))
        XCTAssertEqual(result.estimatedTotalInterest, TestSupport.money("3461.16"))
        XCTAssertFalse(result.notPayableAsConfigured)
    }

    // All six per-debt payoff milestones.
    func testLemPerDebtPayoffDates() throws {
        let result = try lemResult()
        let byID = Dictionary(uniqueKeysWithValues: result.debtSummaries.map { ($0.debtID, $0) })
        let expected: [(String, Int, Int, Int)] = [
            ("B", 2026, 8, 20), ("D", 2026, 10, 15), ("A", 2026, 11, 26),
            ("F", 2027, 1, 7), ("C", 2027, 5, 13), ("E", 2027, 6, 24)
        ]
        for (letter, year, month, day) in expected {
            XCTAssertEqual(
                byID[PlanningFixtures.debtID(letter)]?.payoffDate,
                TestSupport.date(year, month, day),
                "payoff date for \(letter)"
            )
        }
        XCTAssertEqual(
            result.payoffOrder,
            ["B", "D", "A", "F", "C", "E"].map(PlanningFixtures.debtID),
            "recommended payoff order"
        )
        XCTAssertEqual(result.currentTargetDebtID, PlanningFixtures.debtID("B"))
    }

    // Check 1 keeps $400 ($300 allowance + $100 floor top-up from $900 to
    // the $1,000 floor), transfers $1,694, reserves $386.31, budgets
    // $1,307.69, and ends at $28,665.71 attacking B.
    func testLemFirstCheckAllocations() throws {
        let result = try lemResult()
        let first = try XCTUnwrap(result.paychecks.first)
        XCTAssertEqual(first.date, TestSupport.date(2026, 8, 20))
        XCTAssertEqual(first.income, TestSupport.money("2094.00"))
        XCTAssertEqual(first.allowanceReserved, TestSupport.money("300.00"))
        XCTAssertEqual(first.floorTopUp, TestSupport.money("100.00"))
        XCTAssertEqual(first.keepInSpending, TestSupport.money("400.00"))
        XCTAssertEqual(first.transferToReserves, TestSupport.money("1694.00"))
        XCTAssertEqual(first.obligationReserveTotal, TestSupport.money("386.31"))
        XCTAssertEqual(first.debtBudget, TestSupport.money("1307.69"))
        XCTAssertEqual(first.minimumsTotal + first.extraTotal, TestSupport.money("1307.69"))
        XCTAssertEqual(first.unassignedCash, 0)
        XCTAssertEqual(first.totalDebtAfter, TestSupport.money("28665.71"))
        XCTAssertEqual(first.targetDebtID, PlanningFixtures.debtID("B"))
        XCTAssertEqual(first.spendingCeilingAfter, TestSupport.money("1300.00"))
        // B is retired in check 1 and the remainder rolls to D in the same
        // paycheck (required mission test 4).
        let bBalance = first.endingBalances.first { $0.debtID == PlanningFixtures.debtID("B") }
        XCTAssertEqual(bBalance?.balance, 0)
        let dPayment = try XCTUnwrap(first.payments.first { $0.debtID == PlanningFixtures.debtID("D") })
        XCTAssertGreaterThan(dPayment.extra, 0)
        XCTAssertTrue(dPayment.reasons.contains(.rolloverAfterPayoff))
    }

    // Budgets: $1,407.69 for checks 2–8, $1,503.69 from the Dec 10 raise on.
    func testLemBudgetSteps() throws {
        let result = try lemResult()
        for check in result.paychecks.dropFirst() {
            let expected = check.date < TestSupport.date(2026, 12, 10)
                ? TestSupport.money("1407.69")
                : TestSupport.money("1503.69")
            XCTAssertEqual(check.debtBudget, expected, "budget on \(check.date)")
            XCTAssertEqual(check.floorTopUp, 0, "no further top-ups after check 1")
        }
    }

    // Attack targets follow the documented schedule column.
    func testLemAttackTargets() throws {
        let result = try lemResult()
        let expected = ["B", "D", "D", "D", "D", "A", "A", "A", "F", "F", "F",
                        "C", "C", "C", "C", "C", "C", "C", "C", "C", "E", "E", "E"]
        XCTAssertEqual(result.paychecks.count, expected.count)
        for (check, letter) in zip(result.paychecks, expected) {
            XCTAssertEqual(check.targetDebtID, PlanningFixtures.debtID(letter),
                           "target on check \(check.sequence)")
        }
    }

    // Final check pays $929.54 and leaves the rest unassigned; the no-spend
    // ceiling path runs $1,300 → $7,900.
    func testLemFinalCheckAndCeilingPath() throws {
        let result = try lemResult()
        let last = try XCTUnwrap(result.paychecks.last)
        // The source document prints $929.54 for the final payment, but that
        // column carries the documented ±$0.01–$0.06 float artifacts (see
        // ENGINEERING.md); the clean-Decimal value — identical in the frozen
        // calc-v1 engine — is $929.59. The engine output is authoritative.
        XCTAssertEqual(last.minimumsTotal + last.extraTotal, TestSupport.money("929.59"))
        XCTAssertEqual(last.unassignedCash, TestSupport.money("574.10"))
        XCTAssertEqual(last.totalDebtAfter, 0)
        XCTAssertEqual(result.cashBufferPath.first, TestSupport.money("1300.00"))
        XCTAssertEqual(result.cashBufferPath.last, TestSupport.money("7900.00"))
        // Ceiling climbs by exactly the kept amount each check.
        for (index, check) in result.paychecks.enumerated().dropFirst() {
            XCTAssertEqual(
                check.spendingCeilingAfter,
                result.paychecks[index - 1].spendingCeilingAfter + check.keepInSpending
            )
        }
    }

    // The strongest parity guarantee: every calc-v2 total matches the frozen
    // calc-v1 engine check by check — dates, interest, and balances.
    func testLemMatchesLegacyEngineCheckByCheck() throws {
        let v2 = try lemResult()
        let v1 = DebtCalculationEngine.baselineProjection()
        XCTAssertEqual(v2.paycheckCount, v1.paychecksUsed)
        XCTAssertEqual(v2.forecastPayoffDate, v1.payoffDate)
        XCTAssertEqual(v2.estimatedTotalInterest, v1.totalInterest)
        for (v2Check, v1Check) in zip(v2.paychecks, v1.schedule) {
            XCTAssertEqual(v2Check.date, v1Check.date, "check \(v2Check.sequence) date")
            XCTAssertEqual(v2Check.totalDebtAfter, v1Check.totalDebtAfter,
                           "check \(v2Check.sequence) total debt")
            XCTAssertEqual(v2Check.interestAccrued, v1Check.interestAccrued,
                           "check \(v2Check.sequence) interest")
            XCTAssertEqual(v2Check.minimumsTotal + v2Check.extraTotal, v1Check.budgetUsed,
                           "check \(v2Check.sequence) budget used")
            for balance in v2Check.endingBalances {
                let letter = PlanningFixtures.debtID("B") == balance.debtID ? "B"
                    : PlanningFixtures.debtID("D") == balance.debtID ? "D"
                    : PlanningFixtures.debtID("A") == balance.debtID ? "A"
                    : PlanningFixtures.debtID("F") == balance.debtID ? "F"
                    : PlanningFixtures.debtID("C") == balance.debtID ? "C" : "E"
                XCTAssertEqual(balance.balance, v1Check.balancesAfter[letter],
                               "check \(v2Check.sequence) balance for \(letter)")
            }
        }
    }

    // Required mission test 17: the legacy engine itself is untouched and
    // still reproduces the documented plan under calculation version 1.
    func testLegacyBaselineRegressionIntact() {
        let result = DebtCalculationEngine.baselineProjection()
        XCTAssertEqual(result.paychecksUsed, 23)
        XCTAssertEqual(result.payoffDate, TestSupport.date(2027, 6, 24))
        XCTAssertEqual(result.totalInterest, TestSupport.money("3461.16"))
        XCTAssertEqual(result.perCardPayoffDates["B"], TestSupport.date(2026, 8, 20))
        XCTAssertEqual(result.perCardPayoffDates["E"], TestSupport.date(2027, 6, 24))
        XCTAssertEqual(result.schedule.first?.totalDebtAfter, TestSupport.money("28665.71"))
        XCTAssertEqual(result.schedule.first?.budgetUsed, TestSupport.money("1307.69"))
        XCTAssertEqual(PlanContract.calculationVersion, 1)
        XCTAssertEqual(PlanCalculationVersion.v1LegacyBaseline.rawValue, 1)
        XCTAssertEqual(PlanCalculationVersion.v2Avalanche.rawValue, 2)
    }

    // The minimum-only comparison is supported for Lem (all cards) and shows
    // real savings.
    func testLemMinimumOnlyComparisonShowsSavings() throws {
        let result = try lemResult()
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
