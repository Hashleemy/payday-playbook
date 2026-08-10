import SwiftUI
import SwiftData

/// Filterable ledger of every money action (F-05).
struct LedgerListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LedgerEntry.effectiveDate, order: .reverse) private var entries: [LedgerEntry]
    @Query(sort: \DebtAccount.priority) private var debts: [DebtAccount]

    @State private var searchText = ""
    @State private var typeFilter: LedgerEntryType?
    @State private var cardFilter: String?
    @State private var paydayOnly = false
    @State private var dateFilterOn = false
    @State private var fromDate = Date()
    @State private var toDate = Date()
    @State private var editingEntry: LedgerEntry?

    private var filtered: [LedgerEntry] {
        entries.filter { entry in
            if let typeFilter, entry.type != typeFilter { return false }
            if let cardFilter, entry.debtPlanID != cardFilter { return false }
            if paydayOnly && entry.paydayCheckInID == nil { return false }
            if dateFilterOn {
                let day = DateMath.startOfDay(entry.effectiveDate)
                if day < DateMath.startOfDay(fromDate) || day > DateMath.startOfDay(toDate) {
                    return false
                }
            }
            if !searchText.isEmpty {
                let haystack = "\(entry.note ?? "") \(entry.type.displayName) \(entry.debtPlanID ?? "")"
                    .lowercased()
                if !haystack.contains(searchText.lowercased()) { return false }
            }
            return true
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Type", selection: $typeFilter) {
                    Text("All types").tag(LedgerEntryType?.none)
                    ForEach(LedgerEntryType.allCases) { type in
                        Text(type.displayName).tag(LedgerEntryType?.some(type))
                    }
                }
                Picker("Card", selection: $cardFilter) {
                    Text("All cards").tag(String?.none)
                    ForEach(debts) { debt in
                        Text("\(debt.displayName) (\(debt.planID))").tag(String?.some(debt.planID))
                    }
                }
                Toggle("Payday entries only", isOn: $paydayOnly)
                Toggle("Filter by date", isOn: $dateFilterOn)
                if dateFilterOn {
                    DatePicker("From", selection: $fromDate, displayedComponents: .date)
                    DatePicker("To", selection: $toDate, displayedComponents: .date)
                }
            }
            if filtered.isEmpty {
                EmptyStateView(
                    title: "No entries yet",
                    message: "Every payment, transfer, reserve, and correction you record appears here.",
                    symbolName: "list.bullet.rectangle"
                )
            }
            ForEach(filtered) { entry in
                Button {
                    editingEntry = entry
                } label: {
                    LedgerRow(entry: entry)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Ledger")
        .searchable(text: $searchText, prompt: "Search notes and types")
        .sheet(item: $editingEntry) { entry in
            LedgerEntryEditView(entry: entry)
        }
    }
}

struct LedgerRow: View {
    let entry: LedgerEntry

    private var title: String {
        if entry.type == .c1BalanceAdjustment && entry.amount == 0 && entry.note != nil {
            return "Note"
        }
        return entry.type.displayName
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text(DateMath.mediumString(entry.effectiveDate))
                    if let card = entry.debtPlanID {
                        Text("· Card \(card)")
                    }
                    if entry.isCorrection {
                        Text("· correction")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let note = entry.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            MoneyText(amount: entry.amount, font: .subheadline.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }
}

/// Edit preserves an audit note; corrections are appended, never silent.
/// Fields edit local state so Cancel discards cleanly.
struct LedgerEntryEditView: View {
    let entry: LedgerEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment

    @State private var amountText = ""
    @State private var noteText = ""
    @State private var auditNote = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Entry") {
                    LabeledContent("Type") { Text(entry.type.displayName) }
                    LabeledContent("Date") { Text(DateMath.mediumString(entry.effectiveDate)) }
                    HStack {
                        Text("Amount")
                        Spacer()
                        TextField("Amount", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                    }
                    TextField("Note", text: $noteText)
                }
                Section("Audit note (required to save changes)") {
                    TextField("Why is this being edited?", text: $auditNote, axis: .vertical)
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
                        Text("Save Changes")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle("Edit entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                amountText = MoneyFormat.editingString(entry.amount)
                noteText = entry.note ?? ""
                auditNote = ""
            }
        }
    }

    private func save() {
        guard let amount = MoneyFormat.parse(amountText) else {
            errorMessage = "Enter a valid amount."
            return
        }
        if amount.isNegative && !entry.type.allowsNegativeAmount {
            errorMessage = "\(entry.type.displayName) entries cannot be negative. Record a refund, reversal, or correction instead."
            return
        }
        let trimmed = auditNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "An audit note is required when editing an entry."
            return
        }
        entry.amount = amount
        entry.note = noteText.isEmpty ? nil : noteText
        entry.auditNote = [entry.auditNote, trimmed]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        entry.updatedAt = Date()
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
