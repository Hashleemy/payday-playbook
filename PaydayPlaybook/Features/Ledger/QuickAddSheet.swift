import SwiftUI
import SwiftData

/// Global "+" sheet: payment, balance update, windfall, C1/C2 adjustment, note.
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
                    CashAdjustmentView()
                } label: {
                    Label("Checking 1 / 2 adjustment", systemImage: "building.columns")
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
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
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
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
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

/// Records a windfall assigned to Checking 2 (debt) or kept in Checking 1.
struct WindfallView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment

    enum Destination: String, CaseIterable, Identifiable {
        case debt = "Apply to debt (Checking 2)"
        case keep = "Keep in Checking 1"
        var id: String { rawValue }
    }

    @State private var amount: Decimal?
    @State private var destination: Destination = .debt
    @State private var effectiveDate = Date()
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Windfall") {
                MoneyField(label: "Amount", value: $amount)
                Picker("Use it for", selection: $destination) {
                    ForEach(Destination.allCases) { destination in
                        Text(destination.rawValue).tag(destination)
                    }
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
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Windfall")
        .onAppear { effectiveDate = appEnvironment.dateProvider.now }
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

/// Manual C1/C2 adjustments, C1 spending, and reserve use entries.
struct CashAdjustmentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment

    enum Kind: String, CaseIterable, Identifiable {
        case c1Spending = "Checking 1 spending"
        case c1Add = "Checking 1 buffer addition"
        case c1Adjust = "Checking 1 balance adjustment"
        case carUse = "Car reserve use"
        case trainUse = "Train reserve use"
        case carAdd = "Car reserve contribution"
        case trainAdd = "Train reserve contribution"
        var id: String { rawValue }
    }

    @State private var kind: Kind = .c1Spending
    @State private var amount: Decimal?
    @State private var effectiveDate = Date()
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Adjustment") {
                Picker("Type", selection: $kind) {
                    ForEach(Kind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                MoneyField(label: kind == .c1Adjust ? "Amount (+/−)" : "Amount", value: $amount)
                DatePicker("Date", selection: $effectiveDate, displayedComponents: .date)
                TextField("Note (optional)", text: $note)
            }
            if kind == .c1Adjust {
                Section {
                    Text("Adjustments can be negative to correct the Checking 1 balance downward. An audit note is recommended.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
                    Text("Record")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Adjustment")
        .onAppear { effectiveDate = appEnvironment.dateProvider.now }
    }

    private func save() {
        guard let amount else {
            errorMessage = "Enter an amount."
            return
        }
        if amount.isNegative && kind != .c1Adjust {
            errorMessage = "Only balance adjustments may be negative. Use a refund/correction for other reversals."
            return
        }
        if amount == 0 {
            errorMessage = "Enter a non-zero amount."
            return
        }
        let entry: LedgerEntry
        let date = DateMath.startOfDay(effectiveDate)
        let text = note.isEmpty ? nil : note
        switch kind {
        case .c1Spending:
            entry = LedgerEntry(effectiveDate: date, type: .c1Spending, amount: amount,
                                sourceAccount: .checking1, destinationAccount: .external, note: text)
        case .c1Add:
            entry = LedgerEntry(effectiveDate: date, type: .c1BufferAddition, amount: amount,
                                sourceAccount: .external, destinationAccount: .checking1, note: text)
        case .c1Adjust:
            entry = LedgerEntry(effectiveDate: date, type: .c1BalanceAdjustment, amount: amount,
                                sourceAccount: nil, destinationAccount: .checking1, note: text,
                                auditNote: text ?? "Manual adjustment")
        case .carUse:
            entry = LedgerEntry(effectiveDate: date, type: .carReserveUse, amount: amount,
                                sourceAccount: .checking2, destinationAccount: .external, note: text)
        case .trainUse:
            entry = LedgerEntry(effectiveDate: date, type: .trainReserveUse, amount: amount,
                                sourceAccount: .checking2, destinationAccount: .external, note: text)
        case .carAdd:
            entry = LedgerEntry(effectiveDate: date, type: .carReserveContribution, amount: amount,
                                sourceAccount: .checking2, destinationAccount: .checking2, note: text)
        case .trainAdd:
            entry = LedgerEntry(effectiveDate: date, type: .trainReserveContribution, amount: amount,
                                sourceAccount: .checking2, destinationAccount: .checking2, note: text)
        }
        modelContext.insert(entry)
        do {
            try modelContext.save()
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
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
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
    @State private var amount: Decimal?
    @State private var effectiveDate = Date()
    @State private var note = ""
    @State private var auditNote = ""
    @State private var errorMessage: String?

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
                    Text("Checking 1").tag(Target.checking1)
                    Text("Checking 2").tag(Target.checking2)
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
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Refund / correction")
        .onAppear {
            effectiveDate = appEnvironment.dateProvider.now
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
