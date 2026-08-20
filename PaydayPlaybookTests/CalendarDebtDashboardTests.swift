import XCTest
import SwiftData
@testable import PaydayPlaybook

/// T-25 (V4-08, R-29): the Calendar debt dashboard. Exact wording — "paid
/// toward", never "paid off", for dollars; the verbatim overage rendering;
/// the upcoming allocation labeled with its availability date; the
/// content-fingerprint refresh (same-count edits included); and every figure
/// reconciling to the ledger to the cent through the allocation service.
/// All fixture values are fictional.
@MainActor
final class CalendarDebtDashboardTests: XCTestCase {

    // MARK: - Wording (exact, string-matched)

    func testPaidTowardDebtsLabelIsExact() {
        XCTAssertEqual(DebtDashboardCopy.paidThisMonthLabel, "Paid toward debts this month")
    }

    func testDollarsAreNeverCalledPaidOff() {
        let staticCopy = [
            DebtDashboardCopy.cardTitle,
            DebtDashboardCopy.paidThisMonthLabel,
            DebtDashboardCopy.clearedThisMonthLabel,
            DebtDashboardCopy.plannedAllocationLabel,
            DebtDashboardCopy.carryInLabel,
            DebtDashboardCopy.usedLabel,
            DebtDashboardCopy.remainingLabel,
            DebtDashboardCopy.plannedAllocationFootnote,
            DebtDashboardCopy.overageText(TestSupport.money("120.00")),
            DebtDashboardCopy.upcomingText(
                amount: TestSupport.money("900.00"), availableOn: TestSupport.date(2054, 9, 3)
            ),
            DebtDashboardCopy.nextPaydayLabel(TestSupport.date(2054, 9, 3)),
            DebtDashboardCopy.beforeFirstPaydayText(
                amount: TestSupport.money("900.00"), availableOn: TestSupport.date(2054, 8, 20)
            ),
            DebtDashboardCopy.currentCycleHeader(
                start: TestSupport.date(2054, 8, 20), nextPayday: TestSupport.date(2054, 9, 3)
            )
        ]
        for text in staticCopy {
            XCTAssertFalse(
                text.lowercased().contains("paid off"),
                "dollar copy must never say 'paid off': \(text)"
            )
        }
    }

    func testOverageRendersVerbatimWithZeroRemaining() {
        let overage = TestSupport.money("300.00")
        let text = DebtDashboardCopy.overageText(overage)
        XCTAssertTrue(text.hasPrefix("$0 remaining · +"), "overage must lead with $0 remaining, got: \(text)")
        XCTAssertTrue(text.hasSuffix(" over planned allocation"), "overage must name the planned allocation, got: \(text)")
        XCTAssertTrue(text.contains(MoneyFormat.string(overage)))
        XCTAssertFalse(text.contains("-"), "an overage is never shown as negative money")
    }

    func testUpcomingAllocationIsLabeledWithItsAvailabilityDate() {
        let date = TestSupport.date(2054, 9, 3)
        let text = DebtDashboardCopy.upcomingText(amount: TestSupport.money("900.00"), availableOn: date)
        XCTAssertTrue(text.contains(DateMath.mediumString(date)))
        XCTAssertTrue(text.contains("becomes available"))
        XCTAssertFalse(text.lowercased().contains("spendable"))
    }

    func testPlannedAllocationIsNeverPresentedAsAccountCash() {
        XCTAssertTrue(DebtDashboardCopy.plannedAllocationFootnote.contains("isn't your account cash"))
    }

    func testClearedIsReservedForDebtsNotDollars() {
        let line = DebtDashboardCopy.clearedDebtLine(
            ClearedDebt(id: UUID(), name: "Card A", clearedOn: TestSupport.date(2054, 8, 22))
        )
        XCTAssertTrue(line.contains("Card A"))
        XCTAssertTrue(line.contains("cleared"))
        XCTAssertTrue(line.contains(DateMath.mediumString(TestSupport.date(2054, 8, 22))))
    }

    // MARK: - Content fingerprint (same-count edits must refresh)

    func testAnAmountEditWithEqualRowCountsChangesTheFingerprint() {
        let id = UUID()
        let before = DebtAllocationFingerprint.fingerprint(
            entries: [(id, TestSupport.date(2054, 8, 21))], activePlanIDs: []
        )
        // Editing a row bumps its updatedAt; the row count stays equal.
        let after = DebtAllocationFingerprint.fingerprint(
            entries: [(id, TestSupport.date(2054, 8, 22))], activePlanIDs: []
        )
        XCTAssertNotEqual(before, after, "a same-count edit must still refresh the dashboard")
    }

    func testInsertingAndDeletingRowsChangesTheFingerprint() {
        let first = (UUID(), TestSupport.date(2054, 8, 21))
        let second = (UUID(), TestSupport.date(2054, 8, 22))
        let one = DebtAllocationFingerprint.fingerprint(entries: [first], activePlanIDs: [])
        let two = DebtAllocationFingerprint.fingerprint(entries: [first, second], activePlanIDs: [])
        XCTAssertNotEqual(one, two)
        XCTAssertEqual(
            DebtAllocationFingerprint.fingerprint(entries: [first], activePlanIDs: []), one,
            "deleting back to the original content restores the original fingerprint"
        )
    }

    func testTheFingerprintIgnoresFetchOrder() {
        let first = (UUID(), TestSupport.date(2054, 8, 21))
        let second = (UUID(), TestSupport.date(2054, 8, 22))
        XCTAssertEqual(
            DebtAllocationFingerprint.fingerprint(entries: [first, second], activePlanIDs: []),
            DebtAllocationFingerprint.fingerprint(entries: [second, first], activePlanIDs: []),
            "SwiftData fetch order must not fake a content change"
        )
    }

    func testActivatingADifferentPlanChangesTheFingerprint() {
        let entry = (UUID(), TestSupport.date(2054, 8, 21))
        let planA = UUID()
        let planB = UUID()
        XCTAssertNotEqual(
            DebtAllocationFingerprint.fingerprint(entries: [entry], activePlanIDs: [planA]),
            DebtAllocationFingerprint.fingerprint(entries: [entry], activePlanIDs: [planB]),
            "a plan activation re-anchors the fold and must refresh the dashboard"
        )
    }

    // MARK: - Dashboard state reconciles to the service to the cent

    private func makeStore() throws -> (container: ModelContainer, context: ModelContext) {
        let container = try TestSupport.makeContainer()
        return (container, ModelContext(container))
    }

    private func insertPlan(
        _ context: ModelContext,
        firstPayday: Date = TestSupport.date(2054, 8, 20),
        budgets: [String]
    ) throws {
        let plan = PlanVersion(
            name: "Plan v1",
            createdAt: TestSupport.date(2054, 8, 1),
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
        context.insert(plan)
        for (index, budget) in budgets.enumerated() {
            context.insert(PaydayPlanItem(
                planVersionID: plan.id,
                sequenceNumber: index + 1,
                date: DateMath.addingDays(14 * index, to: firstPayday),
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
        try context.save()
    }

    func testTheDashboardStateMatchesTheServiceToTheCent() throws {
        let store = try makeStore()
        try insertPlan(store.context, budgets: ["1000.00", "1000.00"])
        for (day, amount) in [(TestSupport.date(2054, 8, 21), "199.99"), (TestSupport.date(2054, 8, 23), "0.01")] {
            store.context.insert(LedgerEntry(
                effectiveDate: day,
                type: .cardPayment,
                amount: TestSupport.money(amount),
                sourceAccount: .checking2,
                destinationAccount: .card
            ))
        }
        try store.context.save()

        let environment = AppEnvironment(dateProvider: FixedDateProvider(fixed: TestSupport.date(2054, 8, 25)))
        let state = CalendarDebtDashboardState.load(context: store.context, environment: environment)

        let cycle = try XCTUnwrap(state.cycle)
        XCTAssertEqual(cycle.paidThisCycle, TestSupport.money("200.00"))
        XCTAssertEqual(cycle.remaining, TestSupport.money("800.00"))
        let month = try XCTUnwrap(state.month)
        XCTAssertEqual(month.paidTowardDebts, TestSupport.money("200.00"))

        // The state carries the service's figures untouched (no view math).
        let service = DebtAllocationService(
            context: store.context,
            dateProvider: FixedDateProvider(fixed: TestSupport.date(2054, 8, 25))
        )
        XCTAssertEqual(state.cycle, try service.currentCycle(asOf: TestSupport.date(2054, 8, 25)))
        XCTAssertEqual(state.month, try service.monthlyProgress(month: TestSupport.date(2054, 8, 25)))
        XCTAssertTrue(state.showsCard)
    }

    func testBeforeTheFirstPaydayTheStateCarriesTheUpcomingAllocation() throws {
        let store = try makeStore()
        try insertPlan(store.context, budgets: ["900.00"])
        let environment = AppEnvironment(dateProvider: FixedDateProvider(fixed: TestSupport.date(2054, 8, 10)))
        let state = CalendarDebtDashboardState.load(context: store.context, environment: environment)

        XCTAssertNil(state.cycle)
        let upcoming = try XCTUnwrap(state.upcoming)
        XCTAssertEqual(upcoming.availableOn, TestSupport.date(2054, 8, 20))
        XCTAssertEqual(upcoming.amount, TestSupport.money("900.00"))
        XCTAssertTrue(state.showsCard)
    }

    func testTheCardStaysHiddenWithNoPlanAndNoActivity() throws {
        let store = try makeStore()
        let environment = AppEnvironment(dateProvider: FixedDateProvider(fixed: TestSupport.date(2054, 8, 10)))
        let state = CalendarDebtDashboardState.load(context: store.context, environment: environment)
        XCTAssertNil(state.cycle)
        XCTAssertNil(state.upcoming)
        XCTAssertFalse(state.showsCard, "an empty install gets no fabricated debt story")
    }

    func testPaymentActivityAloneShowsTheCard() throws {
        // No plan at all, but real payments this month: the month section
        // still has an honest story to tell.
        let store = try makeStore()
        store.context.insert(LedgerEntry(
            effectiveDate: TestSupport.date(2054, 8, 5),
            type: .cardPayment,
            amount: TestSupport.money("75.00"),
            sourceAccount: .checking2,
            destinationAccount: .card
        ))
        try store.context.save()

        let environment = AppEnvironment(dateProvider: FixedDateProvider(fixed: TestSupport.date(2054, 8, 10)))
        let state = CalendarDebtDashboardState.load(context: store.context, environment: environment)
        XCTAssertNil(state.cycle)
        XCTAssertEqual(state.month?.paidTowardDebts, TestSupport.money("75.00"))
        XCTAssertTrue(state.showsCard)
    }
}
