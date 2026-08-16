import XCTest
@testable import PaydayPlaybook

/// T-7 (scenario correctness) and T-8 (honest inputs) for calc v3.
///
/// All fixture values are fictional (V3-12).
final class ScenarioCalculationTests: XCTestCase {

    private func compute(
        _ snapshot: StoredPlanInput = ScenarioFixtures.snapshot(),
        _ definitions: [StoredScenarioDefinition] = ScenarioFixtures.allDefinitions()
    ) throws -> [ScenarioKind: ScenarioResult] {
        let results = try ScenarioCalculationService.scenarios(from: snapshot, definitions: definitions)
        return Dictionary(uniqueKeysWithValues: results.map { ($0.kind, $0) })
    }

    // MARK: - T-7 ordering and deltas

    func testExactlyThreeScenariosInTheRequestedOrder() throws {
        let results = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(), definitions: ScenarioFixtures.allDefinitions())
        XCTAssertEqual(results.map(\.kind), [.fastestSafe, .balanced, .moreCushion])
    }

    func testPayoffAndInterestAreOrderedFastestSafeThroughMoreCushion() throws {
        let byKind = try compute()
        let fastest = try XCTUnwrap(byKind[.fastestSafe]?.payoffDate)
        let balanced = try XCTUnwrap(byKind[.balanced]?.payoffDate)
        let cushion = try XCTUnwrap(byKind[.moreCushion]?.payoffDate)

        // Ties are allowed: constraints can coincide at these balances.
        XCTAssertLessThanOrEqual(fastest, balanced)
        XCTAssertLessThanOrEqual(balanced, cushion)

        let fastestInterest = try XCTUnwrap(byKind[.fastestSafe]).estimatedTotalInterest
        let balancedInterest = try XCTUnwrap(byKind[.balanced]).estimatedTotalInterest
        let cushionInterest = try XCTUnwrap(byKind[.moreCushion]).estimatedTotalInterest
        XCTAssertLessThanOrEqual(fastestInterest, balancedInterest)
        XCTAssertLessThanOrEqual(balancedInterest, cushionInterest)
    }

    func testDeltasAreMeasuredAgainstBalanced() throws {
        let byKind = try compute()
        let balanced = try XCTUnwrap(byKind[.balanced])
        XCTAssertEqual(balanced.deltaVsBalanced?.interestDelta, 0)
        XCTAssertEqual(balanced.deltaVsBalanced?.timeDelta, 0)

        let fastest = try XCTUnwrap(byKind[.fastestSafe])
        let delta = try XCTUnwrap(fastest.deltaVsBalanced)
        XCTAssertEqual(delta.interestDelta,
                       (fastest.estimatedTotalInterest - balanced.estimatedTotalInterest).rounded2)
        XCTAssertEqual(delta.timeDelta,
                       DateMath.days(from: try XCTUnwrap(balanced.payoffDate),
                                     to: try XCTUnwrap(fastest.payoffDate)))
        XCTAssertLessThanOrEqual(delta.timeDelta, 0, "Fastest Safe should not finish later")
    }

    func testMoreCushionRetainsMoreCashAndSendsLessToDebt() throws {
        let byKind = try compute()
        let balanced = try XCTUnwrap(byKind[.balanced])
        let cushion = try XCTUnwrap(byKind[.moreCushion])
        XCTAssertGreaterThan(cushion.cashRetainedPerPaycheck, balanced.cashRetainedPerPaycheck)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(cushion.minimumEndingCash),
                                    try XCTUnwrap(balanced.minimumEndingCash))

        // Compared per paycheck, not on the whole-plan average: the two plans
        // run different numbers of paychecks, so an average is dominated by
        // whichever final paycheck happens to be smaller.
        let balancedFirst = try XCTUnwrap(balanced.plan?.paychecks.first)
        let cushionFirst = try XCTUnwrap(cushion.plan?.paychecks.first)
        XCTAssertGreaterThan(cushionFirst.scenarioCashRetained, balancedFirst.scenarioCashRetained)
        XCTAssertGreaterThan(cushionFirst.keepInSpending, balancedFirst.keepInSpending)
        XCTAssertLessThan(cushionFirst.extraTotal, balancedFirst.extraTotal)
        XCTAssertEqual(cushionFirst.minimumsTotal, balancedFirst.minimumsTotal,
                       "cushioning must never come out of a required minimum")
    }

    func testFastestSafeDropsTheAllowanceToZero() throws {
        let byKind = try compute()
        let fastest = try XCTUnwrap(byKind[.fastestSafe]?.plan)
        for paycheck in fastest.paychecks {
            XCTAssertEqual(paycheck.allowanceReserved, 0)
            XCTAssertEqual(paycheck.scenarioCashRetained, 0)
        }
    }

    func testBalancedRetainsExactlyThePlannedSavings() throws {
        let byKind = try compute()
        let balanced = try XCTUnwrap(byKind[.balanced]?.plan)
        let savings = TestSupport.money("100.00")
        // Every paycheck with surplus retains the full planned amount; the
        // final one may retain less because the surplus ran out.
        let fullyFunded = balanced.paychecks.dropLast()
        XCTAssertFalse(fullyFunded.isEmpty)
        for paycheck in fullyFunded {
            XCTAssertEqual(paycheck.scenarioCashRetained, savings,
                           "paycheck \(paycheck.sequence) did not keep the planned savings")
        }
    }

    func testMinimumEndingCashComesFromTheCashPath() throws {
        let byKind = try compute()
        for kind in ScenarioKind.allCases {
            let result = try XCTUnwrap(byKind[kind])
            let plan = try XCTUnwrap(result.plan)
            XCTAssertEqual(result.minimumEndingCash, plan.cashBufferPath.min())
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.minimumEndingCash), 0)
        }
    }

    func testExtraPaymentCeilingCapsExtraAndKeepsTheRestAsCash() throws {
        let capped = ScenarioFixtures.definition(
            .moreCushion, additionalReserve: nil, extraPaymentCeiling: "300.00")
        let results = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(), definitions: [capped])
        let plan = try XCTUnwrap(results.first?.plan)

        let ceiling = TestSupport.money("300.00")
        // Only the last paycheck may exceed the cap, and only by the sub-cent
        // remainder the truncation leaves behind.
        for paycheck in plan.paychecks.dropLast() {
            XCTAssertLessThanOrEqual(paycheck.extraTotal, ceiling + TestSupport.money("0.01"),
                                     "paycheck \(paycheck.sequence) exceeded the ceiling")
        }
        XCTAssertTrue(plan.paychecks.contains { $0.scenarioCashRetained > 0 },
                      "held-back money must be retained as cash, not lost")
        XCTAssertTrue(plan.warnings.contains { $0.code == .extraPaymentCeilingHeldBackCash },
                      "the tradeoff the cap creates must be stated, not implied")
        ScenarioFixtures.assertReconciles(plan, "ceiling")
    }

    func testDeterminismAcrossRepeatedRuns() throws {
        let first = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(), definitions: ScenarioFixtures.allDefinitions())
        let second = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(), definitions: ScenarioFixtures.allDefinitions())
        XCTAssertEqual(first, second)
    }

    func testProtocolAndStaticEntryPointsAgree() throws {
        let viaProtocol: any ScenarioCalculating = ScenarioCalculationService()
        XCTAssertEqual(
            try viaProtocol.scenarios(from: ScenarioFixtures.snapshot(),
                                      definitions: ScenarioFixtures.allDefinitions()),
            try ScenarioCalculationService.scenarios(from: ScenarioFixtures.snapshot(),
                                                     definitions: ScenarioFixtures.allDefinitions())
        )
    }

    // MARK: - T-7 edge cases

    func testZeroAPRDebtSortsLastAndAccruesNoInterest() throws {
        let debts = [
            ScenarioFixtures.debt(1, name: "Zero-rate Card", balance: "1200.00", apr: "0.00"),
            ScenarioFixtures.debt(2, name: "High-rate Card", balance: "1200.00", apr: "0.3499")
        ]
        let results = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(debts: debts),
            definitions: [ScenarioFixtures.definition(.balanced)]
        )
        let plan = try XCTUnwrap(results.first?.plan)
        XCTAssertEqual(plan.payoffOrder.first, ScenarioFixtures.debtID(2))
        XCTAssertTrue(results.first?.warnings.contains { $0.code == .aprMissingOrZero } ?? false,
                      "a 0% APR should be surfaced, not silently assumed")
    }

    func testVeryHighAPRStillProducesAFiniteEstimate() throws {
        let debts = [ScenarioFixtures.debt(1, name: "Payday Advance", balance: "800.00", apr: "3.9900")]
        let results = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(debts: debts),
            definitions: [ScenarioFixtures.definition(.balanced)]
        )
        let result = try XCTUnwrap(results.first)
        XCTAssertNotNil(result.payoffDate)
        XCTAssertGreaterThan(result.estimatedTotalInterest, 0)
        ScenarioFixtures.assertReconciles(try XCTUnwrap(result.plan), "high APR")
    }

    func testAlreadyPaidDebtIsIgnoredWithoutAPayoffEvent() throws {
        let debts = [
            ScenarioFixtures.debt(1, name: "Settled Card", balance: "0.00", apr: "0.2199"),
            ScenarioFixtures.debt(2, name: "Open Card", balance: "600.00", apr: "0.2199")
        ]
        let results = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(debts: debts),
            definitions: [ScenarioFixtures.definition(.balanced)]
        )
        let plan = try XCTUnwrap(results.first?.plan)
        XCTAssertFalse(plan.events.contains {
            $0.kind == .debtPayoff && $0.debtID == ScenarioFixtures.debtID(1)
        }, "a debt that started at $0 was never paid off in this plan")
    }

    func testMinimumLargerThanBalanceNeverOverpays() throws {
        let debts = [
            ScenarioFixtures.debt(1, name: "Nearly Clear Loan", type: .personalLoan,
                                  balance: "40.00", apr: "0.0999", minimum: "500.00", dueDay: 10)
        ]
        let results = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(debts: debts),
            definitions: [ScenarioFixtures.definition(.balanced)]
        )
        let plan = try XCTUnwrap(results.first?.plan)
        let paid = plan.debtSummaries.first { $0.debtID == ScenarioFixtures.debtID(1) }?.totalPaid ?? 0
        XCTAssertLessThan(paid, TestSupport.money("60.00"),
                          "the payment must be capped at the balance plus its modeled interest")
        for point in plan.paychecks.flatMap(\.endingBalances) {
            XCTAssertGreaterThanOrEqual(point.balance, 0)
        }
    }

    func testEqualAPRTiesResolveDeterministically() throws {
        let debts = [
            ScenarioFixtures.debt(1, name: "Tie A", balance: "1000.00", apr: "0.2100", dueDay: 20),
            ScenarioFixtures.debt(2, name: "Tie B", balance: "1000.00", apr: "0.2100", dueDay: 8),
            ScenarioFixtures.debt(3, name: "Tie C", balance: "1000.00", apr: "0.2100", dueDay: 8)
        ]
        let snapshot = ScenarioFixtures.snapshot(debts: debts)
        let definitions = [ScenarioFixtures.definition(.balanced)]
        let first = try ScenarioCalculationService.scenarios(from: snapshot, definitions: definitions)
        let second = try ScenarioCalculationService.scenarios(from: snapshot, definitions: definitions)
        XCTAssertEqual(first, second)
        // R-08: earlier due day wins, then creation order.
        let plan = try XCTUnwrap(first.first?.plan)
        XCTAssertEqual(plan.currentTargetDebtID, ScenarioFixtures.debtID(2))
    }

    func testInsufficientIncomeReportsTheGapInsteadOfNegativeCash() throws {
        let snapshot = ScenarioFixtures.snapshot(
            takeHome: "300.00", startingBalance: "0.00", protectedFloor: "1200.00")
        let results = try ScenarioCalculationService.scenarios(
            from: snapshot, definitions: [ScenarioFixtures.definition(.balanced)])
        let plan = try XCTUnwrap(results.first?.plan)
        let firstRow = try XCTUnwrap(plan.paychecks.first)
        let shortfall = try XCTUnwrap(firstRow.shortfall)
        XCTAssertGreaterThan(shortfall.gap, 0)
        XCTAssertEqual(shortfall.gap, shortfall.floorGap + shortfall.obligationGap + shortfall.minimumsGap)
        XCTAssertGreaterThanOrEqual(firstRow.transferToReserves, 0)
        XCTAssertTrue(results.first?.warnings.contains { $0.code == .shortfallOutsideFunds } ?? false)
    }

    func testPrepaymentRestrictedLoanReceivesMinimumsOnly() throws {
        let debts = [
            ScenarioFixtures.debt(1, name: "Locked Student Loan", type: .studentLoan,
                                  balance: "5000.00", apr: "0.0650", minimum: "150.00",
                                  dueDay: 12, prepayment: .ineligible),
            ScenarioFixtures.debt(2, name: "Open Card", balance: "1500.00", apr: "0.2299")
        ]
        let results = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(debts: debts),
            definitions: [ScenarioFixtures.definition(.balanced)]
        )
        let plan = try XCTUnwrap(results.first?.plan)
        for paycheck in plan.paychecks {
            let extra = paycheck.payments.first { $0.debtID == ScenarioFixtures.debtID(1) }?.extra ?? 0
            XCTAssertEqual(extra, 0, "an ineligible debt must never receive extra principal")
        }
        XCTAssertTrue(plan.warnings.contains { $0.code == .prepaymentProhibited })
    }

    func testUnknownPrepaymentWarnsAndWithholdsExtra() throws {
        let debts = [
            ScenarioFixtures.debt(1, name: "Unconfirmed Loan", type: .personalLoan,
                                  balance: "3000.00", apr: "0.1450", minimum: "120.00",
                                  dueDay: 18, prepayment: .unknown)
        ]
        let results = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(debts: debts),
            definitions: [ScenarioFixtures.definition(.balanced)]
        )
        let plan = try XCTUnwrap(results.first?.plan)
        XCTAssertTrue(plan.warnings.contains { $0.code == .prepaymentEligibilityUnknown })
        XCTAssertTrue(plan.hasUnassignedCash,
                      "money with no eligible target stays visible, never silently spent")
    }

    // MARK: - T-7 calendar edges

    func testSemimonthlyMonthEndAndLeapYearPaydaysClampCorrectly() throws {
        // Days 15 and 31 across February 2028 (a leap year): the second payday
        // must land on the 29th, not roll into March.
        let snapshot = ScenarioFixtures.snapshot(
            cadence: .semimonthly,
            semimonthlyPayDay1: 15, semimonthlyPayDay2: 31,
            nextPayday: TestSupport.date(2028, 1, 15),
            takeHome: "1300.00"
        )
        let results = try ScenarioCalculationService.scenarios(
            from: snapshot, definitions: [ScenarioFixtures.definition(.balanced)])
        let plan = try XCTUnwrap(results.first?.plan)
        let dates = plan.paychecks.map(\.date)
        XCTAssertTrue(dates.contains(TestSupport.date(2028, 1, 31)))
        XCTAssertTrue(dates.contains(TestSupport.date(2028, 2, 15)))
        XCTAssertTrue(dates.contains(TestSupport.date(2028, 2, 29)),
                      "February 2028 has 29 days; day 31 clamps there")
        XCTAssertFalse(dates.contains(TestSupport.date(2028, 2, 28)))
        ScenarioFixtures.assertReconciles(plan, "semimonthly leap")
    }

    func testMonthlyDay31ClampsAcrossShortMonths() throws {
        let snapshot = ScenarioFixtures.snapshot(
            cadence: .monthly, monthlyPayDay: 31,
            nextPayday: TestSupport.date(2027, 3, 31),
            takeHome: "3200.00"
        )
        let results = try ScenarioCalculationService.scenarios(
            from: snapshot, definitions: [ScenarioFixtures.definition(.balanced)])
        let plan = try XCTUnwrap(results.first?.plan)
        let dates = Set(plan.paychecks.map(\.date))
        XCTAssertTrue(dates.contains(TestSupport.date(2027, 4, 30)),
                      "April has 30 days; day 31 clamps there")
        ScenarioFixtures.assertReconciles(plan, "monthly day 31")
    }

    func testBiweeklyAccrualDaysAreAlwaysFourteen() throws {
        let byKind = try compute()
        let plan = try XCTUnwrap(byKind[.balanced]?.plan)
        for paycheck in plan.paychecks {
            XCTAssertEqual(paycheck.accrualDays, 14)
        }
    }

    // MARK: - T-8 honest inputs (R-24 / V3-06)

    func testFastestSafeNeedsMinimumProtectedCash() throws {
        let results = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(),
            definitions: [ScenarioFixtures.definition(.fastestSafe, minimumProtectedCash: nil)]
        )
        let result = try XCTUnwrap(results.first)
        XCTAssertFalse(result.isComputable)
        XCTAssertNil(result.plan)
        XCTAssertEqual(result.missingInputs.map(\.field), [.minimumProtectedCash])
        XCTAssertFalse(try XCTUnwrap(result.missingInputs.first).message.isEmpty)
    }

    func testFastestSafeNeedsTheZeroAllowanceConfirmation() throws {
        let results = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(),
            definitions: [ScenarioFixtures.definition(.fastestSafe, zeroAllowanceConfirmed: false)]
        )
        let result = try XCTUnwrap(results.first)
        XCTAssertFalse(result.isComputable)
        XCTAssertEqual(result.missingInputs.map(\.field), [.zeroAllowanceConfirmation])
    }

    func testBalancedNeedsPlannedSavings() throws {
        let results = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(),
            definitions: [ScenarioFixtures.definition(.balanced, plannedSavings: nil)]
        )
        XCTAssertEqual(try XCTUnwrap(results.first).missingInputs.map(\.field), [.plannedSavings])
    }

    func testMoreCushionNeedsAReserveOrACeiling() throws {
        let results = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(),
            definitions: [ScenarioFixtures.definition(
                .moreCushion, additionalReserve: nil, extraPaymentCeiling: nil)]
        )
        XCTAssertEqual(try XCTUnwrap(results.first).missingInputs.map(\.field), [.cushionConstraint])

        // Either one alone is enough.
        for definition in [
            ScenarioFixtures.definition(.moreCushion, additionalReserve: "200.00", extraPaymentCeiling: nil),
            ScenarioFixtures.definition(.moreCushion, additionalReserve: nil, extraPaymentCeiling: "250.00")
        ] {
            let computed = try ScenarioCalculationService.scenarios(
                from: ScenarioFixtures.snapshot(), definitions: [definition])
            XCTAssertTrue(try XCTUnwrap(computed.first).isComputable)
        }
    }

    func testMissingInstallmentMinimumIsNamedForEveryScenario() throws {
        let debts = [
            ScenarioFixtures.debt(1, name: "Unquantified Medical Bill", type: .medicalDebt,
                                  balance: "2200.00", apr: "0.0000", minimum: nil, dueDay: 9)
        ]
        let results = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(debts: debts),
            definitions: ScenarioFixtures.allDefinitions()
        )
        XCTAssertEqual(results.count, 3)
        for result in results {
            XCTAssertFalse(result.isComputable)
            let missing = try XCTUnwrap(result.missingInputs.first { $0.field == .debtMinimum })
            XCTAssertEqual(missing.debtID, ScenarioFixtures.debtID(1))
            XCTAssertTrue(missing.message.contains("Unquantified Medical Bill"))
        }
    }

    func testNoDebtsIsAMissingInputNotAnEmptyPlan() throws {
        let results = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(debts: []),
            definitions: [ScenarioFixtures.definition(.balanced)]
        )
        XCTAssertEqual(try XCTUnwrap(results.first).missingInputs.map(\.field), [.debts])
    }

    func testNoIncomeIsAMissingInput() throws {
        let results = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(takeHome: "0.00"),
            definitions: [ScenarioFixtures.definition(.balanced)]
        )
        XCTAssertTrue(try XCTUnwrap(results.first).missingInputs.contains { $0.field == .income })
    }

    func testAbsentBillsAreNamedAsAnAssumptionNotInvented() throws {
        let results = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(obligations: []),
            definitions: [ScenarioFixtures.definition(.balanced)]
        )
        let result = try XCTUnwrap(results.first)
        XCTAssertTrue(result.isComputable)
        XCTAssertTrue(result.warnings.contains { $0.code == .noBillsConfigured })
    }

    func testUnusablePayScheduleThrowsAnActionableError() throws {
        let snapshot = ScenarioFixtures.snapshot(cadence: .monthly, monthlyPayDay: nil)
        XCTAssertThrowsError(try ScenarioCalculationService.scenarios(
            from: snapshot, definitions: ScenarioFixtures.allDefinitions())
        ) { error in
            XCTAssertEqual(error as? PlanGenerationService.GenerationError,
                           .missingPayDay(cadence: "monthly"))
        }
    }

    // MARK: - T-8 income override (R-18)

    func testIncomeOverrideNeverMutatesTheSavedInput() throws {
        let snapshot = ScenarioFixtures.snapshot()
        let override = StoredIncomeOverride(
            amount: TestSupport.money("3100.00"), cadence: .biweekly,
            monthlyPayDay: nil, semimonthlyPayDay1: nil, semimonthlyPayDay2: nil,
            effectiveDate: ScenarioFixtures.firstPayday
        )
        let definition = ScenarioFixtures.definition(.balanced, incomeOverride: override)

        let before = snapshot
        _ = try ScenarioCalculationService.scenarios(from: snapshot, definitions: [definition])
        XCTAssertEqual(snapshot, before, "the saved snapshot must be untouched")

        // The engine input built from the saved snapshot is likewise unchanged.
        let plain = try PlanGenerationService.engineInput(from: snapshot)
        XCTAssertEqual(plain.income.amounts.map(\.amount), [TestSupport.money("2400.00")])
    }

    func testIncomeOverrideRaisesTakeHomeAndPullsPayoffForward() throws {
        let baseline = try compute()[.balanced]
        let override = StoredIncomeOverride(
            amount: TestSupport.money("3400.00"), cadence: .biweekly,
            monthlyPayDay: nil, semimonthlyPayDay1: nil, semimonthlyPayDay2: nil,
            effectiveDate: ScenarioFixtures.firstPayday
        )
        let results = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(),
            definitions: [ScenarioFixtures.definition(.balanced, incomeOverride: override)]
        )
        let raised = try XCTUnwrap(results.first)
        XCTAssertLessThanOrEqual(try XCTUnwrap(raised.payoffDate),
                                 try XCTUnwrap(baseline?.payoffDate))
        XCTAssertTrue(raised.assumptions.contains { $0.code == .incomeOverrideApplied })
        ScenarioFixtures.assertReconciles(try XCTUnwrap(raised.plan), "override")
    }

    func testChangingPayFrequencyRebasesTheTimelineAndSaysSo() throws {
        let override = StoredIncomeOverride(
            amount: TestSupport.money("1250.00"), cadence: .weekly,
            monthlyPayDay: nil, semimonthlyPayDay1: nil, semimonthlyPayDay2: nil,
            effectiveDate: TestSupport.date(2027, 4, 5)
        )
        let results = try ScenarioCalculationService.scenarios(
            from: ScenarioFixtures.snapshot(),
            definitions: [ScenarioFixtures.definition(.balanced, incomeOverride: override)]
        )
        let result = try XCTUnwrap(results.first)
        let plan = try XCTUnwrap(result.plan)
        XCTAssertEqual(plan.paychecks.first?.date, TestSupport.date(2027, 4, 5))
        XCTAssertEqual(plan.paychecks.dropFirst().first?.date, TestSupport.date(2027, 4, 12))
        XCTAssertTrue(result.assumptions.contains { $0.code == .incomeOverrideRebasesTimeline })
        ScenarioFixtures.assertReconciles(plan, "cadence override")
    }

    // MARK: - V3-15 separation

    func testScenariosProduceNoPersistableSideEffects() throws {
        // The service takes a value type and returns value types; there is no
        // context to write to. This pins the shape so a future change cannot
        // quietly introduce persistence.
        let snapshot = ScenarioFixtures.snapshot()
        let results = try ScenarioCalculationService.scenarios(
            from: snapshot, definitions: ScenarioFixtures.allDefinitions())
        XCTAssertEqual(snapshot, ScenarioFixtures.snapshot())
        for result in results {
            XCTAssertEqual(result.plan?.kind, .plan,
                           "a preview is generated, never activated as a reforecast")
        }
    }
}
