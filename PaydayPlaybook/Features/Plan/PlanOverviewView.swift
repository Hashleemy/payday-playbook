import SwiftUI
import SwiftData

/// The Generated Plan experience (V2-10, V2-14): what the plan assumes, what
/// it recommends, what it forecasts, and the paycheck-by-paycheck playbook —
/// with the three truths kept visibly separate.
struct PlanOverviewView: View {
    let plan: PlanVersion

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @Query private var checkIns: [PaydayCheckIn]
    @Query private var snapshots: [BalanceSnapshot]

    @State private var data = PlanViewData()
    @State private var track: PlanTrack = .baseline
    @State private var loaded = false
    @State private var showActivateFlow = false
    @State private var showAllPaychecks = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                headerCard
                if let note = data.lowConfidenceNote {
                    noticeCard(title: "Limited detail", message: note, symbol: "questionmark.circle")
                }
                if !data.warningLines.isEmpty {
                    warningsCard
                }
                inputsCard
                recommendationCard
                outcomeCard
                comparisonCard
                timelineCard
                trackSelector
                playbookCard
                if !data.scenarios.isEmpty || data.scenarioNote != nil {
                    scenarioCard
                }
                assumptionsCard
                activateCard
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(data.planName.isEmpty ? plan.name : data.planName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadIfNeeded)
        .onChange(of: checkIns.count) { _, _ in reload() }
        .onChange(of: snapshots.count) { _, _ in reload() }
        .sheet(isPresented: $showActivateFlow, onDismiss: reload) {
            PlanActivationView()
        }
    }

    private func reloadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    private func reload() {
        data = PlanViewDataLoader.load(plan: plan, context: modelContext, environment: appEnvironment)
    }

    // MARK: - Header

    private var headerCard: some View {
        DashboardCard(title: data.planName, systemImage: "doc.text.magnifyingglass") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if data.isActive {
                        badge("Active", color: .mint)
                    }
                    if data.isBaseline {
                        badge("Baseline — never edited", color: .blue)
                    }
                    badge("Calculation v\(data.calculationVersion)", color: .secondary)
                }
                if let generated = data.generatedAt {
                    Text("Created \(DateMath.mediumString(generated))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(data.generatedFromProfile
                     ? "Generated from your own accounts, income, obligations, and debts."
                     : "Loaded from a stored plan. Its schedule is kept exactly as recorded.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color == .secondary ? Color.secondary : color)
    }

    private func noticeCard(title: String, message: String, symbol: String) -> some View {
        DashboardCard(title: title, systemImage: symbol) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var warningsCard: some View {
        DashboardCard(title: "Before you rely on this", systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(data.warningLines.enumerated()), id: \.offset) { _, line in
                    Label(line, systemImage: "info.circle")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Inputs

    private var inputsCard: some View {
        DashboardCard(title: "What this plan is built on", systemImage: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 8) {
                labeledRow("Pay cadence", data.cadenceText)
                labeledRow("First payday", data.firstPaydayText)
                if !data.takeHomeText.isEmpty {
                    labeledRow("Take-home", data.takeHomeText)
                }
                ForEach(Array(data.incomeChangeLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Text("Protected cash floor")
                    Spacer()
                    MoneyText(amount: data.protectedFloor)
                }
                HStack {
                    Text("Allowance — available, not spent")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    MoneyText(amount: data.allowanceCap)
                }
                if !data.obligationLines.isEmpty {
                    Divider()
                    Text("Essential obligations")
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(data.obligationLines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(line.name)
                                Text("\(MoneyFormat.string(line.amount)) \(line.cadence.lowercased())")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            MoneyText(amount: line.perPaycheck)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(line.name), \(MoneyFormat.string(line.amount)) \(line.cadence), reserving \(MoneyFormat.string(line.perPaycheck)) per paycheck")
                    }
                    Text("Reserved a slice at a time each paycheck, so the full amount is there when it's due.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !data.accountLines.isEmpty {
                    Divider()
                    Text("Accounts")
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(data.accountLines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(line.name)
                                Text(line.roles)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            MoneyText(amount: line.balance)
                        }
                    }
                }
            }
            .font(.subheadline)
        }
    }

    private func labeledRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Recommendation

    private var recommendationCard: some View {
        DashboardCard(title: "Recommended order", systemImage: "arrow.down.right.circle") {
            VStack(alignment: .leading, spacing: 10) {
                Text(data.avalancheExplanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = data.balanceUnavailableReason {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(data.debtRows) { row in
                    debtRowView(row)
                }
                Divider()
                HStack {
                    Text("Principal outstanding")
                    Spacer()
                    MoneyText(amount: data.totalPrincipalNow, font: .subheadline.weight(.semibold))
                }
                HStack {
                    Text("Principal when this plan started")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    MoneyText(amount: data.totalStartingPrincipal)
                }
                if let original = data.totalOriginalPrincipal {
                    HStack {
                        Text("Original principal borrowed")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        MoneyText(amount: original)
                    }
                }
            }
            .font(.subheadline)
        }
    }

    private func debtRowView(_ row: PlanDebtRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(row.priority).")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Image(systemName: row.debtType.iconSystemName)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(.subheadline.weight(.medium))
                    Text("\(row.debtType.displayName) · \(DebtFormat.aprText(row.apr)) APR")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                MoneyText(amount: row.currentBalance)
            }
            HStack(spacing: 8) {
                if let utilization = row.utilization {
                    UtilizationBadge(utilization: utilization)
                }
                if !row.receivesExtraPrincipal {
                    Text("Minimums only")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let payoff = row.payoffDate {
                    Text("Payoff \(DateMath.mediumString(payoff))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(debtRowAccessibilityLabel(row))
    }

    private func debtRowAccessibilityLabel(_ row: PlanDebtRow) -> String {
        var parts = [
            "Priority \(row.priority)",
            row.name,
            row.debtType.displayName,
            "\(DebtFormat.aprText(row.apr)) APR",
            "balance \(MoneyFormat.string(row.currentBalance))"
        ]
        if let utilization = row.utilization {
            parts.append("using \(UtilizationMath.wholePercentString(utilization)) of its limit")
        }
        if !row.receivesExtraPrincipal { parts.append("receives minimums only") }
        if let payoff = row.payoffDate { parts.append("projected payoff \(DateMath.mediumString(payoff))") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Outcome

    private var outcomeCard: some View {
        DashboardCard(title: "What it projects", systemImage: "flag.filled.and.flag.crossed") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Projected debt-free")
                    Spacer()
                    Text(data.payoffDate.map(DateMath.mediumString) ?? "Not inside the horizon")
                        .font(.subheadline.weight(.semibold))
                }
                HStack {
                    Text("Paychecks in the plan")
                    Spacer()
                    Text("\(data.paycheckCount)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                HStack {
                    Text("Total estimated interest")
                    Spacer()
                    MoneyText(amount: data.totalEstimatedInterest, font: .subheadline.weight(.semibold))
                }
                Text("Every figure here is an estimate. Your issuer's interest, minimums, and posting dates will differ.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline)
        }
    }

    private var comparisonCard: some View {
        DashboardCard(title: "Versus paying minimums only", systemImage: "arrow.left.arrow.right") {
            VStack(alignment: .leading, spacing: 6) {
                if let minimumInterest = data.minimumOnlyInterest {
                    HStack {
                        Text("Minimums-only interest")
                        Spacer()
                        MoneyText(amount: minimumInterest)
                    }
                    if let date = data.minimumOnlyPayoffDate {
                        HStack {
                            Text("Minimums-only payoff")
                            Spacer()
                            Text(DateMath.mediumString(date))
                                .font(.subheadline.weight(.medium))
                        }
                    }
                    if let saved = data.interestSaved {
                        Divider()
                        HStack {
                            Text("Estimated interest saved")
                            Spacer()
                            MoneyText(amount: saved, font: .subheadline.weight(.semibold), color: .mint)
                        }
                        if let days = data.daysSaved {
                            Text("About \(days) day\(days == 1 ? "" : "s") sooner than minimums alone.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let reason = data.minimumOnlyUnavailableReason {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("plan.minimumOnlyUnavailable")
                }
            }
            .font(.subheadline)
        }
    }

    // MARK: - Per-debt timeline

    private var timelineCard: some View {
        DashboardCard(title: "Payoff timeline", systemImage: "chart.bar.doc.horizontal") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(data.debtRows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: row.debtType.iconSystemName)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        Text(row.name)
                        Spacer()
                        Text(row.payoffDate.map(DateMath.mediumString) ?? "—")
                            .font(.subheadline.weight(.medium))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(row.name) projected payoff \(row.payoffDate.map(DateMath.mediumString) ?? "not yet projected")")
                }
                if data.debtRows.isEmpty {
                    Text("No debts are recorded on this plan.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
        }
    }

    // MARK: - Track selector + playbook

    private var trackSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Which truth", selection: $track) {
                ForEach(PlanTrack.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("plan.trackPicker")
            .onChange(of: track) { _, _ in showAllPaychecks = false }
            Text(track.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    /// The playbook can run to hundreds of paychecks; render a readable
    /// window first and let the user ask for the rest.
    private static let initialPlaybookRows = 12

    private var playbookCard: some View {
        DashboardCard(title: "\(track.displayName) — paycheck by paycheck", systemImage: "list.number") {
            LazyVStack(alignment: .leading, spacing: 12) {
                let allRows = data.rows(for: track)
                let rows = showAllPaychecks ? allRows : Array(allRows.prefix(Self.initialPlaybookRows))
                if rows.isEmpty {
                    Text(emptyTrackMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("plan.emptyTrack")
                } else {
                    if track == .reforecast, let reason = data.reforecastUnavailableReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(rows) { row in
                        PlanPaycheckRowView(row: row)
                        if row.id != rows.last?.id { Divider() }
                    }
                    if allRows.count > rows.count {
                        Button {
                            showAllPaychecks = true
                        } label: {
                            Text("Show all \(allRows.count) paychecks")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("plan.showAllPaychecks")
                    }
                }
            }
        }
    }

    private var emptyTrackMessage: String {
        switch track {
        case .baseline:
            return "This plan version has no stored payday schedule."
        case .actual:
            return "No paydays have been recorded yet. Completed check-ins appear here — nothing is filled in from the plan."
        case .reforecast:
            return data.reforecastUnavailableReason
                ?? "No reforecast is available yet. Record a confirmed balance to produce one."
        }
    }

    // MARK: - Scenarios

    private var scenarioCard: some View {
        DashboardCard(title: "What if you changed a guardrail", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(data.scenarios) { scenario in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scenario.title)
                            .font(.subheadline.weight(.medium))
                        Text(scenario.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(scenarioOutcome(scenario))
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(scenario.title). \(scenario.detail) \(scenarioOutcome(scenario))")
                }
                if let note = data.scenarioNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func scenarioOutcome(_ scenario: PlanScenario) -> String {
        var parts: [String] = []
        if let date = scenario.payoffDate {
            parts.append("Debt-free \(DateMath.mediumString(date))")
        } else {
            parts.append("Doesn't finish inside the projection horizon")
        }
        if let delta = scenario.dayDelta, delta != 0 {
            parts.append("\(abs(delta)) day\(abs(delta) == 1 ? "" : "s") \(delta > 0 ? "later" : "sooner")")
        }
        let interestDelta = scenario.interestDelta
        if interestDelta != 0 {
            let direction = interestDelta > 0 ? "more" : "less"
            parts.append("about \(MoneyFormat.string(abs(interestDelta))) \(direction) interest")
        }
        return parts.joined(separator: " · ") + "."
    }

    // MARK: - Assumptions

    private var assumptionsCard: some View {
        DashboardCard(title: "Assumptions", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 6) {
                if data.assumptionLines.isEmpty {
                    Text("No assumptions were recorded for this plan version.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(data.assumptionLines.enumerated()), id: \.offset) { _, line in
                        Text("• \(line)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Activation

    private var activateCard: some View {
        DashboardCard(title: "Change the plan", systemImage: "plus.rectangle.on.folder") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Plans are never edited in place. Updating your inputs and activating creates a new plan version — this one, and all your history, stay exactly as they are.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showActivateFlow = true
                } label: {
                    Text("Save & Activate New Plan Version")
                }
                .buttonStyle(.primaryAction)
                .accessibilityIdentifier("plan.activateButton")
            }
        }
    }
}

/// One paycheck of the playbook: deposits, reserves, transfers, minimums,
/// extra principal, and ending cash.
struct PlanPaycheckRowView: View {
    let row: PlanPaycheckRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Payday #\(row.sequence)")
                    .font(.subheadline.weight(.semibold))
                Text(DateMath.mediumString(row.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                MoneyText(amount: row.income, font: .subheadline.weight(.semibold))
            }
            if let shortfall = row.shortfall, shortfall != 0 {
                Label("Needs attention — about \(MoneyFormat.string(shortfall)) short", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                gridRow("Keep in spending", row.keepInSpending)
                gridRow("Move to reserves", row.transferToReserves)
                if row.allowance != 0 {
                    gridRow(row.isActualRecord ? "Allowance spent" : "Allowance (available, not spent)", row.allowance)
                }
                if row.floorTopUp != 0 {
                    gridRow("Floor top-up", row.floorTopUp)
                }
                ForEach(Array(row.obligationReserves.enumerated()), id: \.offset) { _, reserve in
                    gridRow("Reserve — \(reserve.name)", reserve.amount)
                }
                if let minimums = row.minimumsTotal, minimums != 0 {
                    gridRow("Minimums", minimums)
                }
                if let extra = row.extraTotal, extra != 0 {
                    gridRow("Extra principal", extra)
                }
                gridRow(row.isActualRecord ? "Paid to debts" : "Debt budget", row.debtBudget)
                if let target = row.targetLabel {
                    GridRow {
                        Text("Target").foregroundStyle(.secondary)
                        Text(target).font(.caption.weight(.medium))
                    }
                }
                if !row.isActualRecord {
                    gridRow("Debt after", row.debtAfter)
                }
                gridRow(row.isActualRecord ? "Confirmed balance" : "Ending cash (no-spend)", row.endingCash)
            }
            .font(.caption)
            ForEach(Array(row.movements.enumerated()), id: \.offset) { _, movement in
                Text(movement)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private func gridRow(_ label: String, _ amount: Decimal) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            MoneyText(amount: amount, font: .caption.weight(.medium))
        }
    }

    private var accessibilityLabel: String {
        var parts = [
            "Payday \(row.sequence), \(DateMath.mediumString(row.date))",
            "income \(MoneyFormat.string(row.income))",
            "keep \(MoneyFormat.string(row.keepInSpending))",
            "move \(MoneyFormat.string(row.transferToReserves))"
        ]
        if row.obligationReserveTotal != 0 {
            parts.append("reserve \(MoneyFormat.string(row.obligationReserveTotal))")
        }
        parts.append("\(row.isActualRecord ? "paid to debts" : "debt budget") \(MoneyFormat.string(row.debtBudget))")
        if let target = row.targetLabel { parts.append("target \(target)") }
        if let shortfall = row.shortfall, shortfall != 0 {
            parts.append("needs attention, about \(MoneyFormat.string(shortfall)) short")
        }
        return parts.joined(separator: ", ")
    }
}
