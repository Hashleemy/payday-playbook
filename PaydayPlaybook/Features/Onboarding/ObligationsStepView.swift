import SwiftUI
import SwiftData

/// Step 7 — essential recurring obligations (§4.5, V2-07). Shows the
/// per-paycheck reserve live so the smoothing math is visible before a plan
/// exists.
struct ObligationsStepView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var obligations: [RecurringObligation]

    let onContinue: () -> Void
    let onBack: () -> Void

    @State private var editing: ObligationEditorTarget?

    private var activeObligations: [RecurringObligation] {
        obligations.filter { !$0.isArchived }
            .sorted { ($0.createdAt, $0.name) < ($1.createdAt, $1.name) }
    }

    private var essentialObligations: [RecurringObligation] {
        activeObligations.filter(\.isEssential)
    }

    var body: some View {
        OnboardingScaffold(
            title: "What has to get paid?",
            subtitle: "Rent, car, transit, insurance, utilities — the bills that aren't optional.",
            continueTitle: activeObligations.isEmpty ? "I have none of these" : "Continue",
            continueIdentifier: "onboarding.obligationsContinue",
            onBack: onBack,
            onContinue: onContinue
        ) {
            SetupExplainer(
                text: "The plan sets aside a slice of every paycheck for these before it decides how much can go to debt. Without them it would promise money you've already spent.",
                systemImage: "tray.and.arrow.down"
            )

            if activeObligations.isEmpty {
                EmptyStateView(
                    title: "No bills added",
                    message: "Add the ones you must pay every month. You can continue without any.",
                    symbolName: "house"
                )
                starterChips
            } else {
                VStack(spacing: 8) {
                    ForEach(activeObligations) { obligation in
                        ObligationRow(obligation: obligation) { editing = .existing(obligation) }
                    }
                }
                reserveSummary
            }

            Button {
                editing = .new(nil)
            } label: {
                Label("Add a bill", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("obligations.add")
        }
        .sheet(item: $editing) { target in
            ObligationEditorView(target: target, allowsDelete: true)
        }
    }

    /// Starter names only — never a prefilled amount (§4.5).
    private var starterChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Common ones")
                .font(.subheadline.weight(.medium))
            HStack {
                ForEach(["Rent", "Car", "Transit", "Insurance"], id: \.self) { suggestion in
                    Button(suggestion) {
                        editing = .new(suggestion)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Add \(suggestion)")
                    .accessibilityIdentifier("obligations.starter.\(suggestion)")
                }
            }
        }
    }

    /// Live R-04 preview using the saved pay cadence (biweekly until income
    /// is entered, which is the common case at this point in the flow).
    private var reserveSummary: some View {
        let cadence = (try? IncomeRepository(context: modelContext).activeSchedule())?.cadence ?? .biweekly
        let total = essentialObligations.reduce(Decimal.zero) { running, obligation in
            running + ObligationMath.perPaycheckReserve(
                amount: obligation.amount,
                cadence: obligation.cadence,
                paychecksPerYear: cadence.paychecksPerYear
            )
        }
        return VStack(alignment: .leading, spacing: 4) {
            SetupSummaryRow(label: "Set aside each paycheck", value: MoneyFormat.string(total))
                .font(.subheadline.weight(.medium))
            Text("Spread evenly across your paychecks so a big bill never lands as a surprise.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Row

private struct ObligationRow: View {
    @Environment(\.modelContext) private var modelContext
    let obligation: RecurringObligation
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(obligation.name)
                        .font(.body.weight(.medium))
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !obligation.isEssential {
                        Text("Not essential — left out of the plan's reserves")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    MoneyText(amount: obligation.amount, font: .body.weight(.semibold))
                    Text(perPaycheckText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(obligation.name), \(MoneyFormat.string(obligation.amount)) \(obligation.cadence.displayName.lowercased()), \(perPaycheckText)")
        .accessibilityHint("Opens the bill editor")
        .accessibilityIdentifier("obligations.row.\(obligation.name)")
    }

    private var detail: String {
        var parts = [obligation.cadence.displayName]
        if let dueDay = obligation.dueDay {
            parts.append("due the \(SetupDayField.dayLabel(dueDay))")
        }
        return parts.joined(separator: " · ")
    }

    private var perPaycheckText: String {
        let cadence = (try? IncomeRepository(context: modelContext).activeSchedule())?.cadence ?? .biweekly
        let reserve = ObligationMath.perPaycheckReserve(
            amount: obligation.amount,
            cadence: obligation.cadence,
            paychecksPerYear: cadence.paychecksPerYear
        )
        return "\(MoneyFormat.string(reserve)) per check"
    }
}

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

                    if allowsDelete, let obligation = target.obligation {
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
}
