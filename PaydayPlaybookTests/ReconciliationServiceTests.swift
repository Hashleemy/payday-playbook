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

    /// A draft that reconciles exactly, derived from the payday's own planned
    /// figures rather than transcribed amounts — so it stays balanced whatever
    /// the fixture's numbers are.
    ///
    /// `cardPayments` defaults to the payday's whole budget on its target
    /// debt, which balances the income identities. Tests that need the check
    /// to be *on plan* — where the forecast must not move — pass the
    /// per-card split from `onPlanCardPayments` instead, because paying the
    /// same total to a different card is a different plan.
    private func balancedDraft(
        for item: PaydayPlanItem,
        cardPayments: [String: Decimal]? = nil
    ) -> ReconciliationService.DraftAmounts {
        ReconciliationService.DraftAmounts(
            actualIncome: item.plannedIncome,
            actualC1Kept: item.plannedC1Keep,
            actualC1Balance: item.plannedC1NoSpendCeiling,
            actualAllowanceSpent: nil,
            actualC2Transfer: item.plannedC2Transfer,
            actualCarReserve: item.plannedCarReserve,
            actualTrainReserve: item.plannedTrainReserve,
            cardPayments: cardPayments ?? [item.plannedTargetDebtID: item.plannedCardBudget],
            reportedBalances: [:]
        )
    }

    /// The per-card payments that land the *actual* track exactly on the
    /// plan's stored balances: `payment = before − after`.
    ///
    /// Deliberately excludes accrued interest. The plan's `balanceAfter`
    /// already has the period's interest baked in, while the actual track
    /// derives balances from recorded payments alone. Paying the
    /// interest-inclusive figure would leave every card a period's interest
    /// *below* plan and the forecast would run a check early — which is a
    /// real difference, not an on-plan check.
    private func onPlanCardPayments(
        for item: PaydayPlanItem,
        previous: PaydayPlanItem?,
        context: ModelContext,
        debts: [String: DebtAccount]
    ) throws -> [String: Decimal] {
        func balances(_ item: PaydayPlanItem) throws -> [String: Decimal] {
            let itemID = item.id
            let rows = try context.fetch(
                FetchDescriptor<PlannedCardBalance>(
                    predicate: #Predicate { $0.paydayPlanItemID == itemID }
                )
            )
            return Dictionary(rows.map { ($0.debtPlanID, $0.balanceAfter) },
                              uniquingKeysWith: { first, _ in first })
        }

        let after = try balances(item)
        let before: [String: Decimal]
        if let previous {
            before = try balances(previous)
        } else {
            before = debts.mapValues(\.startingBalance)
        }

        var payments: [String: Decimal] = [:]
        for (planID, start) in before {
            guard debts[planID] != nil, let end = after[planID] else { continue }
            let payment = (start - end).rounded2
            if payment > 0 { payments[planID] = payment }
        }
        return payments
    }

    /// The plan's own per-card balances after a payday.
    private func plannedBalances(
        for item: PaydayPlanItem, context: ModelContext
    ) throws -> [String: Decimal] {
        let itemID = item.id
        let rows = try context.fetch(
            FetchDescriptor<PlannedCardBalance>(predicate: #Predicate { $0.paydayPlanItemID == itemID })
        )
        return Dictionary(rows.map { ($0.debtPlanID, $0.balanceAfter) },
                          uniquingKeysWith: { first, _ in first })
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
            actualIncome: TestSupport.money("2400.00"),
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
            actualIncome: TestSupport.money("2400.00"),
            actualC1Kept: TestSupport.money("500.00"),
            actualC2Transfer: TestSupport.money("2100.00")
        )
        var issues = ReconciliationService.validate(draft)
        XCTAssertTrue(issues.contains { issue in
            if case .overallocatedIncome(let by) = issue { return by == TestSupport.money("200.00") }
            return false
        })

        // Card payments exceed what Checking 2 holds.
        draft = ReconciliationService.DraftAmounts(
            actualIncome: TestSupport.money("2400.00"),
            actualC1Kept: TestSupport.money("300.00"),
            actualC2Transfer: TestSupport.money("2100.00"),
            actualCarReserve: TestSupport.money("323.08"),
            actualTrainReserve: TestSupport.money("69.23"),
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

        let now = TestSupport.date(2054, 8, 20)
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
        XCTAssertEqual(entriesOf(.c2Transfer).first?.amount, first.plannedC2Transfer)
        XCTAssertEqual(entriesOf(.carReserveContribution).first?.amount, TestSupport.money("323.08"))
        XCTAssertEqual(entriesOf(.trainReserveContribution).first?.amount, TestSupport.money("69.23"))
        XCTAssertEqual(entriesOf(.c1BufferAddition).first?.amount, first.plannedBufferAdd == 0 ? nil : first.plannedBufferAdd)
        let payments = entriesOf(.cardPayment)
        XCTAssertEqual(payments.count, 1)
        XCTAssertEqual(
            payments.reduce(Decimal.zero) { $0 + $1.amount },
            first.plannedCardBudget
        )
        // Every entry links back to the check-in for the audit trail.
        XCTAssertTrue(entries.allSatisfy { $0.paydayCheckInID == checkIn.id })

        // The confirmed C1 balance became an authoritative snapshot; the paid
        // card's reported balance did too.
        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
        XCTAssertTrue(snapshots.contains { $0.cashAccount == .checking1 && $0.amount == first.plannedC1NoSpendCeiling })
    }

    /// A user-reported card balance becomes an authoritative snapshot.
    func testReportedCardBalanceBecomesAnAuthoritativeSnapshot() throws {
        let (context, plan, items, debts) = try makeSeededContext()
        let first = try XCTUnwrap(items.first)
        let checkIn = PaydayCheckIn(paydayPlanItemID: first.id)
        context.insert(checkIn)

        var draft = balancedDraft(for: first)
        let reported = TestSupport.money("1234.56")
        draft.reportedBalances = [first.plannedTargetDebtID: reported]

        _ = try ReconciliationService.completeCheckIn(
            context: context, checkIn: checkIn, planItem: first, plan: plan,
            draft: draft, debtsByPlanID: debts
        )

        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
        XCTAssertTrue(snapshots.contains {
            $0.debtPlanID == first.plannedTargetDebtID && $0.amount == reported && $0.isAuthoritative
        })
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
            now: TestSupport.date(2054, 8, 20)
        )

        let provider = FixedDateProvider(fixed: TestSupport.date(2054, 8, 21))
        let service = AccountBalanceService(context: context, dateProvider: provider)
        let before = try service.checking1State(plan: plan, planItems: items)
        XCTAssertEqual(before.actualBalance, TestSupport.money("1800.00"))
        XCTAssertEqual(before.noSpendCeiling, TestSupport.money("1800.00"))
        XCTAssertEqual(before.allowanceAvailable, TestSupport.money("300.00"))

        // Record $100 of actual allowance spending the day after payday.
        context.insert(LedgerEntry(
            effectiveDate: TestSupport.date(2054, 8, 21),
            type: .c1Spending,
            amount: TestSupport.money("100.00"),
            sourceAccount: .checking1,
            destinationAccount: .external
        ))
        try context.save()

        let after = try service.checking1State(plan: plan, planItems: items)
        XCTAssertEqual(after.actualBalance, TestSupport.money("1700.00"))
        XCTAssertEqual(after.allowanceAvailable, TestSupport.money("200.00"))
        XCTAssertEqual(after.allowanceSpentThisPeriod, TestSupport.money("100.00"))
        // Ceiling did not move.
        XCTAssertEqual(after.noSpendCeiling, TestSupport.money("1800.00"))
        // And the stored baseline row is untouched.
        XCTAssertEqual(first.plannedC1NoSpendCeiling, TestSupport.money("1800.00"))
    }

    // Required test 12: an authoritative snapshot changes the forecast while
    // Original Plan v1 stays identical.
    func testSnapshotChangesForecastNotBaseline() throws {
        let (context, plan, items, debts) = try makeSeededContext()
        _ = debts
        let provider = TestSupport.fixedToday
        let reforecastService = ReforecastService(context: context, dateProvider: provider)

        let baselineForecast = try XCTUnwrap(try reforecastService.reforecast(trigger: .manual))
        XCTAssertEqual(baselineForecast.projectedPayoffDate, TestSupport.date(2055, 6, 24))
        XCTAssertEqual(baselineForecast.remainingPaychecks, 23)

        // The user pays C down dramatically and records the real balance.
        let cardC = try XCTUnwrap(debts["C"])
        context.insert(BalanceSnapshot(
            debtAccountID: cardC.id,
            debtPlanID: "C",
            effectiveDate: TestSupport.date(2054, 8, 10),
            amount: TestSupport.money("500.00"),
            sourceType: .currentOnlineBalance,
            isAuthoritative: true
        ))
        try context.save()

        let updated = try XCTUnwrap(try reforecastService.reforecast(trigger: .balanceSnapshot))
        let newPayoff = try XCTUnwrap(updated.projectedPayoffDate)
        XCTAssertLessThan(newPayoff, TestSupport.date(2055, 6, 24))
        XCTAssertLessThan(updated.remainingPaychecks, 23)

        // Original Plan v1 rows are untouched.
        let itemsAfter = try TestSupport.planItems(context, plan: plan)
        XCTAssertEqual(itemsAfter.count, 23)
        XCTAssertEqual(itemsAfter.first?.plannedDebtAfter, TestSupport.money("34948.24"))
        XCTAssertEqual(itemsAfter.last?.plannedDebtAfter, 0)
        XCTAssertEqual(plan.baselineModeledInterest, TestSupport.money("2617.18"))
        XCTAssertEqual(items.first?.plannedCardBudget, TestSupport.money("1707.69"))
    }

    // Completing the first payday exactly to plan keeps the forecast on the
    // original payoff date.
    func testOnPlanCompletionKeepsForecastOnTrack() throws {
        let (context, plan, items, debts) = try makeSeededContext()
        let first = try XCTUnwrap(items.first)
        let checkIn = PaydayCheckIn(paydayPlanItemID: first.id)
        context.insert(checkIn)
        // Exactly on plan means the same money to the same cards, not just
        // the same total — a different split is a different plan.
        let onPlan = try onPlanCardPayments(
            for: first, previous: nil, context: context, debts: debts
        )
        var draft = balancedDraft(for: first, cardPayments: onPlan)
        // On plan also means the user confirms the balances the plan
        // predicted, so the forecast restarts from the plan's own position
        // rather than from payments alone (which carry no accrued interest).
        draft.reportedBalances = try plannedBalances(for: first, context: context)
        try ReconciliationService.completeCheckIn(
            context: context, checkIn: checkIn, planItem: first, plan: plan,
            draft: draft, debtsByPlanID: debts,
            now: TestSupport.date(2054, 8, 20)
        )

        let provider = FixedDateProvider(fixed: TestSupport.date(2054, 8, 21))
        let reforecastService = ReforecastService(context: context, dateProvider: provider)
        let forecast = try XCTUnwrap(try reforecastService.reforecast(trigger: .paydayCompleted))
        XCTAssertEqual(forecast.projectedPayoffDate, TestSupport.date(2055, 6, 24))
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
            now: TestSupport.date(2054, 8, 20)
        )

        let provider = FixedDateProvider(fixed: TestSupport.date(2054, 8, 21))
        let service = AccountBalanceService(context: context, dateProvider: provider)
        let c2 = try service.checking2State()
        // The transfer went in and the whole card budget went out, leaving
        // exactly the two obligation reserves behind.
        XCTAssertEqual(c2.totalBalance, TestSupport.money("392.31"))
        XCTAssertEqual(c2.carReserved, TestSupport.money("323.08"))
        XCTAssertEqual(c2.trainReserved, TestSupport.money("69.23"))
        XCTAssertEqual(c2.availableForDebt, .zero)
        XCTAssertFalse(c2.hasNegativeBucket)

        // Debt balances follow the payments: the target took the whole budget.
        let balances = try service.debtBalances()
        let target = try XCTUnwrap(balances.first { $0.debt.planID == first.plannedTargetDebtID })
        XCTAssertLessThan(target.balance, target.debt.startingBalance)
    }
}
