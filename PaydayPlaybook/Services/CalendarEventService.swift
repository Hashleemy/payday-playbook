import Foundation
import SwiftData

/// Merges the whole plan into date-keyed display events (F-07, V2-12):
/// paydays with income, account transfers, protected-buffer and obligation
/// reserves, debt payments with the active avalanche target, debt and
/// obligation due dates, milestones and projected payoffs, actual ledger
/// entries and check-ins, and reforecast markers.
///
/// Every event carries an explicit `EventStatus` rendered as icon + text —
/// never color alone — and a typed `DeepLink` so a tapped day can open the
/// exact Check-In, Debt, Entry, or Milestone.
struct CalendarEventService {

    // MARK: - Taxonomy

    enum EventKind: String, CaseIterable, Identifiable {
        case payday
        case transfer
        case reserve
        case debtPayment
        case debtDue
        case obligationDue
        case milestone
        case entry
        case reforecast

        var id: String { rawValue }

        var label: String {
            switch self {
            case .payday: return "Payday"
            case .transfer: return "Transfer"
            case .reserve: return "Reserve"
            case .debtPayment: return "Debt payment"
            case .debtDue: return "Debt due"
            case .obligationDue: return "Bill due"
            case .milestone: return "Milestone"
            case .entry: return "Entry"
            case .reforecast: return "Reforecast"
            }
        }

        var symbolName: String {
            switch self {
            case .payday: return "dollarsign.circle.fill"
            case .transfer: return "arrow.left.arrow.right"
            case .reserve: return "shield.lefthalf.filled"
            case .debtPayment: return "creditcard.and.123"
            case .debtDue: return "creditcard"
            case .obligationDue: return "house"
            case .milestone: return "star.fill"
            case .entry: return "circlebadge.fill"
            case .reforecast: return "arrow.triangle.2.circlepath"
            }
        }

        /// Display order inside one day: the play-by-play reads top to
        /// bottom in allocation order, then due dates, then records.
        var dayOrder: Int {
            switch self {
            case .payday: return 0
            case .transfer: return 1
            case .reserve: return 2
            case .debtPayment: return 3
            case .debtDue: return 4
            case .obligationDue: return 5
            case .milestone: return 6
            case .entry: return 7
            case .reforecast: return 8
            }
        }
    }

    /// The five user-facing truth states (V2-12/V2-15). Rendered as icon +
    /// text so status never depends on color alone.
    enum EventStatus: String {
        case planned
        case actual
        case completed
        case needsAttention
        case reforecast

        var label: String {
            switch self {
            case .planned: return "Planned"
            case .actual: return "Actual"
            case .completed: return "Completed"
            case .needsAttention: return "Needs attention"
            case .reforecast: return "Reforecast"
            }
        }

        var symbolName: String {
            switch self {
            case .planned: return "circle.dotted"
            case .actual: return "pencil.circle.fill"
            case .completed: return "checkmark.circle.fill"
            case .needsAttention: return "exclamationmark.triangle.fill"
            case .reforecast: return "arrow.triangle.2.circlepath.circle.fill"
            }
        }
    }

    /// Typed navigation target for an event (V2-11: deep links must survive
    /// plan edits — they carry entity identity, never row positions).
    enum DeepLink: Hashable {
        case checkIn(itemID: UUID)
        case debt(planID: String)
        case entry(entryID: UUID)
        case milestone(milestoneID: UUID)
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all
        case paydays
        case moneyMoves
        case dueDates
        case milestones
        case actualEntries
        case needsAttention
        case reforecasts

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .paydays: return "Paydays"
            case .moneyMoves: return "Transfers & reserves"
            case .dueDates: return "Due dates"
            case .milestones: return "Milestones"
            case .actualEntries: return "Actual entries"
            case .needsAttention: return "Needs attention"
            case .reforecasts: return "Reforecasts"
            }
        }

        func includes(_ event: Event) -> Bool {
            switch self {
            case .all:
                return true
            case .paydays:
                return event.kind == .payday
            case .moneyMoves:
                return [.transfer, .reserve, .debtPayment].contains(event.kind)
            case .dueDates:
                return [.debtDue, .obligationDue].contains(event.kind)
            case .milestones:
                return event.kind == .milestone
            case .actualEntries:
                return event.kind == .entry || event.status == .actual || event.status == .completed
            case .needsAttention:
                return event.status == .needsAttention
            case .reforecasts:
                return event.kind == .reforecast || event.status == .reforecast
            }
        }
    }

    struct Event: Identifiable {
        /// Stable within a plan: "<family>-<entity>-<occurrence>", so views
        /// and schedulers can diff renders without duplicates.
        let id: String
        let date: Date
        let kind: EventKind
        let status: EventStatus
        let title: String
        let detail: String?
        let link: DeepLink?

        /// Icon + text accessibility description (status is spoken, never
        /// implied by color).
        var accessibilityDescription: String {
            var parts = ["\(kind.label): \(title)", status.label]
            if let detail { parts.append(detail) }
            return parts.joined(separator: ", ")
        }
    }

    // MARK: - Setup

    let context: ModelContext
    let dateProvider: DateProviding

    init(context: ModelContext, dateProvider: DateProviding) {
        self.context = context
        self.dateProvider = dateProvider
    }

    /// The plan whose schedule the calendar renders: the active plan that
    /// owns payday items (an onboarding-generated plan owns its own), else
    /// the Original Plan v1 template/migration baseline (0.1.x behavior —
    /// user-tweaked "Plan v2" versions borrow the baseline's dates).
    static func schedulePlan(context: ModelContext) throws -> PlanVersion? {
        let plans = try context.fetch(FetchDescriptor<PlanVersion>())
        for plan in plans.filter({ $0.isActive }).sorted(by: { $0.createdAt > $1.createdAt }) {
            let planID = plan.id
            let itemCount = try context.fetchCount(
                FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
            )
            if itemCount > 0 { return plan }
        }
        return try PlanSeeder.existingBaseline(context: context)
    }

    // MARK: - Merge

    func events(from start: Date, to end: Date) throws -> [Event] {
        var events: [Event] = []
        let today = DateMath.startOfDay(dateProvider.now)
        let startDay = DateMath.startOfDay(start)
        let endDay = DateMath.startOfDay(end)
        guard startDay <= endDay else { return [] }

        let obligations = try context.fetch(FetchDescriptor<RecurringObligation>())
        let obligationsByID = Dictionary(uniqueKeysWithValues: obligations.map { ($0.id, $0) })
        let debts = try context.fetch(FetchDescriptor<DebtAccount>())
        let debtsByPlanID = Dictionary(grouping: debts, by: \.planID)

        if let plan = try Self.schedulePlan(context: context) {
            try appendPlanEvents(
                &events, plan: plan, obligationsByID: obligationsByID,
                debtsByPlanID: debtsByPlanID,
                startDay: startDay, endDay: endDay, today: today
            )
        }

        appendDueDateEvents(&events, debts: debts, obligations: obligations, startDay: startDay, endDay: endDay, today: today)
        try appendMilestoneEvents(&events, startDay: startDay, endDay: endDay)
        try appendActualEvents(&events, startDay: startDay, endDay: endDay)
        try appendReforecastEvents(&events, startDay: startDay, endDay: endDay)

        return events.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            if lhs.kind.dayOrder != rhs.kind.dayOrder { return lhs.kind.dayOrder < rhs.kind.dayOrder }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Planned play-by-play

    private func appendPlanEvents(
        _ events: inout [Event],
        plan: PlanVersion,
        obligationsByID: [UUID: RecurringObligation],
        debtsByPlanID: [String: [DebtAccount]],
        startDay: Date, endDay: Date, today: Date
    ) throws {
        let planID = plan.id
        let planItems = try context.fetch(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
        )
        let checkIns = try context.fetch(FetchDescriptor<PaydayCheckIn>())
        let checkInsByItem = Dictionary(grouping: checkIns, by: \.paydayPlanItemID)
        let reserveRows = try context.fetch(FetchDescriptor<PlannedObligationReserve>())
        let reservesByItem = Dictionary(grouping: reserveRows, by: \.paydayPlanItemID)

        for item in planItems {
            let day = DateMath.startOfDay(item.date)
            guard day >= startDay, day <= endDay else { continue }
            let checkIn = checkInsByItem[item.id]?.first

            let paydayStatus: EventStatus
            var paydayDetail = "Income \(MoneyFormat.string(item.plannedIncome)) · Keep \(MoneyFormat.string(item.plannedC1Keep))"
            if let checkIn, checkIn.status == .needsAttention {
                paydayStatus = .needsAttention
                paydayDetail += " · Completed with an exception"
            } else if let checkIn, checkIn.status == .completed {
                paydayStatus = .completed
                if let actualIncome = checkIn.actualIncome, actualIncome != item.plannedIncome {
                    paydayDetail += " · Actual income \(MoneyFormat.string(actualIncome))"
                }
            } else if item.needsAttention {
                // R-09 shortfall flagged at generation.
                paydayStatus = .needsAttention
                paydayDetail += " · Short by \(MoneyFormat.string(item.shortfallAmount ?? 0)) — outside funds needed"
            } else if day <= today {
                paydayStatus = .needsAttention
                paydayDetail += " · Check-in still open"
            } else {
                paydayStatus = .planned
            }
            events.append(Event(
                id: "payday-\(item.sequenceNumber)",
                date: day, kind: .payday, status: paydayStatus,
                title: "Payday #\(item.sequenceNumber)",
                detail: paydayDetail,
                link: .checkIn(itemID: item.id)
            ))

            let laterTruth: EventStatus = (checkIn?.status == .completed || checkIn?.status == .needsAttention)
                ? .completed
                : (day <= today ? .needsAttention : .planned)

            if item.plannedC2Transfer > 0 {
                var detail = "Move \(MoneyFormat.string(item.plannedC2Transfer)) to reserves"
                if let actual = checkIn?.actualC2Transfer, actual != item.plannedC2Transfer {
                    detail += " · Actual \(MoneyFormat.string(actual))"
                }
                events.append(Event(
                    id: "transfer-\(item.sequenceNumber)",
                    date: day, kind: .transfer, status: laterTruth,
                    title: "Account transfer",
                    detail: detail,
                    link: .checkIn(itemID: item.id)
                ))
            }

            if item.plannedBufferAdd > 0 {
                events.append(Event(
                    id: "reserve-buffer-\(item.sequenceNumber)",
                    date: day, kind: .reserve, status: laterTruth,
                    title: "Protected buffer",
                    detail: "Add \(MoneyFormat.string(item.plannedBufferAdd)) toward the cash floor",
                    link: .checkIn(itemID: item.id)
                ))
            }

            // Obligation reserves: schema-2 rows first, legacy car/train
            // columns as the fallback for stores whose rows are absent.
            let rows = reservesByItem[item.id] ?? []
            if rows.isEmpty {
                for (key, title, amount) in [
                    ("car", "Car reserve", item.plannedCarReserve),
                    ("train", "Train reserve", item.plannedTrainReserve)
                ] where amount > 0 {
                    events.append(Event(
                        id: "reserve-\(key)-\(item.sequenceNumber)",
                        date: day, kind: .reserve, status: laterTruth,
                        title: title,
                        detail: "Reserve \(MoneyFormat.string(amount)) this paycheck",
                        link: .checkIn(itemID: item.id)
                    ))
                }
            } else {
                for row in rows.sorted(by: { $0.amount > $1.amount }) where row.amount > 0 {
                    let name = obligationsByID[row.obligationID]?.name ?? "Obligation"
                    events.append(Event(
                        id: "reserve-\(row.obligationID.uuidString)-\(item.sequenceNumber)",
                        date: day, kind: .reserve, status: laterTruth,
                        title: "\(name) reserve",
                        detail: "Reserve \(MoneyFormat.string(row.amount)) this paycheck",
                        link: .checkIn(itemID: item.id)
                    ))
                }
            }

            if item.plannedCardBudget > 0 {
                let targetName = debtsByPlanID[item.plannedTargetDebtID]?.first?.displayName
                    ?? (item.plannedTargetDebtID.isEmpty ? "debts" : "Card \(item.plannedTargetDebtID)")
                events.append(Event(
                    id: "debtpay-\(item.sequenceNumber)",
                    date: day, kind: .debtPayment, status: laterTruth,
                    title: "Debt payments",
                    detail: "Minimums + extra \(MoneyFormat.string(item.plannedCardBudget)) · Avalanche target: \(targetName)",
                    link: item.plannedTargetDebtID.isEmpty ? .checkIn(itemID: item.id) : .debt(planID: item.plannedTargetDebtID)
                ))
            }
        }
    }

    // MARK: - Due dates (prospective, from current model state — V2-11)

    private func appendDueDateEvents(
        _ events: inout [Event],
        debts: [DebtAccount], obligations: [RecurringObligation],
        startDay: Date, endDay: Date, today: Date
    ) {
        let windowEnd = DateMath.addingDays(1, to: endDay)
        for debt in debts where !debt.isArchived {
            guard let dueDay = debt.dueDayOfMonth else { continue }
            for due in DueDateRule.occurrences(dueDay: dueDay, from: startDay, to: windowEnd, shift: debt.dueDateShiftRule) {
                let minimum = debt.minimumAmount.map { "Minimum \(MoneyFormat.string($0))" } ?? "Statement minimum"
                let clampedNote = DueDateRule.isClamped(dueDay: dueDay, inMonthOf: due) ? " · day \(dueDay) → last day" : ""
                events.append(Event(
                    id: "debt-due-\(debt.id.uuidString)-\(Self.dayKey(due))",
                    date: due, kind: .debtDue,
                    status: due < today ? .actual : .planned,
                    title: "\(debt.displayName) due",
                    detail: minimum + clampedNote,
                    link: .debt(planID: debt.planID)
                ))
            }
        }
        for obligation in obligations where !obligation.isArchived {
            guard let dueDay = obligation.dueDay else { continue }
            for due in DueDateRule.occurrences(dueDay: dueDay, from: startDay, to: windowEnd, shift: obligation.dueDateShiftRule) {
                events.append(Event(
                    id: "obligation-due-\(obligation.id.uuidString)-\(Self.dayKey(due))",
                    date: due, kind: .obligationDue,
                    status: due < today ? .actual : .planned,
                    title: "\(obligation.name) due",
                    detail: "\(MoneyFormat.string(obligation.amount)) · \(obligation.cadence.displayName)",
                    link: nil
                ))
            }
        }
    }

    // MARK: - Milestones & projected payoffs

    private func appendMilestoneEvents(_ events: inout [Event], startDay: Date, endDay: Date) throws {
        let milestones = try context.fetch(FetchDescriptor<Milestone>())
        for milestone in milestones {
            let displayDate = milestone.achievedDate ?? milestone.forecastDate ?? milestone.baselineDate
            guard let displayDate else { continue }
            let day = DateMath.startOfDay(displayDate)
            guard day >= startDay, day <= endDay else { continue }
            let achieved = milestone.achievedDate != nil
            let moved = !achieved && milestone.forecastDate != nil
                && milestone.baselineDate != nil
                && milestone.forecastDate != milestone.baselineDate
            events.append(Event(
                id: "milestone-\(milestone.id.uuidString)",
                date: day, kind: .milestone,
                status: achieved ? .completed : (moved ? .reforecast : .planned),
                title: milestone.title,
                detail: achieved ? "Achieved" : (moved ? "Projected (reforecast)" : "Projected"),
                link: .milestone(milestoneID: milestone.id)
            ))
        }
    }

    // MARK: - Actuals (ledger + balance snapshots)

    private func appendActualEvents(_ events: inout [Event], startDay: Date, endDay: Date) throws {
        let entries = try context.fetch(FetchDescriptor<LedgerEntry>())
        for entry in entries {
            let day = DateMath.startOfDay(entry.effectiveDate)
            guard day >= startDay, day <= endDay else { continue }
            events.append(Event(
                id: "entry-\(entry.id.uuidString)",
                date: day, kind: .entry, status: .actual,
                title: entry.type.displayName,
                detail: MoneyFormat.string(entry.amount),
                link: .entry(entryID: entry.id)
            ))
        }

        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
        for snapshot in snapshots where snapshot.debtAccountID != nil {
            let day = DateMath.startOfDay(snapshot.effectiveDate)
            guard day >= startDay, day <= endDay else { continue }
            events.append(Event(
                id: "snapshot-\(snapshot.id.uuidString)",
                date: day, kind: .entry, status: .actual,
                title: "Balance update\(snapshot.debtPlanID.map { " · Card \($0)" } ?? "")",
                detail: MoneyFormat.string(snapshot.amount),
                link: snapshot.debtPlanID.map { .debt(planID: $0) }
            ))
        }
    }

    // MARK: - Reforecast markers (plan-versus-actual)

    private func appendReforecastEvents(_ events: inout [Event], startDay: Date, endDay: Date) throws {
        let snapshots = try context.fetch(FetchDescriptor<ForecastSnapshot>())
        // One marker per day — the latest snapshot that day tells the story.
        let byDay = Dictionary(grouping: snapshots) { DateMath.startOfDay($0.calculatedAt) }
        for (day, group) in byDay {
            guard day >= startDay, day <= endDay else { continue }
            guard let latest = group.max(by: { $0.calculatedAt < $1.calculatedAt }) else { continue }
            // The initial seed forecast is the baseline, not a reforecast.
            guard latest.triggerType != .initialSeed else { continue }
            let payoff = latest.projectedPayoffDate.map { "Debt-free \(DateMath.mediumString($0))" } ?? "Payoff date open"
            events.append(Event(
                id: "reforecast-\(latest.id.uuidString)",
                date: day, kind: .reforecast, status: .reforecast,
                title: "Reforecast",
                detail: "\(payoff) · \(latest.remainingPaychecks) checks left",
                link: nil
            ))
        }
    }

    static func dayKey(_ date: Date) -> String {
        let c = DateMath.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Deep-link resolution

    /// What a tapped deep link should actually do, once the target has been
    /// checked against the store.
    enum LinkResolution: Equatable {
        case openCheckIn(item: UUID)
        case openDebt(planID: String)
        case openEntry(entryID: UUID)
        case openMilestone(milestoneID: UUID)
        /// The target is archived or gone; the message is user-facing copy.
        case unavailable(message: String)
    }

    /// Resolves a link against current data. Plan edits, archiving, and
    /// deletion all happen between rendering an event and tapping it, so
    /// every target is re-checked rather than trusted (V2-11).
    func resolve(_ link: DeepLink) throws -> LinkResolution {
        switch link {
        case .checkIn(let itemID):
            let exists = try context.fetchCount(
                FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.id == itemID })
            ) > 0
            return exists
                ? .openCheckIn(item: itemID)
                : .unavailable(message: "This payday belongs to an older plan version and can't be opened.")
        case .debt(let planID):
            let matches = try context.fetch(
                FetchDescriptor<DebtAccount>(predicate: #Predicate { $0.planID == planID })
            )
            if matches.contains(where: { !$0.isArchived }) { return .openDebt(planID: planID) }
            if matches.isEmpty { return .unavailable(message: "This debt no longer exists.") }
            return .unavailable(message: "This debt is archived. You can find it under Debts once unarchived.")
        case .entry(let entryID):
            let exists = try context.fetchCount(
                FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.id == entryID })
            ) > 0
            return exists
                ? .openEntry(entryID: entryID)
                : .unavailable(message: "This entry has been removed from the ledger.")
        case .milestone(let milestoneID):
            let exists = try context.fetchCount(
                FetchDescriptor<Milestone>(predicate: #Predicate { $0.id == milestoneID })
            ) > 0
            return exists
                ? .openMilestone(milestoneID: milestoneID)
                : .unavailable(message: "This milestone belongs to an older plan version.")
        }
    }
}
