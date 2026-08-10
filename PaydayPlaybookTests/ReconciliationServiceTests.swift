import XCTest
import SwiftData
@testable import PaydayPlaybook

/// Required tests 11, 12, 14, 15 plus atomic completion behavior (F-03, F-05).
final class ReconciliationServiceTests: XCTestCase {

    private func makeSeededContext() throws -> (ModelContext, PlanVersion, [PaydayPlanItem], [String: DebtAccount]) {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let plan = try TestSupport.seed(context)
        let items = try TestSupport.planItems(context, plan: plan)
        let debts = try context.fetch(FetchDescriptor<DebtAccount>())
        let byID = Dictionary(uniqueKeysWithValues: debts.map { ($0.planID, $0) })
        return (context, plan, items, byID)
    }

    private func balancedDraft(for item: PaydayPlanItem) -> ReconciliationService.DraftAmounts {
        ReconciliationService.DraftAmounts(
            actualIncome: item.plannedIncome,
            actualC1Kept: item.plannedC1Keep,
            actualC1Balance: TestSupport.money("1300.00"),
            actualAllowanceSpent: nil,
            actualC2Transfer: item.plannedC2Transfer,
            actualCarReserve: item.plannedCarReserve,
            actualTrainReserve: item.plannedTrainReserve,
            cardPayments: [
                "B": TestSupport.money("1061.07"),
                "D": TestSupport.money("246.62")
            ],
            reportedBalances: ["B": .zero]
        )
    }

    // Required test 14: negative currency inputs are rejected.
    func testNegativeInputsRejected() {
        var draft = ReconciliationService.DraftAmounts(actualIncome: TestSupport.money("-1.00"))
        var issues = ReconciliationService.validate(draft)
        XCTAssertTrue(issues.contains { issue in
            if case .negativeAmount = issue { return true }
            return false
        })

        draft = ReconciliationService.DraftAmounts(
            actualIncome: TestSupport.money("2094.00"),
            cardPayments: ["B": TestSupport.money("-50.00")]
        )
        issues = ReconciliationService.validate(draft)
        XCTAssertTrue(issues.contains { issue in
            if case .negativeAmount(let field) = issue { return field.contains("B") }
            return false
        })
        XCTAssertTrue(issues.first { if case .negativeAmount = $0 { return true }; return false }!.isBlocking)

        // Refund/reversal/correction entry types are the explicit negative path.
        XCTAssertTrue(LedgerEntryType.refundReversal.allowsNegativeAmount)
        XCTAssertTrue(LedgerEntryType.correction.allowsNegativeAmount)
        XCTAssertFalse(LedgerEntryType.cardPayment.allowsNegativeAmount)
        XCTAssertFalse(LedgerEntryType.c2Transfer.allowsNegativeAmount)
    }

    // Required test 15: overallocated income and negative C2 are caught.
    func testOverallocationAndNegativeC2Caught() {
        // Kept + transferred exceeds income.
        var draft = ReconciliationService.DraftAmounts(
            actualIncome: TestSupport.money("2094.00"),
            actualC1Kept: TestSupport.money("500.00"),
            actualC2Transfer: TestSupport.money("1794.00")
        )
        var issues = ReconciliationService.validate(draft)
        XCTAssertTrue(issues.contains { issue in
            if case .overallocatedIncome(let by) = issue { return by == TestSupport.money("200.00") }
            return false
        })

        // Card payments exceed what Checking 2 holds.
        draft = ReconciliationService.DraftAmounts(
            actualIncome: TestSupport.money("2094.00"),
            actualC1Kept: TestSupport.money("400.00"),
            actualC2Transfer: TestSupport.money("1694.00"),
            actualCarReserve: TestSupport.money("335.08"),
            actualTrainReserve: TestSupport.money("51.23"),
            cardPayments: ["B": TestSupport.money("2000.00")]
        )
        issues = ReconciliationService.validate(draft, priorC2Available: .zero)
        XCTAssertTrue(issues.contains { issue in
            if case .cardPaymentsExceedC2 = issue { return true }
            return false
        })
    }

    // Completion writes the full atomic record set.
    func testCompletionWritesAtomicRecords() throws {
        let (context, plan, items, debts) = try makeSeededContext()
        let first = try XCTUnwrap(items.first)
        let checkIn = PaydayCheckIn(paydayPlanItemID: first.id)
        context.insert(checkIn)

        let now = TestSupport.date(2026, 8, 20)
        let result = try ReconciliationService.completeCheckIn(
            context: context,
            checkIn: checkIn,
            planItem: first,
            plan: plan,
            draft: balancedDraft(for: first),
            debtsByPlanID: debts,
            now: now
        )

        XCTAssertEqual(result.checkIn.status, .completed)
        XCTAssertEqual(result.checkIn.completedAt, now)
        XCTAssertTrue(result.issues.isEmpty)

        let entries = try context.fetch(FetchDescriptor<LedgerEntry>())
        func entriesOf(_ type: LedgerEntryType) -> [LedgerEntry] {
            entries.filter { $0.type == type }
        }
        XCTAssertEqual(entriesOf(.c2Transfer).first?.amount, TestSupport.money("1694.00"))
        XCTAssertEqual(entriesOf(.carReserveContribution).first?.amount, TestSupport.money("335.08"))
        XCTAssertEqual(entriesOf(.trainReserveContribution).first?.amount, TestSupport.money("51.23"))
        XCTAssertEqual(entriesOf(.c1BufferAddition).first?.amount, TestSupport.money("100.00"))
        let payments = entriesOf(.cardPayment)
        XCTAssertEqual(payments.count, 2)
        XCTAssertEqual(
            payments.reduce(Decimal.zero) { $0 + $1.amount },
            TestSupport.money("1307.69")
        )
        // Every entry links back to the check-in for the audit trail.
        XCTAssertTrue(entries.allSatisfy { $0.paydayCheckInID == checkIn.id })

        // The confirmed C1 balance became an authoritative snapshot; the paid
        // card's reported balance did too.
        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
        XCTAssertTrue(snapshots.contains { $0.cashAccount == .checking1 && $0.amount == TestSupport.money("1300.00") })
        XCTAssertTrue(snapshots.contains { $0.debtPlanID == "B" && $0.amount == .zero })
    }

    // Unreconciled completion requires an explanation (F-03).
    func testUnreconciledCompletionRequiresException() throws {
        let (context, plan, items, debts) = try makeSeededContext()
        let first = try XCTUnwrap(items.first)
        let checkIn = PaydayCheckIn(paydayPlanItemID: first.id)
        context.insert(checkIn)

        var draft = balancedDraft(for: first)
        draft.actualC2Transfer = TestSupport.money("1500.00")   // leaves $194 unallocated

        XCTAssertThrowsError(try ReconciliationService.completeCheckIn(
            context: context, checkIn: checkIn, planItem: first, plan: plan,
            draft: draft, debtsByPlanID: debts
        )) { error in
            guard case ReconciliationService.CompletionError.unreconciledWithoutExplanation = error else {
                return XCTFail("Expected unreconciledWithoutExplanation, got \(error)")
            }
        }
        // Nothing was written by the failed attempt.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), 0)

        // With an explanation it completes as needs-attention.
        draft.cardPayments = ["B": TestSupport.money("1061.07")]
        let result = try ReconciliationService.completeCheckIn(
            context: context, checkIn: checkIn, planItem: first, plan: plan,
            draft: draft, debtsByPlanID: debts,
            exception: "Held back $194 for an unexpected bill."
        )
        XCTAssertEqual(result.checkIn.status, .needsAttention)
        XCTAssertEqual(result.checkIn.reconciliationException, "Held back $194 for an unexpected bill.")
    }

    // Required test 11: recording allowance spending lowers actual C1 only;
    // the baseline no-spend ceiling is untouched.
    func testAllowanceSpendingLowersActualOnly() throws {
        let (context, plan, items, debts) = try makeSeededContext()
        let first = try XCTUnwrap(items.first)
        let checkIn = PaydayCheckIn(paydayPlanItemID: first.id)
        context.insert(checkIn)
        try ReconciliationService.completeCheckIn(
            context: context, checkIn: checkIn, planItem: first, plan: plan,
            draft: balancedDraft(for: first), debtsByPlanID: debts,
            now: TestSupport.date(2026, 8, 20)
        )

        let provider = FixedDateProvider(fixed: TestSupport.date(2026, 8, 21))
        let service = AccountBalanceService(context: context, dateProvider: provider)
        let before = try service.checking1State(plan: plan, planItems: items)
        XCTAssertEqual(before.actualBalance, TestSupport.money("1300.00"))
        XCTAssertEqual(before.noSpendCeiling, TestSupport.money("1300.00"))
        XCTAssertEqual(before.allowanceAvailable, TestSupport.money("300.00"))

        // Record $100 of actual allowance spending the day after payday.
        context.insert(LedgerEntry(
            effectiveDate: TestSupport.date(2026, 8, 21),
            type: .c1Spending,
            amount: TestSupport.money("100.00"),
            sourceAccount: .checking1,
            destinationAccount: .external
        ))
        try context.save()

        let after = try service.checking1State(plan: plan, planItems: items)
        XCTAssertEqual(after.actualBalance, TestSupport.money("1200.00"))
        XCTAssertEqual(after.allowanceAvailable, TestSupport.money("200.00"))
        XCTAssertEqual(after.allowanceSpentThisPeriod, TestSupport.money("100.00"))
        // Ceiling did not move.
        XCTAssertEqual(after.noSpendCeiling, TestSupport.money("1300.00"))
        // And the stored baseline row is untouched.
        XCTAssertEqual(first.plannedC1NoSpendCeiling, TestSupport.money("1300.00"))
    }

    // Required test 12: an authoritative snapshot changes the forecast while
    // Original Plan v1 stays identical.
    func testSnapshotChangesForecastNotBaseline() throws {
        let (context, plan, items, debts) = try makeSeededContext()
        _ = debts
        let provider = TestSupport.fixedToday
        let reforecastService = ReforecastService(context: context, dateProvider: provider)

        let baselineForecast = try XCTUnwrap(try reforecastService.reforecast(trigger: .manual))
        XCTAssertEqual(baselineForecast.projectedPayoffDate, TestSupport.date(2027, 6, 24))
        XCTAssertEqual(baselineForecast.remainingPaychecks, 23)

        // The user pays C down dramatically and records the real balance.
        let cardC = try XCTUnwrap(debts["C"])
        context.insert(BalanceSnapshot(
            debtAccountID: cardC.id,
            debtPlanID: "C",
            effectiveDate: TestSupport.date(2026, 8, 10),
            amount: TestSupport.money("5000.00"),
            sourceType: .currentOnlineBalance,
            isAuthoritative: true
        ))
        try context.save()

        let updated = try XCTUnwrap(try reforecastService.reforecast(trigger: .balanceSnapshot))
        let newPayoff = try XCTUnwrap(updated.projectedPayoffDate)
        XCTAssertLessThan(newPayoff, TestSupport.date(2027, 6, 24))
        XCTAssertLessThan(updated.remainingPaychecks, 23)

        // Original Plan v1 rows are untouched.
        let itemsAfter = try TestSupport.planItems(context, plan: plan)
        XCTAssertEqual(itemsAfter.count, 23)
        XCTAssertEqual(itemsAfter.first?.plannedDebtAfter, TestSupport.money("28665.71"))
        XCTAssertEqual(itemsAfter.last?.plannedDebtAfter, 0)
        XCTAssertEqual(plan.baselineModeledInterest, TestSupport.money("3461.16"))
        XCTAssertEqual(items.first?.plannedCardBudget, TestSupport.money("1307.69"))
    }

    // Completing the first payday exactly to plan keeps the forecast on the
    // original payoff date.
    func testOnPlanCompletionKeepsForecastOnTrack() throws {
        let (context, plan, items, debts) = try makeSeededContext()
        let first = try XCTUnwrap(items.first)
        let checkIn = PaydayCheckIn(paydayPlanItemID: first.id)
        context.insert(checkIn)
        try ReconciliationService.completeCheckIn(
            context: context, checkIn: checkIn, planItem: first, plan: plan,
            draft: balancedDraft(for: first), debtsByPlanID: debts,
            now: TestSupport.date(2026, 8, 20)
        )

        let provider = FixedDateProvider(fixed: TestSupport.date(2026, 8, 21))
        let reforecastService = ReforecastService(context: context, dateProvider: provider)
        let forecast = try XCTUnwrap(try reforecastService.reforecast(trigger: .paydayCompleted))
        XCTAssertEqual(forecast.projectedPayoffDate, TestSupport.date(2027, 6, 24))
        XCTAssertEqual(forecast.remainingPaychecks, 22)
    }

    // Checking 2 buckets derive from the ledger (F-09).
    func testChecking2BucketsAfterCompletion() throws {
        let (context, plan, items, debts) = try makeSeededContext()
        let first = try XCTUnwrap(items.first)
        let checkIn = PaydayCheckIn(paydayPlanItemID: first.id)
        context.insert(checkIn)
        try ReconciliationService.completeCheckIn(
            context: context, checkIn: checkIn, planItem: first, plan: plan,
            draft: balancedDraft(for: first), debtsByPlanID: debts,
            now: TestSupport.date(2026, 8, 20)
        )

        let provider = FixedDateProvider(fixed: TestSupport.date(2026, 8, 21))
        let service = AccountBalanceService(context: context, dateProvider: provider)
        let c2 = try service.checking2State()
        // 1694 in, 1307.69 paid out to cards.
        XCTAssertEqual(c2.totalBalance, TestSupport.money("386.31"))
        XCTAssertEqual(c2.carReserved, TestSupport.money("335.08"))
        XCTAssertEqual(c2.trainReserved, TestSupport.money("51.23"))
        XCTAssertEqual(c2.availableForDebt, .zero)
        XCTAssertFalse(c2.hasNegativeBucket)

        // Debt balances follow the payments.
        let balances = try service.debtBalances()
        let cardB = try XCTUnwrap(balances.first { $0.debt.planID == "B" })
        XCTAssertTrue(cardB.isPaidOff)
    }
}
