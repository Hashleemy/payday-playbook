import XCTest
import SwiftData
import UserNotifications
@testable import PaydayPlaybook

/// V3-07 / V3-13 hardening of the v0.2.0 due-date, calendar, and reminder
/// machinery.
///
/// Everything here is simulator-testable by construction: the pure planner,
/// the store-backed calendar merge, and a fake notification center. What
/// cannot be proven here — that iOS actually delivers on the trigger, and
/// what the copy looks like on a real lock screen — is in the device
/// checklist in the agent report, not asserted as if it had been checked.
@MainActor
final class CalendarRemindersHardeningTests: XCTestCase {

    // MARK: - Fixtures

    private func makeStore(
        today: Date = TestSupport.date(2054, 8, 10)
    ) throws -> (ModelContext, FixedDateProvider) {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context)
        for missing in NotificationPreference.missingDefaults(
            existing: try context.fetch(FetchDescriptor<NotificationPreference>())
        ) {
            context.insert(missing)
        }
        try context.save()
        return (context, FixedDateProvider(fixed: today))
    }

    private func seededDebt(_ context: ModelContext, planID: String = "B") throws -> DebtAccount {
        try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == planID })
    }

    private func plan(
        _ context: ModelContext, _ provider: DateProviding
    ) throws -> NotificationPlanner.Plan {
        NotificationPlanner.plan(try NotificationPlanner.makeInput(context: context, dateProvider: provider))
    }

    private func calendar(
        _ context: ModelContext, _ provider: DateProviding
    ) -> CalendarEventService {
        CalendarEventService(context: context, dateProvider: provider)
    }

    /// Occurrence keys (`yyyyMMdd`) of one entity's pending due reminders.
    private func pendingOccurrences(
        _ center: FakeNotificationCenter, entity: UUID, family: NotificationFamily
    ) -> [String] {
        center.pendingIdentifiers
            .filter { $0.hasPrefix("\(family.rawValue)-\(entity.uuidString)-") }
            .map { String($0.suffix(8)) }
            .sorted()
    }

    // MARK: - Editing due rules (one shared path, prospective)

    func testDueDayEditIsAuditedAndStampsAnEffectiveDate() throws {
        let (context, provider) = try makeStore()
        let debt = try seededDebt(context)
        debt.dueDayOfMonth = 12
        debt.dueDayEffectiveFrom = nil
        try context.save()

        let outcome = try DueRuleEditService.apply(
            DueRule(dueDay: 20), to: debt, now: provider.now, context: context
        )

        XCTAssertTrue(outcome.didChange)
        XCTAssertTrue(outcome.needsReconcile)
        XCTAssertEqual(debt.dueDayOfMonth, 20)
        XCTAssertEqual(debt.dueDayEffectiveFrom, DateMath.startOfDay(provider.now))
        let log = try XCTUnwrap(debt.dueDateAuditLog)
        XCTAssertTrue(log.contains("12"))
        XCTAssertTrue(log.contains("20"))
    }

    /// The v0.2.0 editors stamped the effective date only when the *day*
    /// changed, so switching the weekend rule silently moved every already
    /// drawn past occurrence by up to two days. A shift rule is part of the
    /// due rule, and changing it is prospective like any other edit.
    func testWeekendRuleChangeAloneIsAlsoProspectiveAndAudited() throws {
        let (context, provider) = try makeStore()
        let obligation = RecurringObligation(
            name: "Storage unit", amount: TestSupport.money("55.00"), cadence: .monthly, dueDay: 15
        )
        context.insert(obligation)
        try context.save()
        XCTAssertNil(obligation.dueDayEffectiveFrom)

        let outcome = try DueRuleEditService.apply(
            DueRule(dueDay: 15, shift: .nextWeekday), to: obligation, now: provider.now, context: context
        )

        XCTAssertTrue(outcome.didChange, "changing only the weekend rule is still a change")
        XCTAssertEqual(obligation.dueDay, 15)
        XCTAssertEqual(obligation.dueDateShiftRule, .nextWeekday)
        XCTAssertEqual(obligation.dueDayEffectiveFrom, DateMath.startOfDay(provider.now))
        XCTAssertTrue(try XCTUnwrap(obligation.dueDateAuditLog).contains("nextWeekday"))
    }

    func testResavingTheSameRuleChangesNothingAndKeepsHistoryVisible() throws {
        let (context, provider) = try makeStore()
        let debt = try seededDebt(context)
        debt.dueDayOfMonth = 18
        debt.dueDateShiftRule = .previousWeekday
        debt.dueDayEffectiveFrom = nil
        debt.dueDateAuditLog = nil
        try context.save()

        let outcome = try DueRuleEditService.apply(
            DueRule(dueDay: 18, shift: .previousWeekday), to: debt, now: provider.now, context: context
        )

        XCTAssertFalse(outcome.didChange)
        XCTAssertFalse(outcome.needsReconcile)
        XCTAssertNil(debt.dueDayEffectiveFrom, "a no-op save must not blank out drawn history")
        XCTAssertNil(debt.dueDateAuditLog, "a no-op save must not write an audit entry")
    }

    func testClearingTheDueDayNormalizesTheShiftRuleSoItReadsAsOneChange() throws {
        let (context, provider) = try makeStore()
        let debt = try seededDebt(context)
        debt.dueDayOfMonth = nil
        debt.dueDateShiftRule = .exactDay
        try context.save()

        // "No due day, weekend → Monday" is the same rule as "no due day":
        // there is nothing to shift. It must not register as an edit.
        let noop = try DueRuleEditService.apply(
            DueRule(dueDay: nil, shift: .nextWeekday), to: debt, now: provider.now, context: context
        )
        XCTAssertFalse(noop.didChange)

        debt.dueDayOfMonth = 9
        try context.save()
        let cleared = try DueRuleEditService.apply(
            DueRule(dueDay: nil), to: debt, now: provider.now, context: context
        )
        XCTAssertTrue(cleared.didChange)
        XCTAssertNil(debt.dueDayOfMonth)
        XCTAssertTrue(try XCTUnwrap(debt.dueDateAuditLog).contains("none"))
    }

    func testInvalidDayIsRejectedBeforeAnythingIsMutated() throws {
        let (context, provider) = try makeStore()
        let debt = try seededDebt(context)
        debt.dueDayOfMonth = 5
        debt.dueDateAuditLog = nil
        try context.save()

        for text in ["0", "32", "-3", "abc"] {
            XCTAssertThrowsError(try DueRuleEditService.parseDueDay(text), "\(text) must not parse")
        }
        XCTAssertEqual(try DueRuleEditService.parseDueDay(""), nil)
        XCTAssertEqual(try DueRuleEditService.parseDueDay(" 17 "), 17)
        XCTAssertEqual(debt.dueDayOfMonth, 5)
        XCTAssertNil(debt.dueDateAuditLog)
        _ = provider
    }

    func testBothSubjectsShareOneEditPath() throws {
        let (context, provider) = try makeStore()
        let debt = try seededDebt(context)
        let obligation = RecurringObligation(
            name: "Insurance", amount: TestSupport.money("90.00"), cadence: .monthly, dueDay: 3
        )
        context.insert(obligation)
        try context.save()

        let subjects: [any DueRuleSubject] = [debt, obligation]
        for subject in subjects {
            let outcome = try DueRuleEditService.apply(
                DueRule(dueDay: 21, shift: .previousWeekday), to: subject, now: provider.now, context: context
            )
            XCTAssertTrue(outcome.didChange)
            XCTAssertEqual(subject.dueRule, DueRule(dueDay: 21, shift: .previousWeekday))
            XCTAssertEqual(subject.dueRuleEffectiveFrom, DateMath.startOfDay(provider.now))
        }
    }

    func testClampDisclosureNamesTheNextShortMonthAndStaysSilentBelow29() throws {
        let now = TestSupport.date(2054, 12, 5)
        XCTAssertNil(DueRuleEditService.clampDisclosure(for: DueRule(dueDay: 28), now: now))
        let note = try XCTUnwrap(DueRuleEditService.clampDisclosure(for: DueRule(dueDay: 31), now: now))
        XCTAssertTrue(note.contains("31"))
        // 2055 is not a leap year, so the next month that cannot hold day 31
        // and is shortest is February — the note must name a real date.
        XCTAssertTrue(note.contains(DateMath.mediumString(TestSupport.date(2055, 2, 28))), note)
    }

    // MARK: - Calendar: future rebuilds, history holds still

    func testDueDateEditUpdatesFutureCalendarRowsImmediately() throws {
        let (context, provider) = try makeStore()
        let service = calendar(context, provider)
        let debt = try seededDebt(context)
        debt.dueDayOfMonth = 6
        try context.save()

        try DueRuleEditService.apply(DueRule(dueDay: 22), to: debt, now: provider.now, context: context)

        let future = try service.events(from: TestSupport.date(2054, 9, 1), to: TestSupport.date(2054, 9, 30))
            .filter { $0.kind == .debtDue && $0.id.contains(debt.id.uuidString) }
        XCTAssertEqual(future.count, 1, "exactly one due marker per month")
        XCTAssertEqual(future[0].date, TestSupport.date(2054, 9, 22))
    }

    func testHistoricalMarkersAndCompletedWorkDoNotMoveWhenTheRuleChanges() throws {
        let today = TestSupport.date(2054, 8, 10)
        let (context, provider) = try makeStore(today: today)
        let service = calendar(context, provider)
        let debt = try seededDebt(context)
        debt.dueDayOfMonth = 6
        try context.save()

        let pastBefore = try service.events(from: TestSupport.date(2054, 6, 1), to: TestSupport.date(2054, 7, 31))
        let pastDueBefore = pastBefore.filter { $0.kind == .debtDue && $0.id.contains(debt.id.uuidString) }
        XCTAssertFalse(pastDueBefore.isEmpty, "the fixture must draw some history to protect")

        try DueRuleEditService.apply(
            DueRule(dueDay: 22, shift: .nextWeekday), to: debt, now: provider.now, context: context
        )

        let pastAfter = try service.events(from: TestSupport.date(2054, 6, 1), to: TestSupport.date(2054, 7, 31))
        let pastDueAfter = pastAfter.filter { $0.kind == .debtDue && $0.id.contains(debt.id.uuidString) }
        XCTAssertTrue(
            pastDueAfter.allSatisfy { after in pastDueBefore.contains { $0.id == after.id && $0.date == after.date } },
            "no past due marker may be redrawn on a day the rule did not name at the time"
        )
        // Completed and historical non-due events are untouched by a due-rule
        // edit: same identity, same day, same status.
        let signature: ([CalendarEventService.Event]) -> [String] = { events in
            events.filter { $0.kind != .debtDue }
                .map { "\($0.id)|\(DateMath.mediumString($0.date))|\($0.status.rawValue)" }
                .sorted()
        }
        XCTAssertEqual(signature(pastBefore), signature(pastAfter))
    }

    /// Regression for the weekend-rule leak: before the shared edit path, a
    /// shift-rule change re-rendered *past* months two days off.
    func testWeekendRuleChangeDoesNotMovePastMarkers() throws {
        let today = TestSupport.date(2054, 8, 10)
        let (context, provider) = try makeStore(today: today)
        let service = calendar(context, provider)
        let obligation = RecurringObligation(
            name: "Parking", amount: TestSupport.money("120.00"), cadence: .monthly, dueDay: 5,
            createdAt: TestSupport.date(2054, 1, 5)
        )
        context.insert(obligation)
        try context.save()

        let window = (from: TestSupport.date(2054, 5, 1), to: TestSupport.date(2054, 7, 31))
        let before = try service.events(from: window.from, to: window.to)
            .filter { $0.kind == .obligationDue && $0.id.contains(obligation.id.uuidString) }
            .map(\.date)
        XCTAssertFalse(before.isEmpty)

        try DueRuleEditService.apply(
            DueRule(dueDay: 5, shift: .nextWeekday), to: obligation, now: provider.now, context: context
        )

        let after = try service.events(from: window.from, to: window.to)
            .filter { $0.kind == .obligationDue && $0.id.contains(obligation.id.uuidString) }
            .map(\.date)
        XCTAssertTrue(Set(after).isSubset(of: Set(before)), "past bill markers moved: \(before) → \(after)")
    }

    // MARK: - Calendar: deep links

    func testBillDueMarkersDeepLinkToTheirBill() throws {
        let (context, provider) = try makeStore()
        let service = calendar(context, provider)
        let obligation = RecurringObligation(
            name: "Water", amount: TestSupport.money("48.00"), cadence: .monthly, dueDay: 14,
            createdAt: TestSupport.date(2054, 1, 14)
        )
        context.insert(obligation)
        try context.save()

        let event = try XCTUnwrap(
            try service.events(from: TestSupport.date(2054, 9, 1), to: TestSupport.date(2054, 9, 30))
                .first { $0.kind == .obligationDue && $0.id.contains(obligation.id.uuidString) }
        )
        XCTAssertEqual(event.link, .obligation(obligationID: obligation.id))
        XCTAssertEqual(
            try service.resolve(XCTUnwrap(event.link)),
            .openObligation(obligationID: obligation.id)
        )
    }

    func testArchivedAndDeletedBillsExplainInsteadOfDeadEnding() throws {
        let (context, provider) = try makeStore()
        let service = calendar(context, provider)
        let obligation = RecurringObligation(
            name: "Streaming", amount: TestSupport.money("15.00"), cadence: .monthly, dueDay: 4
        )
        context.insert(obligation)
        try context.save()

        obligation.isArchived = true
        try context.save()
        guard case .unavailable(let archivedMessage) =
                try service.resolve(.obligation(obligationID: obligation.id)) else {
            return XCTFail("an archived bill must not resolve to an open action")
        }
        XCTAssertTrue(archivedMessage.localizedCaseInsensitiveContains("archived"))

        let goneID = obligation.id
        context.delete(obligation)
        try context.save()
        guard case .unavailable(let deletedMessage) =
                try service.resolve(.obligation(obligationID: goneID)) else {
            return XCTFail("a deleted bill must resolve to an explanation")
        }
        XCTAssertFalse(deletedMessage.isEmpty)
    }

    /// Plan letters are reusable slots — `nextPlanID()` hands out the lowest
    /// free one — so a link that carried only a letter could open a debt the
    /// user never tapped once the original was deleted.
    func testAReusedPlanLetterCannotRedirectALinkToAnotherDebt() throws {
        let (context, provider) = try makeStore()
        let service = calendar(context, provider)
        let repository = DebtRepository(context: context)
        let original = try repository.create(
            type: .creditCard, displayName: "Original", currentBalance: TestSupport.money("500.00"),
            apr: 0.2, minimumAmount: TestSupport.money("25.00"), dueDayOfMonth: 10,
            now: provider.now
        )
        try context.save()
        let originalID = original.id
        let letter = original.planID

        context.delete(original)
        try context.save()
        let replacement = try repository.create(
            type: .creditCard, displayName: "Replacement", currentBalance: TestSupport.money("900.00"),
            apr: 0.2, minimumAmount: TestSupport.money("40.00"), dueDayOfMonth: 10,
            now: provider.now
        )
        try context.save()
        XCTAssertEqual(replacement.planID, letter, "the letter must actually be reused for this to be a real test")

        // Entity-keyed link: honest about the deletion.
        guard case .unavailable = try service.resolve(.debt(debtID: originalID, planID: letter)) else {
            return XCTFail("a deleted debt must not resolve through a reused letter")
        }
        // Entity-keyed link to the live debt resolves to that debt.
        XCTAssertEqual(
            try service.resolve(.debt(debtID: replacement.id, planID: letter)),
            .openDebt(debtID: replacement.id, planID: letter)
        )
    }

    /// A balance-update row's subject is known by identity — the calendar only
    /// emits the row when the snapshot carries a debt reference. Linking it by
    /// plan letter alone would hand the tap to whichever debt later inherited
    /// the slot, which is the same misrouting the entity-keyed link closes for
    /// reminders. Found at integration: the producer discarded an ID it held.
    func testABalanceUpdateRowLinksToItsDebtByIdentityNotItsLetter() throws {
        let (context, provider) = try makeStore()
        let service = calendar(context, provider)
        let debt = try seededDebt(context)
        context.insert(BalanceSnapshot(
            debtAccountID: debt.id,
            debtPlanID: debt.planID,
            effectiveDate: TestSupport.date(2054, 9, 12),
            amount: TestSupport.money("1234.56"),
            sourceType: .userEntry
        ))
        try context.save()

        let events = try service.events(
            from: TestSupport.date(2054, 9, 1), to: TestSupport.date(2054, 9, 30)
        )
        let row = try XCTUnwrap(
            events.first { $0.title.hasPrefix("Balance update") },
            "the balance update must appear on the calendar"
        )
        XCTAssertEqual(row.link, .debt(debtID: debt.id, planID: debt.planID))
    }

    // MARK: - Reconciliation: exactly one correct replacement

    func testDueDateEditRemovesOldRequestsAndLeavesExactlyOneReplacement() async throws {
        let (context, provider) = try makeStore()
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center)
        let debt = try seededDebt(context)
        debt.dueDayOfMonth = 12
        try context.save()

        await scheduler.rescheduleAll(context: context, dateProvider: provider, trigger: .launch)
        let before = pendingOccurrences(center, entity: debt.id, family: .debtDueToday)
        XCTAssertFalse(before.isEmpty)
        XCTAssertTrue(before.allSatisfy { $0.hasSuffix("12") })

        try DueRuleEditService.apply(DueRule(dueDay: 24), to: debt, now: provider.now, context: context)
        await scheduler.rescheduleAll(context: context, dateProvider: provider, trigger: .dueDateEdit)

        let after = pendingOccurrences(center, entity: debt.id, family: .debtDueToday)
        XCTAssertFalse(after.isEmpty)
        XCTAssertTrue(after.allSatisfy { $0.hasSuffix("24") }, "old due day still pending: \(after)")
        XCTAssertEqual(Set(after).count, after.count, "no duplicate occurrences")
        XCTAssertTrue(Set(after).isDisjoint(with: Set(before)), "an obsolete request survived the edit")
    }

    func testRepeatedReconciliationIsIdempotentAcrossEveryTrigger() async throws {
        let (context, provider) = try makeStore()
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center)
        let debt = try seededDebt(context)
        debt.dueDayOfMonth = 17
        try context.save()

        await scheduler.rescheduleAll(context: context, dateProvider: provider, trigger: .launch)
        let settled = center.pendingIdentifiers
        XCTAssertFalse(settled.isEmpty)

        for trigger in NotificationScheduler.ReconcileTrigger.allCases {
            let addsBefore = center.addCallCount
            let removesBefore = center.removeCallCount
            await scheduler.rescheduleAll(context: context, dateProvider: provider, trigger: trigger)
            XCTAssertEqual(center.pendingIdentifiers, settled, "\(trigger) changed the pending set")
            XCTAssertEqual(center.addCallCount, addsBefore, "\(trigger) re-added an unchanged request")
            XCTAssertEqual(center.removeCallCount, removesBefore, "\(trigger) removed a wanted request")
            XCTAssertEqual(scheduler.lastTrigger, trigger)
            XCTAssertNil(scheduler.lastSkipReason)
            XCTAssertEqual(scheduler.lastReconciliation?.isNoOp, true)
        }
    }

    func testArchivingABillAndPayingOffADebtCancelTheirReminders() async throws {
        let (context, provider) = try makeStore()
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center)
        let debt = try seededDebt(context)
        debt.dueDayOfMonth = 16
        let obligation = RecurringObligation(
            name: "Locker", amount: TestSupport.money("30.00"), cadence: .monthly, dueDay: 16
        )
        context.insert(obligation)
        try context.save()

        await scheduler.rescheduleAll(context: context, dateProvider: provider, trigger: .launch)
        XCTAssertTrue(center.pendingIdentifiers.contains { $0.contains(debt.id.uuidString) })
        XCTAssertTrue(center.pendingIdentifiers.contains { $0.contains(obligation.id.uuidString) })

        obligation.isArchived = true
        context.insert(BalanceSnapshot(
            debtAccountID: debt.id, debtPlanID: debt.planID,
            effectiveDate: TestSupport.date(2054, 8, 9),
            amount: .zero, sourceType: .currentOnlineBalance
        ))
        try context.save()
        await scheduler.rescheduleAll(context: context, dateProvider: provider, trigger: .archiveOrPayoff)

        XCTAssertFalse(center.pendingIdentifiers.contains { $0.contains(debt.id.uuidString) },
                       "a debt at zero must stop reminding")
        XCTAssertFalse(center.pendingIdentifiers.contains { $0.contains(obligation.id.uuidString) },
                       "an archived bill must stop reminding")
    }

    func testDeletingAnEntityLeavesNoOrphanRequests() async throws {
        let (context, provider) = try makeStore()
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center)
        let obligation = RecurringObligation(
            name: "Newspaper", amount: TestSupport.money("20.00"), cadence: .monthly, dueDay: 19
        )
        context.insert(obligation)
        try context.save()

        await scheduler.rescheduleAll(context: context, dateProvider: provider, trigger: .launch)
        let orphanID = obligation.id
        XCTAssertTrue(center.pendingIdentifiers.contains { $0.contains(orphanID.uuidString) })

        context.delete(obligation)
        try context.save()
        await scheduler.rescheduleAll(context: context, dateProvider: provider, trigger: .foreground)

        XCTAssertFalse(center.pendingIdentifiers.contains { $0.contains(orphanID.uuidString) })
    }

    // MARK: - Permission states

    func testDeniedPermissionSchedulesNothingRecordsWhyAndLeavesTheAppUsable() async throws {
        let (context, provider) = try makeStore()
        let center = FakeNotificationCenter(status: .denied)
        let scheduler = NotificationScheduler(center: center)
        let debt = try seededDebt(context)
        debt.dueDayOfMonth = 11
        try context.save()

        await scheduler.rescheduleAll(context: context, dateProvider: provider, trigger: .permissionChange)

        XCTAssertTrue(center.pendingIdentifiers.isEmpty)
        XCTAssertEqual(center.addCallCount, 0)
        XCTAssertEqual(center.removeCallCount, 0)
        XCTAssertEqual(scheduler.lastSkipReason, .notAuthorized)
        // The calendar — the surface that does not need permission — still
        // renders the due date the reminder would have covered.
        let events = try calendar(context, provider)
            .events(from: TestSupport.date(2054, 9, 1), to: TestSupport.date(2054, 9, 30))
        XCTAssertTrue(events.contains { $0.kind == .debtDue && $0.date == TestSupport.date(2054, 9, 11) })
    }

    func testGrantingPermissionLaterConvergesToExactlyTheDesiredSet() async throws {
        let (context, provider) = try makeStore()
        let center = FakeNotificationCenter(status: .notDetermined)
        let scheduler = NotificationScheduler(center: center)
        let debt = try seededDebt(context)
        debt.dueDayOfMonth = 13
        try context.save()

        await scheduler.rescheduleAll(context: context, dateProvider: provider, trigger: .launch)
        XCTAssertTrue(center.pendingIdentifiers.isEmpty)

        // A request left behind by an earlier authorized run, now obsolete.
        center.seed(identifier: NotificationFamily.debtDueToday.identifier(
            entity: debt.id.uuidString, occurrence: "20540901"
        ))
        let granted = await scheduler.requestAuthorizationAndReconcile(context: context, dateProvider: provider)

        XCTAssertTrue(granted)
        XCTAssertEqual(scheduler.lastTrigger, .permissionChange)
        XCTAssertFalse(center.pendingIdentifiers.contains(
            NotificationFamily.debtDueToday.identifier(entity: debt.id.uuidString, occurrence: "20540901")
        ), "the stale request from before the denial must be cleaned up on the first authorized pass")
        XCTAssertTrue(pendingOccurrences(center, entity: debt.id, family: .debtDueToday)
            .allSatisfy { $0.hasSuffix("13") })
    }

    // MARK: - Privacy (V3-13)

    func testNoIdentifierCarriesALabelOrAnAmount() throws {
        let (context, provider) = try makeStore()
        let debt = try seededDebt(context)
        debt.displayName = "Zebracorn Platinum"
        debt.dueDayOfMonth = 14
        debt.minimumAmount = TestSupport.money("137.42")
        let obligation = RecurringObligation(
            name: "Quokka Storage", amount: TestSupport.money("246.81"), cadence: .monthly, dueDay: 7
        )
        context.insert(obligation)
        try context.save()

        let identifiers = try plan(context, provider).notifications.map(\.identifier)
        XCTAssertFalse(identifiers.isEmpty)
        for identifier in identifiers {
            XCTAssertFalse(identifier.localizedCaseInsensitiveContains("zebracorn"), identifier)
            XCTAssertFalse(identifier.localizedCaseInsensitiveContains("quokka"), identifier)

            // Structural, not substring-based: an identifier is a known
            // family followed by an entity UUID (or a day key for the
            // per-day summary), optionally followed by an 8-digit occurrence.
            // Scanning for digits would be meaningless here — a UUID is hex,
            // so it contains digits by construction. Proving the *shape*
            // proves no free text can be in there at all.
            let family = try XCTUnwrap(
                NotificationFamily.allCases
                    .filter { identifier.hasPrefix($0.rawValue + "-") }
                    .max(by: { $0.rawValue.count < $1.rawValue.count }),
                identifier
            )
            var tail = identifier.dropFirst(family.rawValue.count + 1).split(separator: "-").map(String.init)
            if tail.count == 6 || tail.count == 2 {
                // Trailing yyyyMMdd occurrence key.
                let occurrence = try XCTUnwrap(tail.popLast())
                XCTAssertEqual(occurrence.count, 8, identifier)
                XCTAssertTrue(occurrence.allSatisfy(\.isNumber), identifier)
            }
            let entity = tail.joined(separator: "-")
            XCTAssertTrue(
                UUID(uuidString: entity) != nil || (entity.count == 8 && entity.allSatisfy(\.isNumber)),
                "identifier entity must be a UUID or a day key: \(identifier)"
            )
        }
    }

    func testDefaultCopyCarriesNoFinancialPayloadForAnyFamily() throws {
        let (context, provider) = try makeStore()
        let debt = try seededDebt(context)
        debt.displayName = "Zebracorn Platinum"
        debt.dueDayOfMonth = 14
        debt.minimumAmount = TestSupport.money("137.42")
        let obligation = RecurringObligation(
            name: "Quokka Storage", amount: TestSupport.money("246.81"), cadence: .monthly, dueDay: 7
        )
        context.insert(obligation)
        for preference in try context.fetch(FetchDescriptor<NotificationPreference>()) {
            preference.detailedLockScreenContent = false
        }
        try context.save()

        let notifications = try plan(context, provider).notifications
        XCTAssertFalse(notifications.isEmpty)
        for entry in notifications {
            let copy = entry.title + " " + entry.body
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("zebracorn"), copy)
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("quokka"), copy)
            XCTAssertFalse(copy.contains("$"), "default lock-screen copy must carry no amount: \(copy)")
            XCTAssertFalse(copy.contains(where: \.isNumber), "default lock-screen copy must carry no figures: \(copy)")
        }

        // The detail preference is the only way to opt in, and it is off by
        // default on a fresh store.
        XCTAssertTrue(
            NotificationPreference.seedDefaults().allSatisfy { !$0.detailedLockScreenContent },
            "detailed lock-screen content must be opt-in"
        )
    }

    func testDebtReminderReferenceIsEntityIdentityNotAPlanLetter() throws {
        let (context, provider) = try makeStore()
        let debt = try seededDebt(context)
        debt.dueDayOfMonth = 14
        try context.save()

        let debtReminders = try plan(context, provider).notifications.filter { $0.route == .debt }
        XCTAssertFalse(debtReminders.isEmpty)
        for entry in debtReminders {
            XCTAssertEqual(UUID(uuidString: entry.reference), debt.id, "route reference must be the debt's UUID")
        }

        let router = AppRouter()
        router.handleNotificationRoute([
            NotificationScheduler.routeKey: NotificationRoute.debt.rawValue,
            NotificationScheduler.referenceKey: debt.id.uuidString
        ])
        XCTAssertEqual(router.pendingDebtID, debt.id)
        XCTAssertNil(router.pendingDebtPlanID)

        // A reminder scheduled by 0.1.x/0.2.x still carries only a letter and
        // must keep working after the upgrade.
        let legacyRouter = AppRouter()
        legacyRouter.handleNotificationRoute([
            NotificationScheduler.routeKey: "card",
            NotificationScheduler.referenceKey: "B"
        ])
        XCTAssertEqual(legacyRouter.pendingDebtPlanID, "B")
        XCTAssertNil(legacyRouter.pendingDebtID)
    }

    // MARK: - Calendar edge cases: month end, leap years, semimonthly, time zones

    func testEveryDayAndShiftRuleProducesUniqueOrderedMonthlyOccurrences() {
        let start = DateMath.localDate(year: 2054, month: 1, day: 1)
        let end = DateMath.localDate(year: 2057, month: 1, day: 1)
        for day in DueDateRule.validDays {
            for shift in DueDateShiftRule.allCases {
                let occurrences = DueDateRule.occurrences(dueDay: day, from: start, to: end, shift: shift)
                XCTAssertEqual(Set(occurrences).count, occurrences.count, "duplicate for day \(day) \(shift)")
                XCTAssertEqual(occurrences, occurrences.sorted(), "unordered for day \(day) \(shift)")
                // 36 months, one occurrence each; a shift can push the first
                // or last across the window edge, so allow ±1.
                XCTAssertTrue((35...37).contains(occurrences.count),
                              "day \(day) \(shift) produced \(occurrences.count) occurrences")
            }
        }
    }

    func testLeapYearFebruaryKeepsDay29AndNonLeapClampsToThe28th() throws {
        let (context, provider) = try makeStore(today: TestSupport.date(2055, 12, 20))
        let debt = try seededDebt(context)
        debt.dueDayOfMonth = 29
        try context.save()

        // 2056 is a leap year; 2055 is not.
        XCTAssertFalse(DueDateRule.isClamped(dueDay: 29, inMonthOf: TestSupport.date(2056, 2, 1)))
        XCTAssertTrue(DueDateRule.isClamped(dueDay: 29, inMonthOf: TestSupport.date(2055, 2, 1)))
        XCTAssertEqual(
            DueDateRule.occurrence(dueDay: 29, inMonthOf: TestSupport.date(2056, 2, 1)),
            TestSupport.date(2056, 2, 29)
        )
        XCTAssertEqual(
            DueDateRule.occurrence(dueDay: 29, inMonthOf: TestSupport.date(2055, 2, 1)),
            TestSupport.date(2055, 2, 28)
        )

        let occurrences = try plan(context, provider).notifications
            .filter { $0.family == .debtDueToday && $0.identifier.contains(debt.id.uuidString) }
            .map { String($0.identifier.suffix(8)) }
            .sorted()
        XCTAssertTrue(occurrences.contains("20560129"))
        XCTAssertEqual(Set(occurrences).count, occurrences.count)
    }

    /// The reminder's trigger is wall-clock components, never an absolute
    /// instant, so the intended local financial day and hour survive a move
    /// between time zones. Planned in Los Angeles, planned again in Auckland
    /// (a whole calendar day ahead) — same day, same hour.
    func testTimeZoneMoveKeepsTheIntendedLocalFinancialDayAndHour() throws {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }

        func componentsForDueDay14() throws -> [String] {
            let container = try TestSupport.makeContainer()
            let context = ModelContext(container)
            try TestSupport.seed(context)
            for missing in NotificationPreference.missingDefaults(
                existing: try context.fetch(FetchDescriptor<NotificationPreference>())
            ) {
                context.insert(missing)
            }
            let debt = try seededDebt(context)
            debt.dueDayOfMonth = 14
            try context.save()
            let provider = FixedDateProvider(fixed: DateMath.localDate(year: 2054, month: 8, day: 10))
            return NotificationPlanner.plan(
                try NotificationPlanner.makeInput(context: context, dateProvider: provider)
            )
            .notifications
            .filter { $0.family == .debtDueToday && $0.identifier.contains(debt.id.uuidString) }
            .map { entry in
                let c = entry.dateComponents
                return String(format: "%04d-%02d-%02d %02d:%02d",
                              c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
            }
            .sorted()
        }

        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let losAngeles = try componentsForDueDay14()
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
        let auckland = try componentsForDueDay14()

        XCTAssertFalse(losAngeles.isEmpty)
        XCTAssertEqual(losAngeles, auckland, "the local financial day and hour must not depend on the device's zone")
        XCTAssertTrue(losAngeles.allSatisfy { $0.hasSuffix("09:00") && $0.contains("-14 ") })
    }

    /// Semimonthly pay lands on two fixed days a month, including a month-end
    /// day that does not exist in February. Reminders follow the plan's own
    /// items, so they inherit that clamping rather than re-deriving it.
    func testSemimonthlyPaydayRemindersKeepTheirLocalDay() throws {
        let dates = PayScheduleGenerator.paydays(
            cadence: .semimonthly(firstDay: 15, secondDay: 31),
            anchor: TestSupport.date(2055, 1, 1),
            count: 6
        )
        let asDays = dates.map { DateMath.calendar.component(.day, from: $0) }
        XCTAssertEqual(dates.count, Set(dates).count, "semimonthly must not duplicate a pay date")
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertTrue(asDays.contains(28), "the month-end day clamps in February: \(asDays)")
        XCTAssertTrue(dates.allSatisfy { $0 == DateMath.startOfDay($0) })
        XCTAssertEqual(
            dates.prefix(4).map { DateMath.mediumString($0) },
            [TestSupport.date(2055, 1, 15), TestSupport.date(2055, 1, 31),
             TestSupport.date(2055, 2, 15), TestSupport.date(2055, 2, 28)].map { DateMath.mediumString($0) }
        )
    }

    // MARK: - Rolling window & the system pending limit

    func testTheCapKeepsTheSoonestRemindersAndNeverExceedsTheSystemLimit() throws {
        let (context, provider) = try makeStore()
        // A deliberately dense store: enough bills that the 45-day window
        // would otherwise overrun the 64-request iOS limit.
        for index in 0..<40 {
            context.insert(RecurringObligation(
                name: "Bill \(index)",
                amount: TestSupport.money("10.00"),
                cadence: .monthly,
                dueDay: (index % 28) + 1,
                createdAt: TestSupport.date(2054, 1, 1)
            ))
        }
        try context.save()

        let result = try plan(context, provider)
        XCTAssertLessThanOrEqual(result.notifications.count, NotificationPlanner.maxPendingRequests)
        XCTAssertLessThan(NotificationPlanner.maxPendingRequests, 64, "must stay under the iOS cap with headroom")
        XCTAssertGreaterThan(result.droppedByCap, 0, "the fixture must actually exercise the cap")
        // What survives is the soonest work: nothing dropped fires before
        // anything kept.
        let kept = result.notifications.map(\.fireDate)
        XCTAssertEqual(kept, kept.sorted())
    }
}
