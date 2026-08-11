import XCTest
@testable import PaydayPlaybook

/// Required mission tests 1–8 and 11–16 for the calc-v2 avalanche engine.
final class AvalanchePlanEngineTests: XCTestCase {

    private func id(_ letter: String) -> UUID { PlanningFixtures.debtID(letter) }

    // 1. Highest effective APR receives every eligible extra dollar, no
    //    matter the input order.
    func testHighestAPRReceivesAllExtra() throws {
        let debts = [
            PlanningFixtures.card("L", balance: "3000.00", apr: "0.1500", order: 1),
            PlanningFixtures.card("H", balance: "3000.00", apr: "0.2900", order: 2),
            PlanningFixtures.card("M", balance: "3000.00", apr: "0.2200", order: 3)
        ]
        let result = try AvalanchePlanEngine.generatePlan(PlanningFixtures.simpleInput(debts: debts))
        XCTAssertEqual(result.currentTargetDebtID, id("H"))
        for check in result.paychecks {
            for payment in check.payments where payment.extra > 0 {
                if check.targetDebtID == id("H") {
                    // While H is alive, only H (or same-check rollover
                    // recipients after H is retired) receives extra.
                    if payment.debtID != id("H") {
                        XCTAssertTrue(payment.reasons.contains(.rolloverAfterPayoff),
                                      "non-target extra without payoff rollover")
                    }
                }
            }
        }
        // Payoff order follows APR descending.
        XCTAssertEqual(result.payoffOrder, [id("H"), id("M"), id("L")])
    }

    // 2. Minimums are funded by due dates when cash suffices: each funding
    //    paycheck is the last payday on/before the due date it covers.
    func testMinimumsFundedByDueDates() throws {
        let debts = [
            PlanningFixtures.card("X", balance: "4000.00", apr: "0.2500",
                                  minimum: "80.00", dueDay: 15, order: 1),
            PlanningFixtures.card("Y", balance: "2000.00", apr: "0.2000",
                                  minimum: "40.00", dueDay: 28, order: 2)
        ]
        let result = try AvalanchePlanEngine.generatePlan(
            PlanningFixtures.simpleInput(debts: debts, allowance: "1500.00"))
        var fundedDueDates: Set<Date> = []
        for (index, check) in result.paychecks.enumerated() {
            let nextDate = index + 1 < result.paychecks.count
                ? result.paychecks[index + 1].date : nil
            for payment in check.payments where payment.minimum > 0 {
                let dueDate = try XCTUnwrap(payment.fundsDueDate,
                                            "due-dated debts must report the due date they fund")
                XCTAssertGreaterThanOrEqual(dueDate, check.date,
                                            "funding payday must not be after the due date")
                if let nextDate {
                    XCTAssertLessThan(dueDate, nextDate,
                                      "funding payday must be the last one before the due date")
                }
                fundedDueDates.insert(dueDate)
                XCTAssertTrue(payment.reasons.contains(.minimumDueByDate))
            }
            XCTAssertNil(check.shortfall, "cash was sufficient — no shortfall expected")
        }
        XCTAssertFalse(fundedDueDates.isEmpty)
        // Matching calendar events exist for the funded due dates.
        let dueEvents = result.events.filter { $0.kind == .minimumDue }
        XCTAssertEqual(Set(dueEvents.map(\.date)), fundedDueDates)
    }

    // 3. Shortfalls are explicit: extra→0, allowance→0, exact gap reported —
    //    never silent negative cash.
    func testShortfallExplicitNeverSilent() throws {
        let debts = [
            PlanningFixtures.card("X", balance: "5000.00", apr: "0.2500",
                                  minimum: "250.00", order: 1)
        ]
        let obligations = [
            ObligationInput(id: PlanningFixtures.carObligationID, name: "Rent",
                            amount: TestSupport.money("400.00"), cadence: .biweekly, dueDay: nil)
        ]
        let result = try AvalanchePlanEngine.generatePlan(PlanningFixtures.simpleInput(
            debts: debts, allowance: "100.00", floor: "0.00",
            startingBalance: "0.00", income: "600.00", obligations: obligations))
        let first = try XCTUnwrap(result.paychecks.first)
        let shortfall = try XCTUnwrap(first.shortfall)
        // 600 income − 100 allowance = 500 available; 400 + 250 = 650 needed.
        // Allowance gives up its full 100; the exact remaining gap is 50.
        XCTAssertEqual(shortfall.allowanceReduced, TestSupport.money("100.00"))
        XCTAssertEqual(shortfall.gap, TestSupport.money("50.00"))
        // Floor and obligations are fully funded here, so the whole gap is
        // the minimums portion.
        XCTAssertEqual(shortfall.floorGap, 0)
        XCTAssertEqual(shortfall.obligationGap, 0)
        XCTAssertEqual(shortfall.minimumsGap, TestSupport.money("50.00"))
        XCTAssertEqual(first.allowanceReserved, 0)
        XCTAssertEqual(first.extraTotal, 0)
        XCTAssertEqual(first.minimumsTotal, TestSupport.money("250.00"))
        XCTAssertGreaterThanOrEqual(first.unassignedCash, 0)
        XCTAssertTrue(result.warnings.contains { $0.code == .shortfallOutsideFunds })
        XCTAssertTrue(result.events.contains { $0.kind == .shortfallAlert })
        // Nothing emitted is negative.
        for check in result.paychecks {
            XCTAssertGreaterThanOrEqual(check.debtBudget, 0)
            XCTAssertGreaterThanOrEqual(check.transferToReserves, 0)
            XCTAssertGreaterThanOrEqual(check.unassignedCash, 0)
        }
    }

    // 4. Extra money rolls to the next debt within the same payment event.
    func testRolloverWithinSamePaycheck() throws {
        let debts = [
            PlanningFixtures.card("S", balance: "300.00", apr: "0.2900", order: 1),
            PlanningFixtures.card("N", balance: "5000.00", apr: "0.2000", order: 2)
        ]
        let result = try AvalanchePlanEngine.generatePlan(PlanningFixtures.simpleInput(debts: debts))
        let first = try XCTUnwrap(result.paychecks.first)
        XCTAssertEqual(first.targetDebtID, id("S"))
        let sBalance = first.endingBalances.first { $0.debtID == id("S") }
        XCTAssertEqual(sBalance?.balance, 0)
        let nPayment = try XCTUnwrap(first.payments.first { $0.debtID == id("N") })
        XCTAssertGreaterThan(nPayment.extra, 0, "freed capacity must roll on immediately")
        XCTAssertTrue(nPayment.reasons.contains(.rolloverAfterPayoff))
        XCTAssertTrue(result.events.contains { $0.kind == .debtPayoff && $0.debtID == id("S") })
    }

    // 5. A higher protected floor (or allowance) delays payoff and the
    //    tradeoff is visible.
    func testHigherFloorOrAllowanceDelaysPayoff() throws {
        let debts = [PlanningFixtures.card("X", balance: "9000.00", apr: "0.2500", order: 1)]
        func generate(floor: String, allowance: String) throws -> PlanningResult {
            try AvalanchePlanEngine.generatePlan(PlanningFixtures.simpleInput(
                debts: [debts[0]], allowance: allowance, floor: floor,
                startingBalance: "0.00", income: "1200.00"))
        }
        let lean = try generate(floor: "200.00", allowance: "100.00")
        let cushioned = try generate(floor: "2000.00", allowance: "100.00")
        let generous = try generate(floor: "200.00", allowance: "500.00")

        let leanPayoff = try XCTUnwrap(lean.forecastPayoffDate)
        let cushionedPayoff = try XCTUnwrap(cushioned.forecastPayoffDate)
        let generousPayoff = try XCTUnwrap(generous.forecastPayoffDate)
        XCTAssertGreaterThan(cushionedPayoff, leanPayoff,
                             "a higher floor must delay payoff here")
        XCTAssertGreaterThan(generousPayoff, leanPayoff,
                             "a higher allowance must delay payoff here")
        XCTAssertGreaterThan(cushioned.estimatedTotalInterest, lean.estimatedTotalInterest)
        XCTAssertGreaterThan(generous.estimatedTotalInterest, lean.estimatedTotalInterest)
    }

    // 6. Applying the same extra money earlier saves (or equals) interest
    //    versus holding it for later.
    func testEarlierWindfallNeverCostsMore() throws {
        let debts = [PlanningFixtures.card("X", balance: "8000.00", apr: "0.2600", order: 1)]
        func generate(windfallDate: Date) throws -> PlanningResult {
            try AvalanchePlanEngine.generatePlan(PlanningFixtures.simpleInput(
                debts: [debts[0]],
                windfalls: [Windfall(date: windfallDate, amount: TestSupport.money("1000.00"))]))
        }
        let early = try generate(windfallDate: TestSupport.date(2026, 8, 20))
        let late = try generate(windfallDate: TestSupport.date(2026, 11, 1))
        XCTAssertLessThanOrEqual(early.estimatedTotalInterest, late.estimatedTotalInterest)
        if let earlyPayoff = early.forecastPayoffDate, let latePayoff = late.forecastPayoffDate {
            XCTAssertLessThanOrEqual(earlyPayoff, latePayoff)
        }
        // The windfall paycheck reconciles with the deposit included.
        let windfallCheck = try XCTUnwrap(early.paychecks.first)
        XCTAssertEqual(windfallCheck.windfall, TestSupport.money("1000.00"))
        XCTAssertEqual(windfallCheck.income + windfallCheck.windfall,
                       windfallCheck.keepInSpending + windfallCheck.transferToReserves)
    }

    // 7. Promo APR expiration flips future priority.
    func testPromoExpirationChangesPriority() throws {
        let promo = PromoAPR(apr: TestSupport.money("0.0000"),
                             expirationDate: TestSupport.date(2026, 11, 1))
        let debts = [
            PlanningFixtures.card("P", balance: "6000.00", apr: "0.2999",
                                  promo: promo, order: 1),
            PlanningFixtures.card("Q", balance: "6000.00", apr: "0.2200", order: 2)
        ]
        let result = try AvalanchePlanEngine.generatePlan(PlanningFixtures.simpleInput(
            debts: debts, allowance: "300.00", income: "1300.00"))
        // While the 0% promo runs, Q's 22% is the highest effective APR.
        XCTAssertEqual(result.currentTargetDebtID, id("Q"))
        var sawFlip = false
        for check in result.paychecks {
            if check.date < TestSupport.date(2026, 11, 1) {
                XCTAssertEqual(check.targetDebtID, id("Q"),
                               "promo debt must not be targeted while at 0%")
            } else if check.targetDebtID == id("P") {
                sawFlip = true
                let pPayment = check.payments.first { $0.debtID == id("P") && $0.extra > 0 }
                XCTAssertTrue(pPayment?.reasons.contains(ReasonCode.promoRateExpired) ?? false)
            }
        }
        XCTAssertTrue(sawFlip, "after expiration the 29.99% debt must become the target")
    }

    // 8. Equal-APR ties break deterministically: due day, then principal,
    //    then stable order — independent of input order.
    func testEqualAPRTieBreakDeterministic() throws {
        let base = [
            PlanningFixtures.card("A", balance: "4000.00", apr: "0.2400",
                                  minimum: "50.00", dueDay: 20, order: 1),
            PlanningFixtures.card("B", balance: "4000.00", apr: "0.2400",
                                  minimum: "50.00", dueDay: 5, order: 2),
            PlanningFixtures.card("C", balance: "3000.00", apr: "0.2400",
                                  minimum: "50.00", dueDay: 5, order: 3)
        ]
        let forward = try AvalanchePlanEngine.generatePlan(PlanningFixtures.simpleInput(debts: base))
        let shuffled = try AvalanchePlanEngine.generatePlan(
            PlanningFixtures.simpleInput(debts: [base[2], base[0], base[1]]))
        // Due day 5 beats due day 20; smaller principal beats larger.
        XCTAssertEqual(forward.currentTargetDebtID, id("C"))
        XCTAssertEqual(forward.payoffOrder, [id("C"), id("B"), id("A")])
        XCTAssertEqual(shuffled.payoffOrder, forward.payoffOrder)
        XCTAssertEqual(shuffled.forecastPayoffDate, forward.forecastPayoffDate)
        XCTAssertEqual(shuffled.estimatedTotalInterest, forward.estimatedTotalInterest)
    }

    // 11. Zero-APR debts accrue no interest and sort last; already-paid
    //     debts are inert.
    func testZeroAPRAndPaidOffDebts() throws {
        let debts = [
            PlanningFixtures.card("Z", balance: "2000.00", apr: "0.0000",
                                  minimum: "25.00", order: 1),
            PlanningFixtures.card("H", balance: "2000.00", apr: "0.2000", order: 2),
            PlanningFixtures.card("O", balance: "0.00", apr: "0.2900", order: 3)
        ]
        let result = try AvalanchePlanEngine.generatePlan(PlanningFixtures.simpleInput(debts: debts))
        XCTAssertEqual(result.currentTargetDebtID, id("H"), "0% debt must sort last")
        let summaries = Dictionary(uniqueKeysWithValues: result.debtSummaries.map { ($0.debtID, $0) })
        XCTAssertEqual(summaries[id("Z")]?.interestPaid, 0)
        XCTAssertNil(summaries[id("O")]?.payoffDate, "already-paid debts get no payoff date")
        for check in result.paychecks {
            XCTAssertNil(check.payments.first { $0.debtID == id("O") },
                         "paid-off debts receive no payments")
        }
        XCTAssertFalse(result.events.contains { $0.kind == .debtPayoff && $0.debtID == id("O") })
        // Z still gets its minimum every paycheck while active.
        let firstZ = result.paychecks.first?.payments.first { $0.debtID == id("Z") }
        XCTAssertEqual(firstZ?.minimum, TestSupport.money("25.00"))
    }

    // 12. Utilization uses balance ÷ limit and survives missing/zero limits.
    func testCreditUtilizationSafety() throws {
        let debts = [
            PlanningFixtures.card("A", balance: "300.00", apr: "0.2000",
                                  limit: "1000.00", order: 1),
            PlanningFixtures.card("B", balance: "950.00", apr: "0.2000",
                                  limit: "1000.00", order: 2),
            PlanningFixtures.card("C", balance: "500.00", apr: "0.2000", order: 3),
            PlanningFixtures.card("D", balance: "500.00", apr: "0.2000",
                                  limit: "0.00", order: 4)
        ]
        let result = try AvalanchePlanEngine.generatePlan(PlanningFixtures.simpleInput(debts: debts))
        let byID = Dictionary(uniqueKeysWithValues: result.utilization.map { ($0.debtID, $0) })
        XCTAssertEqual(byID[id("A")]?.utilization, TestSupport.money("0.3"))
        XCTAssertEqual(byID[id("A")]?.level, .elevated)
        XCTAssertEqual(byID[id("B")]?.level, .critical)
        XCTAssertNil(byID[id("C")]?.utilization)
        XCTAssertEqual(byID[id("C")]?.level, .unknown)
        XCTAssertNil(byID[id("D")]?.utilization, "zero limit must not divide")
        XCTAssertEqual(byID[id("D")]?.level, .unknown)
        XCTAssertTrue(result.warnings.contains { $0.code == .creditLimitMissing && $0.debtID == id("C") })
        XCTAssertTrue(result.warnings.contains { $0.code == .creditLimitZero && $0.debtID == id("D") })
    }

    // 13. Unknown prepayment eligibility warns and never receives extra.
    func testPrepaymentUnknownBlocksExtraPrincipal() throws {
        let debts = [
            PlanningFixtures.loan("U", type: .autoLoan, balance: "9000.00", apr: "0.2900",
                                  minimum: "350.00", prepayment: .unknown, order: 1),
            PlanningFixtures.card("E", balance: "4000.00", apr: "0.1800", order: 2)
        ]
        let result = try AvalanchePlanEngine.generatePlan(PlanningFixtures.simpleInput(debts: debts))
        XCTAssertTrue(result.warnings.contains { $0.code == .prepaymentEligibilityUnknown && $0.debtID == id("U") })
        XCTAssertEqual(result.currentTargetDebtID, id("E"),
                       "extra must target the highest-APR *eligible* debt")
        for check in result.paychecks {
            let uPayment = check.payments.first { $0.debtID == id("U") }
            XCTAssertEqual(uPayment?.extra ?? 0, 0,
                           "unknown-eligibility debt must never receive extra principal")
        }
        let summary = result.debtSummaries.first { $0.debtID == id("U") }
        XCTAssertEqual(summary?.receivesExtraPrincipal, false)
        // An explicitly ineligible loan behaves the same with its own note.
        let ineligible = [
            PlanningFixtures.loan("I", type: .studentLoan, balance: "5000.00", apr: "0.3000",
                                  minimum: "200.00", prepayment: .ineligible, order: 1),
            PlanningFixtures.card("E", balance: "4000.00", apr: "0.1800", order: 2)
        ]
        let second = try AvalanchePlanEngine.generatePlan(PlanningFixtures.simpleInput(debts: ineligible))
        XCTAssertTrue(second.warnings.contains { $0.code == .prepaymentProhibited && $0.debtID == id("I") })
        XCTAssertEqual(second.currentTargetDebtID, id("E"))
    }

    // 14. Authoritative balances change only the reforecast; the plan track
    //     is untouched and reproducible.
    func testAuthoritativeBalanceReforecastsOnly() throws {
        let input = PlanningFixtures.lemInput()
        let plan = try AvalanchePlanEngine.generatePlan(input)
        let actuals = ActualState(
            asOf: TestSupport.date(2026, 9, 10),
            balances: [
                BalanceAuthority(debtID: id("B"), balance: 0,
                                 effectiveDate: TestSupport.date(2026, 9, 10)),
                BalanceAuthority(debtID: id("D"), balance: TestSupport.money("2500.00"),
                                 effectiveDate: TestSupport.date(2026, 9, 10))
            ],
            spendingBalance: TestSupport.money("1600.00")
        )
        let reforecast = try AvalanchePlanEngine.reforecast(input, actuals: actuals)
        XCTAssertEqual(reforecast.kind, .reforecast)
        XCTAssertTrue(reforecast.recommendationReasons.contains(.authoritativeBalance))
        // The reforecast starts after asOf and reflects the snapshots.
        let firstCheck = try XCTUnwrap(reforecast.paychecks.first)
        XCTAssertEqual(firstCheck.date, TestSupport.date(2026, 9, 17))
        XCTAssertEqual(firstCheck.sequence, 3, "sequence numbers stay aligned with the plan")
        let payoff = try XCTUnwrap(reforecast.forecastPayoffDate)
        let planPayoff = try XCTUnwrap(plan.forecastPayoffDate)
        XCTAssertLessThan(payoff, planPayoff, "big balance drops must pull payoff earlier")
        // The original plan is unchanged: regenerating produces an identical value.
        let regenerated = try AvalanchePlanEngine.generatePlan(input)
        XCTAssertEqual(regenerated, plan, "reforecasting must never mutate the plan")
        XCTAssertEqual(plan.kind, .plan)
    }

    // 15. The minimum-only comparison refuses to claim results on
    //     insufficient inputs.
    func testMinimumOnlyComparisonRequiresSufficientInputs() throws {
        let insufficient = [
            PlanningFixtures.loan("L", type: .medicalDebt, balance: "3000.00", apr: "0.0000",
                                  minimum: nil, order: 1),
            PlanningFixtures.card("C", balance: "2000.00", apr: "0.2000", order: 2)
        ]
        let result = try AvalanchePlanEngine.generatePlan(PlanningFixtures.simpleInput(debts: insufficient))
        XCTAssertNil(result.minimumOnlyComparison,
                     "no claim may be made without the loan's contractual payment")
        XCTAssertTrue(result.warnings.contains { $0.code == .minimumOnlyUnavailable })
        XCTAssertTrue(result.warnings.contains { $0.code == .installmentMinimumMissing && $0.debtID == id("L") })

        let sufficient = [
            PlanningFixtures.loan("L", type: .medicalDebt, balance: "3000.00", apr: "0.0000",
                                  minimum: "150.00", order: 1),
            PlanningFixtures.card("C", balance: "2000.00", apr: "0.2000", order: 2)
        ]
        let second = try AvalanchePlanEngine.generatePlan(PlanningFixtures.simpleInput(debts: sufficient))
        XCTAssertNotNil(second.minimumOnlyComparison)
    }

    // 16. Every paycheck reconciles to the cent.
    func testDecimalTotalsReconcileToTheCent() throws {
        let result = try AvalanchePlanEngine.generatePlan(PlanningFixtures.lemInput())
        for check in result.paychecks {
            XCTAssertEqual(check.income + check.windfall,
                           check.keepInSpending + check.transferToReserves,
                           "check \(check.sequence): deposit split")
            XCTAssertEqual(check.keepInSpending,
                           check.allowanceReserved + check.floorTopUp,
                           "check \(check.sequence): keep composition")
            let minimumsGap = check.shortfall?.minimumsGap ?? 0
            XCTAssertEqual(check.debtBudget + minimumsGap,
                           check.minimumsTotal + check.extraTotal + check.unassignedCash,
                           "check \(check.sequence): debt budget split")
            let paymentSum = check.payments.reduce(Decimal.zero) { $0 + $1.minimum + $1.extra }
            XCTAssertEqual(paymentSum, check.minimumsTotal + check.extraTotal,
                           "check \(check.sequence): per-debt payments vs totals")
            XCTAssertEqual(check.obligationReserveTotal,
                           check.obligationReserves.reduce(Decimal.zero) { $0 + $1.amount },
                           "check \(check.sequence): obligation reserves")
        }
    }

    // Negative inputs are rejected loudly (R-16).
    func testNegativeInputsRejected() {
        var input = PlanningFixtures.simpleInput(debts: [
            PlanningFixtures.card("X", balance: "1000.00", apr: "0.2000", order: 1)
        ])
        input.debts[0].balance = TestSupport.money("-5.00")
        XCTAssertThrowsError(try AvalanchePlanEngine.generatePlan(input))
        var second = PlanningFixtures.simpleInput(debts: [])
        second.spending.protectedFloor = TestSupport.money("-1.00")
        XCTAssertThrowsError(try AvalanchePlanEngine.generatePlan(second))
    }

    // Review fix: gap money earmarked for underfunded obligations or floor
    // must never surface as phantom "unassigned" cash. The gap breakdown
    // says exactly where the outside funds go.
    func testShortfallGapBreakdownNoPhantomUnassigned() throws {
        // Transfer ($200) cannot cover the $500 obligation reserve; the $400
        // gap is $300 obligations + $100 minimums — none of it is idle cash.
        let debts = [PlanningFixtures.card("X", balance: "5000.00", apr: "0.2000",
                                           minimum: "100.00", order: 1)]
        let obligations = [
            ObligationInput(id: PlanningFixtures.carObligationID, name: "Rent",
                            amount: TestSupport.money("500.00"), cadence: .biweekly, dueDay: nil)
        ]
        let result = try AvalanchePlanEngine.generatePlan(PlanningFixtures.simpleInput(
            debts: debts, allowance: "0.00", floor: "800.00",
            startingBalance: "0.00", income: "1000.00", obligations: obligations))
        let first = try XCTUnwrap(result.paychecks.first)
        let shortfall = try XCTUnwrap(first.shortfall)
        XCTAssertEqual(shortfall.gap, TestSupport.money("400.00"))
        XCTAssertEqual(shortfall.floorGap, 0, "the $800 floor top-up was fully funded")
        XCTAssertEqual(shortfall.obligationGap, TestSupport.money("300.00"))
        XCTAssertEqual(shortfall.minimumsGap, TestSupport.money("100.00"))
        XCTAssertEqual(first.unassignedCash, 0, "a short paycheck has no idle cash")
        XCTAssertEqual(first.debtBudget, 0)
        XCTAssertEqual(first.minimumsTotal, TestSupport.money("100.00"))

        // Floor variant: transfer is $0, so part of the gap covers the floor.
        let floorShort = try AvalanchePlanEngine.generatePlan(PlanningFixtures.simpleInput(
            debts: debts, allowance: "0.00", floor: "800.00",
            startingBalance: "0.00", income: "500.00"))
        let floorCheck = try XCTUnwrap(floorShort.paychecks.first)
        let floorGapShortfall = try XCTUnwrap(floorCheck.shortfall)
        XCTAssertEqual(floorGapShortfall.gap, TestSupport.money("400.00"))
        XCTAssertEqual(floorGapShortfall.floorGap, TestSupport.money("300.00"))
        XCTAssertEqual(floorGapShortfall.obligationGap, 0)
        XCTAssertEqual(floorGapShortfall.minimumsGap, TestSupport.money("100.00"))
        XCTAssertEqual(floorCheck.unassignedCash, 0)
    }

    // Review fix: equal extra amounts must emit in a stable order (input
    // position), not the Dictionary's per-process hash order.
    func testEqualExtraEmissionDeterministicOrder() throws {
        // Both 0% `.other` debts, no minimums; the $1,000 budget pays off the
        // first ($500) and rolls $500 to the second — two equal extras.
        let debts = [
            PlanningFixtures.loan("A", type: .other, balance: "500.00", apr: "0.0000", order: 1),
            PlanningFixtures.loan("B", type: .other, balance: "5000.00", apr: "0.0000", order: 2)
        ]
        let input = PlanningFixtures.simpleInput(
            debts: debts, allowance: "200.00", floor: "500.00",
            startingBalance: "500.00", income: "1200.00")
        let result = try AvalanchePlanEngine.generatePlan(input)
        let first = try XCTUnwrap(result.paychecks.first)
        let extras = first.payments.filter { $0.extra > 0 }
        XCTAssertEqual(extras.map(\.debtID), [id("A"), id("B")],
                       "equal extras must emit in input order")
        XCTAssertEqual(extras.map(\.extra),
                       [TestSupport.money("500.00"), TestSupport.money("500.00")])
        XCTAssertEqual(try AvalanchePlanEngine.generatePlan(input), result)
    }

    // Review fix: a reforecast without a spending-balance snapshot keeps the
    // *planned* no-spend ceiling — it must not re-charge floor top-ups the
    // plan already made.
    func testReforecastNilSpendingBalanceKeepsPlannedCeiling() throws {
        let input = PlanningFixtures.lemInput()
        let actuals = ActualState(
            asOf: TestSupport.date(2026, 9, 10),
            balances: [
                BalanceAuthority(debtID: id("B"), balance: 0,
                                 effectiveDate: TestSupport.date(2026, 9, 10)),
                BalanceAuthority(debtID: id("D"), balance: TestSupport.money("2500.00"),
                                 effectiveDate: TestSupport.date(2026, 9, 10))
            ],
            spendingBalance: nil
        )
        let reforecast = try AvalanchePlanEngine.reforecast(input, actuals: actuals)
        let first = try XCTUnwrap(reforecast.paychecks.first)
        // The plan topped the floor up on check 1 (ceiling $1,600 after
        // check 2); the reforecast must not charge a second $100 top-up.
        XCTAssertEqual(first.floorTopUp, 0)
        XCTAssertEqual(first.keepInSpending, TestSupport.money("300.00"))
        XCTAssertEqual(first.spendingCeilingAfter, TestSupport.money("1900.00"))
    }

    // Review fix: stale debts (no snapshot) accrue estimated interest from
    // the plan's own accrual anchor, not just the last payday gap.
    func testReforecastStaleDebtAccruesFromPlanStart() throws {
        // $10,000 at 36.5% APR accrues exactly $10/day. The plan anchor is
        // Aug 6 (biweekly before Aug 20); first projected check Sep 17 is
        // 42 days later — $420, not the 14-day $140.
        let debts = [PlanningFixtures.card("S", balance: "10000.00", apr: "0.3650", order: 1)]
        let input = PlanningFixtures.simpleInput(debts: debts)
        let actuals = ActualState(asOf: TestSupport.date(2026, 9, 10), balances: [],
                                  spendingBalance: TestSupport.money("500.00"))
        let reforecast = try AvalanchePlanEngine.reforecast(input, actuals: actuals)
        let first = try XCTUnwrap(reforecast.paychecks.first)
        XCTAssertEqual(first.date, TestSupport.date(2026, 9, 17))
        XCTAssertEqual(first.interestAccrued, TestSupport.money("420.00"))
        XCTAssertTrue(reforecast.warnings.contains {
            $0.code == .staleBalanceInput && $0.debtID == id("S")
        })
    }

    // Review fix: duplicate balance entries for one debt must not trap — the
    // latest effective date wins.
    func testDuplicateBalanceAuthoritiesLatestWins() throws {
        let debts = [PlanningFixtures.card("X", balance: "5000.00", apr: "0.2000", order: 1)]
        let input = PlanningFixtures.simpleInput(debts: debts)
        let actuals = ActualState(
            asOf: TestSupport.date(2026, 9, 10),
            balances: [
                BalanceAuthority(debtID: id("X"), balance: TestSupport.money("3000.00"),
                                 effectiveDate: TestSupport.date(2026, 9, 1)),
                BalanceAuthority(debtID: id("X"), balance: TestSupport.money("2000.00"),
                                 effectiveDate: TestSupport.date(2026, 9, 8))
            ],
            spendingBalance: TestSupport.money("500.00")
        )
        let reforecast = try AvalanchePlanEngine.reforecast(input, actuals: actuals)
        XCTAssertEqual(reforecast.totalRemainingPrincipal, TestSupport.money("2000.00"))
    }

    // Review fix: a reforecast dated past the projection horizon still
    // reports "not payable as configured" instead of a silent empty result.
    func testReforecastPastHorizonMarksNotPayable() throws {
        let debts = [PlanningFixtures.card("X", balance: "5000.00", apr: "0.2000", order: 1)]
        let input = PlanningFixtures.simpleInput(debts: debts)
        let actuals = ActualState(asOf: TestSupport.date(2050, 1, 1), balances: [
            BalanceAuthority(debtID: id("X"), balance: TestSupport.money("4000.00"),
                             effectiveDate: TestSupport.date(2050, 1, 1))
        ], spendingBalance: nil)
        let reforecast = try AvalanchePlanEngine.reforecast(input, actuals: actuals)
        XCTAssertTrue(reforecast.paychecks.isEmpty)
        XCTAssertNil(reforecast.forecastPayoffDate)
        XCTAssertTrue(reforecast.notPayableAsConfigured)
        XCTAssertTrue(reforecast.warnings.contains { $0.code == .horizonCapReached })
    }

    // An impossible configuration hits the horizon cap and says so instead
    // of looping or pretending.
    func testNotPayableAsConfigured() throws {
        let debts = [
            PlanningFixtures.card("X", balance: "50000.00", apr: "0.3500", order: 1)
        ]
        let result = try AvalanchePlanEngine.generatePlan(PlanningFixtures.simpleInput(
            debts: debts, allowance: "0.00", floor: "0.00",
            startingBalance: "0.00", income: "100.00"))
        XCTAssertTrue(result.notPayableAsConfigured)
        XCTAssertNil(result.forecastPayoffDate)
        XCTAssertTrue(result.warnings.contains { $0.code == .horizonCapReached })
    }
}
