import XCTest
import SwiftData
@testable import PaydayPlaybook

/// T-24 (V4-07, R-28/R-29): the canonical derived pay-cycle debt-allocation
/// service. Cycle boundaries across all four cadences with month-end, leap,
/// and DST fixtures; the deterministic carry-in fold and its plan-activation
/// re-anchor; payment record/edit/delete recompute; the check-in double-count
/// guard; refund/correction handling; the overage rule; the
/// no-cycle-before-first-payday state; monthly aggregates and cleared-debt
/// attribution. All fixture values are fictional.
final class DebtAllocationServiceTests: XCTestCase {

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let plan: PlanVersion
    }

    /// Inserts an active plan whose payday items follow `cadence` from
    /// `firstPayday`, one item per entry in `budgets` (the planned card
    /// budget for that payday), plus a live `IncomeSchedule` for the
    /// boundary-extension rule (`liveCadence` defaults to the plan's own).
    private func makePlan(
        cadence: PayCadence = .biweekly,
        firstPayday: Date = TestSupport.date(2054, 8, 20),
        budgets: [String],
        monthlyDay: Int? = nil,
        semimonthlyDays: (Int, Int)? = nil,
        liveCadence: PayCadence? = nil,
        liveMonthlyDay: Int? = nil,
        liveSemimonthlyDays: (Int, Int)? = nil,
        withLiveSchedule: Bool = true
    ) throws -> Fixture {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let plan = try insertPlan(
            context,
            name: "Plan v1",
            cadence: cadence,
            firstPayday: firstPayday,
            budgets: budgets,
            monthlyDay: monthlyDay,
            semimonthlyDays: semimonthlyDays,
            createdAt: TestSupport.date(2054, 8, 1)
        )
        if withLiveSchedule {
            context.insert(IncomeSchedule(
                cadence: liveCadence ?? cadence,
                anchorPayday: firstPayday,
                monthlyDay: liveMonthlyDay ?? monthlyDay,
                semimonthlyFirstDay: (liveSemimonthlyDays ?? semimonthlyDays)?.0,
                semimonthlySecondDay: (liveSemimonthlyDays ?? semimonthlyDays)?.1,
                baseTakeHome: TestSupport.money("2400.00")
            ))
        }
        try context.save()
        return Fixture(container: container, context: context, plan: plan)
    }

    @discardableResult
    private func insertPlan(
        _ context: ModelContext,
        name: String,
        cadence: PayCadence,
        firstPayday: Date,
        budgets: [String],
        monthlyDay: Int? = nil,
        semimonthlyDays: (Int, Int)? = nil,
        createdAt: Date
    ) throws -> PlanVersion {
        let plan = PlanVersion(
            name: name,
            createdAt: createdAt,
            isOriginalBaseline: false,
            isActive: true,
            firstPayday: firstPayday,
            payFrequencyDays: 14,
            startingChecking1: TestSupport.money("1500.00"),
            protectedBuffer: TestSupport.money("1500.00"),
            allowanceCap: TestSupport.money("300.00"),
            firstCheckBufferAdd: .zero,
            carReservePerCheck: .zero,
            trainReservePerCheck: .zero,
            calculationVersion: 2,
            avalancheOrderRaw: "A",
            baselinePayoffDate: TestSupport.date(2055, 6, 24),
            baselineModeledInterest: .zero,
            baselineNoSpendCeiling: .zero
        )
        plan.payCadence = cadence
        plan.monthlyPayDay = monthlyDay
        plan.semimonthlyPayDay1 = semimonthlyDays?.0
        plan.semimonthlyPayDay2 = semimonthlyDays?.1
        context.insert(plan)

        let planningCadence = try PlanGenerationService.planningCadence(
            cadence: cadence,
            monthlyPayDay: monthlyDay,
            semimonthlyPayDay1: semimonthlyDays?.0,
            semimonthlyPayDay2: semimonthlyDays?.1
        )
        let dates = PayScheduleGenerator.paydays(cadence: planningCadence, anchor: firstPayday, count: budgets.count)
        for (index, budget) in budgets.enumerated() {
            context.insert(PaydayPlanItem(
                planVersionID: plan.id,
                sequenceNumber: index + 1,
                date: dates[index],
                plannedIncome: TestSupport.money("2400.00"),
                plannedC1Keep: .zero,
                plannedBufferAdd: .zero,
                plannedAllowance: .zero,
                plannedC2Transfer: .zero,
                plannedCarReserve: .zero,
                plannedTrainReserve: .zero,
                plannedCardBudget: TestSupport.money(budget),
                plannedTargetDebtID: "A",
                plannedDebtAfter: .zero,
                plannedC1NoSpendCeiling: .zero
            ))
        }
        return plan
    }

    private func service(_ fixture: Fixture, today: Date) -> DebtAllocationService {
        DebtAllocationService(context: fixture.context, dateProvider: FixedDateProvider(fixed: today))
    }

    @discardableResult
    private func recordPayment(
        _ context: ModelContext,
        on date: Date,
        amount: String,
        debtID: UUID? = nil,
        checkInID: UUID? = nil,
        sourceAccountID: UUID? = nil
    ) throws -> LedgerEntry {
        let entry = LedgerEntry(
            effectiveDate: date,
            type: .cardPayment,
            amount: TestSupport.money(amount),
            sourceAccount: .checking2,
            destinationAccount: .card,
            debtAccountID: debtID,
            paydayCheckInID: checkInID,
            sourceAccountID: sourceAccountID
        )
        context.insert(entry)
        try context.save()
        return entry
    }

    // MARK: - Fold basics

    func testFirstCycleWithNoPaymentsReportsTheFullAllocation() throws {
        let fixture = try makePlan(budgets: ["1000.00", "1000.00"])
        let cycle = try XCTUnwrap(try service(fixture, today: TestSupport.date(2054, 8, 25))
            .currentCycle(asOf: TestSupport.date(2054, 8, 25)))
        XCTAssertEqual(cycle.cycleStart, TestSupport.date(2054, 8, 20))
        XCTAssertEqual(cycle.nextPayday, TestSupport.date(2054, 9, 3))
        XCTAssertEqual(cycle.allocation, TestSupport.money("1000.00"))
        XCTAssertEqual(cycle.carryIn, .zero)
        XCTAssertEqual(cycle.available, TestSupport.money("1000.00"))
        XCTAssertEqual(cycle.paidThisCycle, .zero)
        XCTAssertEqual(cycle.remaining, TestSupport.money("1000.00"))
        XCTAssertEqual(cycle.overage, .zero)
        XCTAssertEqual(cycle.nextAllocation, TestSupport.money("1000.00"))
        XCTAssertEqual(cycle.nextAllocationDate, TestSupport.date(2054, 9, 3))
    }

    func testPartialPaymentLowersTheRemainderImmediately() throws {
        let fixture = try makePlan(budgets: ["1000.00"])
        let today = TestSupport.date(2054, 8, 25)
        let allocation = service(fixture, today: today)

        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 21), amount: "400.00")
        let cycle = try XCTUnwrap(allocation.currentCycle(asOf: today))
        XCTAssertEqual(cycle.paidThisCycle, TestSupport.money("400.00"))
        XCTAssertEqual(cycle.remaining, TestSupport.money("600.00"))
        XCTAssertEqual(cycle.overage, .zero)
    }

    func testMultiplePaymentsSumWithinOneCycle() throws {
        let fixture = try makePlan(budgets: ["1000.00"])
        let today = TestSupport.date(2054, 8, 25)
        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 20), amount: "100.00")
        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 22), amount: "250.00")

        let cycle = try XCTUnwrap(service(fixture, today: today).currentCycle(asOf: today))
        XCTAssertEqual(cycle.paidThisCycle, TestSupport.money("350.00"))
        XCTAssertEqual(cycle.remaining, TestSupport.money("650.00"))
    }

    func testExactUseOfTheAllocationLeavesZeroRemainingAndZeroCarry() throws {
        let fixture = try makePlan(budgets: ["1000.00", "1000.00"])
        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 21), amount: "1000.00")

        let inCycleOne = TestSupport.date(2054, 8, 25)
        let cycleOne = try XCTUnwrap(service(fixture, today: inCycleOne).currentCycle(asOf: inCycleOne))
        XCTAssertEqual(cycleOne.remaining, .zero)
        XCTAssertEqual(cycleOne.overage, .zero)

        let inCycleTwo = TestSupport.date(2054, 9, 4)
        let cycleTwo = try XCTUnwrap(service(fixture, today: inCycleTwo).currentCycle(asOf: inCycleTwo))
        XCTAssertEqual(cycleTwo.carryIn, .zero)
        XCTAssertEqual(cycleTwo.available, TestSupport.money("1000.00"))
    }

    // MARK: - Carryover

    func testUnusedAllocationCarriesIntoTheNextCycle() throws {
        // The contract's own synthetic example: 1000 planned, 750 paid,
        // 250 carries; next cycle 1250 available, 400 paid, 850 remaining.
        let fixture = try makePlan(budgets: ["1000.00", "1000.00"])
        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 22), amount: "750.00")

        let today = TestSupport.date(2054, 9, 5)
        let allocation = service(fixture, today: today)
        let before = try XCTUnwrap(allocation.currentCycle(asOf: today))
        XCTAssertEqual(before.cycleStart, TestSupport.date(2054, 9, 3))
        XCTAssertEqual(before.carryIn, TestSupport.money("250.00"))
        XCTAssertEqual(before.available, TestSupport.money("1250.00"))
        XCTAssertEqual(before.remaining, TestSupport.money("1250.00"))

        try recordPayment(fixture.context, on: TestSupport.date(2054, 9, 4), amount: "400.00")
        let after = try XCTUnwrap(allocation.currentCycle(asOf: today))
        XCTAssertEqual(after.paidThisCycle, TestSupport.money("400.00"))
        XCTAssertEqual(after.remaining, TestSupport.money("850.00"))
    }

    func testCarryoverAccumulatesAcrossConsecutiveCycles() throws {
        let fixture = try makePlan(budgets: ["1000.00", "1000.00", "1000.00"])
        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 21), amount: "700.00")
        try recordPayment(fixture.context, on: TestSupport.date(2054, 9, 4), amount: "800.00")

        // Cycle 1 carries 300; cycle 2 has 1300 available, uses 800,
        // carries 500; cycle 3 opens with 1500 available.
        let today = TestSupport.date(2054, 9, 18)
        let cycle = try XCTUnwrap(service(fixture, today: today).currentCycle(asOf: today))
        XCTAssertEqual(cycle.cycleStart, TestSupport.date(2054, 9, 17))
        XCTAssertEqual(cycle.carryIn, TestSupport.money("500.00"))
        XCTAssertEqual(cycle.available, TestSupport.money("1500.00"))
    }

    func testTheFoldIsDeterministic() throws {
        let fixture = try makePlan(budgets: ["1000.00", "1000.00"])
        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 22), amount: "123.45")
        let today = TestSupport.date(2054, 9, 5)
        let allocation = service(fixture, today: today)
        XCTAssertEqual(try allocation.currentCycle(asOf: today), try allocation.currentCycle(asOf: today))
    }

    // MARK: - Overpayment

    func testOverpaymentShowsZeroRemainingAndTheHonestOverage() throws {
        let fixture = try makePlan(budgets: ["1000.00", "1000.00"])
        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 21), amount: "1300.00")

        let inCycleOne = TestSupport.date(2054, 8, 25)
        let cycleOne = try XCTUnwrap(service(fixture, today: inCycleOne).currentCycle(asOf: inCycleOne))
        XCTAssertEqual(cycleOne.remaining, .zero, "overspending must never show negative money")
        XCTAssertEqual(cycleOne.overage, TestSupport.money("300.00"))

        // The excess is surfaced, never borrowed: the next cycle opens with
        // zero carry-in, not a debt to the plan.
        let inCycleTwo = TestSupport.date(2054, 9, 4)
        let cycleTwo = try XCTUnwrap(service(fixture, today: inCycleTwo).currentCycle(asOf: inCycleTwo))
        XCTAssertEqual(cycleTwo.carryIn, .zero)
        XCTAssertEqual(cycleTwo.available, TestSupport.money("1000.00"))
    }

    // MARK: - Refunds, corrections, deletions

    func testDebtLinkedRefundRestoresTheAllocation() throws {
        let fixture = try makePlan(budgets: ["1000.00"])
        let debtID = UUID()
        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 21), amount: "500.00", debtID: debtID)
        let refund = LedgerEntry(
            effectiveDate: TestSupport.date(2054, 8, 23),
            type: .refundReversal,
            amount: TestSupport.money("200.00"),
            debtAccountID: debtID
        )
        fixture.context.insert(refund)
        try fixture.context.save()

        let today = TestSupport.date(2054, 8, 25)
        let cycle = try XCTUnwrap(service(fixture, today: today).currentCycle(asOf: today))
        XCTAssertEqual(cycle.paidThisCycle, TestSupport.money("300.00"))
        XCTAssertEqual(cycle.remaining, TestSupport.money("700.00"))
    }

    func testCorrectionsWithoutADebtLinkNeverCount() throws {
        let fixture = try makePlan(budgets: ["1000.00"])
        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 21), amount: "400.00")
        // A cash-side correction (no debtAccountID) is not a debt event.
        let correction = LedgerEntry(
            effectiveDate: TestSupport.date(2054, 8, 22),
            type: .correction,
            amount: TestSupport.money("150.00")
        )
        fixture.context.insert(correction)
        try fixture.context.save()

        let today = TestSupport.date(2054, 8, 25)
        let cycle = try XCTUnwrap(service(fixture, today: today).currentCycle(asOf: today))
        XCTAssertEqual(cycle.paidThisCycle, TestSupport.money("400.00"))
    }

    func testDeletingAPaymentRestoresTheRemainder() throws {
        let fixture = try makePlan(budgets: ["1000.00"])
        let today = TestSupport.date(2054, 8, 25)
        let allocation = service(fixture, today: today)
        let entry = try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 21), amount: "400.00")
        XCTAssertEqual(try XCTUnwrap(allocation.currentCycle(asOf: today)).remaining, TestSupport.money("600.00"))

        fixture.context.delete(entry)
        try fixture.context.save()
        XCTAssertEqual(try XCTUnwrap(allocation.currentCycle(asOf: today)).remaining, TestSupport.money("1000.00"))
    }

    func testEditingAPaymentAmountRecomputesTheRemainder() throws {
        let fixture = try makePlan(budgets: ["1000.00"])
        let today = TestSupport.date(2054, 8, 25)
        let allocation = service(fixture, today: today)
        let entry = try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 21), amount: "400.00")
        XCTAssertEqual(try XCTUnwrap(allocation.currentCycle(asOf: today)).remaining, TestSupport.money("600.00"))

        entry.amount = TestSupport.money("650.00")
        try fixture.context.save()
        XCTAssertEqual(try XCTUnwrap(allocation.currentCycle(asOf: today)).remaining, TestSupport.money("350.00"))
    }

    // MARK: - Double-count and non-payment guards

    func testCheckInPaymentRowsAreCountedExactlyOnce() throws {
        // Completing a check-in writes .cardPayment ledger rows carrying
        // paydayCheckInID; the check-in's own CheckInCardPayment draft rows
        // must never ALSO be summed.
        let fixture = try makePlan(budgets: ["1000.00"])
        let checkIn = PaydayCheckIn(paydayPlanItemID: UUID(), status: .completed)
        fixture.context.insert(checkIn)
        fixture.context.insert(CheckInCardPayment(
            checkInID: checkIn.id, debtPlanID: "A", amount: TestSupport.money("300.00")
        ))
        try recordPayment(
            fixture.context, on: TestSupport.date(2054, 8, 20), amount: "300.00", checkInID: checkIn.id
        )
        // A quick-add payment on the same day counts separately, once.
        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 20), amount: "200.00")

        let today = TestSupport.date(2054, 8, 25)
        let cycle = try XCTUnwrap(service(fixture, today: today).currentCycle(asOf: today))
        XCTAssertEqual(
            cycle.paidThisCycle, TestSupport.money("500.00"),
            "check-in + quick-add on the same day must count once each — never the draft rows too"
        )
    }

    func testTransfersNeverCountAsDebtPayments() throws {
        let fixture = try makePlan(budgets: ["1000.00"])
        for entry in [
            LedgerEntry(
                effectiveDate: TestSupport.date(2054, 8, 21),
                type: .accountTransfer,
                amount: TestSupport.money("600.00"),
                sourceAccountID: UUID(),
                destinationAccountID: UUID()
            ),
            LedgerEntry(
                effectiveDate: TestSupport.date(2054, 8, 22),
                type: .c2Transfer,
                amount: TestSupport.money("400.00"),
                sourceAccount: .checking1,
                destinationAccount: .checking2
            )
        ] {
            fixture.context.insert(entry)
        }
        try fixture.context.save()

        let today = TestSupport.date(2054, 8, 25)
        let cycle = try XCTUnwrap(service(fixture, today: today).currentCycle(asOf: today))
        XCTAssertEqual(cycle.paidThisCycle, .zero, "a transfer that funds a payment account is not a payment")
        XCTAssertEqual(cycle.remaining, TestSupport.money("1000.00"))
    }

    func testBalanceAdjustmentsNeverCountAsDebtPayments() throws {
        let fixture = try makePlan(budgets: ["1000.00"])
        for entry in [
            LedgerEntry(
                effectiveDate: TestSupport.date(2054, 8, 21),
                type: .accountAdjustment,
                amount: TestSupport.money("-75.00"),
                destinationAccountID: UUID()
            ),
            LedgerEntry(
                effectiveDate: TestSupport.date(2054, 8, 22),
                type: .c1BalanceAdjustment,
                amount: TestSupport.money("50.00"),
                destinationAccount: .checking1
            )
        ] {
            fixture.context.insert(entry)
        }
        try fixture.context.save()

        let today = TestSupport.date(2054, 8, 25)
        let cycle = try XCTUnwrap(service(fixture, today: today).currentCycle(asOf: today))
        XCTAssertEqual(cycle.paidThisCycle, .zero)
    }

    func testPaymentsFromEveryCheckingAccountCountOnceEach() throws {
        let fixture = try makePlan(budgets: ["1000.00"])
        try recordPayment(
            fixture.context, on: TestSupport.date(2054, 8, 21), amount: "300.00", sourceAccountID: UUID()
        )
        try recordPayment(
            fixture.context, on: TestSupport.date(2054, 8, 22), amount: "200.00", sourceAccountID: UUID()
        )

        let today = TestSupport.date(2054, 8, 25)
        let cycle = try XCTUnwrap(service(fixture, today: today).currentCycle(asOf: today))
        XCTAssertEqual(cycle.paidThisCycle, TestSupport.money("500.00"))
    }

    // MARK: - Boundaries: before the first payday, future paydays

    func testNoCurrentCycleBeforeTheFirstPayday() throws {
        let fixture = try makePlan(budgets: ["1000.00", "1000.00"])
        let today = TestSupport.date(2054, 8, 10)
        let allocation = service(fixture, today: today)
        XCTAssertNil(try allocation.currentCycle(asOf: today))

        let upcoming = try XCTUnwrap(allocation.upcomingAllocation(asOf: today))
        XCTAssertEqual(upcoming.availableOn, TestSupport.date(2054, 8, 20))
        XCTAssertEqual(upcoming.amount, TestSupport.money("1000.00"))
    }

    func testPaymentsBeforeTheFirstPaydayNeverEnterTheFold() throws {
        let fixture = try makePlan(budgets: ["1000.00"])
        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 15), amount: "250.00")

        let today = TestSupport.date(2054, 8, 25)
        let cycle = try XCTUnwrap(service(fixture, today: today).currentCycle(asOf: today))
        XCTAssertEqual(cycle.paidThisCycle, .zero)
        XCTAssertEqual(cycle.remaining, TestSupport.money("1000.00"))

        // The month aggregate still reports the actual payment.
        let month = try service(fixture, today: today).monthlyProgress(month: today)
        XCTAssertEqual(month.paidTowardDebts, TestSupport.money("250.00"))
    }

    func testAFuturePaydayIsNeverAvailableToday() throws {
        let fixture = try makePlan(budgets: ["1000.00", "2000.00"])
        let today = TestSupport.date(2054, 8, 25)
        let cycle = try XCTUnwrap(service(fixture, today: today).currentCycle(asOf: today))
        XCTAssertEqual(cycle.available, TestSupport.money("1000.00"), "the next payday's allocation is upcoming, not spendable")
        XCTAssertEqual(cycle.nextAllocation, TestSupport.money("2000.00"))
        XCTAssertEqual(cycle.nextAllocationDate, TestSupport.date(2054, 9, 3))
    }

    // MARK: - Cadence boundaries

    func testWeeklyCadenceBoundaries() throws {
        let fixture = try makePlan(cadence: .weekly, budgets: ["500.00", "500.00", "500.00"])
        let today = TestSupport.date(2054, 8, 28)
        let cycle = try XCTUnwrap(service(fixture, today: today).currentCycle(asOf: today))
        XCTAssertEqual(cycle.cycleStart, TestSupport.date(2054, 8, 27))
        XCTAssertEqual(cycle.nextPayday, TestSupport.date(2054, 9, 3))
    }

    func testWeeklyBoundariesSurviveTheDSTTransition() throws {
        // 2055-03-14 is the US spring-forward Sunday; a weekly cycle spanning
        // it must keep exact calendar-day boundaries in any time zone.
        let fixture = try makePlan(
            cadence: .weekly,
            firstPayday: TestSupport.date(2055, 3, 10),
            budgets: ["500.00", "500.00", "500.00"]
        )
        let today = TestSupport.date(2055, 3, 15)
        let cycle = try XCTUnwrap(service(fixture, today: today).currentCycle(asOf: today))
        XCTAssertEqual(cycle.cycleStart, TestSupport.date(2055, 3, 10))
        XCTAssertEqual(cycle.nextPayday, TestSupport.date(2055, 3, 17))
    }

    func testSemimonthlyCadenceBoundaries() throws {
        let fixture = try makePlan(
            cadence: .semimonthly,
            firstPayday: TestSupport.date(2054, 8, 15),
            budgets: ["600.00", "600.00", "600.00", "600.00"],
            semimonthlyDays: (15, 31)
        )
        let today = TestSupport.date(2054, 9, 1)
        let cycle = try XCTUnwrap(service(fixture, today: today).currentCycle(asOf: today))
        XCTAssertEqual(cycle.cycleStart, TestSupport.date(2054, 8, 31))
        XCTAssertEqual(cycle.nextPayday, TestSupport.date(2054, 9, 15))
    }

    func testMonthlyCadenceClampsMonthEnd() throws {
        // Day 31 clamps to Feb 28 in a non-leap year (R-11).
        let fixture = try makePlan(
            cadence: .monthly,
            firstPayday: TestSupport.date(2055, 1, 31),
            budgets: ["800.00", "800.00", "800.00"],
            monthlyDay: 31
        )
        let today = TestSupport.date(2055, 2, 10)
        let cycle = try XCTUnwrap(service(fixture, today: today).currentCycle(asOf: today))
        XCTAssertEqual(cycle.cycleStart, TestSupport.date(2055, 1, 31))
        XCTAssertEqual(cycle.nextPayday, TestSupport.date(2055, 2, 28))
    }

    func testMonthlyCadenceClampsToLeapDay() throws {
        // The same day-31 schedule reaches Feb 29 in a leap year.
        let fixture = try makePlan(
            cadence: .monthly,
            firstPayday: TestSupport.date(2056, 1, 31),
            budgets: ["800.00", "800.00", "800.00"],
            monthlyDay: 31
        )
        let today = TestSupport.date(2056, 2, 10)
        let cycle = try XCTUnwrap(service(fixture, today: today).currentCycle(asOf: today))
        XCTAssertEqual(cycle.nextPayday, TestSupport.date(2056, 2, 29))
    }

    // MARK: - Extension past the planned schedule

    func testBoundariesExtendPastTheLastItemWithNoNewAllocation() throws {
        let fixture = try makePlan(budgets: ["1000.00", "1000.00"])
        let today = TestSupport.date(2054, 9, 20)
        let cycle = try XCTUnwrap(service(fixture, today: today).currentCycle(asOf: today))
        // Last plan payday 9/3; biweekly extension: 9/17, 10/1.
        XCTAssertEqual(cycle.cycleStart, TestSupport.date(2054, 9, 17))
        XCTAssertEqual(cycle.nextPayday, TestSupport.date(2054, 10, 1))
        XCTAssertEqual(cycle.allocation, .zero, "no plan item means no new planned allocation")
        XCTAssertEqual(cycle.carryIn, TestSupport.money("2000.00"), "unused allocations keep carrying")
        XCTAssertNil(cycle.nextAllocation)
        XCTAssertNil(cycle.nextAllocationDate)
    }

    func testExtensionFollowsTheLiveIncomeScheduleCadence() throws {
        // Plan items are biweekly, but the live schedule is weekly: past the
        // last item the boundary must continue weekly (R-28).
        let fixture = try makePlan(budgets: ["1000.00", "1000.00"], liveCadence: .weekly)
        let today = TestSupport.date(2054, 9, 11)
        let cycle = try XCTUnwrap(service(fixture, today: today).currentCycle(asOf: today))
        XCTAssertEqual(cycle.cycleStart, TestSupport.date(2054, 9, 10))
        XCTAssertEqual(cycle.nextPayday, TestSupport.date(2054, 9, 17))
    }

    // MARK: - Plan activation re-anchor

    func testActivatingADifferentPlanReAnchorsTheFold() throws {
        let fixture = try makePlan(budgets: ["1000.00", "1000.00"])
        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 21), amount: "200.00")

        // Sanity: the old plan carried 800 into its second cycle.
        let today = TestSupport.date(2054, 9, 5)
        XCTAssertEqual(
            try XCTUnwrap(service(fixture, today: today).currentCycle(asOf: today)).carryIn,
            TestSupport.money("800.00")
        )

        fixture.plan.isActive = false
        try insertPlan(
            fixture.context,
            name: "Plan v2",
            cadence: .biweekly,
            firstPayday: TestSupport.date(2054, 9, 3),
            budgets: ["1200.00", "1200.00"],
            createdAt: TestSupport.date(2054, 9, 2)
        )
        try fixture.context.save()

        let cycle = try XCTUnwrap(service(fixture, today: today).currentCycle(asOf: today))
        XCTAssertEqual(cycle.cycleStart, TestSupport.date(2054, 9, 3))
        XCTAssertEqual(cycle.allocation, TestSupport.money("1200.00"))
        XCTAssertEqual(cycle.carryIn, .zero, "activation re-anchors the fold at the new plan's first payday")
        // The old cycle's payment predates the new anchor, so it is outside
        // the new fold; historical ledger rows are untouched either way.
        XCTAssertEqual(cycle.paidThisCycle, .zero)
    }

    // MARK: - Month aggregates (R-29)

    func testACycleCrossingAMonthBoundaryKeepsBothTruthsSeparate() throws {
        let fixture = try makePlan(budgets: ["1000.00", "1000.00"])
        try recordPayment(fixture.context, on: TestSupport.date(2054, 9, 1), amount: "300.00")

        let today = TestSupport.date(2054, 9, 1)
        let allocation = service(fixture, today: today)
        // Pay-cycle truth: the payment lands in the cycle that opened 8/20.
        let cycle = try XCTUnwrap(allocation.currentCycle(asOf: today))
        XCTAssertEqual(cycle.cycleStart, TestSupport.date(2054, 8, 20))
        XCTAssertEqual(cycle.paidThisCycle, TestSupport.money("300.00"))
        // Calendar-month truth: it is September activity, not August.
        XCTAssertEqual(
            try allocation.monthlyProgress(month: TestSupport.date(2054, 8, 1)).paidTowardDebts, .zero
        )
        XCTAssertEqual(
            try allocation.monthlyProgress(month: TestSupport.date(2054, 9, 1)).paidTowardDebts,
            TestSupport.money("300.00")
        )
    }

    func testTheMonthlyAggregateSpansCycles() throws {
        let fixture = try makePlan(cadence: .weekly, budgets: ["500.00", "500.00", "500.00"])
        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 21), amount: "100.00")
        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 28), amount: "200.00")

        let month = try service(fixture, today: TestSupport.date(2054, 8, 30))
            .monthlyProgress(month: TestSupport.date(2054, 8, 1))
        XCTAssertEqual(month.monthStart, TestSupport.date(2054, 8, 1))
        XCTAssertEqual(month.paidTowardDebts, TestSupport.money("300.00"))
    }

    func testMonthlyProgressSubtractsDebtLinkedRefunds() throws {
        let fixture = try makePlan(budgets: ["1000.00"])
        let debtID = UUID()
        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 21), amount: "500.00", debtID: debtID)
        let refund = LedgerEntry(
            effectiveDate: TestSupport.date(2054, 8, 24),
            type: .refundReversal,
            amount: TestSupport.money("120.00"),
            debtAccountID: debtID
        )
        fixture.context.insert(refund)
        try fixture.context.save()

        let month = try service(fixture, today: TestSupport.date(2054, 8, 25))
            .monthlyProgress(month: TestSupport.date(2054, 8, 1))
        XCTAssertEqual(month.paidTowardDebts, TestSupport.money("380.00"))
    }

    // MARK: - Cleared debts (R-29)

    func testADebtPaidToZeroThisMonthIsClearedThisMonth() throws {
        let fixture = try makePlan(budgets: ["1000.00"])
        let cleared = DebtAccount(
            planID: "A", displayName: "Card A", startingBalance: TestSupport.money("300.00"),
            apr: TestSupport.money("0.24"), priority: 1
        )
        let open = DebtAccount(
            planID: "B", displayName: "Card B", startingBalance: TestSupport.money("500.00"),
            apr: TestSupport.money("0.19"), priority: 2
        )
        fixture.context.insert(cleared)
        fixture.context.insert(open)
        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 22), amount: "300.00", debtID: cleared.id)
        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 22), amount: "200.00", debtID: open.id)

        let month = try service(fixture, today: TestSupport.date(2054, 8, 25))
            .monthlyProgress(month: TestSupport.date(2054, 8, 1))
        XCTAssertEqual(month.debtsCleared.map(\.id), [cleared.id])
        XCTAssertEqual(month.debtsCleared.first?.name, "Card A")
        XCTAssertEqual(month.debtsCleared.first?.clearedOn, TestSupport.date(2054, 8, 22))
    }

    func testADebtClearedLastMonthIsNotClearedThisMonth() throws {
        let fixture = try makePlan(budgets: ["1000.00"])
        let debt = DebtAccount(
            planID: "A", displayName: "Card A", startingBalance: TestSupport.money("300.00"),
            apr: TestSupport.money("0.24"), priority: 1
        )
        fixture.context.insert(debt)
        try recordPayment(fixture.context, on: TestSupport.date(2054, 7, 15), amount: "300.00", debtID: debt.id)

        let allocation = service(fixture, today: TestSupport.date(2054, 8, 25))
        XCTAssertTrue(try allocation.monthlyProgress(month: TestSupport.date(2054, 8, 1)).debtsCleared.isEmpty)
        XCTAssertEqual(
            try allocation.monthlyProgress(month: TestSupport.date(2054, 7, 1)).debtsCleared.map(\.id),
            [debt.id]
        )
    }

    func testARefundReopeningTheDebtMovesTheClearedDateToTheFinalPayment() throws {
        let fixture = try makePlan(budgets: ["1000.00"])
        let debt = DebtAccount(
            planID: "A", displayName: "Card A", startingBalance: TestSupport.money("300.00"),
            apr: TestSupport.money("0.24"), priority: 1
        )
        fixture.context.insert(debt)
        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 10), amount: "300.00", debtID: debt.id)
        let refund = LedgerEntry(
            effectiveDate: TestSupport.date(2054, 8, 20),
            type: .refundReversal,
            amount: TestSupport.money("50.00"),
            debtAccountID: debt.id
        )
        fixture.context.insert(refund)
        try fixture.context.save()
        try recordPayment(fixture.context, on: TestSupport.date(2054, 8, 22), amount: "50.00", debtID: debt.id)

        let month = try service(fixture, today: TestSupport.date(2054, 8, 25))
            .monthlyProgress(month: TestSupport.date(2054, 8, 1))
        XCTAssertEqual(month.debtsCleared.first?.clearedOn, TestSupport.date(2054, 8, 22))
    }
}
