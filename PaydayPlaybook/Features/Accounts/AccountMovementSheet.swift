import SwiftUI
import SwiftData

/// Which money movement the sheet is recording (V3-03).
enum AccountMovementTarget: Identifiable {
    case deposit(CashAccount)
    case withdrawal(CashAccount)
    case transfer(CashAccount)
    case adjustment(CashAccount)

    var id: String {
        switch self {
        case .deposit(let account): return "deposit-\(account.id)"
        case .withdrawal(let account): return "withdrawal-\(account.id)"
        case .transfer(let account): return "transfer-\(account.id)"
        case .adjustment(let account): return "adjustment-\(account.id)"
        }
    }

    var account: CashAccount {
        switch self {
        case .deposit(let account), .withdrawal(let account),
             .transfer(let account), .adjustment(let account):
            return account
        }
    }

    var title: String {
        switch self {
        case .deposit: return "Record a deposit"
        case .withdrawal: return "Record a withdrawal"
        case .transfer: return "Transfer money"
        case .adjustment: return "Update the balance"
        }
    }

    var identifierSuffix: String {
        switch self {
        case .deposit: return "deposit"
        case .withdrawal: return "withdrawal"
        case .transfer: return "transfer"
        case .adjustment: return "adjustment"
        }
    }
}

/// One sheet for all four movements. They share an amount, an effective date,
/// a note, and a resulting-balance preview; only the transfer adds a second
/// account and only the adjustment requires a confirmation step.
struct AccountMovementSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @Query private var allAccounts: [CashAccount]

    let target: AccountMovementTarget

    @State private var amount: Decimal?
    @State private var statedBalance: Decimal?
    @State private var effectiveDate = Date()
    @State private var note = ""
    @State private var destinationID: UUID?
    @State private var error: String?
    @State private var isConfirmingAdjustment = false
    @State private var loaded = false

    private var account: CashAccount { target.account }

    private var transferCandidates: [CashAccount] {
        allAccounts
            .filter { !$0.isArchived && $0.id != account.id }
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }

    private var destination: CashAccount? {
        destinationID.flatMap { id in transferCandidates.first { $0.id == id } }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch target {
                    case .deposit, .withdrawal:
                        movementFields
                    case .transfer:
                        transferFields
                    case .adjustment:
                        adjustmentFields
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("movement.error")
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isAdjustment ? "Review" : "Save", action: primaryAction)
                        .disabled(!isValid)
                        .accessibilityIdentifier("movement.save.\(target.identifierSuffix)")
                }
            }
            .task {
                guard !loaded else { return }
                loaded = true
                effectiveDate = appEnvironment.dateProvider.now
                statedBalance = account.currentBalance
                destinationID = transferCandidates.first?.id
            }
            .alert("Record this balance?", isPresented: $isConfirmingAdjustment) {
                Button("Record balance") { commitAdjustment() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(adjustmentConfirmationMessage)
            }
        }
    }

    private var isAdjustment: Bool {
        if case .adjustment = target { return true }
        return false
    }

    // MARK: - Deposit / withdrawal

    private var movementFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            AccountContextRow(account: account)

            SetupMoneyField(
                title: "Amount",
                value: $amount,
                requirement: .required,
                help: isWithdrawal
                    ? "How much left the account."
                    : "How much arrived in the account.",
                error: amountError,
                fieldIdentifier: "movement.amount"
            )

            effectiveDateField(
                help: "The day the money actually moved. Back-dating is fine — it never rewrites anything already recorded."
            )

            noteField

            if let resulting = resultingBalance {
                ResultingBalanceRow(
                    name: account.name,
                    before: account.currentBalance,
                    after: resulting
                )
            }
        }
    }

    private var isWithdrawal: Bool {
        if case .withdrawal = target { return true }
        return false
    }

    // MARK: - Transfer

    /// §5.1: source, destination, amount, effective date, and the resulting
    /// balance on *both* sides before anything is committed.
    private var transferFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            SetupField(title: "From", requirement: .required) {
                HStack {
                    Text(account.name)
                        .font(.body.weight(.medium))
                    Spacer(minLength: 8)
                    MoneyText(amount: account.currentBalance, font: .footnote)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("From \(account.name), balance \(MoneyFormat.string(account.currentBalance))")
            }

            SetupField(
                title: "To",
                requirement: .required,
                help: "Both balances move together, in one saved movement.",
                error: transferCandidates.isEmpty ? "You need a second active account to transfer between." : nil
            ) {
                Picker("Destination account", selection: $destinationID) {
                    ForEach(transferCandidates) { candidate in
                        Text(candidate.name).tag(UUID?.some(candidate.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(minHeight: 44)
                .accessibilityIdentifier("movement.destination")
                .accessibilityLabel("Destination account")
                .accessibilityValue(destination?.name ?? "none chosen")
            }

            SetupMoneyField(
                title: "Amount",
                value: $amount,
                requirement: .required,
                help: "How much moves from one account to the other.",
                error: amountError,
                fieldIdentifier: "movement.amount"
            )

            effectiveDateField(help: "The day the transfer happened.")

            noteField

            if let amount, amount > 0, let destination {
                VStack(spacing: 4) {
                    ResultingBalanceRow(
                        name: account.name,
                        before: account.currentBalance,
                        after: (account.currentBalance - amount).rounded2
                    )
                    ResultingBalanceRow(
                        name: destination.name,
                        before: destination.currentBalance,
                        after: (destination.currentBalance + amount).rounded2
                    )
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("movement.transferPreview")

                if (account.currentBalance - amount) < account.protectedAmount, account.protectedAmount > 0 {
                    SetupExplainer(
                        text: "This would take \(account.name) below its protected \(MoneyFormat.string(account.protectedAmount)). You can still do it — the plan will just have less to work with.",
                        systemImage: "shield.lefthalf.filled"
                    )
                }
            }
        }
    }

    // MARK: - Adjustment

    /// V3-03: a balance update records a dated snapshot and the difference
    /// that reconciles it. It never edits or deletes an earlier row, and the
    /// screen says so before the confirmation, not after.
    private var adjustmentFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            AccountContextRow(account: account)

            SetupExplainer(
                text: "This records what the balance is today. Everything already recorded stays exactly as it is — the difference is written as its own dated entry, so you can always see what changed and when you found out.",
                systemImage: "clock.arrow.circlepath"
            )

            SetupMoneyField(
                title: "Balance now",
                value: $statedBalance,
                requirement: .required,
                help: "The figure your bank shows.",
                error: statedBalanceError,
                fieldIdentifier: "movement.statedBalance"
            )

            effectiveDateField(help: "The day this balance was true.")

            noteField

            if let statedBalance {
                let delta = (statedBalance - account.currentBalance).rounded2
                VStack(alignment: .leading, spacing: 4) {
                    SetupSummaryRow(
                        label: "Recorded now",
                        value: MoneyFormat.string(account.currentBalance)
                    )
                    SetupSummaryRow(
                        label: delta == 0 ? "No change" : (delta > 0 ? "Difference to add" : "Difference to subtract"),
                        value: MoneyFormat.string(abs(delta))
                    )
                }
                .font(.footnote)
                .accessibilityIdentifier("movement.adjustmentPreview")

                if delta == 0 {
                    Text("Nothing moved, so no entry is written — but the app records that you checked, and when.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if statedBalance < account.protectedAmount, account.protectedAmount > 0 {
                    SetupExplainer(
                        text: "That's below the \(MoneyFormat.string(account.protectedAmount)) protected on this account. Recording it is the right thing to do — the plan will simply work with what's actually there.",
                        systemImage: "shield.lefthalf.filled"
                    )
                }
            }
        }
    }

    private var adjustmentConfirmationMessage: String {
        guard let statedBalance else { return "" }
        let delta = (statedBalance - account.currentBalance).rounded2
        let dateText = DateFormat.medium(effectiveDate)
        if delta == 0 {
            return "\(account.name) is already recorded at \(MoneyFormat.string(statedBalance)). Confirming saves that you checked on \(dateText). No entry is added and nothing already recorded changes."
        }
        let direction = delta > 0 ? "up" : "down"
        return "\(account.name) goes \(direction) to \(MoneyFormat.string(statedBalance)) as of \(dateText). A \(MoneyFormat.string(abs(delta))) entry is added to explain the difference. Nothing already recorded is changed or removed."
    }

    // MARK: - Shared fields

    private func effectiveDateField(help: String) -> some View {
        SetupField(title: "Effective date", requirement: .required, help: help) {
            DatePicker(
                "Effective date",
                selection: $effectiveDate,
                displayedComponents: .date
            )
            .labelsHidden()
            .frame(minHeight: 44)
            .accessibilityIdentifier("movement.effectiveDate")
            .accessibilityLabel("Effective date")
            .accessibilityValue(DateFormat.mediumWithWeekday(effectiveDate))
        }
    }

    private var noteField: some View {
        SetupField(title: "Note", requirement: .optional, help: "Anything you want to remember about it.") {
            TextField("Optional", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .frame(minHeight: 44)
                .accessibilityIdentifier("movement.note")
        }
    }

    // MARK: - Validation

    private var amountError: String? {
        guard let amount else { return nil }
        if amount <= 0 { return "Enter an amount greater than zero." }
        return nil
    }

    private var statedBalanceError: String? {
        guard let statedBalance else { return nil }
        return statedBalance < 0 ? "A checking balance can't be below zero here. If you're overdrawn, record it as zero and add a note." : nil
    }

    private var resultingBalance: Decimal? {
        guard let amount, amount > 0 else { return nil }
        switch target {
        case .deposit: return (account.currentBalance + amount).rounded2
        case .withdrawal: return (account.currentBalance - amount).rounded2
        case .transfer, .adjustment: return nil
        }
    }

    private var isValid: Bool {
        switch target {
        case .deposit, .withdrawal:
            return (amount ?? 0) > 0
        case .transfer:
            return (amount ?? 0) > 0 && destination != nil
        case .adjustment:
            return (statedBalance ?? -1) >= 0
        }
    }

    // MARK: - Commit

    private func primaryAction() {
        if isAdjustment {
            isConfirmingAdjustment = true
        } else {
            commitMovement()
        }
    }

    private var trimmedNote: String? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func commitMovement() {
        let service = CashLedgerService(
            context: modelContext, dateProvider: appEnvironment.dateProvider
        )
        do {
            switch target {
            case .deposit:
                try service.deposit(
                    into: account, amount: amount ?? .zero,
                    effectiveDate: effectiveDate, note: trimmedNote
                )
            case .withdrawal:
                try service.withdraw(
                    from: account, amount: amount ?? .zero,
                    effectiveDate: effectiveDate, note: trimmedNote
                )
            case .transfer:
                guard let destination else { return }
                try service.transfer(
                    from: account, to: destination, amount: amount ?? .zero,
                    effectiveDate: effectiveDate, note: trimmedNote
                )
            case .adjustment:
                return
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func commitAdjustment() {
        do {
            try CashLedgerService(
                context: modelContext, dateProvider: appEnvironment.dateProvider
            ).adjustBalance(
                of: account,
                to: statedBalance ?? account.currentBalance,
                effectiveDate: effectiveDate,
                note: trimmedNote,
                auditNote: "Balance stated by the user on \(DateFormat.medium(effectiveDate))."
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Small shared rows

private struct AccountContextRow: View {
    let account: CashAccount

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.body.weight(.medium))
                Text("Recorded balance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            MoneyText(amount: account.currentBalance, font: .body.weight(.semibold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(account.name), recorded balance \(MoneyFormat.string(account.currentBalance))")
    }
}

/// "Everyday checking: $1,240.00 → $1,090.00" — the before and after of one
/// side of a movement, stated before it is committed.
private struct ResultingBalanceRow: View {
    let name: String
    let before: Decimal
    let after: Decimal

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
                .font(.footnote)
            Spacer(minLength: 8)
            Text(MoneyFormat.string(before))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(MoneyFormat.string(after))
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) goes from \(MoneyFormat.string(before)) to \(MoneyFormat.string(after))")
    }
}
