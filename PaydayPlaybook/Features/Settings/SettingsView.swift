import SwiftUI
import SwiftData
import UserNotifications

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var notificationScheduler: NotificationScheduler
    @Query private var allSettings: [AppSettings]
    @Query(sort: \PlanVersion.createdAt) private var planVersions: [PlanVersion]

    var body: some View {
        List {
            Section("Plan") {
                NavigationLink("Plan versions") { PlanVersionsView() }
                NavigationLink("Pay schedule & paycheck changes") { PayScheduleView() }
                NavigationLink("Allowance & reserves") { AllowanceReservesView() }
                NavigationLink("Original Plan v1 timeline") { OriginalPlanTimelineView() }
            }
            Section("Cards") {
                NavigationLink("Debt accounts") { SettingsDebtListView() }
            }
            Section("Notifications") {
                NavigationLink("Reminders") { NotificationSettingsView() }
            }
            Section("Security") {
                AppLockToggleRow()
            }
            Section("Data") {
                NavigationLink("Backup & export") { ExportView() }
                NavigationLink("Privacy") { PrivacyView() }
            }
            Section("About") {
                NavigationLink("Calculation assumptions") { AssumptionsView() }
                #if DEBUG
                NavigationLink("Plan verification (debug)") { PlanVerificationView() }
                #endif
            }
        }
        .navigationTitle("Settings")
    }
}

// MARK: - App lock

struct AppLockToggleRow: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appLock: AppLockService
    @Query private var allSettings: [AppSettings]
    @State private var unavailable = false

    var body: some View {
        Toggle(isOn: Binding(
            get: { allSettings.first?.appLockEnabled ?? false },
            set: { enable in
                guard let settings = allSettings.first else { return }
                if enable && !AppLockService.biometryAvailable() {
                    unavailable = true
                    return
                }
                settings.appLockEnabled = enable
                appLock.isEnabled = enable
                try? modelContext.save()
            }
        )) {
            Label("Face ID / app lock", systemImage: "faceid")
        }
        .alert("Device authentication unavailable", isPresented: $unavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Set up Face ID or a device passcode in iOS Settings first.")
        }
    }
}

// MARK: - Plan versions

struct PlanVersionsView: View {
    @Query(sort: \PlanVersion.createdAt) private var planVersions: [PlanVersion]

    var body: some View {
        List {
            ForEach(planVersions) { plan in
                NavigationLink {
                    PlanOverviewView(plan: plan)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(plan.name).font(.body.weight(.medium))
                            if plan.isOriginalBaseline {
                                Text("Immutable")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.blue)
                            }
                            if plan.isActive {
                                Text("Active")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.mint.opacity(0.2), in: Capsule())
                                    .foregroundStyle(.mint)
                            }
                        }
                        Text("Created \(DateMath.mediumString(plan.createdAt)) · calculation v\(plan.calculationVersion) · allowance \(MoneyFormat.string(plan.allowanceCap))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Plan versions")
    }
}

/// Read-only Original Plan v1 reference (F-06).
struct OriginalPlanTimelineView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var items: [PaydayPlanItem] = []

    var body: some View {
        List {
            Section {
                Text("The original baseline. It never changes — your actual record and reforecasts live alongside it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(items, id: \.sequenceNumber) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("#\(item.sequenceNumber) — \(DateMath.mediumString(item.date))")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("→ Card \(item.plannedTargetDebtID)")
                            .font(.subheadline)
                    }
                    Text("Income \(MoneyFormat.string(item.plannedIncome)) · keep \(MoneyFormat.string(item.plannedC1Keep)) · move \(MoneyFormat.string(item.plannedC2Transfer)) · cards \(MoneyFormat.string(item.plannedCardBudget))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Debt after \(MoneyFormat.string(item.plannedDebtAfter)) · ceiling \(MoneyFormat.string(item.plannedC1NoSpendCeiling))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle("Original Plan v1")
        .onAppear {
            guard let plan = (try? PlanSeeder.existingBaseline(context: modelContext)) ?? nil else { return }
            let planID = plan.id
            items = ((try? modelContext.fetch(
                FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
            )) ?? []).sorted { $0.sequenceNumber < $1.sequenceNumber }
        }
    }
}

// MARK: - Pay schedule

struct PayScheduleView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @Query(sort: \IncomeRule.effectiveDate) private var rules: [IncomeRule]

    @State private var newAmount: Decimal?
    @State private var newDate = Date()
    @State private var impact: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Current paycheck rules") {
                ForEach(rules) { rule in
                    LabeledContent(DateMath.mediumString(rule.effectiveDate)) {
                        MoneyText(amount: rule.netPaycheckAmount)
                    }
                }
            }
            Section("Add a future paycheck change") {
                MoneyField(label: "New take-home per check", value: $newAmount)
                DatePicker("Effective from", selection: $newDate, displayedComponents: .date)
                Button("Preview impact") { previewImpact() }
                if let impact {
                    Text(impact)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    applyRule()
                } label: {
                    Text("Apply to future dates")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(newAmount == nil)
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            Section {
                Text("Changes apply to future paydays only. Original Plan v1 keeps its seeded income history.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Pay schedule")
        .onAppear { newDate = appEnvironment.dateProvider.now }
    }

    private func previewImpact() {
        guard let newAmount, newAmount > 0 else {
            impact = "Enter a valid amount first."
            return
        }
        let before = try? appEnvironment.reforecastService(context: modelContext).latestForecast()
        impact = "Currently forecast to pay off on \((before?.projectedPayoffDate).map(DateMath.mediumString) ?? "Jun 24, 2027"). Applying \(MoneyFormat.string(newAmount)) from \(DateMath.mediumString(newDate)) will recalculate the forecast when saved."
    }

    private func applyRule() {
        guard let newAmount, newAmount > 0 else {
            errorMessage = "Enter a paycheck amount greater than zero."
            return
        }
        guard let plan = (try? PlanSeeder.existingBaseline(context: modelContext)) ?? nil else { return }
        modelContext.insert(IncomeRule(
            planVersionID: plan.id,
            effectiveDate: DateMath.startOfDay(newDate),
            netPaycheckAmount: newAmount
        ))
        do {
            try modelContext.save()
            _ = try? appEnvironment.reforecastService(context: modelContext).reforecast(trigger: .paycheckChange)
            self.newAmount = nil
            impact = "Saved. The forecast has been updated."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Allowance & reserves

/// Creates a new plan version rather than mutating Original Plan v1.
struct AllowanceReservesView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @Query(sort: \PlanVersion.createdAt) private var planVersions: [PlanVersion]

    @State private var allowance: Decimal?
    @State private var car: Decimal?
    @State private var train: Decimal?
    @State private var impact: String?
    @State private var errorMessage: String?

    private var activePlan: PlanVersion? {
        planVersions.first(where: \.isActive) ?? planVersions.first(where: \.isOriginalBaseline)
    }

    var body: some View {
        List {
            Section("Per-paycheck amounts") {
                MoneyField(label: "Allowance cap", value: $allowance)
                MoneyField(label: "Car reserve", value: $car)
                MoneyField(label: "Train reserve", value: $train)
            }
            Section {
                Button("Preview impact") { previewImpact() }
                if let impact {
                    Text(impact).font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    saveAsNewVersion()
                } label: {
                    Text("Save as New Plan Version")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            Section {
                Text("Original Plan v1 stays untouched and comparable. New amounts apply to future paydays through the reforecast.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Allowance & reserves")
        .onAppear {
            allowance = activePlan?.allowanceCap
            car = activePlan?.carReservePerCheck
            train = activePlan?.trainReservePerCheck
        }
    }

    private func previewImpact() {
        guard let allowance, let car, let train else {
            impact = "Fill in all three amounts first."
            return
        }
        guard activePlan != nil else { return }
        let income = (try? ReforecastService.currentIncome(
            context: modelContext,
            on: appEnvironment.dateProvider.now
        )) ?? PlanContract.raisedIncome
        let budget = income - allowance - car - train
        impact = "Future card budget per check becomes about \(MoneyFormat.string(max(budget, .zero))) at the current paycheck level. Saving creates a new plan version and reforecasts."
    }

    private func saveAsNewVersion() {
        guard let allowance, let car, let train,
              !allowance.isNegative, !car.isNegative, !train.isNegative else {
            errorMessage = "Amounts cannot be negative."
            return
        }
        guard let base = activePlan else { return }
        let copy = PlanVersion(
            name: "Plan v\(planVersions.count + 1)",
            createdAt: appEnvironment.dateProvider.now,
            isOriginalBaseline: false,
            isActive: true,
            firstPayday: base.firstPayday,
            payFrequencyDays: base.payFrequencyDays,
            startingChecking1: base.startingChecking1,
            protectedBuffer: base.protectedBuffer,
            allowanceCap: allowance,
            firstCheckBufferAdd: base.firstCheckBufferAdd,
            carReservePerCheck: car,
            trainReservePerCheck: train,
            calculationVersion: base.calculationVersion,
            timeZoneID: base.timeZoneID,
            avalancheOrderRaw: base.avalancheOrderRaw,
            baselinePayoffDate: base.baselinePayoffDate,
            baselineModeledInterest: base.baselineModeledInterest,
            baselineNoSpendCeiling: base.baselineNoSpendCeiling
        )
        for plan in planVersions where !plan.isOriginalBaseline {
            plan.isActive = false
        }
        // The original stays flagged baseline; active flag moves to the copy.
        for plan in planVersions where plan.isOriginalBaseline {
            plan.isActive = false
        }
        modelContext.insert(copy)
        do {
            try modelContext.save()
            _ = try? appEnvironment.reforecastService(context: modelContext).reforecast(trigger: .planEdit)
            impact = "Saved as \(copy.name). The forecast now uses the new amounts."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Debts list (settings)

struct SettingsDebtListView: View {
    @Query(sort: \DebtAccount.priority) private var debts: [DebtAccount]
    @State private var editing: DebtAccount?

    var body: some View {
        List {
            ForEach(debts) { debt in
                Button {
                    editing = debt
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(debt.displayName) (\(debt.planID))")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text("\((debt.apr * 100) as NSDecimalNumber)% APR · priority #\(debt.priority)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Debt accounts")
        .sheet(item: $editing) { debt in
            DebtEditView(debt: debt)
        }
    }
}

// MARK: - Notifications

struct NotificationSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var notificationScheduler: NotificationScheduler
    @Query private var preferences: [NotificationPreference]

    var body: some View {
        List {
            switch notificationScheduler.authorizationStatus {
            case .denied:
                Section {
                    Label("Notifications are turned off for Payday Playbook in iOS Settings. The app still works fully without them.", systemImage: "bell.slash")
                        .font(.subheadline)
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            case .notDetermined:
                Section {
                    Button {
                        Task {
                            _ = await notificationScheduler.requestAuthorization()
                            await reschedule()
                        }
                    } label: {
                        Label("Enable notifications", systemImage: "bell.badge")
                    }
                }
            default:
                EmptyView()
            }

            ForEach(preferences.sorted { $0.typeRaw < $1.typeRaw }) { preference in
                NotificationPreferenceRow(preference: preference, onChange: {
                    Task { await reschedule() }
                })
            }

            Section {
                Text("Lock-screen content stays generic (“Your payday check-in is ready”) unless detailed previews are enabled per reminder.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Reminders")
        .task {
            await notificationScheduler.refreshAuthorizationStatus()
        }
    }

    private func reschedule() async {
        try? modelContext.save()
        await notificationScheduler.rescheduleAll(
            context: modelContext,
            dateProvider: appEnvironment.dateProvider
        )
    }
}

struct NotificationPreferenceRow: View {
    @Bindable var preference: NotificationPreference
    var onChange: () -> Void

    var body: some View {
        Section(preference.type.displayName) {
            Toggle("Enabled", isOn: Binding(
                get: { preference.enabled },
                set: { preference.enabled = $0; onChange() }
            ))
            if preference.enabled {
                Stepper(
                    "Time: \(timeText)",
                    value: Binding(
                        get: { preference.hour },
                        set: { preference.hour = min(max($0, 0), 23); onChange() }
                    ),
                    in: 0...23
                )
                if preference.type == .cardDueSoon || preference.type == .milestoneApproaching {
                    Stepper(
                        preference.type == .cardDueSoon
                            ? "Lead days: \(preference.leadDays)"
                            : "Paydays of notice: \(preference.leadDays)",
                        value: Binding(
                            get: { preference.leadDays },
                            set: { preference.leadDays = min(max($0, 1), 14); onChange() }
                        ),
                        in: 1...14
                    )
                }
                Toggle("Detailed lock-screen content", isOn: Binding(
                    get: { preference.detailedLockScreenContent },
                    set: { preference.detailedLockScreenContent = $0; onChange() }
                ))
            }
        }
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        var components = DateComponents()
        components.hour = preference.hour
        components.minute = preference.minute
        let date = Calendar.current.date(from: components) ?? Date()
        return formatter.string(from: date)
    }
}

// MARK: - Export / restore

struct ExportView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment

    @State private var jsonURL: URL?
    @State private var csvURLs: [URL] = []
    @State private var errorMessage: String?
    @State private var showImporter = false
    @State private var pendingBackup: ExportService.Backup?
    @State private var pendingSummary: ExportService.RestoreSummary?
    @State private var restoreDone = false

    var body: some View {
        List {
            Section("Backup") {
                Button {
                    do {
                        jsonURL = try ExportService.exportJSON(context: modelContext)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } label: {
                    Label("Create JSON backup", systemImage: "doc.badge.arrow.up")
                }
                if let jsonURL {
                    ShareLink(item: jsonURL) {
                        Label("Share \(jsonURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section("CSV exports") {
                Button {
                    do {
                        csvURLs = try ExportService.exportCSVs(context: modelContext)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } label: {
                    Label("Create CSV files", systemImage: "tablecells")
                }
                ForEach(csvURLs, id: \.self) { url in
                    ShareLink(item: url) {
                        Label(url.lastPathComponent, systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section("Restore") {
                Button {
                    showImporter = true
                } label: {
                    Label("Restore from JSON backup", systemImage: "doc.badge.arrow.down")
                }
                Text("Restoring replaces all current data. A rollback backup is created automatically first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if restoreDone {
                Section {
                    Label("Restore complete.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.mint)
                }
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Backup & export")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                readBackup(url)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            restoreSummaryText,
            isPresented: Binding(
                get: { pendingBackup != nil },
                set: { if !$0 { pendingBackup = nil; pendingSummary = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Replace all data", role: .destructive) { performRestore() }
            Button("Cancel", role: .cancel) { pendingBackup = nil; pendingSummary = nil }
        }
    }

    private var restoreSummaryText: String {
        guard let summary = pendingSummary else { return "" }
        return "Backup from \(DateMath.mediumString(summary.exportedAt)): \(summary.planVersions) plan version(s), \(summary.debts) debts, \(summary.paydays) paydays, \(summary.checkIns) check-ins, \(summary.ledgerEntries) ledger entries. Replace everything currently in the app?"
    }

    private func readBackup(_ url: URL) {
        do {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let backup = try ExportService.readBackup(from: data)
            pendingBackup = backup
            pendingSummary = ExportService.summarize(backup)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performRestore() {
        guard let backup = pendingBackup else { return }
        do {
            // Local rollback backup before the destructive replace.
            _ = try ExportService.exportJSON(
                context: modelContext,
                to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            )
            try ExportService.restore(backup, context: modelContext)
            restoreDone = true
            pendingBackup = nil
            pendingSummary = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Privacy

struct PrivacyView: View {
    var body: some View {
        List {
            Section("What stays on this iPhone") {
                Text("Your plan, debts, balances, payments, check-ins, notes, and settings are stored only in the app's local database on this device. There is no account, server, sync, analytics, or advertising.")
            }
            Section("What is never stored") {
                Label("Full card numbers", systemImage: "xmark.circle")
                Label("CVVs or PINs", systemImage: "xmark.circle")
                Label("Bank or issuer logins", systemImage: "xmark.circle")
                Label("Social Security numbers", systemImage: "xmark.circle")
            }
            Section("What leaves the device") {
                Text("Only files you explicitly export through the share sheet: JSON backups and CSV exports. You choose where they go.")
            }
            Section("Protection") {
                Text("Data files use iOS file protection and are encrypted while the device is locked. Enable the optional Face ID lock for an extra gate when reopening the app.")
            }
        }
        .navigationTitle("Privacy")
    }
}

// MARK: - Assumptions

struct AssumptionsView: View {
    var body: some View {
        List {
            Section("How projections work") {
                Text("Interest is estimated every 14 days as balance × APR × 14 ÷ 365, settled at each paycheck.")
                Text("Estimated minimums are the greater of $17.50 or 0.5% of the post-interest balance, capped at the remaining balance, and are included inside the card budget.")
                Text("All extra card money goes to the highest-APR active card (avalanche order B → D → A → F → C → E). When a card hits $0, capacity rolls to the next card in the same check.")
                Text("Your entered balances and minimums always override estimates for the actual track and the reforecast.")
            }
            Section("Important") {
                Text("Real issuer interest, posting dates, and minimums will differ. Projections are estimates, not guarantees.")
            }
        }
        .navigationTitle("Assumptions")
    }
}

// MARK: - Plan verification (debug)

#if DEBUG
/// Debug-only verification screen (MVP layout §8 manual data verification).
struct PlanVerificationView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var lines: [String] = []

    var body: some View {
        List {
            ForEach(lines, id: \.self) { line in
                Text(line).font(.footnote.monospaced())
            }
        }
        .navigationTitle("Plan verification")
        .onAppear(perform: verify)
    }

    private func verify() {
        var output: [String] = []
        do {
            guard let plan = try PlanSeeder.existingBaseline(context: modelContext) else {
                lines = ["No baseline plan found."]
                return
            }
            let planID = plan.id
            let debts = try modelContext.fetch(FetchDescriptor<DebtAccount>())
            let items = try modelContext.fetch(
                FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
            ).sorted { $0.sequenceNumber < $1.sequenceNumber }
            let milestones = try modelContext.fetch(FetchDescriptor<Milestone>())

            output.append("Plan: \(plan.name)")
            output.append("Debts: \(debts.count)")
            output.append("Paydays: \(items.count)")
            let total = debts.reduce(Decimal.zero) { $0 + $1.startingBalance }
            output.append("Original total: \(MoneyFormat.string(total))")
            for milestone in milestones where milestone.type == .cardPaidOff {
                output.append("\(milestone.title): \((milestone.baselineDate).map(DateMath.mediumString) ?? "—")")
            }
            output.append("Final payoff: \((items.last?.date).map(DateMath.mediumString) ?? "—")")
            output.append("Modeled interest: \(MoneyFormat.string(plan.baselineModeledInterest))")
            output.append("Final no-spend ceiling: \(MoneyFormat.string(items.last?.plannedC1NoSpendCeiling ?? 0))")

            let engineResult = DebtCalculationEngine.baselineProjection()
            output.append("— Engine check —")
            output.append("Engine payoff: \((engineResult.payoffDate).map(DateMath.mediumString) ?? "—") after \(engineResult.paychecksUsed) checks")
            output.append("Engine interest: \(MoneyFormat.string(engineResult.totalInterest))")
        } catch {
            output.append("Verification failed: \(error.localizedDescription)")
        }
        lines = output
    }
}
#endif
