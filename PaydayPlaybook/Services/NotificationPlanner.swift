import Foundation
import SwiftData

/// Deep-link route carried in a notification's `userInfo`.
enum NotificationRoute: String, Codable, CaseIterable {
    case checkIn = "checkin"
    case debt = "debt"
    case obligation = "obligation"
    case today = "today"
    case progress = "progress"
    case milestone = "milestone"

    /// 0.1.x wrote `card` for debt routes; taps on reminders scheduled
    /// before the upgrade must still land somewhere correct.
    static func parse(_ raw: String) -> NotificationRoute? {
        if raw == "card" { return .debt }
        return NotificationRoute(rawValue: raw)
    }
}

/// Identifier namespaces (MVP_LAYOUT §9). Every scheduled request belongs to
/// exactly one family, so the reconciler can recognize the requests it owns
/// and leave anything else alone.
///
/// Format: `<family>-<entity>-<occurrence>`
/// - entity is a stable `UUID` (never a row position or a plan letter, so a
///   plan edit or a rename cannot orphan a reminder);
/// - occurrence is `yyyyMMdd` for date-recurring families, absent for
///   one-per-entity families.
enum NotificationFamily: String, CaseIterable {
    case paydayMorning = "payday-morning"
    case paydayEvening = "payday-evening"
    case debtDueSoon = "debt-due-soon"
    case debtDueToday = "debt-due-today"
    case obligationDueSoon = "obligation-due-soon"
    case obligationDueToday = "obligation-due-today"
    case milestoneApproaching = "milestone-approaching"
    case weeklySummary = "weekly-summary"

    func identifier(entity: String, occurrence: String? = nil) -> String {
        occurrence.map { "\(rawValue)-\(entity)-\($0)" } ?? "\(rawValue)-\(entity)"
    }

    /// Prefixes this app has ever used, including the 0.1.x spellings. The
    /// reconciler removes stale requests under any of them, so an upgrade
    /// replaces old reminders instead of firing them twice.
    static let ownedPrefixes: [String] = allCases.map { $0.rawValue + "-" } + [
        "due-soon-",        // 0.1.x debt-due-soon, keyed by plan letter
        "due-today-",       // 0.1.x debt-due-today, keyed by plan letter
        "milestone-"        // 0.1.x milestone-approaching
    ]

    static func owns(_ identifier: String) -> Bool {
        ownedPrefixes.contains { identifier.hasPrefix($0) }
    }
}

/// One desired notification, fully described and free of UserNotifications
/// types so the whole schedule can be computed and tested without the
/// system notification center.
struct PlannedNotification: Equatable, Identifiable {
    let identifier: String
    let family: NotificationFamily
    /// Local wall-clock components (year, month, day, hour, minute). Stored
    /// as components rather than an instant so the reminder keeps its
    /// intended local time across time-zone moves and DST transitions.
    let dateComponents: DateComponents
    /// The same moment resolved in the current time zone — ordering and
    /// rolling-window math only, never the trigger itself.
    let fireDate: Date
    let title: String
    let body: String
    let route: NotificationRoute
    let reference: String

    var id: String { identifier }

    /// Content fingerprint: when copy or timing changes for an identifier
    /// that already exists, the reconciler re-adds it rather than assuming
    /// the pending request is still correct.
    ///
    /// The whole fire moment is included, not just the time of day. An
    /// identifier can keep its name while its date moves — raising
    /// due-soon lead days, or a reforecast moving a milestone — and those
    /// reminders must be rewritten, not left firing on the old trigger.
    var fingerprint: String {
        let c = dateComponents
        let stamp = String(
            format: "%04d%02d%02dT%02d%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0
        )
        return "\(title)|\(body)|\(route.rawValue)|\(reference)|\(stamp)"
    }
}

/// The store state the planner needs, snapshotted into plain values.
struct NotificationScheduleInput: Equatable {
    struct Preference: Equatable {
        var enabled: Bool
        var hour: Int
        var minute: Int
        var leadDays: Int
        var detailed: Bool
    }

    struct Payday: Equatable {
        var itemID: UUID
        var sequence: Int
        var date: Date
        var income: Decimal
        var keepInSpending: Decimal
        var transferToReserves: Decimal
        var debtBudget: Decimal
        var isCompleted: Bool
        var shortfallAmount: Decimal?
    }

    struct Debt: Equatable {
        var id: UUID
        var planID: String
        var name: String
        var dueDay: Int?
        var shiftRule: DueDateShiftRule
        var minimum: Decimal?
        var isPaidOff: Bool
    }

    struct Obligation: Equatable {
        var id: UUID
        var name: String
        var amount: Decimal
        var dueDay: Int?
        var shiftRule: DueDateShiftRule
        /// A due day is a day *of month*; the cadence decides which months
        /// it actually falls in (quarterly, annual, …).
        var cadence: ObligationCadence
        /// Phase anchor for cadences longer than monthly.
        var anchor: Date
    }

    struct Milestone: Equatable {
        var id: UUID
        var title: String
        var targetDate: Date
    }

    /// Actual "now", including the time of day — a reminder whose moment has
    /// already passed today is never scheduled.
    var now: Date
    var preferences: [NotificationKind: Preference]
    var paydays: [Payday]
    var debts: [Debt]
    var obligations: [Obligation]
    var milestones: [Milestone]
    /// Days between paydays, used to convert a milestone's "paydays of
    /// notice" lead into calendar days.
    var payFrequencyDays: Int
}

/// Builds the desired notification schedule. Pure and deterministic: the
/// same input always yields the same ordered list, which is what makes
/// reconciliation a stable diff rather than a rewrite.
enum NotificationPlanner {

    /// Rolling scheduling window. iOS keeps at most 64 pending requests per
    /// app and silently drops the rest, so the schedule covers the next
    /// `windowDays` and is capped below that limit with headroom.
    static let windowDays = 45
    static let maxPendingRequests = 60

    struct Plan: Equatable {
        var notifications: [PlannedNotification]
        /// Requests the window cap left unscheduled — surfaced rather than
        /// silently dropped; the next reconcile picks them up as time passes.
        var droppedByCap: Int
    }

    static func plan(_ input: NotificationScheduleInput) -> Plan {
        var result: [PlannedNotification] = []
        let today = DateMath.startOfDay(input.now)
        let windowEnd = DateMath.addingDays(windowDays, to: today)

        func preference(_ kind: NotificationKind) -> NotificationScheduleInput.Preference? {
            guard let pref = input.preferences[kind], pref.enabled else { return nil }
            return pref
        }

        // MARK: Payday morning + evening-if-incomplete
        if let morning = preference(.paydayMorning) {
            for payday in input.paydays where !payday.isCompleted {
                guard let entry = make(
                    family: .paydayMorning, entity: payday.itemID.uuidString, occurrence: nil,
                    day: payday.date, pref: morning, now: input.now, windowEnd: windowEnd,
                    title: "Today's play",
                    body: morning.detailed
                        ? "Payday #\(payday.sequence): keep \(MoneyFormat.string(payday.keepInSpending)), move \(MoneyFormat.string(payday.transferToReserves)), pay debts \(MoneyFormat.string(payday.debtBudget))."
                        : "Your payday check-in is ready.",
                    route: .checkIn, reference: payday.itemID.uuidString
                ) else { continue }
                result.append(entry)
            }
        }
        if let evening = preference(.paydayEveningIncomplete) {
            for payday in input.paydays where !payday.isCompleted {
                guard let entry = make(
                    family: .paydayEvening, entity: payday.itemID.uuidString, occurrence: nil,
                    day: payday.date, pref: evening, now: input.now, windowEnd: windowEnd,
                    title: "Payday check-in",
                    body: "Today's payday check-in is still open.",
                    route: .checkIn, reference: payday.itemID.uuidString
                ) else { continue }
                result.append(entry)
            }
        }

        // MARK: Debt due dates
        let debtSoon = preference(.cardDueSoon)
        let debtToday = preference(.cardDueToday)
        if debtSoon != nil || debtToday != nil {
            for debt in input.debts where !debt.isPaidOff {
                guard let dueDay = debt.dueDay else { continue }
                // Scan a little past the window so a due-soon lead inside the
                // window is still found when its due date sits just outside.
                let scanEnd = DateMath.addingDays(windowDays + 40, to: today)
                for due in DueDateRule.occurrences(dueDay: dueDay, from: today, to: scanEnd, shift: debt.shiftRule) {
                    let occurrence = CalendarEventService.dayKey(due)
                    if let pref = debtSoon {
                        let leadDay = DateMath.addingDays(-max(pref.leadDays, 1), to: due)
                        if let entry = make(
                            family: .debtDueSoon, entity: debt.id.uuidString, occurrence: occurrence,
                            day: leadDay, pref: pref, now: input.now, windowEnd: windowEnd,
                            title: "Debt due soon",
                            body: pref.detailed
                                ? "\(debt.name) is due \(DateMath.mediumString(due))\(debt.minimum.map { " · minimum \(MoneyFormat.string($0))" } ?? "")."
                                : "A debt payment is due soon.",
                            route: .debt, reference: debt.planID
                        ) {
                            result.append(entry)
                        }
                    }
                    if let pref = debtToday, let entry = make(
                        family: .debtDueToday, entity: debt.id.uuidString, occurrence: occurrence,
                        day: due, pref: pref, now: input.now, windowEnd: windowEnd,
                        title: "Debt due today",
                        body: pref.detailed
                            ? "\(debt.name) is due today\(debt.minimum.map { " · minimum \(MoneyFormat.string($0))" } ?? "")."
                            : "A debt payment is due today.",
                        route: .debt, reference: debt.planID
                    ) {
                        result.append(entry)
                    }
                }
            }
        }

        // MARK: Essential obligation due dates
        let obligationSoon = preference(.obligationDueSoon)
        let obligationToday = preference(.obligationDueToday)
        if obligationSoon != nil || obligationToday != nil {
            for obligation in input.obligations {
                guard let dueDay = obligation.dueDay else { continue }
                let scanEnd = DateMath.addingDays(windowDays + 40, to: today)
                for due in DueDateRule.occurrences(
                    dueDay: dueDay, cadence: obligation.cadence, anchor: obligation.anchor,
                    from: today, to: scanEnd, shift: obligation.shiftRule
                ) {
                    let occurrence = CalendarEventService.dayKey(due)
                    if let pref = obligationSoon {
                        let leadDay = DateMath.addingDays(-max(pref.leadDays, 1), to: due)
                        if let entry = make(
                            family: .obligationDueSoon, entity: obligation.id.uuidString, occurrence: occurrence,
                            day: leadDay, pref: pref, now: input.now, windowEnd: windowEnd,
                            title: "Bill due soon",
                            body: pref.detailed
                                ? "\(obligation.name) (\(MoneyFormat.string(obligation.amount))) is due \(DateMath.mediumString(due))."
                                : "An essential bill is due soon.",
                            route: .obligation, reference: obligation.id.uuidString
                        ) {
                            result.append(entry)
                        }
                    }
                    if let pref = obligationToday, let entry = make(
                        family: .obligationDueToday, entity: obligation.id.uuidString, occurrence: occurrence,
                        day: due, pref: pref, now: input.now, windowEnd: windowEnd,
                        title: "Bill due today",
                        body: pref.detailed
                            ? "\(obligation.name) (\(MoneyFormat.string(obligation.amount))) is due today."
                            : "An essential bill is due today.",
                        route: .obligation, reference: obligation.id.uuidString
                    ) {
                        result.append(entry)
                    }
                }
            }
        }

        // MARK: Milestones approaching (lead is in paydays of notice)
        if let pref = preference(.milestoneApproaching) {
            let leadDays = max(pref.leadDays, 1) * max(input.payFrequencyDays, 1)
            for milestone in input.milestones {
                let noticeDay = DateMath.addingDays(-leadDays, to: DateMath.startOfDay(milestone.targetDate))
                guard let entry = make(
                    family: .milestoneApproaching, entity: milestone.id.uuidString, occurrence: nil,
                    day: noticeDay, pref: pref, now: input.now, windowEnd: windowEnd,
                    title: "Milestone ahead",
                    body: pref.detailed
                        ? "\(milestone.title) is projected for \(DateMath.mediumString(milestone.targetDate))."
                        : "A payoff milestone is coming up.",
                    route: .milestone, reference: milestone.id.uuidString
                ) else { continue }
                result.append(entry)
            }
        }

        // MARK: Weekly summary (Sundays)
        if let pref = preference(.weeklySummary) {
            var cursor = today
            while cursor <= windowEnd {
                if DateMath.calendar.component(.weekday, from: cursor) == 1,
                   let entry = make(
                       family: .weeklySummary, entity: CalendarEventService.dayKey(cursor), occurrence: nil,
                       day: cursor, pref: pref, now: input.now, windowEnd: windowEnd,
                       title: "Weekly summary",
                       body: "See this week's progress and the next play.",
                       route: .progress, reference: ""
                   ) {
                    result.append(entry)
                }
                cursor = DateMath.addingDays(1, to: cursor)
            }
        }

        // Deterministic order: soonest first, ties broken by identifier.
        result.sort { lhs, rhs in
            if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
            return lhs.identifier < rhs.identifier
        }
        let dropped = max(result.count - maxPendingRequests, 0)
        return Plan(notifications: Array(result.prefix(maxPendingRequests)), droppedByCap: dropped)
    }

    /// Builds one entry, or nil when its moment is in the past or beyond the
    /// rolling window.
    private static func make(
        family: NotificationFamily, entity: String, occurrence: String?,
        day: Date, pref: NotificationScheduleInput.Preference,
        now: Date, windowEnd: Date,
        title: String, body: String,
        route: NotificationRoute, reference: String
    ) -> PlannedNotification? {
        let startOfDay = DateMath.startOfDay(day)
        guard startOfDay <= windowEnd else { return nil }
        var components = DateMath.calendar.dateComponents([.year, .month, .day], from: startOfDay)
        components.hour = pref.hour
        components.minute = pref.minute
        guard let fireDate = DateMath.calendar.date(from: components), fireDate > now else { return nil }
        return PlannedNotification(
            identifier: family.identifier(entity: entity, occurrence: occurrence),
            family: family,
            dateComponents: components,
            fireDate: fireDate,
            title: title,
            body: body,
            route: route,
            reference: reference
        )
    }

    // MARK: - Store snapshot

    /// Reads current store state into the planner's value input. The
    /// schedule always reflects the plan the calendar renders, so the two
    /// can never disagree about which paydays exist.
    static func makeInput(context: ModelContext, dateProvider: DateProviding) throws -> NotificationScheduleInput {
        let now = dateProvider.now
        let today = DateMath.startOfDay(now)

        var preferences: [NotificationKind: NotificationScheduleInput.Preference] = [:]
        for row in try context.fetch(FetchDescriptor<NotificationPreference>()) {
            // Duplicate rows would be a data defect; the enabled one wins so
            // a stray disabled row can never silence a reminder.
            let candidate = NotificationScheduleInput.Preference(
                enabled: row.enabled, hour: row.hour, minute: row.minute,
                leadDays: row.leadDays, detailed: row.detailedLockScreenContent
            )
            if let existing = preferences[row.type], existing.enabled, !candidate.enabled { continue }
            preferences[row.type] = candidate
        }

        var paydays: [NotificationScheduleInput.Payday] = []
        var payFrequencyDays = 14
        if let plan = try CalendarEventService.schedulePlan(context: context) {
            payFrequencyDays = max(plan.payFrequencyDays, 1)
            let planID = plan.id
            let items = try context.fetch(
                FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
            )
            let checkIns = try context.fetch(FetchDescriptor<PaydayCheckIn>())
            let completed = Set(
                checkIns.filter { $0.status == .completed || $0.status == .needsAttention }
                    .map(\.paydayPlanItemID)
            )
            paydays = items
                .filter { DateMath.startOfDay($0.date) >= today }
                .map {
                    NotificationScheduleInput.Payday(
                        itemID: $0.id, sequence: $0.sequenceNumber,
                        date: DateMath.startOfDay($0.date),
                        income: $0.plannedIncome,
                        keepInSpending: $0.plannedC1Keep,
                        transferToReserves: $0.plannedC2Transfer,
                        debtBudget: $0.plannedCardBudget,
                        isCompleted: completed.contains($0.id),
                        shortfallAmount: $0.shortfallAmount
                    )
                }
                .sorted { $0.date < $1.date }
        }

        // Paid-off debts keep their due day but stop nagging; a failure to
        // derive balances must not cancel the whole schedule, so it falls
        // back to "not paid off" (a reminder too many beats none).
        let paidOffIDs: Set<UUID>
        if let balances = try? AccountBalanceService(context: context, dateProvider: dateProvider).debtBalances() {
            paidOffIDs = Set(balances.filter(\.isPaidOff).map(\.debt.id))
        } else {
            paidOffIDs = []
        }
        let debts = try context.fetch(FetchDescriptor<DebtAccount>())
            .filter { !$0.isArchived }
            .map {
                NotificationScheduleInput.Debt(
                    id: $0.id, planID: $0.planID, name: $0.displayName,
                    dueDay: $0.dueDayOfMonth, shiftRule: $0.dueDateShiftRule,
                    minimum: $0.minimumAmount,
                    isPaidOff: paidOffIDs.contains($0.id)
                )
            }
            .sorted { $0.planID < $1.planID }

        let obligations = try context.fetch(FetchDescriptor<RecurringObligation>())
            .filter { !$0.isArchived }
            .map {
                NotificationScheduleInput.Obligation(
                    id: $0.id, name: $0.name, amount: $0.amount,
                    dueDay: $0.dueDay, shiftRule: $0.dueDateShiftRule,
                    cadence: $0.cadence, anchor: $0.createdAt
                )
            }
            .sorted { $0.name < $1.name }

        let milestones = try context.fetch(FetchDescriptor<Milestone>())
            .filter { $0.achievedDate == nil }
            .compactMap { milestone -> NotificationScheduleInput.Milestone? in
                guard let target = milestone.forecastDate ?? milestone.baselineDate else { return nil }
                return NotificationScheduleInput.Milestone(
                    id: milestone.id, title: milestone.title, targetDate: DateMath.startOfDay(target)
                )
            }
            .sorted { $0.targetDate < $1.targetDate }

        return NotificationScheduleInput(
            now: now,
            preferences: preferences,
            paydays: paydays,
            debts: debts,
            obligations: obligations,
            milestones: milestones,
            payFrequencyDays: payFrequencyDays
        )
    }
}

/// The add/remove work one reconcile pass must perform.
struct NotificationReconciliation: Equatable {
    /// Requests to (re-)add: new, or existing with changed content/timing.
    var toAdd: [PlannedNotification]
    /// Identifiers to cancel: ours, pending, and no longer wanted.
    var toRemove: [String]
    var unchanged: Int

    var isNoOp: Bool { toAdd.isEmpty && toRemove.isEmpty }
}

extension NotificationPlanner {
    /// Diffs the desired schedule against what is actually pending.
    ///
    /// Identifiers are stable, so re-adding one replaces it in place — the
    /// diff exists to avoid needless churn, and to remove exactly the
    /// requests this app owns and no longer wants (including identifiers
    /// from earlier app versions, so an upgrade never double-fires).
    static func reconcile(
        desired: [PlannedNotification],
        pending: [(identifier: String, fingerprint: String?)]
    ) -> NotificationReconciliation {
        let pendingByID = Dictionary(pending.map { ($0.identifier, $0.fingerprint) }, uniquingKeysWith: { first, _ in first })
        let desiredIDs = Set(desired.map(\.identifier))

        var toAdd: [PlannedNotification] = []
        var unchanged = 0
        for entry in desired {
            if let existing = pendingByID[entry.identifier], existing == entry.fingerprint {
                unchanged += 1
            } else {
                toAdd.append(entry)
            }
        }
        let toRemove = pending
            .map(\.identifier)
            .filter { NotificationFamily.owns($0) && !desiredIDs.contains($0) }
            .sorted()
        return NotificationReconciliation(toAdd: toAdd, toRemove: toRemove, unchanged: unchanged)
    }
}
