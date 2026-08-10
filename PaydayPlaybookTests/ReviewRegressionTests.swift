import XCTest
import SwiftData
@testable import PaydayPlaybook

/// Regression coverage for defects found in the release-candidate review.
final class ReviewRegressionTests: XCTestCase {

    private func makeSeededContext() throws -> (ModelContext, PlanVersion, [PaydayPlanItem], [String: DebtAccount]) {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let plan = try TestSupport.seed(context)
        let items = try TestSupport.planItems(context, plan: plan)
        let debts = try context.fetch(FetchDescriptor<DebtAccount>())
        let byID = Dictionary(uniqueKeysWithValues: debts.map { ($0.planID, $0) })
        return (context, plan, items, byID)
    }

    // Card payments without a confirmed C2 transfer are unfunded — they must
    // require an explanation, never complete silently.
    func testUnfundedPaymentsRequireExplanation() throws {
        let (context, plan, items, debts) = try makeSeededContext()
        let first = try XCTUnwrap(items.first)
        let checkIn = PaydayCheckIn(paydayPlanItemID: first.id)
        context.insert(checkIn)

        let draft = ReconciliationService.DraftAmounts(
            actualIncome: TestSupport.money("2094.00"),
            actualC1Kept: TestSupport.money("400.00"),
            actualC2Transfer: nil,
            cardPayments: ["B": TestSupport.money("1061.07")]
        )
        let issues = ReconciliationService.validate(draft)
        XCTAssertTrue(issues.contains { $0 == .missingAllocation })
        XCTAssertTrue(issues.contains { issue in
            if case .cardPaymentsExceedC2 = issue { return true }
            return false
        })

        XCTAssertThrowsError(try ReconciliationService.completeCheckIn(
            context: context, checkIn: checkIn, planItem: first, plan: plan,
            draft: draft, debtsByPlanID: debts
        ))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), 0)
    }

    // A skipped C1 balance confirmation is flagged for an explanation.
    func testMissingC1BalanceIsFlagged() {
        let draft = ReconciliationService.DraftAmounts(
            actualIncome: TestSupport.money("2094.00"),
            actualC1Kept: TestSupport.money("400.00"),
            actualC1Balance: nil,
            actualC2Transfer: TestSupport.money("1694.00")
        )
        let issues = ReconciliationService.validate(draft)
        XCTAssertTrue(issues.contains { $0 == .missingC1Balance })
        XCTAssertFalse(issues.first { $0 == .missingC1Balance }!.isBlocking)
    }

    // Outside funds are part of the reported transfer, not an extra C2 credit.
    func testOutsideFundsNotDoubleCountedInC2() throws {
        let (context, plan, items, debts) = try makeSeededContext()
        let first = try XCTUnwrap(items.first)
        let checkIn = PaydayCheckIn(paydayPlanItemID: first.id)
        context.insert(checkIn)

        let draft = ReconciliationService.DraftAmounts(
            actualIncome: TestSupport.money("2094.00"),
            outsideFundsUsed: TestSupport.money("500.00"),
            actualC1Kept: TestSupport.money("400.00"),
            actualC1Balance: TestSupport.money("1300.00"),
            actualC2Transfer: TestSupport.money("2194.00"),
            actualCarReserve: TestSupport.money("335.08"),
            actualTrainReserve: TestSupport.money("51.23"),
            cardPayments: ["B": TestSupport.money("1061.07"), "D": TestSupport.money("246.62")]
        )
        let result = try ReconciliationService.completeCheckIn(
            context: context, checkIn: checkIn, planItem: first, plan: plan,
            draft: draft, debtsByPlanID: debts,
            now: TestSupport.date(2026, 8, 20)
        )
        XCTAssertEqual(result.checkIn.status, .completed)

        let provider = FixedDateProvider(fixed: TestSupport.date(2026, 8, 21))
        let c2 = try AccountBalanceService(context: context, dateProvider: provider).checking2State()
        // 2,194 in (already including the $500) − 1,307.69 paid out.
        XCTAssertEqual(c2.totalBalance, TestSupport.money("886.31"))
        XCTAssertEqual(c2.availableForDebt, TestSupport.money("500.00"))

        // The windfall is still on the ledger for the audit trail.
        let windfalls = try context.fetch(FetchDescriptor<LedgerEntry>())
            .filter { $0.type == .windfall }
        XCTAssertEqual(windfalls.count, 1)
        XCTAssertNil(windfalls.first?.destinationAccount)
    }

    // Prior-period spending reported at check-in does not eat the new period's
    // allowance.
    func testPriorPeriodSpendingKeepsNewAllowanceFull() throws {
        let (context, plan, items, debts) = try makeSeededContext()
        let first = try XCTUnwrap(items.first)
        let checkIn = PaydayCheckIn(paydayPlanItemID: first.id)
        context.insert(checkIn)

        let draft = ReconciliationService.DraftAmounts(
            actualIncome: TestSupport.money("2094.00"),
            actualC1Kept: TestSupport.money("400.00"),
            actualC1Balance: TestSupport.money("1150.00"),
            actualAllowanceSpent: TestSupport.money("150.00"),
            actualC2Transfer: TestSupport.money("1694.00"),
            actualCarReserve: TestSupport.money("335.08"),
            actualTrainReserve: TestSupport.money("51.23"),
            cardPayments: ["B": TestSupport.money("1061.07"), "D": TestSupport.money("246.62")]
        )
        try ReconciliationService.completeCheckIn(
            context: context, checkIn: checkIn, planItem: first, plan: plan,
            draft: draft, debtsByPlanID: debts,
            now: TestSupport.date(2026, 8, 20)
        )

        let provider = FixedDateProvider(fixed: TestSupport.date(2026, 8, 20))
        let service = AccountBalanceService(context: context, dateProvider: provider)
        let c1 = try service.checking1State(plan: plan, planItems: items)
        // The confirmed balance is authoritative; the reported prior-period
        // spending belongs to the closed period, so the new allowance is full.
        XCTAssertEqual(c1.actualBalance, TestSupport.money("1150.00"))
        XCTAssertEqual(c1.allowanceAvailable, TestSupport.money("300.00"))
        XCTAssertEqual(c1.allowanceSpentThisPeriod, .zero)
    }

    // Cards already at zero before a projection get no phantom payoff date.
    func testAlreadyPaidCardsGetNoNewPayoffDate() {
        let debts = [
            DebtCalculationEngine.EngineDebt(planID: "B", apr: TestSupport.money("0.2999"), balance: .zero),
            DebtCalculationEngine.EngineDebt(planID: "D", apr: TestSupport.money("0.2899"), balance: TestSupport.money("1000.00"))
        ]
        let paydays = [
            DebtCalculationEngine.EnginePayday(sequence: 1, date: TestSupport.date(2026, 9, 3), cardBudget: TestSupport.money("1407.69"))
        ]
        let result = DebtCalculationEngine.project(debts: debts, paydays: paydays)
        XCTAssertNil(result.perCardPayoffDates["B"])
        XCTAssertNotNil(result.perCardPayoffDates["D"])
    }

    // An overdue, still-open payday stays in the projection.
    func testOverdueOpenPaydayStaysInForecast() throws {
        let (context, _, _, _) = try makeSeededContext()
        // Aug 21: payday #1 has passed and was never completed.
        let provider = FixedDateProvider(fixed: TestSupport.date(2026, 8, 21))
        let forecast = try XCTUnwrap(
            try ReforecastService(context: context, dateProvider: provider).reforecast(trigger: .manual)
        )
        // All 23 checks, including the overdue one, still project to baseline.
        XCTAssertEqual(forecast.projectedPayoffDate, TestSupport.date(2027, 6, 24))
        XCTAssertEqual(forecast.remainingPaychecks, 23)
    }

    // A locale-consistent money round trip: what the field writes, it re-reads.
    func testMoneyEditingRoundTrip() {
        let values = ["2094.00", "335.08", "0.99", "12345.67"].map(TestSupport.money)
        for value in values {
            let text = MoneyFormat.editingString(value)
            XCTAssertEqual(MoneyFormat.parse(text), value, "round trip failed for \(value)")
        }
    }

    // A malformed backup must not destroy existing data.
    func testFailedRestorePreservesExistingData() throws {
        let (context, _, _, _) = try makeSeededContext()
        var backup = try ExportService.buildBackup(context: context)
        backup.debts[0].startingBalance = "not-a-number"

        XCTAssertThrowsError(try ExportService.restore(backup, context: context))

        // Nothing was deleted by the failed restore.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DebtAccount>()), 6)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PaydayPlanItem>()), 23)
    }

    // Exported CSV neutralizes leading formula characters.
    func testCSVFormulaNeutralization() {
        XCTAssertEqual(ExportService.csvEscape("=HYPERLINK(evil)"), "'=HYPERLINK(evil)")
        XCTAssertEqual(ExportService.csvEscape("+123"), "'+123")
        XCTAssertEqual(ExportService.csvEscape("normal note"), "normal note")
    }
}
