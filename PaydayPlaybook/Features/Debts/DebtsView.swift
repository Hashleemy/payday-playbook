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
                    if active.isEmpty && !balances.isEmpty {
                        Label("All cards are paid off", systemImage: "party.popper")
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
            }
            .onChange(of: ledgerEntries.count) { _, _ in reload() }
            .onChange(of: snapshots.count) { _, _ in reload() }
            .onChange(of: router.pendingDebtPlanID) { _, planID in
                guard let planID else { return }
                router.pendingDebtPlanID = nil
                pushedCard = PushedCard(planID: planID)
            }
            .navigationDestination(item: $pushedCard) { card in
                DebtDetailView(planID: card.planID)
            }
        }
    }

    private func reload() {
        balances = (try? appEnvironment.balanceService(context: modelContext).debtBalances()) ?? []
    }
}

struct DebtRow: View {
    let item: AccountBalanceService.DebtBalance

    private var subtitle: String {
        let apr = "\((item.debt.apr * 100) as NSDecimalNumber)% APR"
        let due = item.debt.dueDayOfMonth.map { " · due day \($0)" } ?? ""
        return "Card \(item.debt.planID) · \(apr)\(due)"
    }

    private var percentPaidText: String {
        "\((item.percentPaid * 100).rounded2) % paid"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.debt.displayName)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .accessibilityLabel(Text(verbatim: "\(item.debt.displayName), balance \(MoneyFormat.string(item.balance)), \(percentPaidText)"))
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
    @State private var showEdit = false

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
                Section("Numbers") {
                    LabeledContent("Original starting balance") {
                        MoneyText(amount: item.debt.startingBalance)
                    }
                    if let baselineToday {
                        LabeledContent("Baseline balance for today") {
                            MoneyText(amount: baselineToday)
                        }
                    }
                    LabeledContent("APR") {
                        Text("\((item.debt.apr * 100) as NSDecimalNumber)%")
                    }
                    LabeledContent("Minimum") {
                        if let minimum = item.debt.minimumAmount {
                            MoneyText(amount: minimum)
                        } else {
                            Text("Baseline estimate").foregroundStyle(.secondary)
                        }
                    }
                    if let dueDay = item.debt.dueDayOfMonth {
                        LabeledContent("Due day") { Text("\(dueDay)") }
                    }
                    LabeledContent("Avalanche priority") { Text("#\(item.debt.priority)") }
                    LabeledContent("Baseline payoff") {
                        Text(PlanContract.baselinePayoffDates[planID].map(DateMath.mediumString) ?? "—")
                    }
                    LabeledContent("Forecast payoff") {
                        Text(forecastPayoff.map(DateMath.mediumString) ?? "—")
                    }
                }
                Section {
                    NavigationLink {
                        AddPaymentView(preselectedPlanID: planID)
                    } label: {
                        Label("Add Payment", systemImage: "plus.circle")
                    }
                    NavigationLink {
                        BalanceUpdateView(preselectedPlanID: planID)
                    } label: {
                        Label("Update Balance", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        showEdit = true
                    } label: {
                        Label("Edit Card", systemImage: "pencil")
                    }
                }
                paymentHistorySection
                snapshotHistorySection
            } else {
                EmptyStateView(title: "Card not found", message: "This card is not part of the plan.")
            }
        }
        .navigationTitle(item?.debt.displayName ?? "Card \(planID)")
        .onAppear(perform: reload)
        .onChange(of: ledgerEntries.count) { _, _ in reload() }
        .onChange(of: allSnapshots.count) { _, _ in reload() }
        .sheet(isPresented: $showEdit, onDismiss: reload) {
            if let debt = item?.debt {
                DebtEditView(debt: debt)
            }
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
    }

    /// Baseline (Original Plan v1) balance for this card as of today.
    private func baselineBalanceToday() -> Decimal? {
        let today = DateMath.startOfDay(appEnvironment.dateProvider.now)
        guard let plan = (try? PlanSeeder.existingBaseline(context: modelContext)) ?? nil else { return nil }
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

/// Editing card metadata never touches seeded balances or APR history silently;
/// APR/minimum edits flow into the next reforecast. Fields edit local state so
/// Cancel discards cleanly.
struct DebtEditView: View {
    let debt: DebtAccount
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var notificationScheduler: NotificationScheduler

    @State private var nameText = ""
    @State private var lastFourText = ""
    @State private var aprText = ""
    @State private var minimumText = ""
    @State private var dueDayText = ""
    @State private var shiftRule: DueDateShiftRule = .exactDay
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Card") {
                    TextField("Nickname / issuer", text: $nameText)
                    TextField("Last four digits (optional)", text: $lastFourText)
                        .keyboardType(.numberPad)
                }
                Section("Terms") {
                    HStack {
                        Text("APR %")
                        Spacer()
                        TextField("APR", text: $aprText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                    }
                    HStack {
                        Text("Minimum payment")
                        Spacer()
                        TextField("Optional", text: $minimumText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                    }
                    HStack {
                        Text("Statement due day")
                        Spacer()
                        TextField("1–31", text: $dueDayText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                    }
                    if !dueDayText.isEmpty {
                        Picker("Weekend due dates", selection: $shiftRule) {
                            ForEach(DueDateShiftRule.allCases) { rule in
                                Text(rule.displayName).tag(rule)
                            }
                        }
                        Text("Days 29–31 fall on the month's last day in shorter months. Due dates only move off weekends if you pick a shift rule.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle("Edit card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                nameText = debt.displayName
                lastFourText = debt.lastFour ?? ""
                aprText = MoneyFormat.editingString(debt.apr * 100)
                minimumText = debt.minimumAmount.map(MoneyFormat.editingString) ?? ""
                dueDayText = debt.dueDayOfMonth.map(String.init) ?? ""
                shiftRule = debt.dueDateShiftRule
            }
        }
    }

    private func save() {
        // Validate everything before touching the model: these are live
        // SwiftData objects, so a half-applied edit followed by an early
        // return would persist changes the user never got to confirm.
        guard let aprPercent = MoneyFormat.parse(aprText), aprPercent >= 0, aprPercent <= 100 else {
            errorMessage = "Enter an APR between 0 and 100."
            return
        }
        var newMinimum: Decimal?
        if !minimumText.isEmpty {
            guard let minimum = MoneyFormat.parse(minimumText), !minimum.isNegative else {
                errorMessage = "The minimum payment cannot be negative."
                return
            }
            newMinimum = minimum
        }
        var newDueDay: Int?
        if !dueDayText.isEmpty {
            guard let day = Int(dueDayText), DueDateRule.validDays.contains(day) else {
                errorMessage = "Enter a due day between 1 and 31."
                return
            }
            newDueDay = day
        }

        let previousDueDay = debt.dueDayOfMonth
        debt.minimumAmount = newMinimum
        debt.dueDayOfMonth = newDueDay
        if newDueDay != previousDueDay {
            // V2-11 / §9: due-date edits are prospective and audited on the
            // item. The effective date stops past months being redrawn with
            // a due day that was not in force then.
            debt.appendDueDateAudit(DueDateRule.auditNote(
                field: "due day",
                from: previousDueDay,
                to: newDueDay,
                on: appEnvironment.dateProvider.now
            ))
            debt.dueDayEffectiveFrom = DateMath.startOfDay(appEnvironment.dateProvider.now)
        }
        debt.dueDateShiftRule = shiftRule
        let trimmedName = nameText.trimmingCharacters(in: .whitespaces)
        debt.displayName = trimmedName.isEmpty ? "Card \(debt.planID)" : trimmedName
        let digits = String(lastFourText.filter(\.isNumber).prefix(4))
        debt.lastFour = digits.isEmpty ? nil : digits
        debt.apr = aprPercent / 100
        debt.updatedAt = Date()
        do {
            try modelContext.save()
            _ = try? appEnvironment.reforecastService(context: modelContext).reforecast(trigger: .aprChange)
            // V2-11: the notification reschedule completes before the edit
            // screen is dismissed, so stable identifiers replace the old
            // due-date reminders with no stale fires and no duplicates.
            isSaving = true
            Task {
                await notificationScheduler.rescheduleAll(
                    context: modelContext,
                    dateProvider: appEnvironment.dateProvider
                )
                isSaving = false
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
