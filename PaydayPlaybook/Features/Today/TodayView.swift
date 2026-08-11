import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Query private var checkIns: [PaydayCheckIn]
    @Query private var ledgerEntries: [LedgerEntry]
    @Query private var snapshots: [BalanceSnapshot]
    @Query private var allSettings: [AppSettings]
    @Query private var planVersions: [PlanVersion]
    @Query private var debts: [DebtAccount]
    @Query private var obligations: [RecurringObligation]
    @Query private var incomeSchedules: [IncomeSchedule]

    @State private var state = TodayState()
    @State private var checkInItem: PaydayPlanItem?
    @State private var showAddSheet = false
    @State private var showDebtFreeFlow = false

    var body: some View {
        NavigationStack {
            scrollContent
                .background(Color(.systemGroupedBackground))
                .navigationTitle(todayTitle)
                .toolbar { toolbarContent }
                .onAppear(perform: handleAppear)
                .onChange(of: refreshToken) { _, _ in reload() }
                .onChange(of: router.pendingCheckInItemID) { _, itemID in
                    openPendingCheckIn(itemID)
                }
                .sheet(item: $checkInItem, onDismiss: reload) { item in
                    CheckInFlowView(planItem: item)
                }
                .sheet(isPresented: $showAddSheet, onDismiss: reload) {
                    QuickAddSheet()
                }
                .sheet(isPresented: $showDebtFreeFlow, onDismiss: reload) {
                    DebtFreeTransitionView()
                }
        }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 14) {
                if state.hasPlan {
                    planSections
                    accountSections
                    closingSections
                } else {
                    noPlanCard
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .accessibilityLabel("Add entry")
        }
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
    }

    /// Every stored change that can move a dashboard number: actuals,
    /// balances, plan activation, and the setup rows the plan is built from.
    private var refreshToken: String {
        let activeID = planVersions.first(where: \.isActive)?.id.uuidString ?? "none"
        return [
            "\(checkIns.count)", "\(ledgerEntries.count)", "\(snapshots.count)",
            "\(planVersions.count)", "\(debts.count)", "\(obligations.count)",
            "\(incomeSchedules.count)", activeID
        ].joined(separator: "|")
    }

    private func handleAppear() {
        reload()
        if let pending = router.pendingCheckInItemID {
            router.pendingCheckInItemID = nil
            checkInItem = state.planItems.first { $0.id == pending }
        }
    }

    private func openPendingCheckIn(_ itemID: UUID?) {
        guard let itemID else { return }
        router.pendingCheckInItemID = nil
        if let item = state.planItems.first(where: { $0.id == itemID }) {
            checkInItem = item
        }
    }

    private var todayTitle: String {
        DateMath.mediumString(appEnvironment.dateProvider.now)
    }

    private func reload() {
        state = TodayState.load(context: modelContext, environment: appEnvironment)
    }

    /// "Card B" for cards, the type name otherwise — resolved from the plan's
    /// stable debt identifier.
    private func debtReference(_ planID: String) -> String {
        guard let debt = state.debtBalances.first(where: { $0.debt.planID == planID })?.debt else {
            return planID
        }
        return debt.debtType.shortReference(planID: planID)
    }

    // MARK: - Section groups

    @ViewBuilder
    private var planSections: some View {
        statusHeader
        if let warning = state.calculationWarning {
            calculationWarningCard(warning)
        }
        todaysPlayCard
        if let target = state.targetDebt {
            targetCard(target)
        }
        planForecastCard
    }

    @ViewBuilder
    private var accountSections: some View {
        if let c1 = state.checking1, let plan = state.plan {
            Checking1Card(state: c1, plan: plan, title: spendingCardTitle)
        }
        if let c2 = state.checking2 {
            Checking2Card(state: c2, title: reservesCardTitle, reserveLines: state.reserveLines)
        }
        otherAccountsCard
    }

    @ViewBuilder
    private var closingSections: some View {
        upcomingStrip
        insightCard
        if state.isDebtFree {
            if let settings = allSettings.first, settings.debtFreeConfirmedAt != nil {
                PhaseTwoCard(settings: settings, releasedPerPaycheck: releasedPerPaycheck)
                phaseTwoEditButton
            } else {
                debtFreeCard
            }
        }
    }

    // MARK: - Recovery / warning states

    private var noPlanCard: some View {
        DashboardCard(title: "No plan yet", systemImage: "map") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your plan isn't set up on this device. Nothing has been lost — your entries stay exactly as recorded.")
                    .font(.subheadline)
                Text("Restore a backup from Settings → Backup & export, or load a plan from Settings → Plan versions.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                NavigationLink {
                    SettingsView()
                } label: {
                    Text("Open Settings")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func calculationWarningCard(_ message: String) -> some View {
        DashboardCard(title: "Worth a look", systemImage: "exclamationmark.triangle") {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sections

    private var statusHeader: some View {
        DashboardCard(title: "Where you stand", systemImage: "flag.checkered") {
            VStack(alignment: .leading, spacing: 8) {
                StatusBadge(kind: state.statusKind)
                HStack(alignment: .firstTextBaseline) {
                    MoneyText(amount: state.totalDebt, font: .system(size: 34, weight: .bold))
                    Text("remaining")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if state.startingPrincipal > 0 {
                    Text("\(state.percentEliminated.asDouble, specifier: "%.1f")% of the original \(MoneyFormat.string(state.startingPrincipal)) eliminated")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let goal = state.goalText, !goal.isEmpty {
                    Text(goal)
                        .font(.subheadline)
                        .italic()
                        .foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Original payoff").font(.caption).foregroundStyle(.secondary)
                        Text(state.plan.map { DateMath.mediumString($0.baselinePayoffDate) } ?? "—")
                            .font(.subheadline.weight(.medium))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Current forecast").font(.caption).foregroundStyle(.secondary)
                        Text(forecastDateText).font(.subheadline.weight(.medium))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var forecastDateText: String {
        if let date = state.forecastPayoffDate {
            return DateMath.mediumString(date)
        }
        if state.hasPlan && (state.forecast != nil || state.calculationWarning != nil) {
            // The engine reported the current budget cannot retire the debt.
            return "Beyond current budget"
        }
        return state.plan.map { DateMath.mediumString($0.baselinePayoffDate) } ?? "—"
    }

    private var todaysPlayCard: some View {
        DashboardCard(title: "Today's play", systemImage: "figure.run") {
            VStack(alignment: .leading, spacing: 10) {
                if let current = state.currentItem, isToday(current.date) || isOpen(current) {
                    PaydayPlaySummary(
                        item: current,
                        reserveTotal: reserveTotal(for: current),
                        targetReference: debtReference(current.plannedTargetDebtID)
                    )
                    checkInButton(for: current)
                } else if let next = state.nextItem {
                    let days = DateMath.days(from: appEnvironment.dateProvider.now, to: next.date)
                    Text("Next payday: \(DateMath.mediumString(next.date)) — \(days) day\(days == 1 ? "" : "s") away")
                        .font(.subheadline)
                    if state.targetDebt != nil {
                        Text("Next target: \(debtReference(next.plannedTargetDebtID)). Next planned payment \(MoneyFormat.string(next.plannedCardBudget)).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let current = state.currentItem {
                        reviewButton(for: current)
                    }
                } else if state.isDebtFree {
                    Text("All planned paydays are complete. You made it.")
                        .font(.subheadline)
                } else {
                    Text("The planned schedule has ended. Keep recording payments from the Debts tab.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reserveTotal(for item: PaydayPlanItem) -> Decimal {
        let legacy = item.plannedCarReserve + item.plannedTrainReserve
        if legacy > 0 { return legacy }
        return state.reserveLines.reduce(Decimal.zero) { $0 + $1.amount }
    }

    private func isToday(_ date: Date) -> Bool {
        DateMath.isSameDay(date, appEnvironment.dateProvider.now)
    }

    private func isOpen(_ item: PaydayPlanItem) -> Bool {
        let status = state.currentCheckIn?.status
        return status != .completed && status != .needsAttention
            && DateMath.startOfDay(item.date) <= DateMath.startOfDay(appEnvironment.dateProvider.now)
    }

    @ViewBuilder
    private func checkInButton(for item: PaydayPlanItem) -> some View {
        let status = state.currentCheckIn?.status
        Button {
            checkInItem = item
        } label: {
            Text(buttonTitle(for: status))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("today.checkInButton")
    }

    private func buttonTitle(for status: CheckInStatus?) -> String {
        switch status {
        case .completed, .needsAttention: return "Review Completed Check"
        case .draft: return "Continue Check-In"
        case nil: return "Start Check-In"
        }
    }

    @ViewBuilder
    private func reviewButton(for item: PaydayPlanItem) -> some View {
        Button {
            checkInItem = item
        } label: {
            Text("Review Completed Check")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    private func targetCard(_ target: AccountBalanceService.DebtBalance) -> some View {
        DashboardCard(title: "Current target", systemImage: "target") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.debt.displayName)
                            .font(.title3.weight(.semibold))
                        Text("\(target.debt.debtType.shortReference(planID: target.debt.planID)) · \(DebtFormat.aprText(target.debt.apr)) APR")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        MoneyText(amount: target.balance, font: .title3.weight(.bold))
                        if let utilization = target.debt.utilization(currentBalance: target.balance) {
                            UtilizationBadge(utilization: utilization)
                        }
                    }
                }
                if let reason = state.targetReason {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let next = nextPlannedItemForDisplay {
                    Text("Planned attack this check: \(MoneyFormat.string(next.plannedCardBudget)) toward \(debtReference(next.plannedTargetDebtID))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let dueDay = target.debt.dueDayOfMonth {
                    Text("\(target.debt.debtType.dueDayLabel): \(dueDay)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                NavigationLink {
                    AddPaymentView(preselectedPlanID: target.debt.planID)
                } label: {
                    Text("Add Payment")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var nextPlannedItemForDisplay: PaydayPlanItem? {
        if let current = state.currentItem, isOpen(current) { return current }
        return state.nextItem
    }

    /// Payoff forecast, paychecks remaining, remaining interest, and the
    /// interest-saved estimate when the engine supports it (V2-14).
    private var planForecastCard: some View {
        DashboardCard(title: "The finish line", systemImage: "flag.filled.and.flag.crossed") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Forecast payoff")
                    Spacer()
                    Text(forecastDateText)
                        .font(.subheadline.weight(.semibold))
                }
                if let paychecks = state.paychecksRemaining {
                    HStack {
                        Text("Paychecks remaining")
                        Spacer()
                        Text("\(paychecks)")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                }
                if let interest = state.estimatedRemainingInterest {
                    HStack {
                        Text("Estimated interest ahead")
                        Spacer()
                        MoneyText(amount: interest, font: .subheadline.weight(.semibold))
                    }
                }
                if let saved = state.interestSaved, saved > 0 {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Estimated interest saved vs. minimums only")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        MoneyText(amount: saved, font: .subheadline.weight(.semibold), color: .mint)
                    }
                }
                Text("Projections are estimates, not guarantees.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let plan = state.plan {
                    NavigationLink {
                        PlanOverviewView(plan: plan)
                    } label: {
                        Text("View Full Plan")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("today.viewPlanButton")
                }
            }
            .font(.subheadline)
        }
    }

    private var spendingCardTitle: String {
        if let name = state.spendingAccount?.account.name, !name.isEmpty {
            return "\(name) — flex cash"
        }
        return "Checking 1 — flex cash"
    }

    private var reservesCardTitle: String {
        if let name = state.reservesAccount?.account.name, !name.isEmpty {
            return "\(name) — bills + debt"
        }
        return "Checking 2 — bills + debt"
    }

    @ViewBuilder
    private var otherAccountsCard: some View {
        if !state.otherAccounts.isEmpty {
            DashboardCard(title: "Other accounts", systemImage: "building.columns") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.otherAccounts, id: \.account.id) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.account.name)
                                Text(roleText(item.account))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            MoneyText(amount: item.balance)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(item.account.name), \(roleText(item.account)), balance \(MoneyFormat.string(item.balance))")
                    }
                }
                .font(.subheadline)
            }
        }
    }

    private func roleText(_ account: CashAccount) -> String {
        var parts = account.roles.map(\.displayName).sorted()
        if account.isDefaultIncome { parts.append("Default income") }
        return parts.joined(separator: " · ")
    }

    private var upcomingStrip: some View {
        DashboardCard(title: "Upcoming", systemImage: "calendar.badge.clock") {
            VStack(alignment: .leading, spacing: 6) {
                if let next = state.nextItem {
                    Label("Next payday \(DateMath.mediumString(next.date))", systemImage: "banknote")
                        .font(.subheadline)
                }
                if let nextDue = nextDueText {
                    Label(nextDue, systemImage: "creditcard")
                        .font(.subheadline)
                }
                if let payoff = nextProjectedPayoffText {
                    Label(payoff, systemImage: "star")
                        .font(.subheadline)
                }
            }
        }
    }

    /// Earliest upcoming due item across every debt type and obligation.
    private var nextDueText: String? {
        let today = DateMath.startOfDay(appEnvironment.dateProvider.now)
        let calendar = DateMath.calendar

        func nextOccurrence(day: Int) -> Date? {
            for offset in 0...1 {
                guard let monthDate = calendar.date(byAdding: .month, value: offset, to: today) else { continue }
                var components = calendar.dateComponents([.year, .month], from: monthDate)
                let range = calendar.range(of: .day, in: .month, for: monthDate)
                components.day = min(day, range?.count ?? 28)
                guard let due = calendar.date(from: components), DateMath.startOfDay(due) >= today else { continue }
                return due
            }
            return nil
        }

        var best: (Date, String)?
        for balance in state.debtBalances {
            guard !balance.isPaidOff, let dueDay = balance.debt.dueDayOfMonth,
                  let due = nextOccurrence(day: dueDay) else { continue }
            if best == nil || due < best!.0 {
                best = (due, balance.debt.displayName)
            }
        }
        for line in obligationDueLines {
            if best == nil || line.0 < best!.0 {
                best = line
            }
        }
        return best.map { "\($0.1) due \(DateMath.mediumString($0.0))" }
    }

    private var obligationDueLines: [(Date, String)] {
        let today = DateMath.startOfDay(appEnvironment.dateProvider.now)
        let calendar = DateMath.calendar
        return obligations.compactMap { obligation in
            guard !obligation.isArchived, let dueDay = obligation.dueDay else { return nil }
            for offset in 0...1 {
                guard let monthDate = calendar.date(byAdding: .month, value: offset, to: today) else { continue }
                var components = calendar.dateComponents([.year, .month], from: monthDate)
                let range = calendar.range(of: .day, in: .month, for: monthDate)
                components.day = min(dueDay, range?.count ?? 28)
                if let due = calendar.date(from: components), DateMath.startOfDay(due) >= today {
                    return (due, obligation.name)
                }
            }
            return nil
        }
    }

    private var nextProjectedPayoffText: String? {
        guard let forecast = state.forecast else { return nil }
        let today = DateMath.startOfDay(appEnvironment.dateProvider.now)
        let upcoming = forecast.perCardPayoffDates
            .filter { DateMath.startOfDay($0.payoffDate) >= today }
            .min { $0.payoffDate < $1.payoffDate }
        return upcoming.map { "\(debtReference($0.debtPlanID)) projected payoff \(DateMath.mediumString($0.payoffDate))" }
    }

    private var insightCard: some View {
        DashboardCard(title: "Insight", systemImage: "sparkles") {
            Text(state.insightLine ?? "On track. Nothing needs your attention today.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var releasedPerPaycheck: Decimal {
        guard let plan = state.plan else { return PlanContract.raisedCardBudget }
        let income = (try? ReforecastService.currentIncome(
            context: modelContext,
            on: appEnvironment.dateProvider.now
        )) ?? PlanContract.raisedIncome
        return (income - plan.allowanceCap - plan.totalFixedReservePerCheck).rounded2
    }

    private var phaseTwoEditButton: some View {
        Button {
            showDebtFreeFlow = true
        } label: {
            Text("Adjust Phase II Goal")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    private var debtFreeCard: some View {
        DashboardCard(title: "Debt-free", systemImage: "party.popper") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Every debt reads $0.00. Confirm to celebrate and set up Phase II.")
                    .font(.subheadline)
                Button {
                    showDebtFreeFlow = true
                } label: {
                    Text("Confirm Debt-Free")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct PaydayPlaySummary: View {
    let item: PaydayPlanItem
    let reserveTotal: Decimal
    let targetReference: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Payday #\(item.sequenceNumber) — \(DateMath.mediumString(item.date))")
                .font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Label("Keep", systemImage: "1.circle.fill")
                    MoneyText(amount: item.plannedC1Keep, font: .subheadline.weight(.medium))
                }
                GridRow {
                    Label("Move", systemImage: "2.circle.fill")
                    MoneyText(amount: item.plannedC2Transfer, font: .subheadline.weight(.medium))
                }
                GridRow {
                    Label("Reserve", systemImage: "3.circle.fill")
                    MoneyText(amount: reserveTotal, font: .subheadline.weight(.medium))
                }
                GridRow {
                    Label("Pay → \(item.plannedTargetDebtID)", systemImage: "4.circle.fill")
                    MoneyText(amount: item.plannedCardBudget, font: .subheadline.weight(.medium))
                }
            }
            .font(.subheadline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Payday \(item.sequenceNumber): keep \(MoneyFormat.string(item.plannedC1Keep)), move \(MoneyFormat.string(item.plannedC2Transfer)), reserve \(MoneyFormat.string(reserveTotal)), pay \(MoneyFormat.string(item.plannedCardBudget)) toward \(targetReference)")
    }
}

struct Checking1Card: View {
    let state: AccountBalanceService.Checking1State
    let plan: PlanVersion
    var title: String = "Checking 1 — flex cash"

    var body: some View {
        DashboardCard(title: title, systemImage: "1.circle") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Actual balance")
                    Spacer()
                    MoneyText(amount: state.actualBalance, font: .body.weight(.semibold))
                }
                if let asOf = state.asOfDate {
                    Text("Based on your confirmation on \(DateMath.mediumString(asOf)) plus entries since.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if state.isBelowFloor {
                    Label("Below the protected floor", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Label("Protected cash intact", systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.mint)
                }
                Divider()
                HStack {
                    Text("Protected floor")
                    Spacer()
                    MoneyText(amount: state.protectedFloor)
                }
                HStack {
                    Text("Available — not spent")
                    Spacer()
                    if state.allowanceActive {
                        MoneyText(amount: state.allowanceAvailable, color: .orange)
                    } else {
                        Text("Starts \(DateMath.mediumString(plan.firstPayday))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if state.allowanceActive && state.allowanceSpentThisPeriod > 0 {
                    Text("\(MoneyFormat.string(state.allowanceSpentThisPeriod)) recorded as spent this period")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Maximum if no allowance had been spent")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    MoneyText(amount: state.noSpendCeiling, color: .blue)
                }
                Text("The ceiling is a tracking reference, never your actual cash.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
    }
}

struct Checking2Card: View {
    let state: AccountBalanceService.Checking2State
    var title: String = "Checking 2 — bills + debt"
    var reserveLines: [(id: UUID, name: String, amount: Decimal)] = []

    /// Legacy car/train buckets only exist on migrated stores; generated
    /// plans carry named obligation reserves instead.
    private var hasLegacyBuckets: Bool {
        state.carReserved != 0 || state.trainReserved != 0
    }

    var body: some View {
        DashboardCard(title: title, systemImage: "2.circle") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Balance")
                    Spacer()
                    MoneyText(amount: state.totalBalance, font: .body.weight(.semibold))
                }
                Divider()
                if hasLegacyBuckets {
                    HStack {
                        Text("Reserved for car")
                        Spacer()
                        MoneyText(amount: state.carReserved)
                    }
                    HStack {
                        Text("Reserved for train")
                        Spacer()
                        MoneyText(amount: state.trainReserved)
                    }
                } else {
                    ForEach(reserveLines, id: \.id) { line in
                        HStack {
                            Text("Reserve for \(line.name) each paycheck")
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            MoneyText(amount: line.amount)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Reserve \(MoneyFormat.string(line.amount)) for \(line.name) each paycheck")
                    }
                }
                HStack {
                    Text("Available for debts")
                    Spacer()
                    MoneyText(amount: state.availableForDebt, color: state.availableForDebt.isNegative ? .red : .primary)
                }
                if state.hasNegativeBucket {
                    Label("A bucket is overallocated — more is earmarked or spent than the account holds.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .font(.subheadline)
        }
    }
}
