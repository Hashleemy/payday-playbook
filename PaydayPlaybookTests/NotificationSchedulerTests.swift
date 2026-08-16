import XCTest
import SwiftData
import UserNotifications
@testable import PaydayPlaybook

/// An in-memory stand-in for `UNUserNotificationCenter`: the real one cannot
/// be exercised in a unit-test process (no granted permission, no app
/// lifecycle), and every guarantee we care about — stable identifiers,
/// replacement rather than duplication, the rolling-window cap, permission
/// states — is about what we ask the center to do.
final class FakeNotificationCenter: NotificationCenterProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: UNAuthorizationStatus
    private var _pending: [String: UNNotificationRequest] = [:]
    private(set) var addCallCount = 0
    private(set) var removeCallCount = 0
    private(set) var requestPermissionCount = 0
    var grantOnRequest = true

    init(status: UNAuthorizationStatus = .authorized) {
        self._status = status
    }

    var status: UNAuthorizationStatus {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }

    var pendingIdentifiers: [String] {
        lock.withLock { _pending.keys.sorted() }
    }

    var pendingByIdentifier: [String: UNNotificationRequest] {
        lock.withLock { _pending }
    }

    /// Seeds a request as if it were scheduled by an earlier launch.
    func seed(identifier: String, fingerprint: String? = nil) {
        let content = UNMutableNotificationContent()
        if let fingerprint {
            content.userInfo = [NotificationScheduler.fingerprintKey: fingerprint]
        }
        var components = DateComponents()
        components.year = 2030
        components.month = 1
        components.day = 1
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        lock.withLock { _pending[identifier] = request }
    }

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestPermission(options: UNAuthorizationOptions) async -> Bool {
        lock.withLock { requestPermissionCount += 1 }
        if grantOnRequest {
            status = .authorized
            return true
        }
        status = .denied
        return false
    }

    func pendingRequests() async -> [UNNotificationRequest] {
        lock.withLock { Array(_pending.values) }
    }

    func add(_ request: UNNotificationRequest) async throws {
        lock.withLock {
            addCallCount += 1
            _pending[request.identifier] = request
        }
    }

    func removePending(identifiers: [String]) {
        lock.withLock {
            removeCallCount += 1
            for identifier in identifiers { _pending.removeValue(forKey: identifier) }
        }
    }
}

@MainActor
final class NotificationSchedulerTests: XCTestCase {

    // MARK: - Fixtures

    /// The fixture already writes the eight preference rows; the schema-2
    /// upgrade only adds kinds that are missing. Anything else here would
    /// create duplicates the app never has.
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

    private func plan(
        _ context: ModelContext, _ provider: DateProviding
    ) throws -> NotificationPlanner.Plan {
        NotificationPlanner.plan(try NotificationPlanner.makeInput(context: context, dateProvider: provider))
    }

    // MARK: - Identifier format & stability

    func testIdentifiersAreNamespacedAndEntityKeyed() throws {
        let (context, provider) = try makeStore()
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        debt.dueDayOfMonth = 20
        try context.save()

        let notifications = try plan(context, provider).notifications
        let payday = try XCTUnwrap(notifications.first { $0.family == .paydayMorning })
        let plan = try XCTUnwrap(try PlanRepository.legacyBaseline(context: context))
        let firstItem = try TestSupport.planItems(context, plan: plan)[0]
        XCTAssertEqual(payday.identifier, "payday-morning-\(firstItem.id.uuidString)")

        let dueToday = try XCTUnwrap(notifications.first { $0.family == .debtDueToday })
        XCTAssertEqual(dueToday.identifier, "debt-due-today-\(debt.id.uuidString)-20540820")

        // Every identifier is recognized as ours, so reconciliation can
        // clean up exactly what it owns.
        XCTAssertTrue(notifications.allSatisfy { NotificationFamily.owns($0.identifier) })
    }

    func testPlanIsDeterministicAcrossRuns() throws {
        let (context, provider) = try makeStore()
        let first = try plan(context, provider).notifications
        let second = try plan(context, provider).notifications
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.fireDate), first.map(\.fireDate).sorted(), "soonest first")
    }

    // MARK: - Reconciliation (replace, never duplicate)

    func testRescheduleTwiceAddsNothingTheSecondTime() async throws {
        let (context, provider) = try makeStore()
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center)

        await scheduler.rescheduleAll(context: context, dateProvider: provider)
        let firstPass = center.pendingIdentifiers
        let addsAfterFirst = center.addCallCount
        XCTAssertFalse(firstPass.isEmpty)

        await scheduler.rescheduleAll(context: context, dateProvider: provider)
        XCTAssertEqual(center.pendingIdentifiers, firstPass, "identifiers are stable")
        XCTAssertEqual(center.addCallCount, addsAfterFirst, "unchanged requests are not re-added")
        XCTAssertEqual(scheduler.lastReconciliation?.toAdd.count, 0)
        XCTAssertEqual(Set(firstPass).count, firstPass.count, "no duplicates")
    }

    func testDueDateEditReplacesTheOldReminderWithNoDuplicate() async throws {
        let (context, provider) = try makeStore()
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center)
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        debt.dueDayOfMonth = 20
        try context.save()

        await scheduler.rescheduleAll(context: context, dateProvider: provider)
        XCTAssertTrue(center.pendingIdentifiers.contains("debt-due-today-\(debt.id.uuidString)-20540820"))

        debt.dueDayOfMonth = 25
        try context.save()
        await scheduler.rescheduleAll(context: context, dateProvider: provider)

        XCTAssertFalse(center.pendingIdentifiers.contains("debt-due-today-\(debt.id.uuidString)-20540820"),
                       "the stale occurrence is cancelled")
        XCTAssertTrue(center.pendingIdentifiers.contains("debt-due-today-\(debt.id.uuidString)-20540825"))
        let dueTodayCount = center.pendingIdentifiers.filter {
            $0.hasPrefix("debt-due-today-\(debt.id.uuidString)")
        }.count
        XCTAssertEqual(dueTodayCount, 1, "one occurrence per month in the window, never two")
    }

    func testChangedCopyForTheSameIdentifierIsReAdded() throws {
        let (context, provider) = try makeStore()
        let desired = try plan(context, provider).notifications
        let entry = try XCTUnwrap(desired.first)

        let unchanged = NotificationPlanner.reconcile(
            desired: [entry],
            pending: [(identifier: entry.identifier, fingerprint: entry.fingerprint)]
        )
        XCTAssertTrue(unchanged.toAdd.isEmpty)
        XCTAssertEqual(unchanged.unchanged, 1)

        let changed = NotificationPlanner.reconcile(
            desired: [entry],
            pending: [(identifier: entry.identifier, fingerprint: "stale-copy")]
        )
        XCTAssertEqual(changed.toAdd.map(\.identifier), [entry.identifier])
        XCTAssertTrue(changed.toRemove.isEmpty, "same identifier is replaced in place, not removed then added")
    }

    // Review regression: the fingerprint must cover the whole fire moment.
    // An identifier can keep its name while its date moves — raising
    // due-soon lead days does exactly that — and the old trigger must not
    // survive as "unchanged".
    func testChangingLeadDaysMovesTheReminderInsteadOfLeavingItStale() async throws {
        let (context, provider) = try makeStore()
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center)
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        debt.dueDayOfMonth = 20
        try context.save()

        await scheduler.rescheduleAll(context: context, dateProvider: provider)
        let identifier = "debt-due-soon-\(debt.id.uuidString)-20540820"
        let before = try XCTUnwrap(center.pendingByIdentifier[identifier])
        XCTAssertEqual(
            (before.trigger as? UNCalendarNotificationTrigger)?.dateComponents.day, 17,
            "3 days of lead from Aug 20"
        )

        let pref = try XCTUnwrap(
            try context.fetch(FetchDescriptor<NotificationPreference>()).first { $0.type == .cardDueSoon }
        )
        pref.leadDays = 6
        try context.save()
        await scheduler.rescheduleAll(context: context, dateProvider: provider)

        let after = try XCTUnwrap(center.pendingByIdentifier[identifier])
        XCTAssertEqual(
            (after.trigger as? UNCalendarNotificationTrigger)?.dateComponents.day, 14,
            "the reminder must move to the new lead day, not keep the stale trigger"
        )
        // Card B is the only debt with a due day; the 45-day window holds
        // its Aug 20 and Sep 20 occurrences, so exactly two move.
        XCTAssertEqual(scheduler.lastReconciliation?.toAdd.count, 2, "one re-add per moved due-soon reminder")
    }

    func testFingerprintDistinguishesFireDatesThatShareEverythingElse() throws {
        let (context, provider) = try makeStore()
        let entry = try XCTUnwrap(try plan(context, provider).notifications.first)
        var moved = entry
        var components = entry.dateComponents
        components.day = (components.day ?? 1) + 1
        moved = PlannedNotification(
            identifier: entry.identifier, family: entry.family,
            dateComponents: components, fireDate: DateMath.addingDays(1, to: entry.fireDate),
            title: entry.title, body: entry.body, route: entry.route, reference: entry.reference
        )
        XCTAssertNotEqual(entry.fingerprint, moved.fingerprint)

        let reconciliation = NotificationPlanner.reconcile(
            desired: [moved],
            pending: [(identifier: entry.identifier, fingerprint: entry.fingerprint)]
        )
        XCTAssertEqual(reconciliation.toAdd.map(\.identifier), [entry.identifier])
    }

    // Review regression: a due day is a day *of month*, so the obligation's
    // cadence decides which months it lands in.
    func testObligationCadenceControlsHowOftenRemindersFire() throws {
        let (context, provider) = try makeStore()
        let quarterly = RecurringObligation(
            name: "Insurance", amount: TestSupport.money("450.00"),
            cadence: .quarterly, dueDay: 10,
            createdAt: TestSupport.date(2054, 8, 1), updatedAt: TestSupport.date(2054, 8, 1)
        )
        let monthly = RecurringObligation(
            name: "Rent", amount: TestSupport.money("1700.00"),
            cadence: .monthly, dueDay: 10,
            createdAt: TestSupport.date(2054, 8, 1), updatedAt: TestSupport.date(2054, 8, 1)
        )
        let weekly = RecurringObligation(
            name: "Transit", amount: TestSupport.money("30.00"),
            cadence: .weekly, dueDay: 10,
            createdAt: TestSupport.date(2054, 8, 1), updatedAt: TestSupport.date(2054, 8, 1)
        )
        context.insert(quarterly)
        context.insert(monthly)
        context.insert(weekly)
        try context.save()

        let notifications = try plan(context, provider).notifications
            .filter { $0.family == .obligationDueToday }
        func days(_ obligation: RecurringObligation) -> [String] {
            notifications
                .filter { $0.identifier.contains(obligation.id.uuidString) }
                .map { String($0.identifier.suffix(8)) }
                .sorted()
        }
        // "Now" is midnight on Aug 10, so today's 9:00 reminder is still
        // ahead. The window runs 45 days, to Sep 24.
        XCTAssertEqual(days(monthly), ["20540810", "20540910"])
        // Quarterly is anchored on its August creation month, so August
        // qualifies and September does not — the point being that the same
        // due day yields fewer reminders than the monthly bill.
        XCTAssertEqual(days(quarterly), ["20540810"], "a quarterly bill must not fire every month")
        XCTAssertTrue(days(weekly).isEmpty, "a weekly bill has no meaningful day-of-month")
    }

    func testReconcileRemovesLegacyIdentifiersButLeavesForeignOnesAlone() throws {
        let (context, provider) = try makeStore()
        let desired = try plan(context, provider).notifications
        let reconciliation = NotificationPlanner.reconcile(
            desired: desired,
            pending: [
                (identifier: "due-soon-B-202608", fingerprint: nil),      // 0.1.x spelling
                (identifier: "payday-morning-17", fingerprint: nil),      // 0.1.x sequence-keyed
                (identifier: "some.other.app.reminder", fingerprint: nil) // not ours
            ]
        )
        XCTAssertEqual(reconciliation.toRemove, ["due-soon-B-202608", "payday-morning-17"])
        XCTAssertFalse(reconciliation.toRemove.contains("some.other.app.reminder"))
    }

    func testUpgradeFromLegacyIdentifiersDoesNotDoubleFire() async throws {
        let (context, provider) = try makeStore()
        let center = FakeNotificationCenter()
        center.seed(identifier: "payday-morning-1")
        center.seed(identifier: "due-soon-B-202608")
        let scheduler = NotificationScheduler(center: center)

        await scheduler.rescheduleAll(context: context, dateProvider: provider)

        XCTAssertFalse(center.pendingIdentifiers.contains("payday-morning-1"))
        XCTAssertFalse(center.pendingIdentifiers.contains("due-soon-B-202608"))
        XCTAssertTrue(center.pendingIdentifiers.contains { $0.hasPrefix("payday-morning-") })
    }

    // MARK: - Check-in completion cancels the evening reminder

    func testCompletingACheckInCancelsThatPaydaysReminders() async throws {
        let (context, provider) = try makeStore()
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(center: center)
        let planVersion = try XCTUnwrap(try PlanRepository.legacyBaseline(context: context))
        let items = try TestSupport.planItems(context, plan: planVersion)

        await scheduler.rescheduleAll(context: context, dateProvider: provider)
        let eveningID = "payday-evening-\(items[0].id.uuidString)"
        XCTAssertTrue(center.pendingIdentifiers.contains(eveningID))

        // Immediate cancellation, before any reconcile.
        scheduler.cancelPaydayReminders(itemID: items[0].id)
        XCTAssertFalse(center.pendingIdentifiers.contains(eveningID))

        // And a following reconcile must not bring it back.
        let checkIn = PaydayCheckIn(paydayPlanItemID: items[0].id)
        checkIn.status = .completed
        context.insert(checkIn)
        try context.save()
        await scheduler.rescheduleAll(context: context, dateProvider: provider)
        XCTAssertFalse(center.pendingIdentifiers.contains(eveningID))
        XCTAssertFalse(center.pendingIdentifiers.contains("payday-morning-\(items[0].id.uuidString)"))
    }

    // MARK: - Permission states

    func testDeniedAuthorizationSchedulesNothingAndTouchesNothing() async throws {
        let (context, provider) = try makeStore()
        let center = FakeNotificationCenter(status: .denied)
        center.seed(identifier: "payday-morning-existing")
        let scheduler = NotificationScheduler(center: center)

        await scheduler.rescheduleAll(context: context, dateProvider: provider)

        XCTAssertEqual(center.addCallCount, 0)
        XCTAssertEqual(center.removeCallCount, 0, "a denied app never disturbs pending state")
        XCTAssertEqual(scheduler.authorizationStatus, .denied)
        XCTAssertNil(scheduler.lastReconciliation)
    }

    func testNotDeterminedSchedulesNothingUntilPermissionIsGranted() async throws {
        let (context, provider) = try makeStore()
        let center = FakeNotificationCenter(status: .notDetermined)
        let scheduler = NotificationScheduler(center: center)

        await scheduler.rescheduleAll(context: context, dateProvider: provider)
        XCTAssertEqual(center.addCallCount, 0)

        let granted = await scheduler.requestAuthorization()
        XCTAssertTrue(granted)
        XCTAssertEqual(center.requestPermissionCount, 1)
        await scheduler.rescheduleAll(context: context, dateProvider: provider)
        XCTAssertGreaterThan(center.addCallCount, 0)
    }

    func testProvisionalAuthorizationSchedulesNormally() async throws {
        let (context, provider) = try makeStore()
        let center = FakeNotificationCenter(status: .provisional)
        let scheduler = NotificationScheduler(center: center)

        await scheduler.rescheduleAll(context: context, dateProvider: provider)
        XCTAssertGreaterThan(center.addCallCount, 0)
        XCTAssertTrue(NotificationScheduler.canSchedule(.provisional))
        XCTAssertFalse(NotificationScheduler.canSchedule(.denied))
        XCTAssertFalse(NotificationScheduler.canSchedule(.notDetermined))
    }

    // MARK: - Rolling window

    func testDenseRealisticScheduleStaysUnderTheSystemPendingLimit() throws {
        let (context, provider) = try makeStore()
        // Give every debt a due day so the schedule is as dense as the app
        // can make it from real data.
        for (index, debt) in try context.fetch(FetchDescriptor<DebtAccount>()).enumerated() {
            debt.dueDayOfMonth = (index % 28) + 1
        }
        for day in 1...6 {
            context.insert(RecurringObligation(
                name: "Bill \(day)", amount: TestSupport.money("100.00"),
                cadence: .monthly, dueDay: day * 4
            ))
        }
        try context.save()

        let result = try plan(context, provider)
        XCTAssertLessThanOrEqual(result.notifications.count, NotificationPlanner.maxPendingRequests)
        XCTAssertLessThan(result.notifications.count, 64, "iOS drops requests past 64")
        XCTAssertEqual(Set(result.notifications.map(\.identifier)).count, result.notifications.count)
    }

    func testRollingWindowCapKeepsTheSoonestAndReportsTheRest() {
        // Driven at the planner boundary so the cap is exercised exactly,
        // independent of how dense a real store happens to be.
        var debts: [NotificationScheduleInput.Debt] = []
        for index in 0..<40 {
            debts.append(NotificationScheduleInput.Debt(
                id: UUID(), planID: String(format: "D%02d", index), name: "Debt \(index)",
                dueDay: (index % 28) + 1, shiftRule: .exactDay,
                minimum: nil, isPaidOff: false
            ))
        }
        let input = NotificationScheduleInput(
            now: TestSupport.date(2054, 8, 10),
            preferences: [
                .cardDueSoon: .init(enabled: true, hour: 9, minute: 0, leadDays: 3, detailed: false),
                .cardDueToday: .init(enabled: true, hour: 9, minute: 0, leadDays: 0, detailed: false)
            ],
            paydays: [], debts: debts, obligations: [], milestones: [],
            payFrequencyDays: 14
        )

        let result = NotificationPlanner.plan(input)
        XCTAssertEqual(result.notifications.count, NotificationPlanner.maxPendingRequests)
        XCTAssertGreaterThan(result.droppedByCap, 0, "the cap is reported, never silent")

        // Nearest-first: everything kept fires no later than anything dropped.
        let cutoff = try! XCTUnwrap(result.notifications.last?.fireDate)
        XCTAssertTrue(result.notifications.allSatisfy { $0.fireDate <= cutoff })
        let uncapped = result.notifications.count + result.droppedByCap
        XCTAssertGreaterThan(uncapped, 64, "the fixture is dense enough to exceed the iOS limit")
    }

    func testWindowExcludesMomentsAlreadyPastAndBeyondTheHorizon() throws {
        // 9:30 AM on a payday: the 8:00 morning reminder has passed, the
        // 7:00 PM evening one has not.
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context)
        for preference in NotificationPreference.seedDefaults() { context.insert(preference) }
        try context.save()
        let paydayMorning = DateMath.calendar.date(
            bySettingHour: 9, minute: 30, second: 0, of: TestSupport.date(2054, 8, 20)
        )!
        let provider = FixedDateProvider(fixed: paydayMorning)

        let notifications = try plan(context, provider).notifications
        let planVersion = try XCTUnwrap(try PlanRepository.legacyBaseline(context: context))
        let firstItem = try TestSupport.planItems(context, plan: planVersion)[0]
        XCTAssertFalse(notifications.contains { $0.identifier == "payday-morning-\(firstItem.id.uuidString)" },
                       "a moment that already passed is never scheduled")
        XCTAssertTrue(notifications.contains { $0.identifier == "payday-evening-\(firstItem.id.uuidString)" })

        let horizon = DateMath.addingDays(NotificationPlanner.windowDays, to: DateMath.startOfDay(paydayMorning))
        XCTAssertTrue(notifications.allSatisfy { $0.fireDate <= DateMath.addingDays(1, to: horizon) })
    }

    // MARK: - Content safety

    func testLockScreenCopyIsGenericUnlessDetailedPreviewsAreEnabled() throws {
        let (context, provider) = try makeStore()
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        debt.dueDayOfMonth = 20
        debt.displayName = "Chase Sapphire"
        debt.minimumAmount = TestSupport.money("125.00")
        try context.save()

        var notifications = try plan(context, provider).notifications
        for entry in notifications {
            XCTAssertFalse(entry.body.contains("Chase Sapphire"), "no entity names by default")
            XCTAssertFalse(entry.body.contains("$"), "no amounts by default: \(entry.body)")
        }

        for preference in try context.fetch(FetchDescriptor<NotificationPreference>()) {
            preference.detailedLockScreenContent = true
        }
        try context.save()
        notifications = try plan(context, provider).notifications
        XCTAssertTrue(notifications.contains { $0.body.contains("Chase Sapphire") })
        XCTAssertTrue(notifications.contains { $0.body.contains("$") })
    }

    func testDisabledPreferencesProduceNoRequests() throws {
        let (context, provider) = try makeStore()
        for preference in try context.fetch(FetchDescriptor<NotificationPreference>()) {
            preference.enabled = false
        }
        try context.save()
        XCTAssertTrue(try plan(context, provider).notifications.isEmpty)
    }

    // MARK: - Obligations & due-date families

    func testObligationDueRemindersUseTheirOwnFamilyAndPreference() throws {
        let (context, provider) = try makeStore()
        let obligation = RecurringObligation(
            name: "Rent", amount: TestSupport.money("1700.00"), cadence: .monthly, dueDay: 1
        )
        context.insert(obligation)
        try context.save()

        var notifications = try plan(context, provider).notifications
        let due = notifications.filter { $0.family == .obligationDueToday || $0.family == .obligationDueSoon }
        XCTAssertFalse(due.isEmpty)
        XCTAssertTrue(due.allSatisfy { $0.identifier.contains(obligation.id.uuidString) })
        XCTAssertTrue(due.allSatisfy { $0.route == .obligation })

        let pref = try XCTUnwrap(
            try context.fetch(FetchDescriptor<NotificationPreference>()).first { $0.type == .obligationDueSoon }
        )
        pref.enabled = false
        try context.save()
        notifications = try plan(context, provider).notifications
        XCTAssertFalse(notifications.contains { $0.family == .obligationDueSoon })
        XCTAssertTrue(notifications.contains { $0.family == .obligationDueToday })
    }

    func testPaidOffDebtStopsNagging() throws {
        let (context, provider) = try makeStore()
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        debt.dueDayOfMonth = 20
        try context.save()
        XCTAssertTrue(try plan(context, provider).notifications.contains { $0.identifier.contains(debt.id.uuidString) })

        context.insert(BalanceSnapshot(
            debtAccountID: debt.id, debtPlanID: debt.planID,
            effectiveDate: TestSupport.date(2054, 8, 9),
            amount: .zero, sourceType: .currentOnlineBalance
        ))
        try context.save()
        XCTAssertFalse(try plan(context, provider).notifications.contains { $0.identifier.contains(debt.id.uuidString) },
                       "a debt at zero should not send due-date reminders")
    }

    func testArchivedDebtAndObligationScheduleNothing() throws {
        let (context, provider) = try makeStore()
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        debt.dueDayOfMonth = 20
        debt.isArchived = true
        let obligation = RecurringObligation(
            name: "Gym", amount: TestSupport.money("40.00"), cadence: .monthly, dueDay: 15, isArchived: true
        )
        context.insert(obligation)
        try context.save()

        let notifications = try plan(context, provider).notifications
        XCTAssertFalse(notifications.contains { $0.identifier.contains(debt.id.uuidString) })
        XCTAssertFalse(notifications.contains { $0.identifier.contains(obligation.id.uuidString) })
    }

    // MARK: - Short months & DST

    func testShortMonthDueDayProducesOneReminderPerMonth() throws {
        let (context, provider) = try makeStore(today: TestSupport.date(2055, 1, 20))
        let debt = try XCTUnwrap(try context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        debt.dueDayOfMonth = 31
        try context.save()

        let notifications = try plan(context, provider).notifications
            .filter { $0.family == .debtDueToday && $0.identifier.contains(debt.id.uuidString) }
        let occurrences = notifications.map { $0.identifier.suffix(8) }.sorted()
        XCTAssertEqual(occurrences, ["20550131", "20550228"], "Feb clamps to the 28th, exactly once")
    }

    func testTriggerCarriesLocalComponentsSoTimeZoneMovesKeepTheHour() throws {
        let (context, provider) = try makeStore()
        let notifications = try plan(context, provider).notifications
        let morning = try XCTUnwrap(notifications.first { $0.family == .paydayMorning })
        XCTAssertEqual(morning.dateComponents.hour, 8)
        XCTAssertEqual(morning.dateComponents.minute, 0)
        XCTAssertNotNil(morning.dateComponents.year)
        XCTAssertNotNil(morning.dateComponents.month)
        XCTAssertNotNil(morning.dateComponents.day)
        // No absolute instant is stored in the trigger: a wall-clock
        // reminder must fire at 8:00 local wherever the user is.
        XCTAssertNil(morning.dateComponents.timeZone)
    }
}
