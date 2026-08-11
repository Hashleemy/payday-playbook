import SwiftUI
import SwiftData

/// Assembled state for the five-second dashboard.
struct TodayState {
    var plan: PlanVersion?
    var planItems: [PaydayPlanItem] = []
    var currentItem: PaydayPlanItem?      // payday on/before today without completion, or today's payday
    var nextItem: PaydayPlanItem?         // next payday strictly after today
    var currentCheckIn: PaydayCheckIn?
    var totalDebt: Decimal = .zero
    var plannedDebtToday: Decimal = .zero
    var percentEliminated: Decimal = .zero
    var statusKind: StatusBadge.Kind = .onTrack
    var targetDebt: AccountBalanceService.DebtBalance?
    var debtBalances: [AccountBalanceService.DebtBalance] = []
    var forecast: ForecastSnapshot?
    var checking1: AccountBalanceService.Checking1State?
    var checking2: AccountBalanceService.Checking2State?
    var isDebtFree = false

    @MainActor
    static func load(context: ModelContext, environment: AppEnvironment) -> TodayState {
        var state = TodayState()
        do {
            guard let plan = try PlanSeeder.currentPlan(context: context) else { return state }
            state.plan = plan
            let planID = plan.id
            let today = DateMath.startOfDay(environment.dateProvider.now)

            let items = try context.fetch(
                FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
            ).sorted { $0.sequenceNumber < $1.sequenceNumber }
            state.planItems = items

            let checkIns = try context.fetch(FetchDescriptor<PaydayCheckIn>())
            let checkInsByItem = Dictionary(grouping: checkIns, by: \.paydayCheckInKey)

            let pastItems = items.filter { DateMath.startOfDay($0.date) <= today }
            let openPast = pastItems.filter { item in
                let status = checkInsByItem[item.id]?.first?.status
                return status != .completed && status != .needsAttention
            }
            // Earliest open payday first so missed check-ins stay reachable.
            state.currentItem = openPast.first ?? pastItems.last
            state.nextItem = items.first { DateMath.startOfDay($0.date) > today }
            if let current = state.currentItem {
                state.currentCheckIn = checkInsByItem[current.id]?.first
            }

            let balanceService = environment.balanceService(context: context)
            let balances = try balanceService.debtBalances()
            state.debtBalances = balances
            state.totalDebt = balances.reduce(Decimal.zero) { $0 + $1.balance }.rounded2
            let startingTotal = balances.reduce(Decimal.zero) { $0 + $1.debt.startingBalance }
            if startingTotal > 0 {
                state.percentEliminated = ((startingTotal - state.totalDebt) / startingTotal * 100).rounded2
            }
            state.isDebtFree = state.totalDebt.isZeroMoney

            let plannedToday = pastItems.last?.plannedDebtAfter ?? PlanContract.startingDebtTotal
            state.plannedDebtToday = plannedToday
            let variance = (plannedToday - state.totalDebt).rounded2
            if state.currentCheckIn?.status == .needsAttention {
                state.statusKind = .needsAttention
            } else if variance >= Decimal(string: "0.01")! {
                state.statusKind = .ahead(variance)
            } else if variance <= Decimal(string: "-0.01")! {
                state.statusKind = .behind(-variance)
            } else {
                state.statusKind = .onTrack
            }

            state.targetDebt = balances.first { !$0.isPaidOff }
            state.forecast = try environment.reforecastService(context: context).latestForecast()
            state.checking1 = try balanceService.checking1State(plan: plan, planItems: items)
            state.checking2 = try balanceService.checking2State()
        } catch {
            // Leave partial state; the dashboard renders what it can.
        }
        return state
    }
}

private extension PaydayCheckIn {
    var paydayCheckInKey: UUID { paydayPlanItemID }
}

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Query private var checkIns: [PaydayCheckIn]
    @Query private var ledgerEntries: [LedgerEntry]
    @Query private var snapshots: [BalanceSnapshot]
    @Query private var allSettings: [AppSettings]

    @State private var state = TodayState()
    @State private var checkInItem: PaydayPlanItem?
    @State private var showAddSheet = false
    @State private var showDebtFreeFlow = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    statusHeader
                    todaysPlayCard
                    if let target = state.targetDebt {
                        targetCard(target)
                    }
                    if let c1 = state.checking1, let plan = state.plan {
                        Checking1Card(state: c1, plan: plan)
                    }
                    if let c2 = state.checking2 {
                        Checking2Card(state: c2)
                    }
                    upcomingStrip
                    if state.isDebtFree {
                        if let settings = allSettings.first, settings.debtFreeConfirmedAt != nil {
                            PhaseTwoCard(settings: settings, releasedPerPaycheck: releasedPerPaycheck)
                            phaseTwoEditButton
                        } else {
                            debtFreeCard
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(todayTitle)
            .toolbar {
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
            .onAppear {
                reload()
                if let pending = router.pendingCheckInItemID {
                    router.pendingCheckInItemID = nil
                    checkInItem = state.planItems.first { $0.id == pending }
                }
            }
            .onChange(of: checkIns.count) { _, _ in reload() }
            .onChange(of: ledgerEntries.count) { _, _ in reload() }
            .onChange(of: snapshots.count) { _, _ in reload() }
            .onChange(of: router.pendingCheckInItemID) { _, itemID in
                guard let itemID else { return }
                router.pendingCheckInItemID = nil
                if let item = state.planItems.first(where: { $0.id == itemID }) {
                    checkInItem = item
                }
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

    private var todayTitle: String {
        DateMath.mediumString(appEnvironment.dateProvider.now)
    }

    private func reload() {
        state = TodayState.load(context: modelContext, environment: appEnvironment)
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
                Text("\(state.percentEliminated.asDouble, specifier: "%.1f")% of the original \(MoneyFormat.string(PlanContract.startingDebtTotal)) eliminated")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
        if let forecast = state.forecast {
            if let date = forecast.projectedPayoffDate {
                return DateMath.mediumString(date)
            }
            // The engine reported the current budget cannot retire the debt.
            return "Beyond current budget"
        }
        return state.plan.map { DateMath.mediumString($0.baselinePayoffDate) } ?? "—"
    }

    private var todaysPlayCard: some View {
        DashboardCard(title: "Today's play", systemImage: "figure.run") {
            VStack(alignment: .leading, spacing: 10) {
                if let current = state.currentItem, isToday(current.date) || isOpen(current) {
                    PaydayPlaySummary(item: current)
                    checkInButton(for: current)
                } else if let next = state.nextItem {
                    let days = DateMath.days(from: appEnvironment.dateProvider.now, to: next.date)
                    Text("Next payday: \(DateMath.mediumString(next.date)) — \(days) day\(days == 1 ? "" : "s") away")
                        .font(.subheadline)
                    if let target = state.targetDebt {
                        Text("Current avalanche card: \(target.debt.displayName). Next planned payment \(MoneyFormat.string(next.plannedCardBudget)) toward card \(next.plannedTargetDebtID).")
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
                        Text("Card \(target.debt.planID) · \(aprText(target.debt.apr)) APR")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    MoneyText(amount: target.balance, font: .title3.weight(.bold))
                }
                if let next = nextPlannedItemForDisplay {
                    Text("Planned attack this check: \(MoneyFormat.string(next.plannedCardBudget)) toward card \(next.plannedTargetDebtID)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let dueDay = target.debt.dueDayOfMonth {
                    Text("Statement due day: \(dueDay)")
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

    private func aprText(_ apr: Decimal) -> String {
        "\((apr * 100) as NSDecimalNumber)%"
    }

    private var upcomingStrip: some View {
        DashboardCard(title: "Upcoming", systemImage: "calendar.badge.clock") {
            VStack(alignment: .leading, spacing: 6) {
                if let next = state.nextItem {
                    Label("Next payday \(DateMath.mediumString(next.date))", systemImage: "banknote")
                        .font(.subheadline)
                }
                if let nextDue = nextCardDueText {
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

    private var nextCardDueText: String? {
        let today = DateMath.startOfDay(appEnvironment.dateProvider.now)
        let calendar = DateMath.calendar
        var best: (Date, String)?
        for balance in state.debtBalances {
            guard !balance.isPaidOff, let dueDay = balance.debt.dueDayOfMonth else { continue }
            for offset in 0...1 {
                guard let monthDate = calendar.date(byAdding: .month, value: offset, to: today) else { continue }
                var components = calendar.dateComponents([.year, .month], from: monthDate)
                components.day = min(dueDay, 28)
                guard let due = calendar.date(from: components), DateMath.startOfDay(due) >= today else { continue }
                if best == nil || due < best!.0 {
                    best = (due, balance.debt.displayName)
                }
                break
            }
        }
        return best.map { "\($0.1) due \(DateMath.mediumString($0.0))" }
    }

    private var nextProjectedPayoffText: String? {
        guard let forecast = state.forecast else { return nil }
        let today = DateMath.startOfDay(appEnvironment.dateProvider.now)
        let upcoming = forecast.perCardPayoffDates
            .filter { DateMath.startOfDay($0.payoffDate) >= today }
            .min { $0.payoffDate < $1.payoffDate }
        return upcoming.map { "Card \($0.debtPlanID) projected payoff \(DateMath.mediumString($0.payoffDate))" }
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
                Text("Every card reads $0.00. Confirm to celebrate and set up Phase II.")
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
                    MoneyText(amount: item.plannedCarReserve + item.plannedTrainReserve, font: .subheadline.weight(.medium))
                }
                GridRow {
                    Label("Pay → \(item.plannedTargetDebtID)", systemImage: "4.circle.fill")
                    MoneyText(amount: item.plannedCardBudget, font: .subheadline.weight(.medium))
                }
            }
            .font(.subheadline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Payday \(item.sequenceNumber): keep \(MoneyFormat.string(item.plannedC1Keep)), move \(MoneyFormat.string(item.plannedC2Transfer)), reserve \(MoneyFormat.string(item.plannedCarReserve + item.plannedTrainReserve)), pay \(MoneyFormat.string(item.plannedCardBudget)) toward card \(item.plannedTargetDebtID)")
    }
}

struct Checking1Card: View {
    let state: AccountBalanceService.Checking1State
    let plan: PlanVersion

    var body: some View {
        DashboardCard(title: "Checking 1 — flex cash", systemImage: "1.circle") {
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
                }
                Divider()
                HStack {
                    Text("Protected floor")
                    Spacer()
                    MoneyText(amount: state.protectedFloor)
                }
                HStack {
                    Text("Allowance available")
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

    var body: some View {
        DashboardCard(title: "Checking 2 — bills + debt", systemImage: "2.circle") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Balance")
                    Spacer()
                    MoneyText(amount: state.totalBalance, font: .body.weight(.semibold))
                }
                Divider()
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
                HStack {
                    Text("Available for cards")
                    Spacer()
                    MoneyText(amount: state.availableForDebt, color: state.availableForDebt.isNegative ? .red : .primary)
                }
                if state.hasNegativeBucket {
                    Label("A bucket is overallocated — more is earmarked or spent than Checking 2 holds.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .font(.subheadline)
        }
    }
}
