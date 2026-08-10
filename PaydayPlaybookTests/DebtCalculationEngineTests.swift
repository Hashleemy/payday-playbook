import XCTest
@testable import PaydayPlaybook

/// Required unit tests 1–3, 7–10, 13 from MVP_LAYOUT §8, plus engine behavior.
final class DebtCalculationEngineTests: XCTestCase {

    // Required test 1: original total equals $29,681.61.
    func testOriginalTotalEquals29681_61() {
        let total = PlanContract.debtSeeds.reduce(Decimal.zero) { $0 + $1.balance }
        XCTAssertEqual(total, TestSupport.money("29681.61"))
    }

    // Required test 2: avalanche order equals B, D, A, F, C, E.
    func testAvalancheOrder() {
        XCTAssertEqual(PlanContract.avalancheOrder, ["B", "D", "A", "F", "C", "E"])
        XCTAssertEqual(PlanContract.debtSeeds.map(\.planID), ["B", "D", "A", "F", "C", "E"])
    }

    // Required test 3: first paycheck Aug 20, 2026; next Sep 3, 2026.
    func testFirstTwoPaydayDates() {
        let result = DebtCalculationEngine.baselineProjection()
        XCTAssertEqual(result.schedule.first?.date, TestSupport.date(2026, 8, 20))
        XCTAssertEqual(result.schedule.dropFirst().first?.date, TestSupport.date(2026, 9, 3))
    }

    // Required test 7: baseline card payoff dates.
    func testBaselinePerCardPayoffDates() {
        let result = DebtCalculationEngine.baselineProjection()
        XCTAssertEqual(result.perCardPayoffDates["B"], TestSupport.date(2026, 8, 20))
        XCTAssertEqual(result.perCardPayoffDates["D"], TestSupport.date(2026, 10, 15))
        XCTAssertEqual(result.perCardPayoffDates["A"], TestSupport.date(2026, 11, 26))
        XCTAssertEqual(result.perCardPayoffDates["F"], TestSupport.date(2027, 1, 7))
        XCTAssertEqual(result.perCardPayoffDates["C"], TestSupport.date(2027, 5, 13))
        XCTAssertEqual(result.perCardPayoffDates["E"], TestSupport.date(2027, 6, 24))
    }

    // Required test 8: final payoff Jun 24, 2027 after 23 checks.
    func testBaselineFinalPayoff() {
        let result = DebtCalculationEngine.baselineProjection()
        XCTAssertEqual(result.payoffDate, TestSupport.date(2027, 6, 24))
        XCTAssertEqual(result.paychecksUsed, 23)
        XCTAssertFalse(result.unfinished)
    }

    // Required test 9: baseline modeled interest rounds to $3,461.16.
    func testBaselineModeledInterest() {
        let result = DebtCalculationEngine.baselineProjection()
        XCTAssertEqual(result.totalInterest, TestSupport.money("3461.16"))
    }

    // Required test 13: paying off a card rolls the remainder to the next card
    // in the same check (check 1: B is retired and D absorbs the leftover).
    func testPayoffRollsRemainderToNextCard() {
        let result = DebtCalculationEngine.baselineProjection()
        guard let firstCheck = result.schedule.first else {
            return XCTFail("No schedule produced")
        }
        XCTAssertEqual(firstCheck.balancesAfter["B"], 0)
        XCTAssertEqual(firstCheck.budgetUsed, TestSupport.money("1307.69"))
        let paymentTotal = firstCheck.paymentsByCard.values.reduce(Decimal.zero, +)
        XCTAssertEqual(paymentTotal.rounded2, TestSupport.money("1307.69"))
        // D received more than a bare estimated minimum because B's leftover rolled on.
        let dPayment = firstCheck.paymentsByCard["D"] ?? 0
        XCTAssertGreaterThan(dPayment, TestSupport.money("26.00"))
        // First check total matches the documented planned debt after.
        XCTAssertEqual(firstCheck.totalDebtAfter, TestSupport.money("28665.71"))
    }

    // Engine income helper follows effective dates.
    func testIncomeRuleSelection() {
        let rules: [(Date, Decimal)] = [
            (TestSupport.date(2026, 8, 20), TestSupport.money("2094.00")),
            (TestSupport.date(2026, 12, 10), TestSupport.money("2190.00"))
        ]
        XCTAssertEqual(
            DebtCalculationEngine.incomeAmount(on: TestSupport.date(2026, 11, 26), rules: rules),
            TestSupport.money("2094.00")
        )
        XCTAssertEqual(
            DebtCalculationEngine.incomeAmount(on: TestSupport.date(2026, 12, 10), rules: rules),
            TestSupport.money("2190.00")
        )
    }

    // A reforecast from the untouched starting position reproduces the baseline.
    func testReforecastFromStartMatchesBaseline() {
        let debts = PlanContract.debtSeeds.map {
            DebtCalculationEngine.EngineDebt(planID: $0.planID, apr: $0.apr, balance: $0.balance)
        }
        let input = DebtCalculationEngine.ReforecastInput(
            debts: debts,
            asOf: TestSupport.date(2026, 8, 10),
            plan: DebtCalculationEngine.PlanSettingsSnapshot(
                allowanceCap: PlanContract.allowanceCap,
                firstCheckBufferAdd: PlanContract.firstCheckBufferAdd,
                carReservePerCheck: PlanContract.carReservePerCheck,
                trainReservePerCheck: PlanContract.trainReservePerCheck,
                payFrequencyDays: 14,
                baselinePayoffDate: PlanContract.baselinePayoffDate
            ),
            incomeRules: [
                (TestSupport.date(2026, 8, 20), PlanContract.firstIncome),
                (TestSupport.date(2026, 12, 10), PlanContract.raisedIncome)
            ],
            nextSequence: 1,
            nextPaydayDate: TestSupport.date(2026, 8, 20),
            includeFirstCheckBuffer: true,
            triggerType: .manual,
            varianceContext: nil
        )
        let result = DebtCalculationEngine.reforecast(input)
        XCTAssertEqual(result.projection.payoffDate, TestSupport.date(2027, 6, 24))
        XCTAssertEqual(result.projection.paychecksUsed, 23)
        XCTAssertEqual(result.projection.totalInterest, TestSupport.money("3461.16"))
        XCTAssertTrue(result.explanation.contains("Jun") || result.explanation.contains("matching"))
    }

    // Extra payments accelerate the forecast payoff.
    func testExtraPaymentAcceleratesForecast() {
        var debts = PlanContract.debtSeeds.map {
            DebtCalculationEngine.EngineDebt(planID: $0.planID, apr: $0.apr, balance: $0.balance)
        }
        // A $5,000 windfall applied to the top target.
        debts[0].balance = 0
        debts[1].balance -= TestSupport.money("3951.00")
        let input = DebtCalculationEngine.ReforecastInput(
            debts: debts,
            asOf: TestSupport.date(2026, 8, 10),
            plan: DebtCalculationEngine.PlanSettingsSnapshot(
                allowanceCap: PlanContract.allowanceCap,
                firstCheckBufferAdd: PlanContract.firstCheckBufferAdd,
                carReservePerCheck: PlanContract.carReservePerCheck,
                trainReservePerCheck: PlanContract.trainReservePerCheck,
                payFrequencyDays: 14,
                baselinePayoffDate: PlanContract.baselinePayoffDate
            ),
            incomeRules: [
                (TestSupport.date(2026, 8, 20), PlanContract.firstIncome),
                (TestSupport.date(2026, 12, 10), PlanContract.raisedIncome)
            ],
            nextSequence: 1,
            nextPaydayDate: TestSupport.date(2026, 8, 20),
            includeFirstCheckBuffer: true,
            triggerType: .extraPayment,
            varianceContext: nil
        )
        let result = DebtCalculationEngine.reforecast(input)
        let payoff = try? XCTUnwrap(result.projection.payoffDate)
        XCTAssertNotNil(payoff)
        XCTAssertLessThan(payoff!, TestSupport.date(2027, 6, 24))
        XCTAssertTrue(result.explanation.contains("earlier"))
    }

    // Minimum payment formula: floor of $17.50 or 0.5% of post-interest balance.
    func testMinimumPaymentFormula() {
        let debts = [
            DebtCalculationEngine.EngineDebt(planID: "X", apr: TestSupport.money("0.20"), balance: TestSupport.money("1000.00")),
            DebtCalculationEngine.EngineDebt(planID: "Y", apr: TestSupport.money("0.20"), balance: TestSupport.money("10000.00"))
        ]
        let paydays = [DebtCalculationEngine.EnginePayday(
            sequence: 1, date: TestSupport.date(2026, 8, 20), cardBudget: TestSupport.money("100.00")
        )]
        let result = DebtCalculationEngine.project(debts: debts, paydays: paydays)
        guard let check = result.schedule.first else { return XCTFail("No schedule") }
        // Y's 0.5% of ~10,076 ≈ 50.38 > 17.50 — Y pays a percentage minimum.
        let yPayment = check.paymentsByCard["Y"] ?? 0
        XCTAssertGreaterThan(yPayment, TestSupport.money("50.00"))
        // X (target) gets its minimum ($17.50 floor beats 0.5% of ~1,007 ≈ 5.04)
        // plus every remaining attack dollar.
        let xPayment = check.paymentsByCard["X"] ?? 0
        XCTAssertEqual((xPayment + yPayment).rounded2, TestSupport.money("100.00"))
        XCTAssertGreaterThan(xPayment, TestSupport.money("17.49"))
    }
}
