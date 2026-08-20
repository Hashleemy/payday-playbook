import SwiftUI
import SwiftData

/// Debt list in avalanche order with a collapsed paid-off section (F-04).
struct DebtsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Query private var ledgerEntries: [LedgerEntry]
    @Query private var snapshots: [BalanceSnapshot]

    struct PushedCard: Identifiable, Hashable {
        let planID: String
        var id: String { planID }
    }

    @State private var balances: [AccountBalanceService.DebtBalance] = []
    @State private var showPaidOff = false
    @State private var pushedCard: PushedCard?

    private var active: [AccountBalanceService.DebtBalance] {
        balances.filter { !$0.isPaidOff }
    }

    private var paidOff: [AccountBalanceService.DebtBalance] {
        balances.filter(\.isPaidOff)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Avalanche order") {
                    if balances.isEmpty {
                        EmptyStateView(
                            title: "No debts yet",
                            message: "Debts you add in setup appear here in payoff order.",
                            symbolName: "creditcard"
                        )
                    } else if active.isEmpty {
                        Label("All debts are paid off", systemImage: "party.popper")
                            .font(.headline)
                            .foregroundStyle(.mint)
                    }
                    ForEach(active, id: \.debt.planID) { item in
                        NavigationLink(value: item.debt.planID) {
                            DebtRow(item: item)
                        }
                    }
                }
                if !paidOff.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showPaidOff) {
                            ForEach(paidOff, id: \.debt.planID) { item in
                                NavigationLink(value: item.debt.planID) {
                                    DebtRow(item: item)
                                }
                            }
                        } label: {
                            Text("Paid off (\(paidOff.count))")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                }
            }
            .navigationTitle("Debts")
            .navigationDestination(for: String.self) { planID in
                DebtDetailView(planID: planID)
            }
            .onAppear {
                reload()
                if let pending = router.pendingDebtPlanID {
                    router.pendingDebtPlanID = nil
                    pushedCard = PushedCard(planID: pending)
                }
                openPendingDebt(router.pendingDebtID)
            }
            .onChange(of: ledgerEntries.count) { _, _ in reload() }
            .onChange(of: snapshots.count) { _, _ in reload() }
            .onChange(of: router.pendingDebtPlanID) { _, planID in
                guard let planID else { return }
                router.pendingDebtPlanID = nil
                pushedCard = PushedCard(planID: planID)
            }
            .onChange(of: router.pendingDebtID) { _, debtID in
                openPendingDebt(debtID)
            }
            .navigationDestination(item: $pushedCard) { card in
                DebtDetailView(planID: card.planID)
            }
        }
    }

    private func reload() {
        balances = (try? appEnvironment.balanceService(context: modelContext).debtBalances()) ?? []
    }

    /// Opens a debt addressed by entity (a v0.3.0 reminder or calendar row).
    /// The plan letter is looked up from the debt rather than trusted from
    /// the link, so a letter reused after a delete cannot open the wrong
    /// debt. A debt that no longer exists leaves the user on the Debts list,
    /// which is the honest place to land (V3-07).
    private func openPendingDebt(_ debtID: UUID?) {
        guard let debtID else { return }
        router.pendingDebtID = nil
        let matches = (try? modelContext.fetch(
            FetchDescriptor<DebtAccount>(predicate: #Predicate { $0.id == debtID })
        )) ?? []
        guard let debt = matches.first else { return }
        pushedCard = PushedCard(planID: debt.planID)
    }
}

struct DebtRow: View {
    let item: AccountBalanceService.DebtBalance

    private var subtitle: String {
        let apr = "\(DebtFormat.aprText(item.debt.apr)) APR"
        let due = item.debt.dueDayOfMonth.map { " · due day \($0)" } ?? ""
        return "\(item.debt.debtType.shortReference(planID: item.debt.planID)) · \(apr)\(due)"
    }

    private var percentPaidText: String {
        "\((item.percentPaid * 100).rounded2) % paid"
    }

    private var utilization: Decimal? {
        item.debt.utilization(currentBalance: item.balance)
    }

    var body: some View {
        HStack {
            Image(systemName: item.debt.debtType.iconSystemName)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.debt.displayName)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let utilization {
                    UtilizationBadge(utilization: utilization)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                MoneyText(amount: item.balance, font: .body.weight(.semibold))
                Text(percentPaidText)
                    .font(.caption)
                    .foregroundStyle(item.isPaidOff ? .mint : .secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    private var accessibilityText: String {
        var parts = [
            item.debt.displayName,
            item.debt.debtType.displayName,
            "balance \(MoneyFormat.string(item.balance))",
            percentPaidText
        ]
        if let utilization {
            parts.append("using \(UtilizationMath.wholePercentString(utilization)) of its limit")
        }
        return parts.joined(separator: ", ")
    }
}

/// Card detail: actual balance, baseline comparison, history, actions.
struct DebtDetailView: View {
    let planID: String

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @Query private var ledgerEntries: [LedgerEntry]
    @Query private var allSnapshots: [BalanceSnapshot]

    @State private var item: AccountBalanceService.DebtBalance?
    @State private var baselineToday: Decimal?
    @State private var forecastPayoff: Date?
    @State private var baselinePayoff: Date?
    @State private var showEdit = false
    @State private var showExtraPayment = false
    @State private var showAddPayment = false

    var body: some View {
        List {
            if let item {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        MoneyText(amount: item.balance, font: .system(size: 34, weight: .bold))
                        if let asOf = item.asOfDate {
                            Text("As of \(DateMath.mediumString(asOf))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if item.isPaidOff {
                            Label("Paid off", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.mint)
                        }
                    }
                }
                // The screen's primary action (V4-05): a Button + destination
                // rather than a NavigationLink row, because List rows ignore
                // custom button styles and the primary CTA must read as one.
                Section {
                    Button {
                        showAddPayment = true
                    } label: {
                        Label("Add Payment", systemImage: "plus.circle")
                    }
                    .buttonStyle(.primaryAction)
                    .accessibilityHint("Records a payment toward this debt")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                Section {
                    NavigationLink {
                        BalanceUpdateView(preselectedPlanID: planID)
                    } label: {
                        Label("Update Balance", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        showEdit = true
                    } label: {
                        Label("Edit Debt", systemImage: "pencil")
                    }
                    // V3-04: the extra-payment entry point on debt detail. It
                    // opens a preview — nothing is scheduled or paid from here.
                    Button {
                        showExtraPayment = true
                    } label: {
                        Label("What if I pay extra?", systemImage: "arrow.up.forward.circle")
                    }
                    .accessibilityIdentifier("debt.whatIfExtra")
                    .accessibilityHint("Shows what an extra payment would do. Nothing is scheduled.")
                }
                Section("Numbers") {
                    LabeledContent(item.debt.debtType.showsOriginalPrincipal
                                   ? "Principal when this plan started"
                                   : "Balance when this plan started") {
                        MoneyText(amount: item.debt.startingBalance)
                    }
                    if item.debt.debtType.showsOriginalPrincipal {
                        LabeledContent("Original principal") {
                            if let original = item.debt.originalPrincipal {
                                MoneyText(amount: original)
                            } else {
                                Text("Not recorded").foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let limit = item.debt.creditLimit, limit > 0 {
                        LabeledContent("Credit limit") { MoneyText(amount: limit) }
                        if let utilization = item.debt.utilization(currentBalance: item.balance) {
                            LabeledContent("Utilization") {
                                UtilizationBadge(utilization: utilization)
                            }
                        }
                    } else if item.debt.debtType.supportsCreditLimit {
                        LabeledContent("Credit limit") {
                            Text("Not recorded").foregroundStyle(.secondary)
                        }
                    }
                    if let baselineToday {
                        LabeledContent("Baseline balance for today") {
                            MoneyText(amount: baselineToday)
                        }
                    }
                    LabeledContent("Debt type") { Text(item.debt.debtType.displayName) }
                    LabeledContent("APR") {
                        Text(DebtFormat.aprText(item.debt.apr))
                    }
                    LabeledContent(item.debt.debtType.minimumLabel) {
                        if let minimum = item.debt.minimumAmount {
                            MoneyText(amount: minimum)
                        } else if item.debt.debtType.requiresEnteredMinimum {
                            Text("Needs an amount").foregroundStyle(.orange)
                        } else {
                            Text("Estimated").foregroundStyle(.secondary)
                        }
                    }
                    if let dueDay = item.debt.dueDayOfMonth {
                        LabeledContent(item.debt.debtType.dueDayLabel) { Text("\(dueDay)") }
                    }
                    LabeledContent("Avalanche priority") { Text("#\(item.debt.priority)") }
                    if !item.debt.isExtraPrincipalEligible {
                        LabeledContent("Extra principal") {
                            Text("Minimums only").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Baseline payoff") {
                        Text(baselinePayoff.map(DateMath.mediumString) ?? "—")
                    }
                    LabeledContent("Forecast payoff") {
                        Text(forecastPayoff.map(DateMath.mediumString) ?? "—")
                    }
                }
                paymentHistorySection
                snapshotHistorySection
            } else {
                EmptyStateView(title: "Debt not found", message: "This debt is not part of the plan.")
            }
        }
        .navigationTitle(item?.debt.displayName ?? "Debt \(planID)")
        .navigationDestination(isPresented: $showAddPayment) {
            AddPaymentView(preselectedPlanID: planID)
        }
        .onAppear(perform: reload)
        .onChange(of: ledgerEntries.count) { _, _ in reload() }
        .onChange(of: allSnapshots.count) { _, _ in reload() }
        .sheet(isPresented: $showEdit, onDismiss: reload) {
            if let debt = item?.debt {
                DebtEditView(debt: debt)
            }
        }
        .sheet(isPresented: $showExtraPayment) {
            // No `onDismiss: reload` — the preview cannot have changed
            // anything, and reloading would imply otherwise.
            ExtraPaymentSheet(initialDebtID: item?.debt.id)
        }
    }

    private var payments: [LedgerEntry] {
        ledgerEntries
            .filter { $0.debtPlanID == planID }
            .sorted { $0.effectiveDate > $1.effectiveDate }
    }

    private var snapshots: [BalanceSnapshot] {
        allSnapshots
            .filter { $0.debtPlanID == planID }
            .sorted { $0.effectiveDate > $1.effectiveDate }
    }

    @ViewBuilder
    private var paymentHistorySection: some View {
        Section("Payment history") {
            if payments.isEmpty {
                Text("No payments recorded yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(payments) { entry in
                LedgerRow(entry: entry)
            }
        }
    }

    @ViewBuilder
    private var snapshotHistorySection: some View {
        Section("Balance history") {
            if snapshots.isEmpty {
                Text("No balance updates recorded yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(snapshots) { snapshot in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(DateMath.mediumString(snapshot.effectiveDate))
                            .font(.subheadline)
                        Text(snapshot.sourceType.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let note = snapshot.note, !note.isEmpty {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    MoneyText(amount: snapshot.amount, font: .subheadline.weight(.semibold))
                }
            }
        }
    }

    private func reload() {
        let balances = (try? appEnvironment.balanceService(context: modelContext).debtBalances()) ?? []
        item = balances.first { $0.debt.planID == planID }
        baselineToday = baselineBalanceToday()
        forecastPayoff = (try? appEnvironment.reforecastService(context: modelContext).latestForecast())?
            .perCardPayoffDates.first { $0.debtPlanID == planID }?.payoffDate
        // Baseline payoff comes from this install's own milestones. No
        // fallback table: a date this store does not hold is unknown, and
        // filling it in from elsewhere would show one plan's date on another.
        let milestones = (try? modelContext.fetch(FetchDescriptor<Milestone>())) ?? []
        baselinePayoff = milestones
            .first { $0.type == .cardPaidOff && $0.relatedDebtPlanID == planID }?
            .baselineDate
    }

    /// Planned balance for this debt as of today, from the plan that owns the
    /// schedule (the active plan version, else the stored baseline).
    private func baselineBalanceToday() -> Decimal? {
        let today = DateMath.startOfDay(appEnvironment.dateProvider.now)
        let plans = (try? modelContext.fetch(FetchDescriptor<PlanVersion>())) ?? []
        let baseline = (try? PlanRepository.legacyBaseline(context: modelContext)) ?? nil
        guard let plan = plans.first(where: \.isActive) ?? baseline else { return nil }
        let planVersionID = plan.id
        let items = (try? modelContext.fetch(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planVersionID })
        )) ?? []
        let past = items
            .filter { DateMath.startOfDay($0.date) <= today }
            .max { $0.sequenceNumber < $1.sequenceNumber }
        guard let past else {
            return item?.debt.startingBalance
        }
        let itemID = past.id
        let planned = (try? modelContext.fetch(
            FetchDescriptor<PlannedCardBalance>(predicate: #Predicate { $0.paydayPlanItemID == itemID })
        )) ?? []
        return planned.first { $0.debtPlanID == planID }?.balanceAfter
    }
}

/// Editing debt metadata never touches recorded balances or history silently;
/// APR/minimum/due-date edits flow into the next reforecast. Fields edit local
/// state so Cancel discards cleanly. Per-type fields follow MVP_LAYOUT §4.7.
struct DebtEditView: View {
    let debt: DebtAccount
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var notificationScheduler: NotificationScheduler

    @State private var debtType: DebtType = .creditCard
    @State private var nameText = ""
    @State private var lastFourText = ""
    @State private var aprText = ""
    @State private var minimumText = ""
    @State private var dueDayText = ""
    @State private var creditLimitText = ""
    @State private var originalPrincipalText = ""
    @State private var extraPrincipalEligible = true
    @State private var shiftRule: DueDateShiftRule = .exactDay
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Debt") {
                    Picker("Type", selection: $debtType) {
                        ForEach(DebtType.allCases) { type in
                            Label(type.displayName, systemImage: type.iconSystemName).tag(type)
                        }
                    }
                    .accessibilityIdentifier("debt.typePicker")
                    TextField("Nickname / issuer", text: $nameText)
                    TextField("Last four digits (optional)", text: $lastFourText)
                        .keyboardType(.numberPad)
                }
                Section("Terms") {
                    fieldRow("APR %", placeholder: "APR", text: $aprText, keyboard: .decimalPad)
                    fieldRow(
                        debtType.minimumLabel,
                        placeholder: debtType.requiresEnteredMinimum ? "Required" : "Optional",
                        text: $minimumText,
                        keyboard: .decimalPad
                    )
                    if debtType.requiresEnteredMinimum {
                        Text("Installment debts need their contractual payment — it isn't estimated.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    fieldRow(debtType.dueDayLabel, placeholder: "1–31", text: $dueDayText, keyboard: .numberPad)
                    Text("Days 29–31 fall on the last day of shorter months.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !dueDayText.isEmpty {
                        // V2-11: due dates only move off a weekend when the
                        // user says so.
                        Picker("Weekend due dates", selection: $shiftRule) {
                            ForEach(DueDateShiftRule.allCases) { rule in
                                Text(rule.displayName).tag(rule)
                            }
                        }
                    }
                }
                if debtType.supportsCreditLimit {
                    Section("Credit card") {
                        fieldRow("Credit limit (optional)", placeholder: "Optional", text: $creditLimitText, keyboard: .decimalPad)
                        Text("Used to show utilization. It never changes how payments are allocated.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if debtType.showsOriginalPrincipal {
                    Section("Principal") {
                        fieldRow("Original principal (optional)", placeholder: "Optional", text: $originalPrincipalText, keyboard: .decimalPad)
                        Text("Used for percent-paid display only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("Extra principal allowed", isOn: $extraPrincipalEligible)
                    Text(extraPrincipalEligible
                         ? "Extra money can go here once it's the top-priority debt."
                         : "This debt receives its minimum only — nothing extra, in any plan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        save()
                    } label: {
                        Text(isSaving ? "Saving…" : "Save")
                    }
                    .buttonStyle(.primaryAction)
                    .disabled(isSaving)
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle("Edit debt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                debtType = debt.debtType
                nameText = debt.displayName
                lastFourText = debt.lastFour ?? ""
                aprText = MoneyFormat.editingString(debt.apr * 100)
                minimumText = debt.minimumAmount.map(MoneyFormat.editingString) ?? ""
                dueDayText = debt.dueDayOfMonth.map(String.init) ?? ""
                creditLimitText = debt.creditLimit.map(MoneyFormat.editingString) ?? ""
                originalPrincipalText = debt.originalPrincipal.map(MoneyFormat.editingString) ?? ""
                extraPrincipalEligible = debt.isExtraPrincipalEligible
                shiftRule = debt.dueDateShiftRule
            }
        }
    }

    private func fieldRow(
        _ label: String,
        placeholder: String,
        text: Binding<String>,
        keyboard: UIKeyboardType
    ) -> some View {
        HStack {
            Text(label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
                .accessibilityLabel(label)
        }
    }

    private func save() {
        guard let aprPercent = MoneyFormat.parse(aprText), aprPercent >= 0, aprPercent <= 100 else {
            errorMessage = "Enter an APR between 0 and 100."
            return
        }
        let minimum: Decimal? = minimumText.isEmpty ? nil : MoneyFormat.parse(minimumText)
        if !minimumText.isEmpty && minimum == nil {
            errorMessage = "Enter a valid \(debtType.minimumLabel.lowercased())."
            return
        }
        var dueDay: Int?
        if !dueDayText.isEmpty {
            guard let day = Int(dueDayText) else {
                errorMessage = "Enter a due day between 1 and 31."
                return
            }
            dueDay = day
        }
        let creditLimit: Decimal? = debtType.supportsCreditLimit && !creditLimitText.isEmpty
            ? MoneyFormat.parse(creditLimitText)
            : nil
        if debtType.supportsCreditLimit && !creditLimitText.isEmpty && creditLimit == nil {
            errorMessage = "Enter a valid credit limit."
            return
        }
        let originalPrincipal: Decimal? = originalPrincipalText.isEmpty
            ? nil
            : MoneyFormat.parse(originalPrincipalText)
        if !originalPrincipalText.isEmpty && originalPrincipal == nil {
            errorMessage = "Enter a valid original principal."
            return
        }
        let trimmedName = nameText.trimmingCharacters(in: .whitespaces)
        let resolvedName = trimmedName.isEmpty
            ? debtType.shortReference(planID: debt.planID)
            : trimmedName

        // One validation path with the model layer, so the UI can never store
        // a combination the plan generator would reject.
        do {
            try ModelValidation.validateDebt(
                type: debtType,
                displayName: resolvedName,
                currentBalance: debt.startingBalance,
                originalPrincipal: originalPrincipal,
                apr: aprPercent / 100,
                minimumAmount: minimum,
                creditLimit: creditLimit,
                dueDayOfMonth: dueDay,
                lastFour: String(lastFourText.filter(\.isNumber).prefix(4))
            )
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }

        // The due rule goes through the one shared prospective path, so a
        // debt edited here and a bill edited in setup produce the same audit
        // trail and the same effective date (V3-07). It must run before the
        // other assignments: it diffs against what is currently stored.
        let dueRuleChanged: Bool
        do {
            dueRuleChanged = try DueRuleEditService.apply(
                DueRule(dueDay: dueDay, shift: shiftRule),
                to: debt,
                now: appEnvironment.dateProvider.now,
                context: modelContext
            ).didChange
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        debt.debtType = debtType
        debt.displayName = resolvedName
        let digits = String(lastFourText.filter(\.isNumber).prefix(4))
        debt.lastFour = digits.isEmpty ? nil : digits
        debt.apr = aprPercent / 100
        debt.minimumAmount = minimum
        debt.creditLimit = debtType.supportsCreditLimit ? creditLimit : nil
        debt.originalPrincipal = originalPrincipal
        debt.isExtraPrincipalEligible = extraPrincipalEligible
        debt.updatedAt = Date()
        do {
            try modelContext.save()
            _ = try? appEnvironment.reforecastService(context: modelContext)
                .reforecast(trigger: dueRuleChanged ? .planEdit : .aprChange)
            // V2-11 / §9: the reschedule completes before the edit screen is
            // dismissed, so stable identifiers replace the old due-date
            // reminders with no stale fires and no duplicates.
            isSaving = true
            Task {
                await notificationScheduler.rescheduleAll(
                    context: modelContext,
                    dateProvider: appEnvironment.dateProvider,
                    trigger: .dueDateEdit
                )
                isSaving = false
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
