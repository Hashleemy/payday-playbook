import SwiftUI
import SwiftData

/// The shared bill editor, hosted by the consolidated Bills & Debts page
/// (V3-08) and the Settings upgrade checklist.
///
/// The `ObligationsStepView` that used to live here — the v0.2.0 standalone
/// obligations step — was retired in v0.4.0: `.obligations` left the
/// onboarding `flowOrder` in v0.3.0 (V3-08), nothing routed to the view any
/// more, and keeping an unreachable second surface for the same rows invites
/// drift. Its `OnboardingStep` raw value stays persistable and its resume
/// mapping stays tested — stored progress is data, the screen was not.

// MARK: - Editor

enum ObligationEditorTarget: Identifiable {
    /// A blank editor, optionally pre-named from a starter chip.
    case new(String?)
    case existing(RecurringObligation)

    var id: String {
        switch self {
        case .new(let name): return "new-\(name ?? "")"
        case .existing(let obligation): return obligation.id.uuidString
        }
    }

    var obligation: RecurringObligation? {
        switch self {
        case .new: return nil
        case .existing(let obligation): return obligation
        }
    }

    var suggestedName: String {
        switch self {
        case .new(let name): return name ?? ""
        case .existing(let obligation): return obligation.name
        }
    }
}

struct ObligationEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @Query private var accounts: [CashAccount]

    let target: ObligationEditorTarget
    var allowsDelete = false

    @State private var name = ""
    @State private var amount: Decimal?
    @State private var cadence: ObligationCadence = .monthly
    @State private var dueDay: Int?
    @State private var accountID: UUID?
    @State private var isEssential = true
    @State private var error: String?
    @State private var loaded = false

    private var activeAccounts: [CashAccount] {
        accounts.filter { !$0.isArchived }
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SetupField(title: "What is it?", requirement: .required) {
                        TextField("Rent", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("obligation.name")
                    }

                    SetupMoneyField(
                        title: "Amount",
                        value: $amount,
                        requirement: .required,
                        help: "What you pay each time, not per month, if they differ.",
                        error: amountError,
                        fieldIdentifier: "obligation.amount"
                    )

                    SetupField(title: "How often", requirement: .required) {
                        Picker("Cadence", selection: $cadence) {
                            ForEach(ObligationCadence.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("obligation.cadence")
                    }

                    SetupDayField(
                        title: "Due day",
                        day: $dueDay,
                        requirement: .optional,
                        help: "Shows on the calendar and can remind you. The money is set aside evenly either way."
                    )

                    if activeAccounts.count > 1 {
                        SetupField(
                            title: "Paid from",
                            requirement: .optional,
                            help: "Usually a reserves account."
                        ) {
                            Picker("Source account", selection: $accountID) {
                                Text("Not set").tag(UUID?.none)
                                ForEach(activeAccounts) { account in
                                    Text(account.name).tag(UUID?.some(account.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("obligation.account")
                        }
                    }

                    SetupField(
                        title: "Is this essential?",
                        requirement: .required,
                        help: "Essential bills are reserved from every paycheck before any debt money. Anything else is just recorded for your own picture."
                    ) {
                        Toggle("Must be paid", isOn: $isEssential)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("obligation.essential")
                    }

                    if let amount, amount > 0 {
                        SetupSummaryRow(label: "Per paycheck", value: MoneyFormat.string(previewReserve(amount)))
                            .font(.subheadline.weight(.medium))
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    if let obligation = target.obligation {
                        // Archive keeps the row and its history; delete is for
                        // something entered by mistake. Both are offered
                        // because they answer different questions — "I don't
                        // pay this any more" and "this shouldn't be here".
                        Button {
                            archive(obligation)
                        } label: {
                            Label("I don't pay this any more", systemImage: "archivebox")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("obligation.archive")
                        .accessibilityHint("Archives the bill. Its history stays, and the plan stops reserving for it.")

                        if allowsDelete {
                            Button(role: .destructive) {
                                delete(obligation)
                            } label: {
                                Label("Remove this bill", systemImage: "trash")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("obligation.delete")
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(target.obligation == nil ? "New bill" : "Edit bill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!isValid)
                        .accessibilityIdentifier("obligation.save")
                }
            }
            .task {
                guard !loaded else { return }
                loaded = true
                load()
            }
        }
    }

    private func previewReserve(_ amount: Decimal) -> Decimal {
        let payCadence = (try? IncomeRepository(context: modelContext).activeSchedule())?.cadence ?? .biweekly
        return ObligationMath.perPaycheckReserve(
            amount: amount, cadence: cadence, paychecksPerYear: payCadence.paychecksPerYear
        )
    }

    private var amountError: String? {
        guard let amount else { return nil }
        if amount < 0 { return "The amount can't be negative." }
        if amount == 0 { return "The amount needs to be more than zero." }
        return nil
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (amount ?? 0) > 0
    }

    private func load() {
        name = target.suggestedName
        guard let obligation = target.obligation else {
            accountID = try? CashAccountRepository(context: modelContext)
                .accounts(withRole: .reserves).first?.id
            return
        }
        amount = obligation.amount
        cadence = obligation.cadence
        dueDay = obligation.dueDay
        accountID = obligation.accountID
        isEssential = obligation.isEssential
    }

    private func save() {
        let repository = ObligationRepository(context: modelContext)
        do {
            if let obligation = target.obligation {
                try repository.update(
                    obligation, name: name, amount: amount ?? .zero, cadence: cadence,
                    dueDay: dueDay, accountID: accountID, isEssential: isEssential,
                    now: appEnvironment.dateProvider.now
                )
            } else {
                try repository.create(
                    name: name, amount: amount ?? .zero, cadence: cadence,
                    dueDay: dueDay, accountID: accountID, isEssential: isEssential,
                    now: appEnvironment.dateProvider.now
                )
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ obligation: RecurringObligation) {
        do {
            try ObligationRepository(context: modelContext).delete(obligation)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func archive(_ obligation: RecurringObligation) {
        do {
            try ObligationRepository(context: modelContext)
                .archive(obligation, now: appEnvironment.dateProvider.now)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
