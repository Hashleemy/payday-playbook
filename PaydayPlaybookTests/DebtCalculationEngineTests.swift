import XCTest
@testable import PaydayPlaybook

/// Required unit tests 1–3, 7–10, 13 from MVP_LAYOUT §8, plus engine behavior.
///
/// These once asserted the documented figures of one real person's plan. They
/// now run against `DebugBaselineFixture` — invented inputs, with a golden
/// projection recorded below. The required tests are unchanged in substance:
/// each still pins the same engine property (starting total, avalanche order,
/// payday spacing, per-card payoffs, final payoff, modelled interest,
/// same-check rollover), only against numbers that describe nobody.
final class DebtCalculationEngineTests: XCTestCase {

    // MARK: - Golden projection over the fictional fixture

    private func projection() -> DebtCalculationEngine.ProjectionResult {
        PlanningFixtures.baselineLegacyProjection()
    }

    // Required test 1: starting total equals the sum of the fixture's cards.
    func testStartingTotalMatchesTheFixtureCards() {
        let total = DebugBaselineFixture.cards
            .reduce(Decimal.zero) { $0 + Decimal(string: $1.balance)! }
        XCTAssertEqual(total, TestSupport.money("36400.00"))
    }

    // Required test 2: avalanche order is APR-descending.
    func testAvalancheOrderIsAPRDescending() {
        let aprs = DebugBaselineFixture.cards.map { Decimal(string: $0.apr)! }
        XCTAssertEqual(aprs, aprs.sorted(by: >), "fixture cards must be in avalanche order")
        XCTAssertEqual(DebugBaselineFixture.cards.map(\.planID), ["A", "B", "C", "D", "E", "F"])
    }

    // Required test 3: first two paydays are two weeks apart.
    func testFirstTwoPaydayDates() {
        let result = projection()
        XCTAssertEqual(result.schedule.first?.date, TestSupport.date(2054, 8, 20))
        XCTAssertEqual(result.schedule.dropFirst().first?.date, TestSupport.date(2054, 9, 3))
    }

    // Required test 7: per-card payoff dates.
    func testPerCardPayoffDates() {
        let result = projection()
        XCTAssertEqual(result.perCardPayoffDates["A"], TestSupport.date(2054, 10, 1))
        XCTAssertEqual(result.perCardPayoffDates["B"], TestSupport.date(2054, 11, 26))
        XCTAssertEqual(result.perCardPayoffDates["C"], TestSupport.date(2055, 1, 21))
        XCTAssertEqual(result.perCardPayoffDates["D"], TestSupport.date(2055, 3, 4))
        XCTAssertEqual(result.perCardPayoffDates["E"], TestSupport.date(2055, 4, 29))
        XCTAssertEqual(result.perCardPayoffDates["F"], TestSupport.date(2055, 6, 24))
    }

    // Required test 8: final payoff date and paycheck count.
    func testFinalPayoff() {
        let result = projection()
        XCTAssertEqual(result.payoffDate, TestSupport.date(2055, 6, 24))
        XCTAssertEqual(result.paychecksUsed, 23)
        XCTAssertFalse(result.unfinished)
    }

    // Required test 9: modelled interest.
    func testModeledInterest() {
        XCTAssertEqual(projection().totalInterest, TestSupport.money("2617.18"))
    }

    // Required test 10: cards are retired strictly in avalanche order.
    func testCardsRetireInAvalancheOrder() throws {
        let result = projection()
        let dates = try ["A", "B", "C", "D", "E", "F"].map {
            try XCTUnwrap(result.perCardPayoffDates[$0], "missing payoff date for \($0)")
        }
        XCTAssertEqual(dates, dates.sorted(), "payoffs must not run out of avalanche order")
    }

    // Required test 13: paying off a card rolls the remainder to the next card
    // in the same check.
    func testPayoffRollsRemainderToNextCard() throws {
        let result = projection()
        // The check that retires the first card is where rollover must happen.
        let retiringCheck = try XCTUnwrap(
            result.schedule.first { $0.balancesAfter["A"].map { $0.rounded2 <= 0 } ?? false },
            "expected a check that retires card A"
        )
        XCTAssertEqual(retiringCheck.date, TestSupport.date(2054, 10, 1))

        // B received more than a bare estimated minimum because A's leftover
        // rolled onto it within the same check.
        let bPayment = retiringCheck.paymentsByCard["B"] ?? 0
        let bBalanceBefore = try XCTUnwrap(
            result.schedule
                .first { $0.sequence == retiringCheck.sequence - 1 }?
                .balancesAfter["B"]
        )
        let bareMinimum = max(PlanContract.minimumPaymentFloor, bBalanceBefore * PlanContract.minimumPaymentRate)
        XCTAssertGreaterThan(bPayment, bareMinimum, "A's remainder must roll onto B")

        // The whole budget is spent, nothing is dropped. Per-card payments
        // are rounded once each, so their sum can differ from the separately
        // rounded budget by a cent; that is presentation rounding, not a leak.
        let paid = retiringCheck.paymentsByCard.values.reduce(Decimal.zero, +)
        let drift = abs((paid - retiringCheck.budgetUsed).rounded2)
        XCTAssertLessThanOrEqual(drift, TestSupport.money("0.01"))
    }

    // Engine income helper follows effective dates.
    func testIncomeRuleSelection() {
        let rules: [(Date, Decimal)] = [
            (TestSupport.date(2054, 8, 20), TestSupport.money("2400.00")),
            (TestSupport.date(2054, 12, 10), TestSupport.money("2500.00"))
        ]
        XCTAssertEqual(
            DebtCalculationEngine.incomeAmount(on: TestSupport.date(2054, 11, 26), rules: rules),
            TestSupport.money("2400.00")
        )
        XCTAssertEqual(
            DebtCalculationEngine.incomeAmount(on: TestSupport.date(2054, 12, 10), rules: rules),
            TestSupport.money("2500.00")
        )
    }

    // MARK: - Reforecast

    private func planSnapshot() -> DebtCalculationEngine.PlanSettingsSnapshot {
        DebtCalculationEngine.PlanSettingsSnapshot(
            allowanceCap: DebugBaselineFixture.allowancePerCheck,
            firstCheckBufferAdd: .zero,
            carReservePerCheck: DebugBaselineFixture.carReservePerCheck,
            trainReservePerCheck: DebugBaselineFixture.transitReservePerCheck,
            payFrequencyDays: 14,
            baselinePayoffDate: TestSupport.date(2055, 6, 24)
        )
    }

    private var fixtureIncomeRules: [(Date, Decimal)] {
        [
            (TestSupport.date(2054, 8, 20), DebugBaselineFixture.firstIncome),
            (TestSupport.date(2054, 12, 10), DebugBaselineFixture.raisedIncome)
        ]
    }

    private func fixtureDebts() -> [DebtCalculationEngine.EngineDebt] {
        DebugBaselineFixture.cards.map {
            DebtCalculationEngine.EngineDebt(
                planID: $0.planID,
                apr: Decimal(string: $0.apr)!,
                balance: Decimal(string: $0.balance)!
            )
        }
    }

    // A reforecast from the untouched starting position reproduces the baseline.
    func testReforecastFromStartMatchesBaseline() {
        let input = DebtCalculationEngine.ReforecastInput(
            debts: fixtureDebts(),
            asOf: TestSupport.date(2054, 8, 10),
            plan: planSnapshot(),
            incomeRules: fixtureIncomeRules,
            nextSequence: 1,
            nextPaydayDate: TestSupport.date(2054, 8, 20),
            includeFirstCheckBuffer: true,
            triggerType: .manual,
            varianceContext: nil
        )
        let result = DebtCalculationEngine.reforecast(input)
        XCTAssertEqual(result.projection.payoffDate, TestSupport.date(2055, 6, 24))
        XCTAssertEqual(result.projection.paychecksUsed, 23)
        XCTAssertEqual(result.projection.totalInterest, TestSupport.money("2617.18"))
    }

    // Extra payments accelerate the forecast payoff.
    func testExtraPaymentAcceleratesForecast() throws {
        var debts = fixtureDebts()
        // A lump sum clears the top target and eats into the next one.
        debts[0].balance = 0
        debts[1].balance -= TestSupport.money("1000.00")
        let input = DebtCalculationEngine.ReforecastInput(
            debts: debts,
            asOf: TestSupport.date(2054, 8, 10),
            plan: planSnapshot(),
            incomeRules: fixtureIncomeRules,
            nextSequence: 1,
            nextPaydayDate: TestSupport.date(2054, 8, 20),
            includeFirstCheckBuffer: true,
            triggerType: .extraPayment,
            varianceContext: nil
        )
        let result = DebtCalculationEngine.reforecast(input)
        let payoff = try XCTUnwrap(result.projection.payoffDate)
        XCTAssertLessThan(payoff, TestSupport.date(2055, 6, 24))
        XCTAssertTrue(result.explanation.contains("earlier"))
    }

    // Minimum payment formula: floor of $17.50 or 0.5% of post-interest balance.
    func testMinimumPaymentFormula() {
        let debts = [
            DebtCalculationEngine.EngineDebt(planID: "X", apr: TestSupport.money("0.20"), balance: TestSupport.money("1500.00")),
            DebtCalculationEngine.EngineDebt(planID: "Y", apr: TestSupport.money("0.20"), balance: TestSupport.money("10000.00"))
        ]
        let paydays = [DebtCalculationEngine.EnginePayday(
            sequence: 1, date: TestSupport.date(2054, 8, 20), cardBudget: TestSupport.money("100.00")
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
