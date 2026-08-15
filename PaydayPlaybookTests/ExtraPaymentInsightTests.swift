import XCTest
@testable import PaydayPlaybook

/// T-6 — extra-payment insights (V3-04, R-20/R-21), plus the multi-debt
/// horizon benchmark.
///
/// All fixture values are fictional (V3-12).
final class ExtraPaymentInsightTests: XCTestCase {

    // MARK: - One-time extras

    func testOneTimeExtraSavesTimeAndInterest() throws {
        let insight = try ExtraPaymentInsightService.insight(
            from: ScenarioFixtures.snapshot(),
            extra: ScenarioFixtures.extraPayment(amount: "1500.00")
        )
        XCTAssertTrue(insight.isComputable)
        let before = try XCTUnwrap(insight.payoffDateBefore)
        let after = try XCTUnwrap(insight.payoffDateAfter)
        XCTAssertLessThanOrEqual(after, before)
        XCTAssertGreaterThan(try XCTUnwrap(insight.daysSaved), 0)
        XCTAssertGreaterThan(try XCTUnwrap(insight.periodsSaved), 0)
        XCTAssertGreaterThan(try XCTUnwrap(insight.interestSaved), 0)
        XCTAssertEqual(insight.interestSaved,
                       (insight.interestBefore - insight.interestAfter).rounded2)
    }

    func testPrincipalReductionMatchesTheEngineOnTheLandingPayday() throws {
        let snapshot = ScenarioFixtures.snapshot()
        let extra = ScenarioFixtures.extraPayment(amount: "600.00")
        let insight = try ExtraPaymentInsightService.insight(from: snapshot, extra: extra)

        let before = try PlanGenerationService.generate(from: snapshot).result
        var withExtra = snapshot
        withExtra.extraPayments = [extra]
        let after = try PlanGenerationService.generate(from: withExtra).result

        let landing = try XCTUnwrap(after.paychecks.first { $0.date >= extra.effectiveDate }?.date)
        let beforeRow = try XCTUnwrap(before.paychecks.first { $0.date == landing })
        let afterRow = try XCTUnwrap(after.paychecks.first { $0.date == landing })
        XCTAssertEqual(insight.projectedPrincipalReduction,
                       (beforeRow.totalDebtAfter - afterRow.totalDebtAfter).rounded2)
        // Reconciles to the cent: the reduction is the money that actually
        // reached debt on that payday.
        XCTAssertEqual(insight.projectedPrincipalReduction,
                       (afterRow.extraTotal - beforeRow.extraTotal).rounded2)
    }

    func testTotalsReconcileToTheEngine() throws {
        let snapshot = ScenarioFixtures.snapshot()
        let extra = ScenarioFixtures.extraPayment(amount: "400.00")
        let insight = try ExtraPaymentInsightService.insight(from: snapshot, extra: extra)

        var withExtra = snapshot
        withExtra.extraPayments = [extra]
        let after = try PlanGenerationService.generate(from: withExtra).result
        XCTAssertEqual(insight.interestAfter, after.estimatedTotalInterest)
        XCTAssertEqual(insight.totalPaid,
                       after.debtSummaries.reduce(Decimal.zero) { $0 + $1.totalPaid }.rounded2)
        XCTAssertEqual(insight.payoffDateAfter, after.forecastPayoffDate)
        ScenarioFixtures.assertReconciles(after, "one-time extra")
    }

    // MARK: - Recurring extras

    func testRecurringPerPaycheckAppliesOnEveryPaydayFromItsDate() throws {
        let start = TestSupport.date(2027, 4, 9)   // the second biweekly payday
        let extra = ScenarioFixtures.extraPayment(
            kind: .recurringPerPaycheck, amount: "200.00", effectiveDate: start)
        var snapshot = ScenarioFixtures.snapshot()
        snapshot.extraPayments = [extra]
        let plan = try PlanGenerationService.generate(from: snapshot).result

        for paycheck in plan.paychecks {
            let expected = paycheck.date >= start ? TestSupport.money("200.00") : .zero
            XCTAssertEqual(paycheck.extraPaymentInflow, expected,
                           "paycheck \(paycheck.sequence) on \(paycheck.date)")
        }
        ScenarioFixtures.assertReconciles(plan, "recurring per paycheck")
    }

    func testRecurringMonthlyAppliesOncePerMonthOnItsDayOfMonth() throws {
        let extra = ScenarioFixtures.extraPayment(
            kind: .recurringMonthly, amount: "300.00",
            effectiveDate: TestSupport.date(2027, 3, 20)
        )
        var snapshot = ScenarioFixtures.snapshot(takeHome: "1500.00")
        snapshot.extraPayments = [extra]
        let plan = try PlanGenerationService.generate(from: snapshot).result

        let applied = plan.paychecks.filter { $0.extraPaymentInflow > 0 }
        XCTAssertFalse(applied.isEmpty)
        // One occurrence per calendar month of the projection, no more.
        let months = Set(applied.map {
            DateMath.calendar.dateComponents([.year, .month], from: $0.date)
        })
        XCTAssertEqual(applied.count, months.count,
                       "a monthly extra must not double up inside one month")
        for paycheck in applied {
            XCTAssertEqual(paycheck.extraPaymentInflow, TestSupport.money("300.00"))
        }
        ScenarioFixtures.assertReconciles(plan, "recurring monthly")
    }

    func testRecurringMonthlyOnDay31ClampsInShortMonths() throws {
        let extra = ScenarioFixtures.extraPayment(
            kind: .recurringMonthly, amount: "150.00",
            effectiveDate: TestSupport.date(2027, 12, 31)
        )
        var snapshot = ScenarioFixtures.snapshot(
            nextPayday: TestSupport.date(2027, 12, 31), takeHome: "1400.00")
        snapshot.extraPayments = [extra]
        let plan = try PlanGenerationService.generate(from: snapshot).result

        // February 2028 has 29 days; the occurrence clamps and still lands on
        // a payday rather than being skipped.
        let inflowDates = plan.paychecks.filter { $0.extraPaymentInflow > 0 }.map(\.date)
        XCTAssertTrue(inflowDates.contains { DateMath.calendar.component(.month, from: $0) == 2 }
                        || plan.forecastPayoffDate.map { $0 < TestSupport.date(2028, 2, 1) } == true,
                      "a day-31 monthly extra must clamp into February, not vanish")
        ScenarioFixtures.assertReconciles(plan, "monthly day 31 extra")
    }

    // MARK: - Targeting (R-07/R-20)

    func testChosenTargetReceivesTheMoneyBeforeTheAvalanchePick() throws {
        // Beacon Card is not the highest-APR debt; naming it must override the
        // avalanche choice for the extra payment only.
        let extra = ScenarioFixtures.extraPayment(
            amount: "500.00", targetDebtID: ScenarioFixtures.debtID(2))
        var snapshot = ScenarioFixtures.snapshot()
        snapshot.extraPayments = [extra]
        let plan = try PlanGenerationService.generate(from: snapshot).result

        let landing = try XCTUnwrap(plan.paychecks.first { $0.extraPaymentInflow > 0 })
        let toBeacon = landing.payments.first { $0.debtID == ScenarioFixtures.debtID(2) }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(toBeacon).extra, TestSupport.money("500.00"))
        XCTAssertTrue(try XCTUnwrap(toBeacon).reasons.contains(.extraPaymentDirectedTarget))

        let insight = try ExtraPaymentInsightService.insight(from: ScenarioFixtures.snapshot(), extra: extra)
        XCTAssertEqual(insight.targetDebtID, ScenarioFixtures.debtID(2))
        XCTAssertFalse(insight.targetWasAutomatic)
    }

    func testAutomaticTargetIsTheAvalanchePick() throws {
        let insight = try ExtraPaymentInsightService.insight(
            from: ScenarioFixtures.snapshot(),
            extra: ScenarioFixtures.extraPayment(amount: "500.00")
        )
        XCTAssertTrue(insight.targetWasAutomatic)
        XCTAssertEqual(insight.targetDebtID, ScenarioFixtures.debtID(1),
                       "Aurora Card carries the highest effective APR")
    }

    func testTargetLargerThanItsBalanceRollsToTheNextDebt() throws {
        // $2,000 aimed at a $900 balance: the surplus must roll on, not stall.
        let extra = ScenarioFixtures.extraPayment(
            amount: "2000.00", targetDebtID: ScenarioFixtures.debtID(2))
        var snapshot = ScenarioFixtures.snapshot()
        snapshot.extraPayments = [extra]
        let plan = try PlanGenerationService.generate(from: snapshot).result

        let landing = try XCTUnwrap(plan.paychecks.first { $0.extraPaymentInflow > 0 })
        let beacon = try XCTUnwrap(landing.endingBalances.first { $0.debtID == ScenarioFixtures.debtID(2) })
        XCTAssertEqual(beacon.balance, 0)
        let aurora = landing.payments.first { $0.debtID == ScenarioFixtures.debtID(1) }?.extra ?? 0
        XCTAssertGreaterThan(aurora, 0, "the overflow must reach the next eligible debt")
        XCTAssertTrue(plan.warnings.contains {
            $0.code == .extraPaymentPartiallyPlaced && $0.debtID == ScenarioFixtures.debtID(2)
        }, "taking less than was aimed at it must be stated, not silently redirected")
        ScenarioFixtures.assertReconciles(plan, "overflowing target")
    }

    func testIneligibleTargetIsWarnedAndRedirected() throws {
        let debts = [
            ScenarioFixtures.debt(1, name: "Open Card", balance: "1800.00", apr: "0.2299"),
            ScenarioFixtures.debt(2, name: "Locked Auto Loan", type: .autoLoan,
                                  balance: "6000.00", apr: "0.0599", minimum: "260.00",
                                  dueDay: 6, prepayment: .ineligible)
        ]
        let extra = ScenarioFixtures.extraPayment(
            amount: "700.00", targetDebtID: ScenarioFixtures.debtID(2))
        let insight = try ExtraPaymentInsightService.insight(
            from: ScenarioFixtures.snapshot(debts: debts), extra: extra)

        XCTAssertTrue(insight.warnings.contains { $0.code == .extraPaymentTargetIneligible })
        XCTAssertEqual(insight.targetDebtID, ScenarioFixtures.debtID(1),
                       "the money goes to the highest-APR debt that accepts it")
    }

    func testUnknownEligibilityTargetIsWarnedNotAssumed() throws {
        let debts = [
            ScenarioFixtures.debt(1, name: "Open Card", balance: "1800.00", apr: "0.2299"),
            ScenarioFixtures.debt(2, name: "Unconfirmed Loan", type: .personalLoan,
                                  balance: "4000.00", apr: "0.1199", minimum: "140.00",
                                  dueDay: 11, prepayment: .unknown)
        ]
        let insight = try ExtraPaymentInsightService.insight(
            from: ScenarioFixtures.snapshot(debts: debts),
            extra: ScenarioFixtures.extraPayment(amount: "700.00",
                                                 targetDebtID: ScenarioFixtures.debtID(2))
        )
        XCTAssertTrue(insight.warnings.contains { $0.code == .extraPaymentTargetUnknownBehavior })
    }

    func testMissingTargetDebtIsANamedMissingInput() throws {
        let insight = try ExtraPaymentInsightService.insight(
            from: ScenarioFixtures.snapshot(),
            extra: ScenarioFixtures.extraPayment(amount: "200.00", targetDebtID: UUID())
        )
        XCTAssertFalse(insight.isComputable)
        XCTAssertEqual(insight.missingInputs.map(\.field), [.extraPaymentTarget])
    }

    func testZeroAmountIsANamedMissingInput() throws {
        let insight = try ExtraPaymentInsightService.insight(
            from: ScenarioFixtures.snapshot(),
            extra: ScenarioFixtures.extraPayment(amount: "0.00")
        )
        XCTAssertFalse(insight.isComputable)
        XCTAssertEqual(insight.missingInputs.map(\.field), [.extraPaymentAmount])
        XCTAssertNil(insight.payoffDateAfter)
    }

    // MARK: - R-21 prepayment semantics and cash warnings

    func testRevolvingDebtNeverClaimsAPrincipalOnlyInstruction() throws {
        let insight = try ExtraPaymentInsightService.insight(
            from: ScenarioFixtures.snapshot(),
            extra: ScenarioFixtures.extraPayment(amount: "300.00",
                                                 targetDebtID: ScenarioFixtures.debtID(1))
        )
        let note = try XCTUnwrap(insight.assumptions.first { $0.code == .revolvingNoPrincipalOnly })
        XCTAssertTrue(note.message.lowercased().contains("after interest"))
        XCTAssertFalse(insight.assumptions.contains { $0.code == .installmentPrincipalOnlyEligible })
    }

    func testEligibleInstallmentDebtGetsPrincipalOnlyGuidance() throws {
        let insight = try ExtraPaymentInsightService.insight(
            from: ScenarioFixtures.snapshot(),
            extra: ScenarioFixtures.extraPayment(amount: "300.00",
                                                 targetDebtID: ScenarioFixtures.debtID(3))
        )
        let note = try XCTUnwrap(
            insight.assumptions.first { $0.code == .installmentPrincipalOnlyEligible })
        XCTAssertEqual(note.debtID, ScenarioFixtures.debtID(3))
    }

    func testNamedSourceAccountWarnsThatFundsAreNotVerified() throws {
        let insight = try ExtraPaymentInsightService.insight(
            from: ScenarioFixtures.snapshot(),
            extra: ScenarioFixtures.extraPayment(
                amount: "300.00", sourceAccountID: ScenarioFixtures.sourceAccountID)
        )
        XCTAssertTrue(insight.warnings.contains { $0.code == .sourceAccountNotVerified })
    }

    func testExtraLargerThanProjectedHeadroomWarnsAboutAvailableCash() throws {
        // Starting balance sits at the floor, so there is no headroom at all.
        let insight = try ExtraPaymentInsightService.insight(
            from: ScenarioFixtures.snapshot(startingBalance: "1000.00", protectedFloor: "1000.00"),
            extra: ScenarioFixtures.extraPayment(
                amount: "900.00", sourceAccountID: ScenarioFixtures.sourceAccountID)
        )
        XCTAssertTrue(insight.warnings.contains { $0.code == .insufficientAvailableCash })
    }

    func testPlanAlreadyUnderTheFloorIsFlagged() throws {
        let insight = try ExtraPaymentInsightService.insight(
            from: ScenarioFixtures.snapshot(takeHome: "500.00", startingBalance: "0.00",
                                            protectedFloor: "9000.00"),
            extra: ScenarioFixtures.extraPayment(amount: "100.00")
        )
        XCTAssertTrue(insight.warnings.contains { $0.code == .protectedFloorAtRisk })
    }

    func testExtraDatedAfterPayoffChangesNothingAndSaysSo() throws {
        let extra = ScenarioFixtures.extraPayment(
            amount: "500.00", effectiveDate: TestSupport.date(2035, 1, 1))
        let insight = try ExtraPaymentInsightService.insight(
            from: ScenarioFixtures.snapshot(), extra: extra)
        XCTAssertEqual(insight.payoffDateAfter, insight.payoffDateBefore)
        XCTAssertEqual(insight.interestAfter, insight.interestBefore)
        XCTAssertTrue(insight.warnings.contains { $0.code == .extraPaymentAfterPayoff })
    }

    // MARK: - Downstream changes

    func testDownstreamChangesReportMovedPayoffDates() throws {
        let insight = try ExtraPaymentInsightService.insight(
            from: ScenarioFixtures.snapshot(),
            extra: ScenarioFixtures.extraPayment(amount: "1800.00")
        )
        XCTAssertFalse(insight.downstreamChanges.isEmpty)
        for change in insight.downstreamChanges {
            if let days = change.daysChanged {
                XCTAssertLessThanOrEqual(days, 0, "extra money must not delay a payoff")
            }
            XCTAssertNotEqual(change.name, "")
        }
    }

    // MARK: - Preview separation (V3-15)

    func testInsightNeverMutatesTheSnapshot() throws {
        let snapshot = ScenarioFixtures.snapshot()
        _ = try ExtraPaymentInsightService.insight(
            from: snapshot, extra: ScenarioFixtures.extraPayment(amount: "500.00"))
        XCTAssertEqual(snapshot, ScenarioFixtures.snapshot())
        XCTAssertTrue(snapshot.extraPayments.isEmpty)
    }

    func testProtocolAndStaticEntryPointsAgree() throws {
        let extra = ScenarioFixtures.extraPayment(amount: "250.00")
        let viaProtocol: any ExtraPaymentInsightCalculating = ExtraPaymentInsightService()
        XCTAssertEqual(
            try viaProtocol.insight(from: ScenarioFixtures.snapshot(), extra: extra),
            try ExtraPaymentInsightService.insight(from: ScenarioFixtures.snapshot(), extra: extra)
        )
    }

    // MARK: - Promotional APR (engine-level)

    /// `StoredPlanInput.debts` carries no promotional-rate column yet, so a
    /// promo can only reach the engine through a directly-built
    /// `PlanningInput`. Calc v3 must honour it exactly as calc v2 does.
    func testPromoAPRStillDrivesPriorityUnderCalcV3() throws {
        var input = try PlanGenerationService.engineInput(from: ScenarioFixtures.snapshot(debts: [
            ScenarioFixtures.debt(1, name: "Promo Card", balance: "3000.00", apr: "0.2999"),
            ScenarioFixtures.debt(2, name: "Standard Card", balance: "3000.00", apr: "0.1999")
        ]))
        input.calculationVersion = .v3Scenario
        input.debts[0].promo = PromoAPR(apr: TestSupport.money("0.0000"),
                                        expirationDate: TestSupport.date(2027, 9, 1))
        input.extraPayments = [ExtraPaymentInput(
            id: ScenarioFixtures.extraPaymentID(), kind: .oneTime,
            amount: TestSupport.money("400.00"),
            effectiveDate: ScenarioFixtures.firstPayday,
            targetDebtID: nil, sourceAccountID: nil
        )]

        let plan = try AvalanchePlanEngine.generatePlan(input)
        let firstPaycheck = try XCTUnwrap(plan.paychecks.first)
        XCTAssertEqual(firstPaycheck.targetDebtID, ScenarioFixtures.debtID(2),
                       "while the promo rate is in force the standard card is the higher effective APR")
        XCTAssertTrue(plan.assumptions.contains { $0.code == .promoNotProrated })
        ScenarioFixtures.assertReconciles(plan, "promo")
    }

    // MARK: - Benchmark

    /// Multi-debt, long-horizon timing for the whole calc-v3 surface: three
    /// scenarios plus an insight over eight debts on a deliberately tight
    /// surplus. Documents the main-thread cost Agent 4 has to plan around.
    func testMultiDebtHorizonBenchmark() throws {
        let debts = (1...8).map { index in
            ScenarioFixtures.debt(
                index,
                name: "Benchmark debt \(index)",
                balance: "\(4000 + index * 750).00",
                apr: "0.\(1200 + index * 150)",
                dueDay: (index * 3) % 28 + 1,
                limit: "\(12000 + index * 1000).00"
            )
        }
        // Take-home barely clears the bills, minimums, and floor, so the
        // projection runs long rather than terminating in a few paychecks.
        let snapshot = ScenarioFixtures.snapshot(
            takeHome: "1750.00",
            obligations: [ScenarioFixtures.bill(amount: "700.00"),
                          ScenarioFixtures.bill(ScenarioFixtures.secondBillID,
                                                name: "Utilities", amount: "180.00", dueDay: 18)],
            debts: debts
        )

        let start = Date()
        let scenarios = try ScenarioCalculationService.scenarios(
            from: snapshot, definitions: ScenarioFixtures.allDefinitions())
        let insight = try ExtraPaymentInsightService.insight(
            from: snapshot,
            extra: ScenarioFixtures.extraPayment(kind: .recurringMonthly, amount: "150.00")
        )
        let elapsed = Date().timeIntervalSince(start)

        let balanced = try XCTUnwrap(scenarios.first { $0.kind == .balanced }?.plan)
        XCTAssertGreaterThan(balanced.paycheckCount, 40, "the benchmark should exercise a long horizon")
        XCTAssertTrue(insight.isComputable)
        for scenario in scenarios {
            ScenarioFixtures.assertReconciles(try XCTUnwrap(scenario.plan), "benchmark \(scenario.kind)")
        }

        // Generous bound: this exists to catch an order-of-magnitude
        // regression, not to police simulator jitter. The measured figure is
        // recorded in the agent report.
        XCTAssertLessThan(elapsed, 10.0,
                          "three scenarios plus an insight over 8 debts took \(elapsed)s")
        print("[benchmark] 8 debts, \(balanced.paycheckCount) paychecks, "
              + "3 scenarios + 1 insight (6 projections): "
              + String(format: "%.3fs", elapsed))
    }
}
