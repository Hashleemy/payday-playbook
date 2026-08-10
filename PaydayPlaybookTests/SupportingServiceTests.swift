import XCTest
import SwiftData
@testable import PaydayPlaybook

/// Money math, notification defaults, milestones, and calendar merge coverage.
final class SupportingServiceTests: XCTestCase {

    func testCurrencyRoundingIsHalfAwayFromZero() {
        XCTAssertEqual(TestSupport.money("1.005").rounded2, TestSupport.money("1.01"))
        XCTAssertEqual(TestSupport.money("1.004").rounded2, TestSupport.money("1.00"))
        XCTAssertEqual(TestSupport.money("-1.005").rounded2, TestSupport.money("-1.01"))
        XCTAssertEqual(TestSupport.money("2.675").rounded2, TestSupport.money("2.68"))
        XCTAssertTrue(TestSupport.money("0.004").isZeroMoney)
        XCTAssertFalse(TestSupport.money("0.006").isZeroMoney)
    }

    func testMoneyParsing() {
        XCTAssertEqual(MoneyFormat.parse("$1,234.56"), TestSupport.money("1234.56"))
        XCTAssertEqual(MoneyFormat.parse("300"), TestSupport.money("300"))
        XCTAssertNil(MoneyFormat.parse(""))
        XCTAssertNil(MoneyFormat.parse("abc"))
    }

    func testNotificationDefaultsMatchSpec() {
        let defaults = NotificationPreference.seedDefaults()
        func pref(_ kind: NotificationKind) -> NotificationPreference? {
            defaults.first { $0.type == kind }
        }
        XCTAssertEqual(pref(.paydayMorning)?.hour, 8)
        XCTAssertEqual(pref(.paydayEveningIncomplete)?.hour, 19)
        XCTAssertEqual(pref(.cardDueSoon)?.hour, 9)
        XCTAssertEqual(pref(.cardDueSoon)?.leadDays, 3)
        XCTAssertEqual(pref(.cardDueToday)?.hour, 9)
        XCTAssertEqual(pref(.weeklySummary)?.hour, 18)
        XCTAssertEqual(pref(.milestoneApproaching)?.leadDays, 1)
        // Lock-screen content defaults to generic for every reminder.
        XCTAssertTrue(defaults.allSatisfy { !$0.detailedLockScreenContent })
    }

    func testMilestoneAchievementFromBalances() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context)
        let debts = try context.fetch(FetchDescriptor<DebtAccount>())
        let cardB = try XCTUnwrap(debts.first { $0.planID == "B" })

        // Pay B to zero and record $5,000+ of total elimination.
        context.insert(BalanceSnapshot(
            debtAccountID: cardB.id, debtPlanID: "B",
            effectiveDate: TestSupport.date(2026, 8, 20),
            amount: .zero, sourceType: .currentOnlineBalance
        ))
        let cardC = try XCTUnwrap(debts.first { $0.planID == "C" })
        context.insert(BalanceSnapshot(
            debtAccountID: cardC.id, debtPlanID: "C",
            effectiveDate: TestSupport.date(2026, 8, 20),
            amount: TestSupport.money("7000.00"), sourceType: .currentOnlineBalance
        ))
        try context.save()

        let provider = FixedDateProvider(fixed: TestSupport.date(2026, 8, 21))
        try MilestoneService(context: context, dateProvider: provider).refreshAchievements()

        let milestones = try context.fetch(FetchDescriptor<Milestone>())
        let cardBMilestone = try XCTUnwrap(milestones.first { $0.relatedDebtPlanID == "B" })
        XCTAssertNotNil(cardBMilestone.achievedDate)
        let fiveK = try XCTUnwrap(milestones.first { $0.thresholdAmount == TestSupport.money("5000.00") })
        XCTAssertNotNil(fiveK.achievedDate)
        let tenK = try XCTUnwrap(milestones.first { $0.thresholdAmount == TestSupport.money("10000.00") })
        XCTAssertNil(tenK.achievedDate)
        let debtFree = try XCTUnwrap(milestones.first { $0.type == .debtFree })
        XCTAssertNil(debtFree.achievedDate)
    }

    func testCalendarMergesPaydaysAndEntries() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context)
        context.insert(LedgerEntry(
            effectiveDate: TestSupport.date(2026, 8, 21),
            type: .c1Spending,
            amount: TestSupport.money("40.00"),
            sourceAccount: .checking1,
            destinationAccount: .external
        ))
        try context.save()

        let provider = FixedDateProvider(fixed: TestSupport.date(2026, 8, 10))
        let service = CalendarEventService(context: context, dateProvider: provider)
        let events = try service.events(
            from: TestSupport.date(2026, 8, 1),
            to: TestSupport.date(2026, 8, 31)
        )

        let paydays = events.filter { $0.kind == .paydayFuture || $0.kind == .paydayDue }
        XCTAssertEqual(paydays.count, 1)
        XCTAssertEqual(paydays.first?.date, TestSupport.date(2026, 8, 20))
        XCTAssertEqual(paydays.first?.kind, .paydayFuture)

        XCTAssertTrue(events.contains { $0.kind == .milestone })   // Card B baseline payoff Aug 20
        XCTAssertTrue(events.contains { $0.kind == .entry && $0.date == TestSupport.date(2026, 8, 21) })

        // Completing the payday flips the marker.
        let plan = try XCTUnwrap(try PlanSeeder.existingBaseline(context: context))
        let items = try TestSupport.planItems(context, plan: plan)
        let checkIn = PaydayCheckIn(paydayPlanItemID: items[0].id)
        checkIn.status = .completed
        context.insert(checkIn)
        try context.save()
        let after = try service.events(
            from: TestSupport.date(2026, 8, 1),
            to: TestSupport.date(2026, 8, 31)
        )
        XCTAssertTrue(after.contains { $0.kind == .paydayCompleted })
    }

    func testDebtFreeDetection() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context)
        let provider = FixedDateProvider(fixed: TestSupport.date(2027, 7, 1))
        let service = MilestoneService(context: context, dateProvider: provider)
        XCTAssertFalse(try service.isDebtFree())

        for debt in try context.fetch(FetchDescriptor<DebtAccount>()) {
            context.insert(BalanceSnapshot(
                debtAccountID: debt.id, debtPlanID: debt.planID,
                effectiveDate: TestSupport.date(2027, 6, 24),
                amount: .zero, sourceType: .currentOnlineBalance
            ))
        }
        try context.save()
        XCTAssertTrue(try service.isDebtFree())
    }

    func testChecking1BeforeFirstPayday() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let plan = try TestSupport.seed(context)
        let items = try TestSupport.planItems(context, plan: plan)
        let provider = TestSupport.fixedToday   // Aug 10, 2026
        let service = AccountBalanceService(context: context, dateProvider: provider)
        let c1 = try service.checking1State(plan: plan, planItems: items)
        // Before the first payday: $900 actual, $900 ceiling, no allowance yet.
        XCTAssertEqual(c1.actualBalance, TestSupport.money("900.00"))
        XCTAssertEqual(c1.noSpendCeiling, TestSupport.money("900.00"))
        XCTAssertFalse(c1.allowanceActive)
        XCTAssertEqual(c1.allowanceAvailable, .zero)
    }
}
