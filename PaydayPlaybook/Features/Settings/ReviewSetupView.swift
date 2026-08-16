import SwiftUI
import SwiftData

/// Settings → "Review setup": the upgrade path for installs that already
/// have a plan (V2-16). A migrated user never repeats onboarding — this
/// screen lists only what v0.2.0 newly knows how to ask about and that their
/// store doesn't answer yet, each row opening the matching editor.
///
/// Nothing here regenerates or edits a plan. Answers refine future forecasts
/// and displays; the immutable baseline, every check-in, and every ledger
/// entry are untouched.
struct ReviewSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var accounts: [CashAccount]
    @Query private var debts: [DebtAccount]
    @Query private var obligations: [RecurringObligation]
    @Query private var profiles: [UserGoalProfile]

    @State private var editingDebt: DebtEditorTarget?
    @State private var editingAccount: AccountEditorTarget?
    @State private var editingObligation: ObligationEditorTarget?
    @State private var showGoals = false
    @State private var showIncome = false

    /// Recomputed on every store change: the queries above exist so that
    /// resolving an item makes its row disappear immediately.
    private var gaps: [SetupGap] {
        _ = (accounts.count, debts.count, obligations.count, profiles.count)
        return (try? SetupCompletenessService(context: modelContext).gaps()) ?? []
    }

    var body: some View {
        List {
            if gaps.isEmpty {
                Section {
                    Label("Everything's filled in", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.mint)
                        .accessibilityIdentifier("reviewSetup.complete")
                    Text("Your plan, history, and reminders are unchanged.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text("This version can use a few details your setup doesn't have yet. Each one is optional — your plan and history stay exactly as they are.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(groupedGaps, id: \.destination) { group in
                    Section(Self.sectionTitle(group.destination)) {
                        ForEach(group.gaps) { gap in
                            Button {
                                open(gap)
                            } label: {
                                GapRow(gap: gap)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("reviewSetup.gap.\(gap.kind.rawValue)")
                        }
                        // Each row above opens the exact item's editor, which
                        // is the shortest route to fixing one thing. This is
                        // the route to the whole picture (§8.8).
                        if group.destination == .debts || group.destination == .obligations {
                            NavigationLink("See all bills & debts") {
                                SettingsBillsAndDebtsView()
                            }
                            .font(.footnote)
                            .accessibilityIdentifier("reviewSetup.billsAndDebts")
                        }
                    }
                }
            }
        }
        .navigationTitle("Review setup")
        .sheet(item: $editingDebt) { DebtEditorView(target: $0) }
        .sheet(item: $editingAccount) { AccountEditorView(target: $0) }
        .sheet(item: $editingObligation) { ObligationEditorView(target: $0) }
        .sheet(isPresented: $showGoals) { GoalSettingsSheet() }
        .sheet(isPresented: $showIncome) { IncomeSettingsSheet() }
    }

    private struct GapGroup {
        let destination: SetupGap.Destination
        let gaps: [SetupGap]
    }

    private var groupedGaps: [GapGroup] {
        let order: [SetupGap.Destination] = [.goals, .accounts, .income, .debts, .obligations]
        return order.compactMap { destination in
            let matching = gaps.filter { $0.destination == destination }
            return matching.isEmpty ? nil : GapGroup(destination: destination, gaps: matching)
        }
    }

    static func sectionTitle(_ destination: SetupGap.Destination) -> String {
        switch destination {
        case .goals: return "Goal & guardrails"
        case .accounts: return "Accounts"
        case .income: return "Income"
        case .debts: return "Debts"
        case .obligations: return "Bills"
        }
    }

    private func open(_ gap: SetupGap) {
        switch gap.destination {
        case .goals:
            showGoals = true
        case .accounts:
            if let id = gap.subjectID, let account = accounts.first(where: { $0.id == id }) {
                editingAccount = .existing(account)
            } else {
                editingAccount = .new
            }
        case .debts:
            if let id = gap.subjectID, let debt = debts.first(where: { $0.id == id }) {
                editingDebt = .existing(debt)
            }
        case .obligations:
            if let id = gap.subjectID, let obligation = obligations.first(where: { $0.id == id }) {
                editingObligation = .existing(obligation)
            } else {
                editingObligation = .new(nil)
            }
        case .income:
            showIncome = true
        }
    }
}

private struct GapRow: View {
    let gap: SetupGap

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: gap.isBlocker ? "exclamationmark.circle" : "questionmark.circle")
                .foregroundStyle(gap.isBlocker ? .orange : Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(gap.title)
                    .font(.body)
                Text(gap.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(gap.title). \(gap.detail)")
        .accessibilityHint("Opens the editor")
    }
}

// MARK: - Income cadence editor for existing users

/// Cadence, anchor payday, and take-home for an install whose income rows
/// came from migration. Editing the live schedule never rewrites a plan —
/// each `PlanVersion` froze its own income timeline at generation.
struct IncomeSettingsSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @Query private var accounts: [CashAccount]

    @State private var takeHome: Decimal?
    @State private var nextPayday = Date()
    @State private var cadence: PayCadence = .biweekly
    @State private var monthlyDay: Int? = 1
    @State private var semimonthlyFirstDay: Int? = 1
    @State private var semimonthlySecondDay: Int? = 15
    @State private var destinationAccountID: UUID?
    @State private var loaded = false
    @State private var error: String?

    private var activeAccounts: [CashAccount] {
        accounts.filter { !$0.isArchived }
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SetupMoneyField(
                        title: "Take-home per paycheck",
                        value: $takeHome,
                        requirement: .required
                    )
                    SetupField(title: "How often", requirement: .required) {
                        Picker("Pay cadence", selection: $cadence) {
                            ForEach(PayCadence.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("incomeSettings.cadence")
                    }
                    if cadence == .monthly {
                        SetupDayField(
                            title: "Payday", day: $monthlyDay,
                            requirement: .required, allowsNone: false
                        )
                    }
                    if cadence == .semimonthly {
                        SetupDayField(
                            title: "First payday", day: $semimonthlyFirstDay,
                            requirement: .required, allowsNone: false
                        )
                        SetupDayField(
                            title: "Second payday", day: $semimonthlySecondDay,
                            requirement: .required,
                            error: semimonthlyFirstDay == semimonthlySecondDay
                                ? "Twice-a-month paydays need two different days." : nil,
                            allowsNone: false
                        )
                    }
                    SetupField(title: "Next payday", requirement: .required) {
                        DatePicker("Next payday", selection: $nextPayday, displayedComponents: .date)
                            .frame(minHeight: 44)
                    }
                    if activeAccounts.count > 1 {
                        SetupField(title: "Where it lands", requirement: .required) {
                            Picker("Deposit account", selection: $destinationAccountID) {
                                ForEach(activeAccounts) { account in
                                    Text(account.name).tag(UUID?.some(account.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(minHeight: 44)
                        }
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                .padding()
            }
            .navigationTitle("Income")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled((takeHome ?? 0) <= 0)
                        .accessibilityIdentifier("incomeSettings.save")
                }
            }
            .task {
                guard !loaded else { return }
                loaded = true
                load()
            }
        }
    }

    private func load() {
        guard let schedule = try? IncomeRepository(context: modelContext).activeSchedule() else {
            nextPayday = DateMath.startOfDay(appEnvironment.dateProvider.now)
            return
        }
        takeHome = schedule.baseTakeHome > 0 ? schedule.baseTakeHome : nil
        nextPayday = schedule.anchorPayday
        cadence = schedule.cadence
        monthlyDay = schedule.monthlyDay ?? 1
        semimonthlyFirstDay = schedule.semimonthlyFirstDay ?? 1
        semimonthlySecondDay = schedule.semimonthlySecondDay ?? 15
        destinationAccountID = schedule.destinationAccountID
    }

    private func save() {
        do {
            try IncomeRepository(context: modelContext).save(
                cadence: cadence,
                anchorPayday: nextPayday,
                takeHome: takeHome ?? .zero,
                monthlyDay: monthlyDay,
                semimonthlyFirstDay: semimonthlyFirstDay,
                semimonthlySecondDay: semimonthlySecondDay,
                destinationAccountID: destinationAccountID,
                now: appEnvironment.dateProvider.now
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Accounts and bills, post-onboarding

/// Accounts list for Settings. Accounts are archived here, not deleted:
/// after onboarding they carry ledger history (§4.8).
struct SettingsAccountsView: View {
    @Query private var accounts: [CashAccount]
    @Environment(\.modelContext) private var modelContext
    @State private var editing: AccountEditorTarget?

    private var activeAccounts: [CashAccount] {
        accounts.filter { !$0.isArchived }
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }

    private var archivedAccounts: [CashAccount] {
        accounts.filter(\.isArchived).sorted { $0.name < $1.name }
    }

    var body: some View {
        List {
            Section {
                ForEach(activeAccounts) { account in
                    Button {
                        editing = .existing(account)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(account.name)
                                Spacer()
                                MoneyText(amount: account.currentBalance)
                            }
                            if account.isDefaultIncome {
                                Text("Gets your paycheck")
                                    .font(.caption)
                                    .foregroundStyle(.mint)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    editing = .new
                } label: {
                    Label("Add an account", systemImage: "plus.circle")
                        .frame(minHeight: 44)
                }
            }
            if !archivedAccounts.isEmpty {
                Section("Archived") {
                    ForEach(archivedAccounts) { account in
                        Text(account.name)
                            .foregroundStyle(.secondary)
                            .frame(minHeight: 44)
                    }
                }
            }
        }
        .navigationTitle("Accounts")
        .sheet(item: $editing) { AccountEditorView(target: $0) }
    }
}

/// Essential bills list for Settings.
struct SettingsObligationsView: View {
    @Query private var obligations: [RecurringObligation]
    @State private var editing: ObligationEditorTarget?

    private var active: [RecurringObligation] {
        obligations.filter { !$0.isArchived }
            .sorted { ($0.createdAt, $0.name) < ($1.createdAt, $1.name) }
    }

    var body: some View {
        List {
            Section {
                ForEach(active) { obligation in
                    Button {
                        editing = .existing(obligation)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(obligation.name)
                                Text(obligation.cadence.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            MoneyText(amount: obligation.amount)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    editing = .new(nil)
                } label: {
                    Label("Add a bill", systemImage: "plus.circle")
                        .frame(minHeight: 44)
                }
            }
        }
        .navigationTitle("Essential bills")
        .sheet(item: $editing) { ObligationEditorView(target: $0) }
    }
}

// MARK: - Goal editor for existing users

/// The goal step's questions, reachable after onboarding. Editing these
/// changes copy and future insights only — never a generated plan's math.
struct GoalSettingsSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment

    @State private var goalText = ""
    @State private var hasTargetDate = false
    @State private var targetDate = Date()
    @State private var posture: PayoffPosture = .steady
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("What are you working toward?") {
                    TextField("Optional goal", text: $goalText)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("goalSettings.text")
                    Toggle("Set a target date", isOn: $hasTargetDate)
                        .frame(minHeight: 44)
                    if hasTargetDate {
                        DatePicker("Target date", selection: $targetDate, displayedComponents: .date)
                            .frame(minHeight: 44)
                    }
                }
                Section("Payoff posture") {
                    Picker("Posture", selection: $posture) {
                        ForEach(PayoffPosture.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Text("Posture shapes the app's wording and its suggestions. It never changes a plan that already exists.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Your goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .accessibilityIdentifier("goalSettings.save")
                }
            }
            .task {
                guard !loaded else { return }
                loaded = true
                load()
            }
        }
    }

    private func load() {
        guard let profile = try? GoalProfileRepository(context: modelContext)
            .profile(now: appEnvironment.dateProvider.now) else { return }
        goalText = profile.goalText ?? ""
        hasTargetDate = profile.targetDebtFreeDate != nil
        targetDate = profile.targetDebtFreeDate ?? appEnvironment.dateProvider.now
        posture = profile.posture
    }

    /// Saves the goal fields only: the floor and allowance keep their stored
    /// values, since changing those follows the F-13 plan-version rule and
    /// belongs to the allowance editor, not here.
    private func save() {
        do {
            let repository = GoalProfileRepository(context: modelContext)
            let profile = try repository.profile(now: appEnvironment.dateProvider.now)
            try repository.save(
                goalText: goalText,
                targetDebtFreeDate: hasTargetDate ? targetDate : nil,
                posture: posture,
                protectedFloor: profile.protectedFloor,
                allowanceCap: profile.allowanceCap,
                now: appEnvironment.dateProvider.now
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
