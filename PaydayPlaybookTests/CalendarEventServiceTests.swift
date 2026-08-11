import XCTest
import SwiftData
@testable import PaydayPlaybook

/// V2-12 calendar merge: taxonomy, ordering, statuses, due-date behavior,
/// deep links, and accessibility text. Uses the seeded Original Plan v1
/// fixture (first payday Aug 20 2026) with a pinned "today" of Aug 10 2026
/// unless a test says otherwise.
final class CalendarEventServiceTests: XCTestCase {

    private func makeService(
        today: Date = TestSupport.date(2026, 8, 10)
    ) throws -> (CalendarEventService, ModelContext) {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context)
        let service = CalendarEventService(context: context, dateProvider: FixedDateProvider(fixed: today))
        return (service, context)
    }

    private func augustEvents(_ service: CalendarEventService) throws -> [CalendarEventService.Event] {
        try service.events(from: TestSupport.date(2026, 8, 1), to: TestSupport.date(2026, 8, 31))
    }

    // MARK: - Merge & ordering

    func testPaydayDayMergesTheFullPlayByPlay() throws {
        let (service, _) = try makeService()
        let events = try augustEvents(service)
        let paydayDay = events.filter { $0.date == TestSupport.date(2026, 8, 20) }

        XCTAssertTrue(paydayDay.contains { $0.kind == .payday && $0.id == "payday-1" })
        XCTAssertTrue(paydayDay.contains { $0.kind == .transfer }, "C2 transfer must render as an account-transfer action")
        XCTAssertTrue(paydayDay.contains { $0.kind == .reserve && $0.title.localizedCaseInsensitiveContains("buffer") },
                      "check 1 adds $100 to the protected buffer")
        XCTAssertTrue(paydayDay.contains { $0.kind == .reserve && $0.title.localizedCaseInsensitiveContains("car") })
        XCTAssertTrue(paydayDay.contains { $0.kind == .reserve && $0.title.localizedCaseInsensitiveContains("train") })
        XCTAssertTrue(paydayDay.contains { $0.kind == .debtPayment && ($0.detail?.contains("target") ?? false) })

        // Income shows on the payday event.
        let payday = try XCTUnwrap(paydayDay.first { $0.kind == .payday })
        XCTAssertTrue(payday.detail?.contains("Income") ?? false)

        // Same-day ordering follows the allocation story.
        let orders = paydayDay.map(\.kind.dayOrder)
        XCTAssertEqual(orders, orders.sorted(), "events within a day must follow allocation order")
    }

    func testEventsAreSortedByDateThenDayOrder() throws {
        let (service, context) = try makeService()
        context.insert(LedgerEntry(
            effectiveDate: TestSupport.date(2026, 8, 21),
            type: .c1Spending,
            amount: TestSupport.money("40.00"),
            sourceAccount: .checking1,
            destinationAccount: .external
        ))
        try context.save()
        let events = try augustEvents(service)
        let dates = events.map(\.date)
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertTrue(events.contains { $0.kind == .entry && $0.date == TestSupport.date(2026, 8, 21) && $0.status == .actual })
        XCTAssertTrue(events.contains { $0.kind == .milestone })  // Card B payoff milestone
    }

    // MARK: - Statuses (Planned / Completed / Needs attention / Actual)

    func testFuturePaydayIsPlannedAndCompletionFlipsStatus() throws {
        let (service, context) = try makeService()
        var events = try augustEvents(service)
        XCTAssertEqual(try XCTUnwrap(events.first { $0.kind == .payday }).status, .planned)

        let plan = try XCTUnwrap(try PlanSeeder.existingBaseline(context: context))
        let items = try TestSupport.planItems(context, plan: plan)
        let checkIn = PaydayCheckIn(paydayPlanItemID: items[0].id)
        checkIn.status = .completed
        context.insert(checkIn)
        try context.save()

        events = try augustEvents(service)
        XCTAssertEqual(try XCTUnwrap(events.first { $0.kind == .payday }).status, .completed)
    }

    func testOverduePaydayWithoutCheckInNeedsAttention() throws {
        let (service, _) = try makeService(today: TestSupport.date(2026, 8, 25))
        let events = try augustEvents(service)
        let payday = try XCTUnwrap(events.first { $0.kind == .payday })
        XCTAssertEqual(payday.status, .needsAttention)
        XCTAssertTrue(payday.detail?.contains("still open") ?? false)
    }

    func testShortfallPaydayNeedsAttentionWithExactGap() throws {
        let (service, context) = try makeService()
        let plan = try XCTUnwrap(try PlanSeeder.existingBaseline(context: context))
        let items = try TestSupport.planItems(context, plan: plan)
        items[0].shortfallAmount = TestSupport.money("55.00")
        try context.save()
        let events = try augustEvents(service)
        let payday = try XCTUnwrap(events.first { $0.kind == .payday })
        XCTAssertEqual(payday.status, .needsAttention)
        XCTAssertTrue(payday.detail?.contains("55.00") ?? false, "R-09 shows the exact gap")
    }

    func testCheckInExceptionSurfacesAsNeedsAttention() throws {
        let (service, context) = try makeService(today: TestSupport.date(2026, 8, 21))
        let plan = try XCTUnwrap(try PlanSeeder.existingBaseline(context: context))
        let items = try TestSupport.planItems(context, plan: plan)
        let checkIn = PaydayCheckIn(paydayPlanItemID: items[0].id)
        checkIn.status = .needsAttention
        context.insert(checkIn)
        try context.save()
        let events = try augustEvents(service)
        XCTAssertEqual(try XCTUnwrap(events.first { $0.kind == .payday }).status, .needsAttention)
    }

    // MARK: - Due dates

    func testDueDayClampsToShortMonthsWithoutDuplicates() throws {
        let (service, context) = try makeService()
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        debt.dueDayOfMonth = 31
        try context.save()

        let february = try service.events(from: TestSupport.date(2027, 2, 1), to: TestSupport.date(2027, 2, 28))
        let dueEvents = february.filter { $0.kind == .debtDue && $0.id.contains(debt.id.uuidString) }
        XCTAssertEqual(dueEvents.count, 1)
        XCTAssertEqual(dueEvents.first?.date, TestSupport.date(2027, 2, 28))
        XCTAssertTrue(dueEvents.first?.detail?.contains("last day") ?? false, "clamping is explained in text")
    }

    func testDueDateEditIsProspectiveAndCreatesNoDuplicates() throws {
        let (service, context) = try makeService()
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        debt.dueDayOfMonth = 12
        try context.save()

        let september = { try service.events(from: TestSupport.date(2026, 9, 1), to: TestSupport.date(2026, 9, 30)) }
        var dueEvents = try september().filter { $0.kind == .debtDue && $0.id.contains(debt.id.uuidString) }
        XCTAssertEqual(dueEvents.map(\.date), [TestSupport.date(2026, 9, 12)])

        debt.dueDayOfMonth = 15
        try context.save()
        dueEvents = try september().filter { $0.kind == .debtDue && $0.id.contains(debt.id.uuidString) }
        XCTAssertEqual(dueEvents.map(\.date), [TestSupport.date(2026, 9, 15)], "the edit replaces the future event — no duplicate on the old day")
    }

    func testWeekendShiftRuleMovesTheMarkerOnlyWhenSelected() throws {
        let (service, context) = try makeService()
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        // Sep 12 2026 is a Saturday.
        debt.dueDayOfMonth = 12
        try context.save()

        var events = try service.events(from: TestSupport.date(2026, 9, 1), to: TestSupport.date(2026, 9, 30))
        XCTAssertTrue(events.contains { $0.kind == .debtDue && $0.date == TestSupport.date(2026, 9, 12) })

        debt.dueDateShiftRule = .nextWeekday
        try context.save()
        events = try service.events(from: TestSupport.date(2026, 9, 1), to: TestSupport.date(2026, 9, 30))
        XCTAssertTrue(events.contains { $0.kind == .debtDue && $0.date == TestSupport.date(2026, 9, 14) })
        XCTAssertFalse(events.contains { $0.kind == .debtDue && $0.date == TestSupport.date(2026, 9, 12) })
    }

    func testArchivedDebtRendersNoDueEvents() throws {
        let (service, context) = try makeService()
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        debt.dueDayOfMonth = 12
        debt.isArchived = true
        try context.save()
        let events = try service.events(from: TestSupport.date(2026, 9, 1), to: TestSupport.date(2026, 9, 30))
        XCTAssertFalse(events.contains { $0.kind == .debtDue && $0.id.contains(debt.id.uuidString) })
    }

    func testObligationDueDatesRenderAndArchiveHides() throws {
        let (service, context) = try makeService()
        let obligation = RecurringObligation(name: "Rent", amount: TestSupport.money("1200.00"), cadence: .monthly, dueDay: 1)
        context.insert(obligation)
        try context.save()

        var events = try service.events(from: TestSupport.date(2026, 9, 1), to: TestSupport.date(2026, 9, 30))
        let rent = events.filter { $0.kind == .obligationDue && $0.title.contains("Rent") }
        XCTAssertEqual(rent.map(\.date), [TestSupport.date(2026, 9, 1)])
        XCTAssertTrue(rent.first?.detail?.contains("1,200") ?? false)

        obligation.isArchived = true
        try context.save()
        events = try service.events(from: TestSupport.date(2026, 9, 1), to: TestSupport.date(2026, 9, 30))
        XCTAssertFalse(events.contains { $0.kind == .obligationDue && $0.title.contains("Rent") })
    }

    // MARK: - Reforecast markers

    func testReforecastSnapshotRendersMarkerButInitialSeedDoesNot() throws {
        let (service, context) = try makeService()
        let plan = try XCTUnwrap(try PlanSeeder.existingBaseline(context: context))
        context.insert(ForecastSnapshot(
            calculatedAt: TestSupport.date(2026, 8, 5),
            sourcePlanVersionID: plan.id,
            triggerType: .initialSeed,
            projectedPayoffDate: TestSupport.date(2027, 6, 24),
            remainingPaychecks: 23,
            estimatedRemainingInterest: TestSupport.money("3461.16"),
            perCardPayoffDates: [],
            summaryExplanation: "seed"
        ))
        context.insert(ForecastSnapshot(
            calculatedAt: TestSupport.date(2026, 8, 22),
            sourcePlanVersionID: plan.id,
            triggerType: .paydayCompleted,
            projectedPayoffDate: TestSupport.date(2027, 6, 24),
            remainingPaychecks: 22,
            estimatedRemainingInterest: TestSupport.money("3300.00"),
            perCardPayoffDates: [],
            summaryExplanation: "after check 1"
        ))
        try context.save()

        let events = try augustEvents(service)
        let markers = events.filter { $0.kind == .reforecast }
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.date, TestSupport.date(2026, 8, 22))
        XCTAssertEqual(markers.first?.status, .reforecast)
    }

    // MARK: - Deep links

    func testEveryLinkedEventCarriesEntityIdentity() throws {
        let (service, context) = try makeService()
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        debt.dueDayOfMonth = 25
        let entry = LedgerEntry(
            effectiveDate: TestSupport.date(2026, 8, 21),
            type: .cardPayment,
            amount: TestSupport.money("100.00"),
            sourceAccount: .checking2,
            destinationAccount: .external
        )
        context.insert(entry)
        try context.save()

        let events = try augustEvents(service)
        let plan = try XCTUnwrap(try PlanSeeder.existingBaseline(context: context))
        let items = try TestSupport.planItems(context, plan: plan)

        XCTAssertEqual(
            events.first { $0.kind == .payday }?.link,
            .checkIn(itemID: items[0].id)
        )
        XCTAssertEqual(
            events.first { $0.kind == .debtDue && $0.id.contains(debt.id.uuidString) }?.link,
            .debt(planID: "B")
        )
        XCTAssertEqual(
            events.first { $0.kind == .entry && $0.id.contains(entry.id.uuidString) }?.link,
            .entry(entryID: entry.id)
        )
        let milestone = try XCTUnwrap(events.first { $0.kind == .milestone })
        if case .milestone = milestone.link {} else {
            XCTFail("milestone events must deep-link to the milestone")
        }
    }

    // MARK: - Filters

    func testFiltersPartitionTheTaxonomy() throws {
        let (service, context) = try makeService(today: TestSupport.date(2026, 8, 25))
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        debt.dueDayOfMonth = 28
        try context.save()
        let events = try augustEvents(service)

        let dueDates = events.filter { CalendarEventService.Filter.dueDates.includes($0) }
        XCTAssertTrue(dueDates.allSatisfy { [.debtDue, .obligationDue].contains($0.kind) })
        XCTAssertFalse(dueDates.isEmpty)

        let needs = events.filter { CalendarEventService.Filter.needsAttention.includes($0) }
        XCTAssertTrue(needs.contains { $0.kind == .payday }, "the overdue payday shows under Needs attention")
        XCTAssertTrue(needs.allSatisfy { $0.status == .needsAttention })

        let moves = events.filter { CalendarEventService.Filter.moneyMoves.includes($0) }
        XCTAssertTrue(moves.contains { $0.kind == .transfer })
        XCTAssertTrue(moves.contains { $0.kind == .reserve })
    }

    // MARK: - Accessibility

    func testAccessibilityDescriptionSpeaksKindTitleAndStatus() throws {
        let (service, _) = try makeService(today: TestSupport.date(2026, 8, 25))
        let events = try augustEvents(service)
        let payday = try XCTUnwrap(events.first { $0.kind == .payday })
        XCTAssertTrue(payday.accessibilityDescription.contains("Payday"))
        XCTAssertTrue(payday.accessibilityDescription.contains("Needs attention"),
                      "status must be spoken, not implied by color")
        for event in events {
            XCTAssertTrue(event.accessibilityDescription.contains(event.status.label))
        }
    }
}
