import SwiftUI
import SwiftData

/// Global "+" sheet: payment, balance update, windfall, checking-account
/// adjustment, note.
struct QuickAddSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    AddPaymentView()
                } label: {
                    Label("Card payment", systemImage: "creditcard")
                }
                NavigationLink {
                    BalanceUpdateView()
                } label: {
                    Label("Card balance update", systemImage: "arrow.triangle.2.circlepath")
                }
                NavigationLink {
                    WindfallView()
                } label: {
                    Label("Windfall", systemImage: "gift")
                }
                NavigationLink {
                    CheckingAccountAdjustmentView()
                } label: {
                    Label(CheckingAccountAdjustmentView.menuTitle, systemImage: "building.columns")
                }
                NavigationLink {
                    RefundCorrectionView()
                } label: {
                    Label("Refund / correction", systemImage: "arrow.uturn.left.circle")
                }
                NavigationLink {
                    NoteEntryView()
                } label: {
                    Label("Note", systemImage: "note.text")
                }
                NavigationLink {
                    LedgerListView()
                } label: {
                    Label("View full ledger", systemImage: "list.bullet.rectangle")
                }
            }
            .navigationTitle("Add entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

/// Records an actual card payment as a ledger entry and triggers a reforecast.
struct AddPaymentView: View {
    var preselectedPlanID: String?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @Query(sort: \DebtAccount.priority) private var debts: [DebtAccount]

    @State private var selectedPlanID = ""
    @State private var amount: Decimal?
    @State private var effectiveDate = Date()
    @State private var note = ""
    @State private var errorMessage: String?
    @State private var showExtraPayment = false

    var body: some View {
        Form {
            Section("Payment") {
                Picker("Card", selection: $selectedPlanID) {
                    ForEach(debts) { debt in
                        Text("\(debt.displayName) (\(debt.planID))").tag(debt.planID)
                    }
                }
                MoneyField(label: "Amount", value: $amount)
                    .accessibilityIdentifier("payment.amount")
                DatePicker("Date", selection: $effectiveDate, displayedComponents: .date)
                TextField("Note (optional)", text: $note)
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
                    Text("Record Payment")
                }
                .buttonStyle(.primaryAction)
                .accessibilityIdentifier("payment.save")

                // V3-04: the second contracted entry point. Offered beside
                // recording a payment, not in place of it — it answers "what
                // would this do?" without recording anything.
                Button {
                    showExtraPayment = true
                } label: {
                    Label("What if I pay extra?", systemImage: "arrow.up.forward.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("payment.whatIfExtra")
                .accessibilityHint("Shows what an extra payment would do. Nothing is recorded.")
            }
            .listRowBackground(Color.clear)
        }
        .sheet(isPresented: $showExtraPayment) {
            ExtraPaymentSheet(
                initialDebtID: debts.first(where: { $0.planID == selectedPlanID })?.id
            )
        }
        .navigationTitle("Card payment")
        .onAppear {
            if selectedPlanID.isEmpty {
                selectedPlanID = preselectedPlanID ?? debts.first?.planID ?? ""
            }
            effectiveDate = appEnvironment.dateProvider.now
        }
    }

    private func save() {
        guard let amount, amount > 0 else {
            errorMessage = "Enter a payment amount greater than zero. Use a refund or correction entry for negative amounts."
            return
        }
        guard let debt = debts.first(where: { $0.planID == selectedPlanID }) else {
            errorMessage = "Choose a card."
            return
        }
        let entry = LedgerEntry(
            effectiveDate: DateMath.startOfDay(effectiveDate),
            type: .cardPayment,
            amount: amount,
            sourceAccount: .checking2,
            destinationAccount: .card,
            debtAccountID: debt.id,
            debtPlanID: debt.planID,
            note: note.isEmpty ? nil : note
        )
        modelContext.insert(entry)
        do {
            try modelContext.save()
            _ = try? appEnvironment.reforecastService(context: modelContext)
                .reforecast(trigger: .extraPayment)
            try? appEnvironment.milestoneService(context: modelContext).refreshAchievements()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Records an authoritative balance snapshot for a card.
struct BalanceUpdateView: View {
    var preselectedPlanID: String?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @Query(sort: \DebtAccount.priority) private var debts: [DebtAccount]

    @State private var selectedPlanID = ""
    @State private var amount: Decimal?
    @State private var effectiveDate = Date()
    @State private var sourceType: SnapshotSourceType = .currentOnlineBalance
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Balance update") {
                Picker("Card", selection: $selectedPlanID) {
                    ForEach(debts) { debt in
                        Text("\(debt.displayName) (\(debt.planID))").tag(debt.planID)
                    }
                }
                MoneyField(label: "Current balance", value: $amount)
                    .accessibilityIdentifier("balance.amount")
                DatePicker("Effective date", selection: $effectiveDate, displayedComponents: .date)
                Picker("Source", selection: $sourceType) {
                    ForEach(SnapshotSourceType.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                TextField("Note (optional)", text: $note)
            }
            Section {
                Text("This balance becomes the source of truth for the actual track and forecast from its effective date. Original Plan v1 never changes.")
                    .font(.footnote)
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
                    Text("Save Balance")
                }
                .buttonStyle(.primaryAction)
                .accessibilityIdentifier("balance.save")
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Balance update")
        .onAppear {
            if selectedPlanID.isEmpty {
                selectedPlanID = preselectedPlanID ?? debts.first?.planID ?? ""
            }
            effectiveDate = appEnvironment.dateProvider.now
        }
    }

    private func save() {
        guard let amount, !amount.isNegative else {
            errorMessage = "Enter the current balance (zero or more)."
            return
        }
        guard let debt = debts.first(where: { $0.planID == selectedPlanID }) else {
            errorMessage = "Choose a card."
            return
        }
        let snapshot = BalanceSnapshot(
            debtAccountID: debt.id,
            debtPlanID: debt.planID,
            effectiveDate: DateMath.startOfDay(effectiveDate),
            amount: amount,
            sourceType: sourceType,
            note: note.isEmpty ? nil : note,
            isAuthoritative: true
        )
        modelContext.insert(snapshot)
        do {
            try modelContext.save()
            _ = try? appEnvironment.reforecastService(context: modelContext)
                .reforecast(trigger: .balanceSnapshot)
            try? appEnvironment.milestoneService(context: modelContext).refreshAchievements()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Records a windfall assigned to debt or kept for spending. The destination
/// labels speak the user's own account names (V4-06); the persisted legacy
/// raws underneath are unchanged.
struct WindfallView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment

    enum Destination: String, CaseIterable, Identifiable {
        case debt
        case keep
        var id: String { rawValue }
    }

    @State private var accounts: [CashAccount] = []
    @State private var amount: Decimal?
    @State private var destination: Destination = .debt
    @State private var effectiveDate = Date()
    @State private var note = ""
    @State private var errorMessage: String?

    private var destinationLabels: (debt: String, keep: String) {
        LegacyCheckingLabels.windfallLabels(in: accounts)
    }

    var body: some View {
        Form {
            Section("Windfall") {
                MoneyField(label: "Amount", value: $amount)
                Picker("Use it for", selection: $destination) {
                    Text(destinationLabels.debt).tag(Destination.debt)
                    Text(destinationLabels.keep).tag(Destination.keep)
                }
                DatePicker("Date", selection: $effectiveDate, displayedComponents: .date)
                TextField("Source — bonus, refund, gift… (optional)", text: $note)
            }
            Section {
                Text("Windfalls only change the forecast when you record how you used them. Nothing is assumed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            Section {
                Button {
                    save()
                } label: {
                    Text("Record Windfall")
                }
                .buttonStyle(.primaryAction)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Windfall")
        .onAppear {
            effectiveDate = appEnvironment.dateProvider.now
            accounts = (try? CashAccountRepository(context: modelContext).activeAccounts()) ?? []
        }
    }

    private func save() {
        guard let amount, amount > 0 else {
            errorMessage = "Enter an amount greater than zero."
            return
        }
        let entry = LedgerEntry(
            effectiveDate: DateMath.startOfDay(effectiveDate),
            type: .windfall,
            amount: amount,
            sourceAccount: .external,
            destinationAccount: destination == .debt ? .checking2 : .checking1,
            note: note.isEmpty ? nil : note
        )
        modelContext.insert(entry)
        do {
            try modelContext.save()
            _ = try? appEnvironment.reforecastService(context: modelContext).reforecast(trigger: .extraPayment)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// User-facing names for the two legacy movement slots (V4-06 vocabulary
/// sweep). The persisted `MoneyAccount` raws (`checking1`/`checking2`) are
/// schema and never change; only the words shown for them derive from the
/// user's own accounts. Migrated installs name their accounts "Checking 1"
/// and "Checking 2", so the derived labels reproduce the founding wording
/// there; the literals below are only the no-account fallback.
enum LegacyCheckingLabels {
    /// (spending, reserves): the day-to-day spending account stands in for
    /// the legacy `checking1` slot, the reserves account for `checking2`.
    /// With one account holding every role, both slots name that account.
    static func labels(in accounts: [CashAccount]) -> (spending: String, reserves: String) {
        let active = accounts
            .filter { !$0.isArchived }
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
        let spending = active.first { $0.roles.contains(.spending) } ?? active.first
        let reserves = active.first { $0.roles.contains(.reserves) && $0.id != spending?.id }
            ?? active.first { $0.roles.contains(.reserves) }
            ?? spending
        return (spending?.name ?? "Checking 1", reserves?.name ?? "Checking 2")
    }

    /// Windfall destination labels: "Apply to debt (<reserves account>)" /
    /// "Keep in <spending account>", dropping the parenthetical when both
    /// slots resolve to the same account — naming it twice would read as two
    /// different places.
    static func windfallLabels(in accounts: [CashAccount]) -> (debt: String, keep: String) {
        let base = labels(in: accounts)
        let debt = base.reserves == base.spending
            ? "Apply to debt"
            : "Apply to debt (\(base.reserves))"
        return (debt, "Keep in \(base.spending)")
    }

    /// Refund/correction target labels, kept distinguishable when one
    /// account holds both roles.
    static func targetLabels(in accounts: [CashAccount]) -> (checking1: String, checking2: String) {
        let base = labels(in: accounts)
        guard base.spending == base.reserves else { return (base.spending, base.reserves) }
        return (base.spending, "\(base.reserves) (reserves)")
    }
}

/// Generic checking-account adjustment (V4-06): choose one of the user's own
/// active accounts, then record either a stated balance ("Set balance to…")
/// or a signed change ("Adjust by amount"). Both types converge on
/// `CashLedgerService.adjustBalance`, which appends a dated
/// `accountAdjustment` delta beside an authoritative snapshot in one save —
/// history is never rewritten.
struct CheckingAccountAdjustmentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment

    /// Exact Add Entry menu copy (T-23).
    static let menuTitle = "Checking account adjustment"

    /// With exactly one active account there is nothing to choose, so it is
    /// preselected; with several, choosing is the form's first step.
    static func preselectedAccountID(in accounts: [CashAccount]) -> UUID? {
        accounts.count == 1 ? accounts.first?.id : nil
    }

    enum AdjustmentType: String, CaseIterable, Identifiable {
        case setBalance
        case adjustByAmount

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .setBalance: return "Set balance to…"
            case .adjustByAmount: return "Adjust by amount"
            }
        }
    }

    @State private var accounts: [CashAccount] = []
    @State private var selectedAccountID: UUID?
    @State private var adjustmentType: AdjustmentType = .setBalance
    @State private var statedBalance: Decimal?
    @State private var amount: Decimal?
    @State private var effectiveDate = Date()
    @State private var note = ""
    @State private var errorMessage: String?
    @State private var isConfirming = false
    @State private var loaded = false

    private var selectedAccount: CashAccount? {
        accounts.first { $0.id == selectedAccountID }
    }

    var body: some View {
        Form {
            if loaded && accounts.isEmpty {
                Section {
                    Text("There's no active checking account to adjust yet. Add one in the Accounts tab first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                accountSection
                if let account = selectedAccount {
                    adjustmentSection(for: account)
                    previewSection(for: account)
                } else {
                    Section {
                        Text("Choose which account is being adjusted.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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
                    isConfirming = true
                } label: {
                    Text("Record")
                }
                .buttonStyle(.primaryAction)
                .disabled(!isValid)
                .accessibilityIdentifier("adjustment.record")
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Adjustment")
        .onAppear(perform: load)
        .onChange(of: selectedAccountID) { _, _ in
            errorMessage = nil
            if let account = selectedAccount {
                statedBalance = account.currentBalance
            }
        }
        .alert("Record this adjustment?", isPresented: $isConfirming) {
            Button("Record") { commit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var accountSection: some View {
        Section("Account") {
            Picker("Account", selection: $selectedAccountID) {
                if selectedAccountID == nil {
                    Text("Choose an account").tag(UUID?.none)
                }
                ForEach(accounts) { account in
                    Text(account.name).tag(UUID?.some(account.id))
                }
            }
            .accessibilityIdentifier("adjustment.account")
            if let account = selectedAccount {
                HStack {
                    Text("Recorded balance")
                        .foregroundStyle(.secondary)
                    Spacer()
                    MoneyText(amount: account.currentBalance, font: .body.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(account.name), recorded balance \(MoneyFormat.string(account.currentBalance))")
            }
        }
    }

    private func adjustmentSection(for account: CashAccount) -> some View {
        Section("Adjustment") {
            Picker("Type", selection: $adjustmentType) {
                ForEach(AdjustmentType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .accessibilityIdentifier("adjustment.type")
            switch adjustmentType {
            case .setBalance:
                MoneyField(label: "Set balance to", value: $statedBalance)
                    .accessibilityIdentifier("adjustment.statedBalance")
            case .adjustByAmount:
                MoneyField(label: "Amount (+/−)", value: $amount)
                    .accessibilityIdentifier("adjustment.amount")
            }
            DatePicker("Date", selection: $effectiveDate, displayedComponents: .date)
                .accessibilityIdentifier("adjustment.date")
            TextField("Note (optional)", text: $note)
                .accessibilityIdentifier("adjustment.note")
        }
    }

    @ViewBuilder
    private func previewSection(for account: CashAccount) -> some View {
        if let delta = proposedDelta(for: account), let resulting = resultingBalance(for: account) {
            Section {
                HStack {
                    Text(delta == 0 ? "No change" : (delta > 0 ? "Difference to add" : "Difference to subtract"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    MoneyText(amount: abs(delta), font: .footnote.weight(.semibold))
                }
                .font(.footnote)
                .accessibilityElement(children: .combine)
                if resulting < account.protectedAmount, account.protectedAmount > 0 {
                    Text("That's below the \(MoneyFormat.string(account.protectedAmount)) protected on this account. Recording it is the right thing to do — the plan will simply work with what's actually there.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("The difference is written as its own dated entry. Everything already recorded stays exactly as it is.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if adjustmentType == .setBalance, statedBalanceError != nil {
            Section {
                Label(statedBalanceError ?? "", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Derived values

    private func proposedDelta(for account: CashAccount) -> Decimal? {
        switch adjustmentType {
        case .setBalance:
            guard let statedBalance, statedBalance >= 0 else { return nil }
            return (statedBalance - account.currentBalance).rounded2
        case .adjustByAmount:
            guard let amount else { return nil }
            return amount.rounded2
        }
    }

    private func resultingBalance(for account: CashAccount) -> Decimal? {
        guard let delta = proposedDelta(for: account) else { return nil }
        return (account.currentBalance + delta).rounded2
    }

    private var statedBalanceError: String? {
        guard adjustmentType == .setBalance, let statedBalance, statedBalance < 0 else { return nil }
        return "A checking balance can't be below zero here. If you're overdrawn, record it as zero and add a note."
    }

    private var isValid: Bool {
        guard let account = selectedAccount else { return false }
        switch adjustmentType {
        case .setBalance:
            return proposedDelta(for: account) != nil
        case .adjustByAmount:
            guard let delta = proposedDelta(for: account) else { return false }
            return delta != 0
        }
    }

    private var confirmationMessage: String {
        guard let account = selectedAccount,
              let delta = proposedDelta(for: account),
              let resulting = resultingBalance(for: account) else { return "" }
        let dateText = DateFormat.medium(effectiveDate)
        if delta == 0 {
            return "\(account.name) is already recorded at \(MoneyFormat.string(resulting)). Confirming saves that you checked on \(dateText). No entry is added and nothing already recorded changes."
        }
        let direction = delta > 0 ? "up" : "down"
        return "\(account.name) goes \(direction) to \(MoneyFormat.string(resulting)) as of \(dateText). A \(MoneyFormat.string(abs(delta))) entry is added to explain the difference. Nothing already recorded is changed or removed."
    }

    // MARK: - Load and commit

    private func load() {
        guard !loaded else { return }
        loaded = true
        effectiveDate = appEnvironment.dateProvider.now
        accounts = (try? CashAccountRepository(context: modelContext).activeAccounts()) ?? []
        selectedAccountID = Self.preselectedAccountID(in: accounts)
        if let account = selectedAccount {
            statedBalance = account.currentBalance
        }
    }

    private func commit() {
        guard let account = selectedAccount else { return }
        let service = CashLedgerService(
            context: modelContext, dateProvider: appEnvironment.dateProvider
        )
        let date = DateMath.startOfDay(effectiveDate)
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? nil : trimmed
        do {
            switch adjustmentType {
            case .setBalance:
                guard let statedBalance else { return }
                try service.adjustBalance(
                    of: account, to: statedBalance, effectiveDate: date, note: text,
                    auditNote: "Balance stated by the user on \(DateFormat.medium(date))."
                )
            case .adjustByAmount:
                guard let amount else { return }
                try service.adjustBalance(
                    of: account, by: amount, effectiveDate: date, note: text,
                    auditNote: "Balance adjusted by the user on \(DateFormat.medium(date))."
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A dated note, stored as a zero-amount adjustment so it appears on the calendar.
struct NoteEntryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment

    @State private var text = ""
    @State private var effectiveDate = Date()

    var body: some View {
        Form {
            Section("Note") {
                TextField("What happened?", text: $text, axis: .vertical)
                DatePicker("Date", selection: $effectiveDate, displayedComponents: .date)
            }
            Section {
                Button {
                    save()
                } label: {
                    Text("Save Note")
                }
                .buttonStyle(.primaryAction)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Note")
        .onAppear { effectiveDate = appEnvironment.dateProvider.now }
    }

    private func save() {
        let entry = LedgerEntry(
            effectiveDate: DateMath.startOfDay(effectiveDate),
            type: .c1BalanceAdjustment,
            amount: .zero,
            destinationAccount: .checking1,
            note: text
        )
        modelContext.insert(entry)
        try? modelContext.save()
        dismiss()
    }
}


/// Explicit refund/reversal and correction entries — the sanctioned path for
/// negative adjustments (F-05).
struct RefundCorrectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @Query(sort: \DebtAccount.priority) private var debts: [DebtAccount]

    enum Kind: String, CaseIterable, Identifiable {
        case refund = "Refund / reversal"
        case correction = "Correction"
        var id: String { rawValue }
    }

    enum Target: Hashable {
        case card(String)
        case checking1
        case checking2
    }

    @State private var kind: Kind = .refund
    @State private var target: Target = .card("B")
    @State private var accounts: [CashAccount] = []
    @State private var amount: Decimal?
    @State private var effectiveDate = Date()
    @State private var note = ""
    @State private var auditNote = ""
    @State private var errorMessage: String?

    /// The two legacy checking slots, shown under the user's own account
    /// names (V4-06); the persisted raws underneath are unchanged.
    private var targetLabels: (checking1: String, checking2: String) {
        LegacyCheckingLabels.targetLabels(in: accounts)
    }

    var body: some View {
        Form {
            Section("Entry") {
                Picker("Type", selection: $kind) {
                    ForEach(Kind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                Picker("Applies to", selection: $target) {
                    ForEach(debts) { debt in
                        Text("\(debt.displayName) (\(debt.planID))").tag(Target.card(debt.planID))
                    }
                    Text(targetLabels.checking1).tag(Target.checking1)
                    Text(targetLabels.checking2).tag(Target.checking2)
                }
                MoneyField(label: kind == .correction ? "Amount (+/−)" : "Amount", value: $amount)
                DatePicker("Date", selection: $effectiveDate, displayedComponents: .date)
                TextField("Note (optional)", text: $note)
                TextField("Audit note — why is this needed?", text: $auditNote, axis: .vertical)
            }
            Section {
                Text(kind == .refund
                     ? "A refund or reversal on a card increases its balance (it undoes a payment); on a checking account it adds the money back."
                     : "A correction adjusts the balance by the signed amount and is permanently marked as a correction.")
                    .font(.footnote)
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
                    Text("Record")
                }
                .buttonStyle(.primaryAction)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Refund / correction")
        .onAppear {
            effectiveDate = appEnvironment.dateProvider.now
            accounts = (try? CashAccountRepository(context: modelContext).activeAccounts()) ?? []
            if let first = debts.first { target = .card(first.planID) }
        }
    }

    private func save() {
        guard let amount, amount != 0 else {
            errorMessage = "Enter a non-zero amount."
            return
        }
        if kind == .refund && amount.isNegative {
            errorMessage = "Refund amounts are positive — the type already reverses direction."
            return
        }
        let trimmedAudit = auditNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAudit.isEmpty else {
            errorMessage = "An audit note is required for refunds and corrections."
            return
        }

        let type: LedgerEntryType = kind == .refund ? .refundReversal : .correction
        var debtAccountID: UUID?
        var debtPlanID: String?
        var destination: MoneyAccount?
        switch target {
        case .card(let planID):
            guard let debt = debts.first(where: { $0.planID == planID }) else {
                errorMessage = "Choose a card."
                return
            }
            debtAccountID = debt.id
            debtPlanID = debt.planID
            destination = .card
        case .checking1:
            destination = .checking1
        case .checking2:
            destination = .checking2
        }

        let entry = LedgerEntry(
            effectiveDate: DateMath.startOfDay(effectiveDate),
            type: type,
            amount: amount,
            sourceAccount: .external,
            destinationAccount: destination,
            debtAccountID: debtAccountID,
            debtPlanID: debtPlanID,
            note: note.isEmpty ? nil : note,
            isCorrection: kind == .correction,
            auditNote: trimmedAudit
        )
        modelContext.insert(entry)
        do {
            try modelContext.save()
            _ = try? appEnvironment.reforecastService(context: modelContext).reforecast(trigger: .manual)
            try? appEnvironment.milestoneService(context: modelContext).refreshAchievements()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
