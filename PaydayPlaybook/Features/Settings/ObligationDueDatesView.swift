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
    @State private var editing: DueRuleEditorTarget?

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
                    editing = DueRuleEditorTarget(obligation)
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
        // The shared editor: the same form, validation, audit trail, and
        // reconcile the consolidated setup page and the debt detail screen
        // use (V3-07).
        .dueRuleEditor($editing)
    }
}
