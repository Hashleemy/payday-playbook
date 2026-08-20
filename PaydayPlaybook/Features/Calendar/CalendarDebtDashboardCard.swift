import SwiftUI
import SwiftData

/// Exact user-facing wording for the Calendar debt dashboard (V4-08).
///
/// The language contract is strict: dollar amounts are "paid toward debts",
/// never "paid off"; "cleared" is reserved for debts whose derived balance
/// reached zero; planned allocation is never presented as account cash; and
/// overspending renders as "$0 remaining · +$X over planned allocation" —
/// never negative money.
enum DebtDashboardCopy {
    static let cardTitle = "Debt progress"
    static let paidThisMonthLabel = "Paid toward debts this month"
    static let clearedThisMonthLabel = "Debts cleared this month"
    static let plannedAllocationLabel = "Planned allocation"
    static let carryInLabel = "Carry-in"
    static let usedLabel = "Used"
    static let remainingLabel = "Remaining"
    /// Honest-cash rule: the allocation is a plan figure, not a bank balance.
    static let plannedAllocationFootnote = "Planned allocation comes from your debt plan — it isn't your account cash."

    static func currentCycleHeader(start: Date, nextPayday: Date) -> String {
        "Current pay cycle · \(DateMath.mediumString(start)) to \(DateMath.mediumString(nextPayday))"
    }

    /// R-28 display rule, verbatim: never negative spendable money.
    static func overageText(_ overage: Decimal) -> String {
        "$0 remaining · +\(MoneyFormat.string(overage)) over planned allocation"
    }

    /// The next allocation labeled with its availability date — an upcoming
    /// amount, never spendable today.
    static func upcomingText(amount: Decimal, availableOn: Date) -> String {
        "\(MoneyFormat.string(amount)) becomes available \(DateMath.mediumString(availableOn))"
    }

    static func nextPaydayLabel(_ date: Date) -> String {
        "Next payday \(DateMath.mediumString(date))"
    }

    /// Shown before the plan's first payday, when no cycle exists yet.
    static func beforeFirstPaydayText(amount: Decimal, availableOn: Date) -> String {
        "No pay cycle has started yet. Your first planned allocation of \(MoneyFormat.string(amount)) becomes available \(DateMath.mediumString(availableOn))."
    }

    static func clearedDebtLine(_ debt: ClearedDebt) -> String {
        "\(debt.name) — cleared \(DateMath.mediumString(debt.clearedOn))"
    }
}

/// Everything the Calendar debt dashboard renders, computed by
/// `DebtAllocationService` only — the card performs no arithmetic of its own
/// (R-29). Load failures leave sections nil; the card renders what it can and
/// never fabricates a number.
struct CalendarDebtDashboardState: Equatable {
    var month: MonthlyDebtProgress?
    var cycle: PayCycleAllocation?
    var upcoming: UpcomingDebtAllocation?

    /// The card renders only when there is a debt story to tell: a live pay
    /// cycle, an upcoming allocation, or actual payment activity this month.
    var showsCard: Bool {
        if cycle != nil || upcoming != nil { return true }
        guard let month else { return false }
        return month.paidTowardDebts != 0 || !month.debtsCleared.isEmpty
    }

    @MainActor
    static func load(context: ModelContext, environment: AppEnvironment) -> CalendarDebtDashboardState {
        var state = CalendarDebtDashboardState()
        let service = environment.debtAllocationService(context: context)
        let now = environment.dateProvider.now
        state.month = try? service.monthlyProgress(month: now)
        state.cycle = try? service.currentCycle(asOf: now)
        if state.cycle == nil {
            state.upcoming = try? service.upcomingAllocation(asOf: now)
        }
        return state
    }
}

/// The V4-08 debt dashboard card at the top of the Calendar tab. Meaning is
/// carried by text — color only reinforces — and every figure comes from
/// `DebtAllocationService` untouched.
struct CalendarDebtDashboardCard: View {
    let state: CalendarDebtDashboardState

    var body: some View {
        DashboardCard(title: DebtDashboardCopy.cardTitle, systemImage: "creditcard.and.123") {
            VStack(alignment: .leading, spacing: 10) {
                if let month = state.month {
                    monthSection(month)
                }
                if let cycle = state.cycle {
                    cycleSection(cycle)
                } else if let upcoming = state.upcoming {
                    Text(DebtDashboardCopy.beforeFirstPaydayText(
                        amount: upcoming.amount, availableOn: upcoming.availableOn
                    ))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Text(DebtDashboardCopy.plannedAllocationFootnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func monthSection(_ month: MonthlyDebtProgress) -> some View {
        moneyRow(DebtDashboardCopy.paidThisMonthLabel, amount: month.paidTowardDebts, emphasized: true)
        if !month.debtsCleared.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(DebtDashboardCopy.clearedThisMonthLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(month.debtsCleared) { debt in
                    Label(DebtDashboardCopy.clearedDebtLine(debt), systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.mint)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func cycleSection(_ cycle: PayCycleAllocation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(DebtDashboardCopy.currentCycleHeader(start: cycle.cycleStart, nextPayday: cycle.nextPayday))
                .font(.caption)
                .foregroundStyle(.secondary)
            moneyRow(DebtDashboardCopy.plannedAllocationLabel, amount: cycle.allocation)
            if cycle.carryIn != 0 {
                moneyRow(DebtDashboardCopy.carryInLabel, amount: cycle.carryIn)
            }
            moneyRow(DebtDashboardCopy.usedLabel, amount: cycle.paidThisCycle)
            if cycle.overage > 0 {
                Text(DebtDashboardCopy.overageText(cycle.overage))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                moneyRow(DebtDashboardCopy.remainingLabel, amount: cycle.remaining, emphasized: true)
            }
            if let nextAllocation = cycle.nextAllocation, let nextDate = cycle.nextAllocationDate {
                VStack(alignment: .leading, spacing: 1) {
                    Text(DebtDashboardCopy.nextPaydayLabel(nextDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(DebtDashboardCopy.upcomingText(amount: nextAllocation, availableOn: nextDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func moneyRow(_ label: String, amount: Decimal, emphasized: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(emphasized ? .subheadline.weight(.medium) : .subheadline)
            Spacer(minLength: 8)
            MoneyText(amount: amount, font: emphasized ? .subheadline.weight(.semibold) : .subheadline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(MoneyFormat.string(amount))")
    }
}
