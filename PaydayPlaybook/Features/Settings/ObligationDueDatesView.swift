import SwiftUI
import SwiftData

/// Due-date editing for essential recurring obligations (V2-11).
///
/// Scope is deliberately due dates only: obligation CRUD (name, amount,
/// cadence) belongs to the settings/onboarding owners. Edits here are
/// prospective — they re-render future calendar events and reschedule the
/// obligation's pending notifications before the sheet dismisses; past
/// ledger history is untouched.
struct ObligationDueDatesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecurringObligation.name) private var obligations: [RecurringObligation]
    @State private var editing: RecurringObligation?

    private var activeObligations: [RecurringObligation] {
        obligations.filter { !$0.isArchived }
    }

    var body: some View {
        List {
            if activeObligations.isEmpty {
                Text("No essential obligations yet. Obligations added during setup appear here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(activeObligations) { obligation in
                Button {
                    editing = obligation
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(obligation.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text("\(MoneyFormat.string(obligation.amount)) · \(obligation.cadence.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(obligation.dueDay.map { "Due day \($0)" } ?? "No due day")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Edit due date")
            }
            Section {
                Text("Due dates drive calendar markers and reminders. Days 29–31 fall on the month's last day in shorter months.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Obligation due dates")
        .sheet(item: $editing) { obligation in
            ObligationDueDateEditView(obligation: obligation)
        }
    }
}

struct ObligationDueDateEditView: View {
    let obligation: RecurringObligation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var notificationScheduler: NotificationScheduler

    @State private var dueDayText = ""
    @State private var shiftRule: DueDateShiftRule = .exactDay
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(obligation.name) {
                    HStack {
                        Text("Due day of month")
                        Spacer()
                        TextField("1–31 or blank", text: $dueDayText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 110)
                    }
                    if !dueDayText.isEmpty {
                        Picker("Weekend due dates", selection: $shiftRule) {
                            ForEach(DueDateShiftRule.allCases) { rule in
                                Text(rule.displayName).tag(rule)
                            }
                        }
                    }
                    Text("Changes apply to future dates only. Reserving per paycheck is unchanged — the due day is when the bill itself is due.")
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
                        Text(isSaving ? "Saving…" : "Save")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle("Edit due date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                dueDayText = obligation.dueDay.map(String.init) ?? ""
                shiftRule = obligation.dueDateShiftRule
            }
        }
    }

    private func save() {
        // Validate before mutating: the obligation is a live SwiftData
        // object, so an early return after assignment would persist an edit
        // the user never confirmed.
        var newDueDay: Int?
        if !dueDayText.isEmpty {
            guard let day = Int(dueDayText), DueDateRule.validDays.contains(day) else {
                errorMessage = "Enter a due day between 1 and 31, or leave it blank."
                return
            }
            newDueDay = day
        }
        let previousDueDay = obligation.dueDay
        obligation.dueDay = newDueDay
        if newDueDay != previousDueDay {
            obligation.appendDueDateAudit(DueDateRule.auditNote(
                field: "due day",
                from: previousDueDay,
                to: newDueDay,
                on: appEnvironment.dateProvider.now
            ))
            obligation.dueDayEffectiveFrom = DateMath.startOfDay(appEnvironment.dateProvider.now)
        }
        obligation.dueDateShiftRule = shiftRule
        obligation.updatedAt = Date()
        do {
            try modelContext.save()
            // V2-11: the reschedule completes before dismissal so stable
            // identifiers replace the old reminders — no stale fires, no
            // duplicates.
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
