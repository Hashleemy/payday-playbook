import SwiftUI
import SwiftData

/// Step 6 — income and paydays (§4.4, V2-06). Take-home per check, the next
/// payday, the cadence, where it lands, and any raise already scheduled.
struct IncomeStepView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @Query private var accounts: [CashAccount]

    let onContinue: () -> Void
    let onBack: () -> Void

    @State private var takeHome: Decimal?
    @State private var nextPayday = Date()
    @State private var cadence: PayCadence = .biweekly
    @State private var monthlyDay: Int? = 1
    @State private var semimonthlyFirstDay: Int? = 1
    @State private var semimonthlySecondDay: Int? = 15
    @State private var destinationAccountID: UUID?
    @State private var changes: [IncomeChange] = []
    @State private var showChangeEditor = false
    @State private var error: String?
    @State private var loaded = false

    private var activeAccounts: [CashAccount] {
        accounts.filter { !$0.isArchived }
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }

    var body: some View {
        OnboardingScaffold(
            title: "When do you get paid?",
            subtitle: "Take-home — what actually lands in your account, after taxes and deductions.",
            continueEnabled: isValid,
            continueIdentifier: "onboarding.incomeContinue",
            onBack: onBack,
            onContinue: save
        ) {
            SetupMoneyField(
                title: "Take-home per paycheck",
                value: $takeHome,
                requirement: .required,
                help: "The deposit amount, not your salary.",
                error: takeHomeError
            )
            .accessibilityIdentifier("income.takeHome")

            SetupField(
                title: "How often",
                requirement: .required,
                help: cadenceHelp
            ) {
                Picker("Pay cadence", selection: $cadence) {
                    ForEach(PayCadence.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(minHeight: 44)
                .accessibilityIdentifier("income.cadence")
            }

            if cadence == .monthly {
                SetupDayField(
                    title: "Payday",
                    day: $monthlyDay,
                    requirement: .required,
                    help: "Pick 31 for \"the last day of the month\" — shorter months adjust automatically.",
                    allowsNone: false
                )
                .accessibilityIdentifier("income.monthlyDay")
            }

            if cadence == .semimonthly {
                SetupDayField(
                    title: "First payday",
                    day: $semimonthlyFirstDay,
                    requirement: .required,
                    allowsNone: false
                )
                SetupDayField(
                    title: "Second payday",
                    day: $semimonthlySecondDay,
                    requirement: .required,
                    help: "Pick 31 for \"the last day of the month\".",
                    error: semimonthlyError,
                    allowsNone: false
                )
            }

            SetupField(
                title: "Next payday",
                requirement: .required,
                help: "The next one coming up. Everything after it is generated from your cadence.",
                error: paydayError
            ) {
                DatePicker(
                    "Next payday",
                    selection: $nextPayday,
                    displayedComponents: .date
                )
                .frame(minHeight: 44)
                .accessibilityIdentifier("income.nextPayday")
            }

            if activeAccounts.count > 1 {
                SetupField(
                    title: "Where it lands",
                    requirement: .required,
                    help: "The account your paycheck is deposited into."
                ) {
                    Picker("Deposit account", selection: $destinationAccountID) {
                        ForEach(activeAccounts) { account in
                            Text(account.name).tag(UUID?.some(account.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("income.destination")
                }
            }

            futureChangesSection

            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showChangeEditor) {
            IncomeChangeEditorView { date, amount in
                addChange(effectiveDate: date, amount: amount)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            load()
        }
    }

    private var futureChangesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SetupField(
                title: "A raise or change coming?",
                requirement: .optional,
                help: "If you already know your pay changes on a date, add it — the plan uses the new amount from that day forward."
            ) {
                VStack(spacing: 8) {
                    ForEach(changes) { change in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(MoneyFormat.string(change.newTakeHome))
                                    .font(.body.weight(.medium))
                                Text("from \(DateMath.mediumString(change.effectiveDate))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button(role: .destructive) {
                                removeChange(change)
                            } label: {
                                Image(systemName: "trash")
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Remove the change to \(MoneyFormat.string(change.newTakeHome))")
                        }
                        .padding(10)
                        .background(
                            Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .accessibilityElement(children: .contain)
                    }

                    Button {
                        showChangeEditor = true
                    } label: {
                        Label("Add a future change", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("income.addChange")
                }
            }
        }
    }

    private var cadenceHelp: String {
        switch cadence {
        case .weekly: return "52 paychecks a year."
        case .biweekly: return "Every two weeks — 26 paychecks a year."
        case .semimonthly: return "Twice a month on set dates — 24 paychecks a year."
        case .monthly: return "12 paychecks a year."
        }
    }

    // MARK: - Validation

    private var takeHomeError: String? {
        guard let takeHome else { return nil }
        if takeHome < 0 { return "Take-home can't be negative." }
        if takeHome == 0 { return "Take-home needs to be more than zero." }
        return nil
    }

    private var semimonthlyError: String? {
        guard cadence == .semimonthly else { return nil }
        return semimonthlyFirstDay == semimonthlySecondDay
            ? "Twice-a-month paydays need two different days."
            : nil
    }

    private var paydayError: String? {
        let today = DateMath.startOfDay(appEnvironment.dateProvider.now)
        return DateMath.startOfDay(nextPayday) < today
            ? "That date has passed. Pick the next payday coming up."
            : nil
    }

    private var isValid: Bool {
        guard let takeHome, takeHome > 0 else { return false }
        guard paydayError == nil, semimonthlyError == nil else { return false }
        if cadence == .monthly, monthlyDay == nil { return false }
        if cadence == .semimonthly, semimonthlyFirstDay == nil || semimonthlySecondDay == nil {
            return false
        }
        return true
    }

    // MARK: - Persistence

    private func load() {
        let repository = IncomeRepository(context: modelContext)
        let defaultAccount = try? CashAccountRepository(context: modelContext).defaultIncomeAccount()
        guard let schedule = try? repository.activeSchedule() else {
            nextPayday = DateMath.startOfDay(appEnvironment.dateProvider.now)
            destinationAccountID = defaultAccount?.id ?? activeAccounts.first?.id
            return
        }
        takeHome = schedule.baseTakeHome > 0 ? schedule.baseTakeHome : nil
        nextPayday = schedule.anchorPayday
        cadence = schedule.cadence
        monthlyDay = schedule.monthlyDay ?? 1
        semimonthlyFirstDay = schedule.semimonthlyFirstDay ?? 1
        semimonthlySecondDay = schedule.semimonthlySecondDay ?? 15
        destinationAccountID = schedule.destinationAccountID ?? defaultAccount?.id
        changes = (try? repository.changes(for: schedule)) ?? []
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
            error = nil
            onContinue()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Future changes need a saved schedule to hang from, so the schedule is
    /// written first — the same rows the Continue button would have written.
    private func addChange(effectiveDate: Date, amount: Decimal) {
        do {
            let repository = IncomeRepository(context: modelContext)
            let schedule = try repository.save(
                cadence: cadence,
                anchorPayday: nextPayday,
                takeHome: takeHome ?? .zero,
                monthlyDay: monthlyDay,
                semimonthlyFirstDay: semimonthlyFirstDay,
                semimonthlySecondDay: semimonthlySecondDay,
                destinationAccountID: destinationAccountID,
                now: appEnvironment.dateProvider.now
            )
            try repository.addChange(
                to: schedule, effectiveDate: effectiveDate, newTakeHome: amount,
                now: appEnvironment.dateProvider.now
            )
            changes = (try? repository.changes(for: schedule)) ?? changes
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func removeChange(_ change: IncomeChange) {
        do {
            let repository = IncomeRepository(context: modelContext)
            try repository.delete(change)
            if let schedule = try repository.activeSchedule() {
                changes = (try? repository.changes(for: schedule)) ?? []
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Future income change editor

struct IncomeChangeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (Date, Decimal) -> Void

    @State private var effectiveDate = Date()
    @State private var amount: Decimal?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SetupMoneyField(
                        title: "New take-home per paycheck",
                        value: $amount,
                        requirement: .required,
                        help: "What each check will be after the change.",
                        error: (amount ?? 1) <= 0 && amount != nil
                            ? "The new amount needs to be more than zero." : nil
                    )
                    .accessibilityIdentifier("incomeChange.amount")

                    SetupField(
                        title: "Starting when",
                        requirement: .required,
                        help: "The first payday the new amount applies to."
                    ) {
                        DatePicker("Effective date", selection: $effectiveDate, displayedComponents: .date)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("incomeChange.date")
                    }
                }
                .padding()
            }
            .navigationTitle("Income change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let amount, amount > 0 {
                            onSave(effectiveDate, amount)
                            dismiss()
                        }
                    }
                    .disabled((amount ?? 0) <= 0)
                    .accessibilityIdentifier("incomeChange.save")
                }
            }
        }
    }
}
