import SwiftUI
import SwiftData
import Charts

/// Charts, stats, milestones, and the reforecast explanation (F-10, F-12).
struct ProgressTabView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Query private var checkIns: [PaydayCheckIn]
    @Query private var ledgerEntries: [LedgerEntry]
    @Query private var balanceSnapshots: [BalanceSnapshot]
    @Query(sort: \Milestone.baselineDate) private var milestones: [Milestone]

    enum Track: String, CaseIterable, Identifiable {
        case plan = "Plan"
        case actual = "Actual"
        case reforecast = "Reforecast"
        var id: String { rawValue }
    }

    struct DebtPoint: Identifiable {
        let id = UUID()
        let date: Date
        let amount: Decimal
        let track: String
    }

    @State private var track: Track = .actual
    @State private var highlightedMilestoneID: UUID?
    @State private var debtSeries: [DebtPoint] = []
    @State private var perCardBalances: [AccountBalanceService.DebtBalance] = []
    @State private var forecast: ForecastSnapshot?
    @State private var stats: Stats = Stats()
    @State private var c1Series: [DebtPoint] = []
    @State private var insights: [InsightCardData] = []

    /// The plan that owns the schedule: the active version, else the stored
    /// baseline. Progress renders generated plans the same as Original Plan v1.
    private var schedulePlan: PlanVersion? {
        let plans = (try? modelContext.fetch(FetchDescriptor<PlanVersion>())) ?? []
        let baseline = (try? PlanRepository.legacyBaseline(context: modelContext)) ?? nil
        let active = plans.first(where: \.isActive)
        if let active {
            let activeID = active.id
            let itemCount = (try? modelContext.fetchCount(
                FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == activeID })
            )) ?? 0
            if itemCount > 0 { return active }
        }
        return baseline ?? active
    }

    /// Total principal when the tracked debts started, summed from the debt
    /// rows themselves so it is right for every install.
    private var startingDebtTotal: Decimal {
        perCardBalances.reduce(Decimal.zero) { $0 + $1.debt.startingBalance }.rounded2
    }

    struct Stats {
        var eliminated: Decimal = .zero
        var percentEliminated: Decimal = .zero
        var dailyInterestCost: Decimal = .zero
        var paychecksRemaining: Int = 0
        var daysToPayoff: Int = 0
        var contributionsLogged: Int = 0
        var principalPaid: Decimal = .zero
        var interestModeled: Decimal = .zero
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 14) {
                    InsightsRow(insights: insights)
                    // §8.6: the primary entry to the three-plan calculator,
                    // directly after the insights row.
                    ScenariosEntryCard()
                    statsGrid
                    debtChartCard
                    perCardCard
                    principalVsInterestCard
                    c1Card
                    varianceCard
                    payoffTimelineCard
                    milestonesCard
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            // A milestone deep link (calendar tap or "milestone ahead"
            // reminder) scrolls to that milestone and highlights it. A
            // milestone that no longer exists simply leaves Progress as it
            // is — the tap still landed somewhere useful.
            .onChange(of: router.pendingMilestoneID) { _, milestoneID in
                revealMilestone(milestoneID, proxy: proxy)
            }
            .onAppear {
                revealMilestone(router.pendingMilestoneID, proxy: proxy)
            }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Progress")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        LedgerListView()
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .accessibilityLabel("Open ledger")
                }
            }
            .onAppear(perform: reload)
            .onChange(of: checkIns.count) { _, _ in reload() }
            .onChange(of: ledgerEntries.count) { _, _ in reload() }
            .onChange(of: balanceSnapshots.count) { _, _ in reload() }
        }
    }

    // MARK: - Cards

    private var statsGrid: some View {
        DashboardCard(title: "The numbers", systemImage: "number") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    statCell("Eliminated", MoneyFormat.string(stats.eliminated))
                    statCell("Percent done", "\(stats.percentEliminated.rounded2)%")
                }
                GridRow {
                    statCell("Daily interest cost", MoneyFormat.string(stats.dailyInterestCost))
                    statCell("Paychecks left", "\(stats.paychecksRemaining)")
                }
                GridRow {
                    statCell("Days to payoff", "\(stats.daysToPayoff)")
                    statCell("Entries logged", "\(stats.contributionsLogged)")
                }
            }
        }
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private var debtChartCard: some View {
        DashboardCard(title: "Total debt over time", systemImage: "chart.line.downtrend.xyaxis") {
            Picker("Track", selection: $track) {
                ForEach(Track.allCases) { track in
                    Text(track.rawValue).tag(track)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: track) { _, _ in reload() }

            Chart(debtSeries) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Debt", point.amount.asDouble)
                )
                .foregroundStyle(by: .value("Track", point.track))
                .interpolationMethod(.monotone)
            }
            .chartYAxisLabel("Debt ($)")
            .frame(height: 220)
            .accessibilityLabel("Line chart of total debt over time")

            AccessibleChartSummary(summary: debtChartSummary)
        }
    }

    private var debtChartSummary: String {
        let start = MoneyFormat.string(startingDebtTotal)
        switch track {
        case .plan:
            guard let plan = schedulePlan else { return "No plan schedule is stored yet." }
            let count = debtSeries.filter { $0.track == "Plan" }.count - 1
            return "The plan takes debt from \(start) on \(DateMath.mediumString(plan.firstPayday)) to $0.00 on \(DateMath.mediumString(plan.baselinePayoffDate)) across \(max(count, 0)) paychecks."
        case .actual:
            let current = MoneyFormat.string((startingDebtTotal - stats.eliminated).rounded2)
            return "Actual debt is \(current); \(MoneyFormat.string(stats.eliminated)) of \(start) has been eliminated."
        case .reforecast:
            if let payoff = forecast?.projectedPayoffDate {
                return "The current reforecast reaches $0.00 on \(DateMath.mediumString(payoff))."
            }
            return "No reforecast has been calculated yet."
        }
    }

    private var perCardCard: some View {
        DashboardCard(title: "Balance by debt", systemImage: "creditcard") {
            Chart(perCardBalances, id: \.debt.planID) { item in
                BarMark(
                    x: .value("Debt", item.debt.debtType.shortReference(planID: item.debt.planID)),
                    y: .value("Balance", item.balance.asDouble)
                )
                .foregroundStyle(item.isPaidOff ? Color.mint : Color.accentColor)
            }
            .chartYAxisLabel("Balance ($)")
            .frame(height: 180)
            .accessibilityLabel("Bar chart of balance by debt")

            AccessibleChartSummary(summary: perCardSummary)
        }
    }

    private var perCardSummary: String {
        perCardBalances
            .map { "\($0.debt.displayName): \(MoneyFormat.string($0.balance))" }
            .joined(separator: ", ")
    }

    private var principalVsInterestCard: some View {
        DashboardCard(title: "Principal versus modeled interest", systemImage: "percent") {
            Chart {
                BarMark(x: .value("Amount", stats.principalPaid.asDouble), y: .value("Kind", "Principal"))
                    .foregroundStyle(Color.mint)
                BarMark(x: .value("Amount", stats.interestModeled.asDouble), y: .value("Kind", "Interest"))
                    .foregroundStyle(Color.orange)
            }
            .frame(height: 120)
            .accessibilityLabel("Bar chart comparing principal paid and modeled interest")
            AccessibleChartSummary(
                summary: "Cumulative principal paid \(MoneyFormat.string(stats.principalPaid)); remaining modeled interest \(MoneyFormat.string(stats.interestModeled))."
            )
        }
    }

    private var c1Card: some View {
        DashboardCard(title: "Spending account versus floor and ceiling", systemImage: "1.circle") {
            Chart(c1Series) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Amount", point.amount.asDouble)
                )
                .foregroundStyle(by: .value("Track", point.track))
            }
            .chartYAxisLabel("Balance ($)")
            .frame(height: 180)
            .accessibilityLabel("Line chart of the spending account balance versus the protected floor and no-spend ceiling")
            AccessibleChartSummary(summary: c1ChartSummary)
        }
    }

    /// Computed from the plan's own ceiling path — never a fixed sentence,
    /// which would be wrong for any plan but the one it was written for.
    private var c1ChartSummary: String {
        let ceilings = c1Series.filter { $0.track == "No-spend ceiling" }
        guard let first = ceilings.first, let last = ceilings.last, let plan = schedulePlan else {
            return "No spending-account path is stored for this plan yet."
        }
        return "The no-spend ceiling grows from \(MoneyFormat.string(first.amount)) to \(MoneyFormat.string(last.amount)); the protected floor stays at \(MoneyFormat.string(plan.protectedBuffer)). Your actual balance lands between them based on what you spend."
    }

    private var varianceCard: some View {
        DashboardCard(title: "Plan versus actual by payday", systemImage: "arrow.left.arrow.right") {
            let variances = paydayVariances()
            if variances.isEmpty {
                Text("Complete a payday check-in to see variance.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Chart(variances, id: \.0) { item in
                    BarMark(
                        x: .value("Payday", "#\(item.0)"),
                        y: .value("Variance", item.1.asDouble)
                    )
                    .foregroundStyle(item.1 >= 0 ? Color.mint : Color.orange)
                }
                .chartYAxisLabel("Card payments vs plan ($)")
                .frame(height: 160)
                .accessibilityLabel("Bar chart of card payment variance by payday")
                AccessibleChartSummary(summary: varianceSummary(variances))
            }
            if let explanation = forecast?.summaryExplanation {
                Divider()
                Label(explanation, systemImage: "sparkles")
                    .font(.subheadline)
            }
        }
    }

    private func varianceSummary(_ variances: [(Int, Decimal)]) -> String {
        variances
            .map { "Payday \($0.0): \($0.1 >= 0 ? "+" : "")\(MoneyFormat.string($0.1)) versus plan" }
            .joined(separator: ", ")
    }

    private var payoffTimelineCard: some View {
        DashboardCard(title: "Payoff timeline", systemImage: "flag.checkered") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Debt").font(.caption).foregroundStyle(.secondary)
                    Text("Baseline").font(.caption).foregroundStyle(.secondary)
                    Text("Forecast").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(timelineOrder, id: \.self) { planID in
                    GridRow {
                        Text(debtLabel(planID)).font(.subheadline.weight(.medium))
                        Text(baselinePayoffText(planID))
                            .font(.subheadline)
                        Text(forecastPayoffText(planID))
                            .font(.subheadline)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(payoffTimelineAccessibility)
        }
    }

    /// Debts in this install's own avalanche order.
    private var timelineOrder: [String] {
        perCardBalances.map(\.debt.planID)
    }

    private func debtLabel(_ planID: String) -> String {
        guard let debt = perCardBalances.first(where: { $0.debt.planID == planID })?.debt else {
            return "Card \(planID)"
        }
        return debt.displayName
    }

    /// This install's own baseline payoff milestone. There is no fallback
    /// table: a date this store does not hold is shown as unknown rather
    /// than filled in from somewhere else.
    private func baselinePayoffText(_ planID: String) -> String {
        guard let milestone = milestones.first(where: {
            $0.type == .cardPaidOff && $0.relatedDebtPlanID == planID
        }), let date = milestone.baselineDate else { return "—" }
        return DateMath.mediumString(date)
    }

    private var payoffTimelineAccessibility: String {
        timelineOrder.map { planID in
            "\(debtLabel(planID)): baseline \(baselinePayoffText(planID)), forecast \(forecastPayoffText(planID))"
        }.joined(separator: ". ")
    }

    private func forecastPayoffText(_ planID: String) -> String {
        if let date = forecast?.perCardPayoffDates.first(where: { $0.debtPlanID == planID })?.payoffDate {
            return DateMath.mediumString(date)
        }
        if let balance = perCardBalances.first(where: { $0.debt.planID == planID }), balance.isPaidOff {
            return "Paid off"
        }
        return "—"
    }

    private var milestonesCard: some View {
        DashboardCard(title: "Milestones", systemImage: "star") {
            VStack(alignment: .leading, spacing: 8) {
                if let next = milestones.first(where: { $0.achievedDate == nil }) {
                    Label {
                        Text("Next: \(next.title) — projected \((next.forecastDate ?? next.baselineDate).map(DateMath.mediumString) ?? "—")")
                    } icon: {
                        Image(systemName: "arrow.right.circle")
                    }
                    .font(.subheadline.weight(.medium))
                    Divider()
                }
                ForEach(milestones) { milestone in
                    HStack {
                        Image(systemName: milestone.achievedDate != nil ? "checkmark.seal.fill" : "seal")
                            .foregroundStyle(milestone.achievedDate != nil ? .mint : .secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(milestone.title).font(.subheadline)
                            Text(milestoneSubtitle(milestone))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(highlightedMilestoneID == milestone.id
                                  ? Color.accentColor.opacity(0.18)
                                  : Color.clear)
                    )
                    .id(milestone.id)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// Honors a milestone deep link once, then clears it so returning to
    /// the tab later does not re-scroll.
    private func revealMilestone(_ milestoneID: UUID?, proxy: ScrollViewProxy) {
        guard let milestoneID, milestones.contains(where: { $0.id == milestoneID }) else {
            router.pendingMilestoneID = nil
            return
        }
        highlightedMilestoneID = milestoneID
        router.pendingMilestoneID = nil
        withAnimation { proxy.scrollTo(milestoneID, anchor: .center) }
    }

    private func milestoneSubtitle(_ milestone: Milestone) -> String {
        if let achieved = milestone.achievedDate {
            return "Achieved \(DateMath.mediumString(achieved))"
        }
        var parts: [String] = []
        if let baseline = milestone.baselineDate {
            parts.append("Baseline \(DateMath.mediumString(baseline))")
        }
        if let forecastDate = milestone.forecastDate {
            parts.append("Forecast \(DateMath.mediumString(forecastDate))")
        }
        return parts.isEmpty ? "Ahead" : parts.joined(separator: " · ")
    }

    // MARK: - Data

    private func paydayVariances() -> [(Int, Decimal)] {
        // `schedulePlan`, not `existingBaseline`: the latter is template-only,
        // so a generated plan produced an empty variance chart.
        guard let plan = schedulePlan else { return [] }
        let planVersionID = plan.id
        let items = (try? modelContext.fetch(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planVersionID })
        )) ?? []
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var results: [(Int, Decimal)] = []
        for checkIn in checkIns where checkIn.status == .completed || checkIn.status == .needsAttention {
            guard let item = itemsByID[checkIn.paydayPlanItemID] else { continue }
            let checkInID = checkIn.id
            let paid = ledgerEntries
                .filter { $0.paydayCheckInID == checkInID && $0.type == .cardPayment }
                .reduce(Decimal.zero) { $0 + $1.amount }
            results.append((item.sequenceNumber, (paid - item.plannedCardBudget).rounded2))
        }
        return results.sorted { $0.0 < $1.0 }
    }

    private func reload() {
        let environment = appEnvironment
        let balances = (try? environment.balanceService(context: modelContext).debtBalances()) ?? []
        perCardBalances = balances
        forecast = try? environment.reforecastService(context: modelContext).latestForecast()

        let startingTotal = balances.reduce(Decimal.zero) { $0 + $1.debt.startingBalance }
        let currentTotal = balances.reduce(Decimal.zero) { $0 + $1.balance }
        var newStats = Stats()
        newStats.eliminated = (startingTotal - currentTotal).rounded2
        if startingTotal > 0 {
            newStats.percentEliminated = ((startingTotal - currentTotal) / startingTotal * 100).rounded2
        }
        newStats.dailyInterestCost = balances
            .reduce(Decimal.zero) { $0 + $1.balance * $1.debt.apr / Decimal(365) }
            .rounded2
        newStats.paychecksRemaining = forecast?.remainingPaychecks ?? 0
        if let payoff = forecast?.projectedPayoffDate {
            newStats.daysToPayoff = max(0, DateMath.days(from: environment.dateProvider.now, to: payoff))
        }
        newStats.contributionsLogged = ledgerEntries.count
        newStats.principalPaid = ledgerEntries
            .filter { $0.type == .cardPayment }
            .reduce(Decimal.zero) { $0 + $1.amount }
            .rounded2
        newStats.interestModeled = forecast?.estimatedRemainingInterest ?? .zero
        stats = newStats

        debtSeries = buildDebtSeries()
        c1Series = buildC1Series()
        insights = InsightsBuilder.build(context: modelContext, environment: environment)
    }

    private func buildDebtSeries() -> [DebtPoint] {
        guard let plan = schedulePlan else { return [] }
        let planVersionID = plan.id
        let items = ((try? modelContext.fetch(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planVersionID })
        )) ?? []).sorted { $0.sequenceNumber < $1.sequenceNumber }

        switch track {
        case .plan:
            var points = [DebtPoint(
                date: DateMath.addingDays(-1, to: plan.firstPayday),
                amount: startingDebtTotal,
                track: "Plan"
            )]
            points += items.map { DebtPoint(date: $0.date, amount: $0.plannedDebtAfter, track: "Plan") }
            return points
        case .actual:
            return buildActualSeries()
        case .reforecast:
            guard let forecast else { return [] }
            var points: [DebtPoint] = []
            let balances = perCardBalances.reduce(Decimal.zero) { $0 + $1.balance }
            points.append(DebtPoint(date: appEnvironment.dateProvider.now, amount: balances, track: "Reforecast"))
            if let payoff = forecast.projectedPayoffDate {
                points.append(DebtPoint(date: payoff, amount: .zero, track: "Reforecast"))
            }
            return points
        }
    }

    /// Actual debt totals at each activity date. Authoritative snapshots
    /// override the running per-card balances from their effective date, the
    /// same rule the balance service applies.
    private func buildActualSeries() -> [DebtPoint] {
        var points: [DebtPoint] = [
            DebtPoint(
                date: DateMath.addingDays(
                    -1, to: schedulePlan?.firstPayday ?? appEnvironment.dateProvider.now
                ),
                amount: startingDebtTotal,
                track: "Actual"
            )
        ]
        let today = DateMath.startOfDay(appEnvironment.dateProvider.now)

        var perCard: [String: Decimal] = Dictionary(
            uniqueKeysWithValues: perCardBalances.map { ($0.debt.planID, $0.debt.startingBalance) }
        )
        let debtEntries = ledgerEntries.filter { entry in
            entry.debtPlanID != nil
                && [.cardPayment, .refundReversal, .correction].contains(entry.type)
                && DateMath.startOfDay(entry.effectiveDate) <= today
        }
        let authoritative = balanceSnapshots.filter { snapshot in
            snapshot.debtPlanID != nil && snapshot.isAuthoritative
                && DateMath.startOfDay(snapshot.effectiveDate) <= today
        }
        let activityDates = Set(
            debtEntries.map { DateMath.startOfDay($0.effectiveDate) }
                + authoritative.map { DateMath.startOfDay($0.effectiveDate) }
        ).sorted()

        for date in activityDates {
            // Snapshots first: they reset the card, then same-day entries
            // recorded after them apply on top (mirrors AccountBalanceService).
            for snapshot in authoritative where DateMath.isSameDay(snapshot.effectiveDate, date) {
                if let card = snapshot.debtPlanID {
                    perCard[card] = snapshot.amount
                }
            }
            for entry in debtEntries where DateMath.isSameDay(entry.effectiveDate, date) {
                guard let card = entry.debtPlanID else { continue }
                let sameDaySnapshot = authoritative.first {
                    $0.debtPlanID == card && DateMath.isSameDay($0.effectiveDate, date)
                }
                if let sameDaySnapshot, entry.createdAt <= sameDaySnapshot.createdAt { continue }
                switch entry.type {
                case .cardPayment: perCard[card, default: .zero] -= entry.amount
                case .refundReversal, .correction: perCard[card, default: .zero] += entry.amount
                default: break
                }
            }
            let total = perCard.values.reduce(Decimal.zero) { $0 + max($1, .zero) }
            points.append(DebtPoint(date: date, amount: total.rounded2, track: "Actual"))
        }

        points.append(DebtPoint(
            date: appEnvironment.dateProvider.now,
            amount: perCardBalances.reduce(Decimal.zero) { $0 + $1.balance },
            track: "Actual"
        ))
        return points
    }

    private func buildC1Series() -> [DebtPoint] {
        guard let plan = schedulePlan else { return [] }
        let planVersionID = plan.id
        let items = ((try? modelContext.fetch(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planVersionID })
        )) ?? []).sorted { $0.sequenceNumber < $1.sequenceNumber }

        var points: [DebtPoint] = []
        for item in items {
            points.append(DebtPoint(date: item.date, amount: item.plannedC1NoSpendCeiling, track: "No-spend ceiling"))
            points.append(DebtPoint(date: item.date, amount: plan.protectedBuffer, track: "Protected floor"))
        }
        if let c1 = try? appEnvironment.balanceService(context: modelContext)
            .checking1State(plan: plan, planItems: items) {
            points.append(DebtPoint(date: appEnvironment.dateProvider.now, amount: c1.actualBalance, track: "Actual"))
        }
        return points
    }
}
