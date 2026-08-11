import Foundation
import SwiftData

/// Merges paydays, card due dates, milestones, snapshots, and ledger entries
/// into display events for the calendar dashboard.
struct CalendarEventService {

    enum EventKind: String, CaseIterable, Identifiable {
        case paydayFuture
        case paydayCompleted
        case paydayDue
        case cardDue
        case milestone
        case entry

        var id: String { rawValue }

        var label: String {
            switch self {
            case .paydayFuture: return "Payday"
            case .paydayCompleted: return "Payday complete"
            case .paydayDue: return "Payday due"
            case .cardDue: return "Card due"
            case .milestone: return "Milestone"
            case .entry: return "Entry"
            }
        }

        var symbolName: String {
            switch self {
            case .paydayFuture: return "circle.fill"
            case .paydayCompleted: return "checkmark.circle.fill"
            case .paydayDue: return "exclamationmark.circle"
            case .cardDue: return "creditcard"
            case .milestone: return "star.fill"
            case .entry: return "circlebadge.fill"
            }
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all
        case paydays
        case cardDueDates
        case milestones
        case actualEntries

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .paydays: return "Paydays"
            case .cardDueDates: return "Card due dates"
            case .milestones: return "Milestones"
            case .actualEntries: return "Actual entries"
            }
        }

        func includes(_ kind: EventKind) -> Bool {
            switch self {
            case .all: return true
            case .paydays: return [.paydayFuture, .paydayCompleted, .paydayDue].contains(kind)
            case .cardDueDates: return kind == .cardDue
            case .milestones: return kind == .milestone
            case .actualEntries: return kind == .entry
            }
        }
    }

    struct Event: Identifiable {
        let id: String
        let date: Date
        let kind: EventKind
        let title: String
        let detail: String?
        /// Plan item ID, debt plan letter, milestone ID, or ledger entry ID.
        let reference: String?
    }

    let context: ModelContext
    let dateProvider: DateProviding

    init(context: ModelContext, dateProvider: DateProviding) {
        self.context = context
        self.dateProvider = dateProvider
    }

    func events(from start: Date, to end: Date) throws -> [Event] {
        var events: [Event] = []
        let today = DateMath.startOfDay(dateProvider.now)
        let startDay = DateMath.startOfDay(start)
        let endDay = DateMath.startOfDay(end)

        guard let plan = try PlanSeeder.currentPlan(context: context) else { return [] }
        let planID = plan.id
        let planItems = try context.fetch(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
        )
        let checkIns = try context.fetch(FetchDescriptor<PaydayCheckIn>())
        let checkInsByItem = Dictionary(grouping: checkIns, by: \.paydayPlanItemID)

        for item in planItems {
            let day = DateMath.startOfDay(item.date)
            guard day >= startDay, day <= endDay else { continue }
            let checkIn = checkInsByItem[item.id]?.first
            let kind: EventKind
            if let checkIn, checkIn.status == .completed || checkIn.status == .needsAttention {
                kind = .paydayCompleted
            } else if day <= today {
                kind = .paydayDue
            } else {
                kind = .paydayFuture
            }
            events.append(Event(
                id: "payday-\(item.sequenceNumber)",
                date: day,
                kind: kind,
                title: "Payday #\(item.sequenceNumber)",
                detail: "Keep \(MoneyFormat.string(item.plannedC1Keep)) · Move \(MoneyFormat.string(item.plannedC2Transfer)) · Cards \(MoneyFormat.string(item.plannedCardBudget)) → \(item.plannedTargetDebtID)",
                reference: item.id.uuidString
            ))
        }

        let debts = try context.fetch(FetchDescriptor<DebtAccount>())
        let calendar = DateMath.calendar
        for debt in debts where !debt.isArchived {
            guard let dueDay = debt.dueDayOfMonth else { continue }
            var cursor = startDay
            while cursor <= endDay {
                var components = calendar.dateComponents([.year, .month], from: cursor)
                components.day = min(dueDay, 28)
                if let dueDate = calendar.date(from: components) {
                    let day = DateMath.startOfDay(dueDate)
                    if day >= startDay && day <= endDay {
                        events.append(Event(
                            id: "due-\(debt.planID)-\(Int(day.timeIntervalSince1970))",
                            date: day,
                            kind: .cardDue,
                            title: "\(debt.displayName) due",
                            detail: "Statement due day \(dueDay)",
                            reference: debt.planID
                        ))
                    }
                }
                guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
                cursor = next
            }
        }

        let milestones = try context.fetch(FetchDescriptor<Milestone>())
        for milestone in milestones {
            let displayDate = milestone.achievedDate ?? milestone.forecastDate ?? milestone.baselineDate
            guard let displayDate else { continue }
            let day = DateMath.startOfDay(displayDate)
            guard day >= startDay, day <= endDay else { continue }
            let state = milestone.achievedDate != nil ? "Achieved" : "Projected"
            events.append(Event(
                id: "milestone-\(milestone.id.uuidString)",
                date: day,
                kind: .milestone,
                title: milestone.title,
                detail: state,
                reference: milestone.id.uuidString
            ))
        }

        let entries = try context.fetch(FetchDescriptor<LedgerEntry>())
        for entry in entries {
            let day = DateMath.startOfDay(entry.effectiveDate)
            guard day >= startDay, day <= endDay else { continue }
            events.append(Event(
                id: "entry-\(entry.id.uuidString)",
                date: day,
                kind: .entry,
                title: entry.type.displayName,
                detail: MoneyFormat.string(entry.amount),
                reference: entry.id.uuidString
            ))
        }

        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
        for snapshot in snapshots where snapshot.debtAccountID != nil {
            let day = DateMath.startOfDay(snapshot.effectiveDate)
            guard day >= startDay, day <= endDay else { continue }
            events.append(Event(
                id: "snapshot-\(snapshot.id.uuidString)",
                date: day,
                kind: .entry,
                title: "Balance update\(snapshot.debtPlanID.map { " · Card \($0)" } ?? "")",
                detail: MoneyFormat.string(snapshot.amount),
                reference: snapshot.debtPlanID
            ))
        }

        return events.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.id < rhs.id
        }
    }
}
