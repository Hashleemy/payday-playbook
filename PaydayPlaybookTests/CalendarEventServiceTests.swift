import XCTest
import SwiftData
@testable import PaydayPlaybook

/// V2-12 calendar merge: taxonomy, ordering, statuses, due-date behavior,
/// deep links, and accessibility text. Uses the seeded Original Plan v1
/// fixture (first payday Aug 20 2026) with a pinned "today" of Aug 10 2026
/// unless a test says otherwise.
final class CalendarEventServiceTests: XCTestCase {

    private func makeService(
        today: Date = TestSupport.date(2054, 8, 10)
    ) throws -> (CalendarEventService, ModelContext) {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context)
        let service = CalendarEventService(context: context, dateProvider: FixedDateProvider(fixed: today))
        return (service, context)
    }

    /// The plan's opening stretch — wide enough to include the first card
    /// payoff milestone, which the fixture reaches in October.
    private func augustEvents(_ service: CalendarEventService) throws -> [CalendarEventService.Event] {
        try service.events(from: TestSupport.date(2054, 8, 1), to: TestSupport.date(2054, 10, 31))
    }

    // MARK: - Merge & ordering

    func testPaydayDayMergesTheFullPlayByPlay() throws {
        let (service, _) = try makeService()
        let events = try augustEvents(service)
        let paydayDay = events.filter { $0.date == TestSupport.date(2054, 8, 20) }

        XCTAssertTrue(paydayDay.contains { $0.kind == .payday && $0.id == "payday-1" })
        XCTAssertTrue(paydayDay.contains { $0.kind == .transfer }, "C2 transfer must render as an account-transfer action")
        XCTAssertFalse(paydayDay.contains { $0.kind == .reserve && $0.title.localizedCaseInsensitiveContains("buffer") },
                       "the floor is already met, so no buffer top-up is drawn")
        XCTAssertTrue(paydayDay.contains { $0.kind == .reserve && $0.title.localizedCaseInsensitiveContains("car") })
        XCTAssertEqual(paydayDay.filter { $0.kind == .reserve }.count, 2,
                       "both obligation reserves render")
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
            effectiveDate: TestSupport.date(2054, 8, 21),
            type: .c1Spending,
            amount: TestSupport.money("40.00"),
            sourceAccount: .checking1,
            destinationAccount: .external
        ))
        try context.save()
        let events = try augustEvents(service)
        let dates = events.map(\.date)
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertTrue(events.contains { $0.kind == .entry && $0.date == TestSupport.date(2054, 8, 21) && $0.status == .actual })
        XCTAssertTrue(events.contains { $0.kind == .milestone })  // first card payoff milestone
    }

    // MARK: - Statuses (Planned / Completed / Needs attention / Actual)

    func testFuturePaydayIsPlannedAndCompletionFlipsStatus() throws {
        let (service, context) = try makeService()
        var events = try augustEvents(service)
        XCTAssertEqual(try XCTUnwrap(events.first { $0.kind == .payday }).status, .planned)

        let plan = try XCTUnwrap(try PlanRepository.legacyBaseline(context: context))
        let items = try TestSupport.planItems(context, plan: plan)
        let checkIn = PaydayCheckIn(paydayPlanItemID: items[0].id)
        checkIn.status = .completed
        context.insert(checkIn)
        try context.save()

        events = try augustEvents(service)
        XCTAssertEqual(try XCTUnwrap(events.first { $0.kind == .payday }).status, .completed)
    }

    func testOverduePaydayWithoutCheckInNeedsAttention() throws {
        let (service, _) = try makeService(today: TestSupport.date(2054, 8, 25))
        let events = try augustEvents(service)
        let payday = try XCTUnwrap(events.first { $0.kind == .payday })
        XCTAssertEqual(payday.status, .needsAttention)
        XCTAssertTrue(payday.detail?.contains("still open") ?? false)
    }

    func testShortfallPaydayNeedsAttentionWithExactGap() throws {
        let (service, context) = try makeService()
        let plan = try XCTUnwrap(try PlanRepository.legacyBaseline(context: context))
        let items = try TestSupport.planItems(context, plan: plan)
        items[0].shortfallAmount = TestSupport.money("55.00")
        try context.save()
        let events = try augustEvents(service)
        let payday = try XCTUnwrap(events.first { $0.kind == .payday })
        XCTAssertEqual(payday.status, .needsAttention)
        XCTAssertTrue(payday.detail?.contains("55.00") ?? false, "R-09 shows the exact gap")
    }

    func testCheckInExceptionSurfacesAsNeedsAttention() throws {
        let (service, context) = try makeService(today: TestSupport.date(2054, 8, 21))
        let plan = try XCTUnwrap(try PlanRepository.legacyBaseline(context: context))
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

        let february = try service.events(from: TestSupport.date(2055, 2, 1), to: TestSupport.date(2055, 2, 28))
        let dueEvents = february.filter { $0.kind == .debtDue && $0.id.contains(debt.id.uuidString) }
        XCTAssertEqual(dueEvents.count, 1)
        XCTAssertEqual(dueEvents.first?.date, TestSupport.date(2055, 2, 28))
        XCTAssertTrue(dueEvents.first?.detail?.contains("last day") ?? false, "clamping is explained in text")
    }

    func testDueDateEditIsProspectiveAndCreatesNoDuplicates() throws {
        let (service, context) = try makeService()
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        debt.dueDayOfMonth = 12
        try context.save()

        let september = { try service.events(from: TestSupport.date(2054, 9, 1), to: TestSupport.date(2054, 9, 30)) }
        var dueEvents = try september().filter { $0.kind == .debtDue && $0.id.contains(debt.id.uuidString) }
        XCTAssertEqual(dueEvents.map(\.date), [TestSupport.date(2054, 9, 12)])

        debt.dueDayOfMonth = 15
        try context.save()
        dueEvents = try september().filter { $0.kind == .debtDue && $0.id.contains(debt.id.uuidString) }
        XCTAssertEqual(dueEvents.map(\.date), [TestSupport.date(2054, 9, 15)], "the edit replaces the future event — no duplicate on the old day")
    }

    func testWeekendShiftRuleMovesTheMarkerOnlyWhenSelected() throws {
        let (service, context) = try makeService()
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        // Sep 12 2026 is a Saturday.
        debt.dueDayOfMonth = 12
        try context.save()

        var events = try service.events(from: TestSupport.date(2054, 9, 1), to: TestSupport.date(2054, 9, 30))
        XCTAssertTrue(events.contains { $0.kind == .debtDue && $0.date == TestSupport.date(2054, 9, 12) })

        debt.dueDateShiftRule = .nextWeekday
        try context.save()
        events = try service.events(from: TestSupport.date(2054, 9, 1), to: TestSupport.date(2054, 9, 30))
        XCTAssertTrue(events.contains { $0.kind == .debtDue && $0.date == TestSupport.date(2054, 9, 14) })
        XCTAssertFalse(events.contains { $0.kind == .debtDue && $0.date == TestSupport.date(2054, 9, 12) })
    }

    func testArchivedDebtRendersNoDueEvents() throws {
        let (service, context) = try makeService()
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        debt.dueDayOfMonth = 12
        debt.isArchived = true
        try context.save()
        let events = try service.events(from: TestSupport.date(2054, 9, 1), to: TestSupport.date(2054, 9, 30))
        XCTAssertFalse(events.contains { $0.kind == .debtDue && $0.id.contains(debt.id.uuidString) })
    }

    func testObligationDueDatesRenderAndArchiveHides() throws {
        let (service, context) = try makeService()
        let obligation = RecurringObligation(name: "Rent", amount: TestSupport.money("1700.00"), cadence: .monthly, dueDay: 1)
        context.insert(obligation)
        try context.save()

        var events = try service.events(from: TestSupport.date(2054, 9, 1), to: TestSupport.date(2054, 9, 30))
        let rent = events.filter { $0.kind == .obligationDue && $0.title.contains("Rent") }
        XCTAssertEqual(rent.map(\.date), [TestSupport.date(2054, 9, 1)])
        XCTAssertTrue(rent.first?.detail?.contains("1,700") ?? false)

        obligation.isArchived = true
        try context.save()
        events = try service.events(from: TestSupport.date(2054, 9, 1), to: TestSupport.date(2054, 9, 30))
        XCTAssertFalse(events.contains { $0.kind == .obligationDue && $0.title.contains("Rent") })
    }

    // Review regression: a due day is a day *of month*; the cadence decides
    // which months it lands in.
    func testObligationCadenceControlsHowOftenItIsDrawn() throws {
        let (service, context) = try makeService()
        let quarterly = RecurringObligation(
            name: "Insurance", amount: TestSupport.money("450.00"),
            cadence: .quarterly, dueDay: 10,
            createdAt: TestSupport.date(2054, 8, 1), updatedAt: TestSupport.date(2054, 8, 1)
        )
        let annual = RecurringObligation(
            name: "Domain", amount: TestSupport.money("20.00"),
            cadence: .annual, dueDay: 10,
            createdAt: TestSupport.date(2054, 8, 1), updatedAt: TestSupport.date(2054, 8, 1)
        )
        let biweekly = RecurringObligation(
            name: "Transit", amount: TestSupport.money("30.00"),
            cadence: .biweekly, dueDay: 10,
            createdAt: TestSupport.date(2054, 8, 1), updatedAt: TestSupport.date(2054, 8, 1)
        )
        context.insert(quarterly)
        context.insert(annual)
        context.insert(biweekly)
        try context.save()

        func months(_ obligation: RecurringObligation) throws -> [Date] {
            try service.events(from: TestSupport.date(2054, 8, 1), to: TestSupport.date(2055, 7, 31))
                .filter { $0.kind == .obligationDue && $0.id.contains(obligation.id.uuidString) }
                .map(\.date)
        }
        // Anchored on the August creation month: Aug, Nov, Feb, May.
        XCTAssertEqual(try months(quarterly), [
            TestSupport.date(2054, 8, 10), TestSupport.date(2054, 11, 10),
            TestSupport.date(2055, 2, 10), TestSupport.date(2055, 5, 10)
        ])
        XCTAssertEqual(try months(annual), [TestSupport.date(2054, 8, 10)])
        XCTAssertTrue(try months(biweekly).isEmpty,
                      "a day-of-month is meaningless for a biweekly bill; the per-paycheck reserve carries it")
    }

    // Review regression: an edit is prospective. Past months must not be
    // redrawn with a due day that was not in force then.
    func testEditingADueDayDoesNotRewritePastOccurrences() throws {
        let (service, context) = try makeService(today: TestSupport.date(2054, 10, 5))
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        debt.dueDayOfMonth = 20
        try context.save()

        // Before any edit the due day describes history too.
        XCTAssertEqual(
            try service.events(from: TestSupport.date(2054, 9, 1), to: TestSupport.date(2054, 9, 30))
                .filter { $0.kind == .debtDue }.map(\.date),
            [TestSupport.date(2054, 9, 20)]
        )

        // The user moves it to the 5th, effective today (Oct 5).
        debt.dueDayOfMonth = 5
        debt.dueDayEffectiveFrom = TestSupport.date(2054, 10, 5)
        try context.save()

        XCTAssertTrue(
            try service.events(from: TestSupport.date(2054, 9, 1), to: TestSupport.date(2054, 9, 30))
                .filter { $0.kind == .debtDue }.isEmpty,
            "September must not be redrawn on the 5th — that was never its due day"
        )
        XCTAssertEqual(
            try service.events(from: TestSupport.date(2054, 11, 1), to: TestSupport.date(2054, 11, 30))
                .filter { $0.kind == .debtDue }.map(\.date),
            [TestSupport.date(2054, 11, 5)],
            "future months use the new due day"
        )
    }

    // Review regression: a past due date is not a record of anything, so it
    // must not claim Actual status or appear under the Actual filter.
    func testPastDueDatesStayPlannedAndOutOfTheActualFilter() throws {
        let (service, context) = try makeService(today: TestSupport.date(2054, 8, 31))
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        debt.dueDayOfMonth = 5
        try context.save()

        let events = try augustEvents(service)
        let due = try XCTUnwrap(events.first { $0.kind == .debtDue })
        XCTAssertEqual(due.date, TestSupport.date(2054, 8, 5), "in the past relative to Aug 31")
        XCTAssertEqual(due.status, .planned, "nothing recorded a payment; do not call it Actual")
        XCTAssertFalse(CalendarEventService.Filter.actualEntries.includes(due))
        XCTAssertTrue(CalendarEventService.Filter.dueDates.includes(due))
    }

    // MARK: - Reforecast markers

    func testReforecastSnapshotRendersMarkerButInitialSeedDoesNot() throws {
        let (service, context) = try makeService()
        let plan = try XCTUnwrap(try PlanRepository.legacyBaseline(context: context))
        context.insert(ForecastSnapshot(
            calculatedAt: TestSupport.date(2054, 8, 5),
            sourcePlanVersionID: plan.id,
            triggerType: .initialSeed,
            projectedPayoffDate: TestSupport.date(2055, 6, 24),
            remainingPaychecks: 23,
            estimatedRemainingInterest: TestSupport.money("2617.18"),
            perCardPayoffDates: [],
            summaryExplanation: "seed"
        ))
        context.insert(ForecastSnapshot(
            calculatedAt: TestSupport.date(2054, 8, 22),
            sourcePlanVersionID: plan.id,
            triggerType: .paydayCompleted,
            projectedPayoffDate: TestSupport.date(2055, 6, 24),
            remainingPaychecks: 22,
            estimatedRemainingInterest: TestSupport.money("3300.00"),
            perCardPayoffDates: [],
            summaryExplanation: "after check 1"
        ))
        try context.save()

        let events = try augustEvents(service)
        let markers = events.filter { $0.kind == .reforecast }
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.date, TestSupport.date(2054, 8, 22))
        XCTAssertEqual(markers.first?.status, .reforecast)
    }

    // MARK: - Deep links

    func testEveryLinkedEventCarriesEntityIdentity() throws {
        let (service, context) = try makeService()
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        debt.dueDayOfMonth = 25
        let entry = LedgerEntry(
            effectiveDate: TestSupport.date(2054, 8, 21),
            type: .cardPayment,
            amount: TestSupport.money("100.00"),
            sourceAccount: .checking2,
            destinationAccount: .external
        )
        context.insert(entry)
        try context.save()

        let events = try augustEvents(service)
        let plan = try XCTUnwrap(try PlanRepository.legacyBaseline(context: context))
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

    // MARK: - Deep-link resolution (archived / deleted fallback)

    func testLinksResolveToTheirEntityWhileItExists() throws {
        let (service, context) = try makeService()
        let plan = try XCTUnwrap(try PlanRepository.legacyBaseline(context: context))
        let item = try TestSupport.planItems(context, plan: plan)[0]
        let entry = LedgerEntry(
            effectiveDate: TestSupport.date(2054, 8, 21), type: .cardPayment,
            amount: TestSupport.money("100.00"),
            sourceAccount: .checking2, destinationAccount: .external
        )
        context.insert(entry)
        try context.save()
        let milestone = try XCTUnwrap(try context.fetch(FetchDescriptor<Milestone>()).first)

        XCTAssertEqual(try service.resolve(.checkIn(itemID: item.id)), .openCheckIn(item: item.id))
        XCTAssertEqual(try service.resolve(.debt(planID: "B")), .openDebt(planID: "B"))
        XCTAssertEqual(try service.resolve(.entry(entryID: entry.id)), .openEntry(entryID: entry.id))
        XCTAssertEqual(
            try service.resolve(.milestone(milestoneID: milestone.id)),
            .openMilestone(milestoneID: milestone.id)
        )
    }

    func testArchivedDebtLinkExplainsRatherThanDeadEnds() throws {
        let (service, context) = try makeService()
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        debt.isArchived = true
        try context.save()

        let resolution = try service.resolve(.debt(planID: "B"))
        guard case .unavailable(let message) = resolution else {
            return XCTFail("an archived debt must not resolve to an open action")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("archived"))
    }

    func testDeletedTargetsResolveToAnExplanationForEveryLinkType() throws {
        let (service, context) = try makeService()
        let plan = try XCTUnwrap(try PlanRepository.legacyBaseline(context: context))
        let item = try TestSupport.planItems(context, plan: plan)[0]
        let entry = LedgerEntry(
            effectiveDate: TestSupport.date(2054, 8, 21), type: .cardPayment,
            amount: TestSupport.money("100.00"),
            sourceAccount: .checking2, destinationAccount: .external
        )
        context.insert(entry)
        let milestone = try XCTUnwrap(try context.fetch(FetchDescriptor<Milestone>()).first)
        try context.save()

        context.delete(item)
        context.delete(entry)
        context.delete(milestone)
        for debt in try context.fetch(FetchDescriptor<DebtAccount>()) where debt.planID == "B" {
            context.delete(debt)
        }
        try context.save()

        for link: CalendarEventService.DeepLink in [
            .checkIn(itemID: item.id),
            .debt(planID: "B"),
            .entry(entryID: entry.id),
            .milestone(milestoneID: milestone.id)
        ] {
            guard case .unavailable(let message) = try service.resolve(link) else {
                return XCTFail("a deleted target must resolve to an explanation: \(link)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    // MARK: - Filters

    func testFiltersPartitionTheTaxonomy() throws {
        let (service, context) = try makeService(today: TestSupport.date(2054, 8, 25))
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
        let (service, _) = try makeService(today: TestSupport.date(2054, 8, 25))
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
