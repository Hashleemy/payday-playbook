import Foundation
import SwiftData

/// The current pay cycle's debt-allocation story (V4-07, R-28). Every figure
/// is derived — nothing here is persisted, and the arithmetic is deliberately
/// outside the engine's calculation versioning.
///
/// `allocation` is *planned allocation* (the plan track's `plannedCardBudget`
/// for the cycle's opening payday) — never actual account cash. `remaining`
/// and `overage` are both non-negative by construction: overspending a cycle
/// surfaces as overage, never as negative spendable money.
struct PayCycleAllocation: Equatable {
    /// The most recent plan payday on or before the as-of date.
    let cycleStart: Date
    /// The next cycle boundary (exclusive end of this cycle).
    let nextPayday: Date
    /// Planned debt allocation that became available at `cycleStart`.
    let allocation: Decimal
    /// Positive unused remainder carried in from the prior cycle.
    let carryIn: Decimal
    /// `carryIn + allocation`.
    let available: Decimal
    /// Qualifying debt payments recorded in `[cycleStart, nextPayday)`.
    let paidThisCycle: Decimal
    /// `max(0, available − paidThisCycle)`.
    let remaining: Decimal
    /// `max(0, paidThisCycle − available)`.
    let overage: Decimal
    /// The next payday's planned allocation, when the plan still has one.
    let nextAllocation: Decimal?
    /// The date `nextAllocation` becomes available. Never spendable today.
    let nextAllocationDate: Date?
}

/// A debt whose derived balance reached the payoff condition (V4-08, R-29).
/// "Cleared" is reserved for debts; dollar amounts are never "paid off".
struct ClearedDebt: Equatable, Identifiable {
    let id: UUID
    let name: String
    let clearedOn: Date
}

/// Calendar-month debt progress (V4-08, R-29). `paidTowardDebts` is the
/// qualifying-payment sum over the month — dollars paid toward debt, which is
/// a different fact from a pay cycle's remaining allocation and from any
/// debt being paid off.
struct MonthlyDebtProgress: Equatable {
    let monthStart: Date
    let paidTowardDebts: Decimal
    let debtsCleared: [ClearedDebt]
}

/// The next planned allocation that has not become available yet. This is the
/// dashboard's answer before the plan's first payday, when there is no
/// current cycle at all (R-28) — an upcoming allocation, never spendable now.
struct UpcomingDebtAllocation: Equatable {
    let availableOn: Date
    let amount: Decimal
}

/// The canonical derived view of pay-cycle debt allocation (V4-07/V4-08).
protocol DebtAllocationCalculating {
    func currentCycle(asOf: Date) throws -> PayCycleAllocation?
    func monthlyProgress(month: Date) throws -> MonthlyDebtProgress
    func upcomingAllocation(asOf: Date) throws -> UpcomingDebtAllocation?
}

/// Derives pay-cycle debt allocation and monthly debt progress from the
/// stored plan schedule and the ledger — deterministic arithmetic with no
/// persisted state and no engine run (R-28/R-29).
///
/// This is the only implementation of the cycle-boundary rule: the current
/// cycle is `[most recent plan payday ≤ asOf, next plan payday)` over the
/// active plan's `PaydayPlanItem` dates (the calendar's `schedulePlan`
/// source), extended past the last item by the live `IncomeSchedule` cadence.
///
/// Qualifying payments are `.cardPayment` ledger rows by `effectiveDate`,
/// minus debt-linked `.refundReversal`/`.correction` rows. Check-in payments
/// are already `.cardPayment` rows (carrying `paydayCheckInID`), so
/// `PaydayCheckIn`/`CheckInCardPayment` are never also summed — reading both
/// would double-count. Transfers and balance adjustments never count.
struct DebtAllocationService: DebtAllocationCalculating {
    let context: ModelContext
    let dateProvider: DateProviding

    init(context: ModelContext, dateProvider: DateProviding) {
        self.context = context
        self.dateProvider = dateProvider
    }

    // MARK: - Current cycle (R-28)

    func currentCycle(asOf: Date) throws -> PayCycleAllocation? {
        let today = DateMath.startOfDay(asOf)
        guard let schedule = try loadSchedule() else { return nil }
        guard let firstPayday = schedule.paydays.first, firstPayday <= today else {
            // Before the plan's first payday there is no current cycle —
            // callers show the upcoming allocation instead.
            return nil
        }

        // Cycle-opening boundaries: every plan payday, extended past the last
        // item until one boundary lies beyond the as-of day, so the current
        // cycle always has a closing boundary.
        var opens = schedule.paydays
        while let last = opens.last, last <= today {
            opens.append(nextBoundary(after: last, schedule: schedule))
        }
        guard let currentIndex = opens.lastIndex(where: { $0 <= today }) else { return nil }

        // Cycles opened by a plan payday carry that payday's planned card
        // budget; extended boundaries past the plan's end plan no allocation.
        func allocation(at index: Int) -> Decimal {
            index < schedule.items.count ? schedule.items[index].plannedCardBudget : .zero
        }

        let payments = try qualifyingPayments()
        var usedByCycle = [Decimal](repeating: .zero, count: currentIndex + 1)
        for payment in payments {
            guard payment.day >= opens[0], payment.day < opens[currentIndex + 1] else { continue }
            if let index = opens.lastIndex(where: { $0 <= payment.day }), index <= currentIndex {
                usedByCycle[index] += payment.amount
            }
        }

        // The carry-in fold, anchored at the plan's first payday:
        // carryIn(first) = 0; available(N) = carryIn(N) + allocation(N);
        // carryIn(N+1) = max(0, available(N) − used(N)). Overspending never
        // borrows from the future — the excess surfaces as overage.
        var carryIn = Decimal.zero
        var available = Decimal.zero
        var used = Decimal.zero
        for index in 0...currentIndex {
            available = carryIn + allocation(at: index)
            used = usedByCycle[index]
            if index < currentIndex {
                carryIn = max(.zero, available - used)
            }
        }

        let nextIndex = currentIndex + 1
        let hasNextPlannedPayday = nextIndex < schedule.items.count

        return PayCycleAllocation(
            cycleStart: opens[currentIndex],
            nextPayday: opens[nextIndex],
            allocation: allocation(at: currentIndex).rounded2,
            carryIn: carryIn.rounded2,
            available: available.rounded2,
            paidThisCycle: used.rounded2,
            remaining: max(.zero, available - used).rounded2,
            overage: max(.zero, used - available).rounded2,
            nextAllocation: hasNextPlannedPayday ? schedule.items[nextIndex].plannedCardBudget.rounded2 : nil,
            nextAllocationDate: hasNextPlannedPayday ? opens[nextIndex] : nil
        )
    }

    // MARK: - Upcoming allocation

    func upcomingAllocation(asOf: Date) throws -> UpcomingDebtAllocation? {
        let today = DateMath.startOfDay(asOf)
        guard let schedule = try loadSchedule() else { return nil }
        guard let nextIndex = schedule.paydays.firstIndex(where: { $0 > today }) else { return nil }
        return UpcomingDebtAllocation(
            availableOn: schedule.paydays[nextIndex],
            amount: schedule.items[nextIndex].plannedCardBudget.rounded2
        )
    }

    // MARK: - Monthly progress (R-29)

    func monthlyProgress(month: Date) throws -> MonthlyDebtProgress {
        guard let interval = DateMath.calendar.dateInterval(of: .month, for: month) else {
            // Unreachable for any valid date; report an empty month rather
            // than inventing figures.
            return MonthlyDebtProgress(monthStart: DateMath.startOfDay(month), paidTowardDebts: .zero, debtsCleared: [])
        }
        let monthStart = DateMath.startOfDay(interval.start)
        let monthEnd = DateMath.startOfDay(interval.end)

        let paid = try qualifyingPayments()
            .filter { $0.day >= monthStart && $0.day < monthEnd }
            .reduce(Decimal.zero) { $0 + $1.amount }

        return MonthlyDebtProgress(
            monthStart: monthStart,
            paidTowardDebts: paid.rounded2,
            debtsCleared: try clearedDebts(from: monthStart, before: monthEnd)
        )
    }

    // MARK: - Qualifying payments (R-28)

    /// The signed contribution of one ledger row to "paid toward debts":
    /// `.cardPayment` rows count in full; debt-linked `.refundReversal` and
    /// `.correction` rows count negatively (their positive amounts restore
    /// debt balance, undoing a payment); everything else — transfers, balance
    /// adjustments, spending, reserves — never counts.
    static func qualifyingAmount(of entry: LedgerEntry) -> Decimal? {
        switch entry.type {
        case .cardPayment:
            return entry.amount
        case .refundReversal, .correction:
            guard entry.debtAccountID != nil else { return nil }
            return -entry.amount
        default:
            return nil
        }
    }

    private func qualifyingPayments() throws -> [(day: Date, amount: Decimal)] {
        try context.fetch(FetchDescriptor<LedgerEntry>()).compactMap { entry in
            Self.qualifyingAmount(of: entry).map { (DateMath.startOfDay(entry.effectiveDate), $0) }
        }
    }

    // MARK: - Cleared debts (R-29)

    private func clearedDebts(from monthStart: Date, before monthEnd: Date) throws -> [ClearedDebt] {
        let balances = try AccountBalanceService(context: context, dateProvider: dateProvider).debtBalances()
        guard balances.contains(where: \.isPaidOff) else { return [] }

        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
        let entries = try context.fetch(FetchDescriptor<LedgerEntry>())
        let today = DateMath.startOfDay(dateProvider.now)

        return balances
            .filter(\.isPaidOff)
            .compactMap { item -> ClearedDebt? in
                guard let clearedOn = Self.zeroReachingDate(
                    debt: item.debt, snapshots: snapshots, entries: entries, today: today
                ) else { return nil }
                guard clearedOn >= monthStart, clearedOn < monthEnd else { return nil }
                return ClearedDebt(id: item.debt.id, name: item.debt.displayName, clearedOn: clearedOn)
            }
            .sorted { $0.clearedOn < $1.clearedOn }
    }

    /// The earliest dated event — authoritative snapshot or debt-linked
    /// ledger row — after which the debt's derived balance reaches zero and
    /// stays there. Event selection mirrors
    /// `AccountBalanceService.debtBalances()` exactly, so the attribution can
    /// never disagree with the balance it explains. A debt that was never
    /// positive (no dated event brought it to zero) has no cleared date.
    static func zeroReachingDate(
        debt: DebtAccount,
        snapshots: [BalanceSnapshot],
        entries: [LedgerEntry],
        today: Date
    ) -> Date? {
        let debtID = debt.id
        let authoritative = snapshots
            .filter { snapshot in
                snapshot.debtAccountID == debtID
                    && snapshot.isAuthoritative
                    && DateMath.startOfDay(snapshot.effectiveDate) <= today
            }
            .max { lhs, rhs in
                if lhs.effectiveDate != rhs.effectiveDate { return lhs.effectiveDate < rhs.effectiveDate }
                return lhs.createdAt < rhs.createdAt
            }
        let baseDate = authoritative.map { DateMath.startOfDay($0.effectiveDate) }

        var balance = authoritative?.amount ?? debt.startingBalance
        var candidate: Date? = (balance.rounded2 <= 0) ? baseDate : nil

        let relevant = entries
            .filter { entry in
                guard entry.debtAccountID == debtID else { return false }
                switch entry.type {
                case .cardPayment, .refundReversal, .correction: break
                default: return false
                }
                let day = DateMath.startOfDay(entry.effectiveDate)
                guard day <= today else { return false }
                if let authoritative, let baseDate {
                    if day < baseDate { return false }
                    if day == baseDate && entry.createdAt <= authoritative.createdAt { return false }
                }
                return true
            }
            .sorted { lhs, rhs in
                let lhsDay = DateMath.startOfDay(lhs.effectiveDate)
                let rhsDay = DateMath.startOfDay(rhs.effectiveDate)
                if lhsDay != rhsDay { return lhsDay < rhsDay }
                return lhs.createdAt < rhs.createdAt
            }

        for entry in relevant {
            switch entry.type {
            case .cardPayment: balance -= entry.amount
            case .refundReversal, .correction: balance += entry.amount
            default: continue
            }
            if balance.rounded2 <= 0 {
                if candidate == nil { candidate = DateMath.startOfDay(entry.effectiveDate) }
            } else {
                candidate = nil
            }
        }
        return candidate
    }

    // MARK: - Schedule resolution

    private struct AllocationSchedule {
        let plan: PlanVersion
        /// Sequence-ordered plan items; `paydays[i]` opens the cycle whose
        /// allocation is `items[i].plannedCardBudget`.
        let items: [PaydayPlanItem]
        let paydays: [Date]
        /// Cadence for extending boundaries past the last plan item; nil
        /// falls back to the plan's fixed day interval.
        let extensionCadence: PlanningPayCadence?
        let fallbackIntervalDays: Int
    }

    private func loadSchedule() throws -> AllocationSchedule? {
        guard let plan = try CalendarEventService.schedulePlan(context: context) else { return nil }
        let items = try PlanRepository.planItems(context: context, plan: plan)
        guard !items.isEmpty else { return nil }
        return AllocationSchedule(
            plan: plan,
            items: items,
            paydays: items.map { DateMath.startOfDay($0.date) },
            extensionCadence: extensionCadence(for: plan),
            fallbackIntervalDays: max(plan.payFrequencyDays, 1)
        )
    }

    /// The cadence that extends the boundary rule past the plan's last item:
    /// the live `IncomeSchedule` when one exists (R-28), else the plan row's
    /// own cadence columns. Both convert through the one canonical cadence
    /// conversion so a second copy cannot disagree.
    private func extensionCadence(for plan: PlanVersion) -> PlanningPayCadence? {
        let live = try? context.fetch(
            FetchDescriptor<IncomeSchedule>(predicate: #Predicate { !$0.isArchived })
        ).first
        if let live,
           let cadence = try? PlanGenerationService.planningCadence(
               cadence: live.cadence,
               monthlyPayDay: live.monthlyDay,
               semimonthlyPayDay1: live.semimonthlyFirstDay,
               semimonthlyPayDay2: live.semimonthlySecondDay
           ) {
            return cadence
        }
        return try? PlanGenerationService.planningCadence(
            cadence: plan.payCadence,
            monthlyPayDay: plan.monthlyPayDay,
            semimonthlyPayDay1: plan.semimonthlyPayDay1,
            semimonthlyPayDay2: plan.semimonthlyPayDay2
        )
    }

    /// The first cadence occurrence strictly after `day` (the
    /// `ReforecastService` continue-the-cadence precedent, generalized to all
    /// four cadences via `PayScheduleGenerator`'s R-11 clamping).
    private func nextBoundary(after day: Date, schedule: AllocationSchedule) -> Date {
        if let cadence = schedule.extensionCadence {
            switch cadence {
            case .weekly:
                return DateMath.addingDays(7, to: day)
            case .biweekly:
                return DateMath.addingDays(14, to: day)
            case .monthly, .semimonthly:
                if let next = PayScheduleGenerator.paydays(
                    cadence: cadence, anchor: DateMath.addingDays(1, to: day), count: 1
                ).first {
                    return next
                }
            }
        }
        return DateMath.addingDays(schedule.fallbackIntervalDays, to: day)
    }
}

// MARK: - Content fingerprint (R-29)

/// Order-independent fingerprint of ledger content (row IDs + `updatedAt`)
/// and the active plan identity. The Calendar dashboard observes this instead
/// of row counts, so an amount edit that keeps counts equal still refreshes,
/// and activating a different plan re-derives the re-anchored fold.
enum DebtAllocationFingerprint {
    static func fingerprint(entries: [(id: UUID, updatedAt: Date)], activePlanIDs: [UUID]) -> Int {
        var combined = 0
        for entry in entries {
            var hasher = Hasher()
            hasher.combine(entry.id)
            hasher.combine(entry.updatedAt)
            combined = combined &+ hasher.finalize()
        }
        for planID in activePlanIDs {
            var hasher = Hasher()
            hasher.combine("active-plan")
            hasher.combine(planID)
            combined = combined &+ hasher.finalize()
        }
        return combined
    }
}
