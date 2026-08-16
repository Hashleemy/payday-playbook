import SwiftUI
import SwiftData

/// Identifiable handle for presenting `DueRuleEditorView` with
/// `.sheet(item:)`. The id is the subject's own entity id, so re-presenting
/// the editor for the same debt or bill reuses the sheet instead of stacking
/// a second one.
struct DueRuleEditorTarget: Identifiable {
    let id: UUID
    let subject: any DueRuleSubject

    init(_ subject: any DueRuleSubject) {
        self.id = subject.dueRuleSubjectID
        self.subject = subject
    }
}

extension View {
    /// Presents the shared due-rule editor.
    ///
    /// **This is the integration point for every screen that edits a due
    /// date** — the consolidated Bills & Debts setup page, the debt detail
    /// screen, and the obligation due-dates settings screen (V3-07). Screens
    /// attach this modifier and set the binding; they do not reimplement the
    /// form, the validation, the audit trail, or the reschedule. One editor
    /// means one behavior, and a fix lands everywhere at once.
    func dueRuleEditor(_ target: Binding<DueRuleEditorTarget?>) -> some View {
        sheet(item: target) { DueRuleEditorView(subject: $0.subject) }
    }
}

/// Editing a debt's or a bill's due rule (V2-11 as hardened by V3-07).
///
/// Three guarantees the screen owes the user, all of them the reason this is
/// one view rather than three:
/// - the edit is **prospective** — future markers and reminders change, the
///   history the calendar already drew does not;
/// - a day that does not exist in every month is **disclosed**, not silently
///   clamped behind the user's back (R-11); and
/// - the notification reconcile **completes before the sheet dismisses**, so
///   the user never returns to a calendar that disagrees with the reminders
///   they are about to receive.
struct DueRuleEditorView: View {
    let subject: any DueRuleSubject

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var notificationScheduler: NotificationScheduler

    @State private var dueDayText = ""
    @State private var shiftRule: DueDateShiftRule = .exactDay
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var now: Date { appEnvironment.dateProvider.now }

    /// The rule as currently typed, used for live disclosure. Invalid input
    /// simply produces no preview — the error appears on save, where the user
    /// is expecting a verdict.
    private var draftRule: DueRule? {
        guard let day = try? DueRuleEditService.parseDueDay(dueDayText) else { return nil }
        return DueRule(dueDay: day, shift: shiftRule)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(subject.dueRuleDisplayName) {
                    HStack {
                        Text("Due day of month")
                        Spacer()
                        TextField("1–31 or blank", text: $dueDayText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 110)
                            .accessibilityIdentifier("dueRule.day")
                    }
                    if !dueDayText.isEmpty {
                        Picker("Weekend due dates", selection: $shiftRule) {
                            ForEach(DueDateShiftRule.allCases) { rule in
                                Text(rule.displayName).tag(rule)
                            }
                        }
                        .accessibilityIdentifier("dueRule.shift")
                    }
                }

                Section {
                    if let preview = nextOccurrenceText {
                        Label(preview, systemImage: "calendar")
                            .font(.footnote)
                            .accessibilityIdentifier("dueRule.next")
                    }
                    if let clampNote = draftRule.flatMap({ DueRuleEditService.clampDisclosure(for: $0, now: now) }) {
                        Label(clampNote, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("dueRule.clampNote")
                    }
                    Text("Changes apply to future dates only. Past calendar days keep the rule that was in force then, and the amount you set aside each paycheck is unchanged — the due day is only when the \(subject.dueRuleSubjectNoun) itself is due.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !NotificationScheduler.canSchedule(notificationScheduler.authorizationStatus) {
                        // Denied permission changes nothing about due dates:
                        // the calendar is the primary surface and it keeps
                        // working (V3-16). Say so rather than letting the
                        // user assume the edit did not take.
                        Label(
                            "Reminders are off, so this updates your calendar only.",
                            systemImage: "bell.slash"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("dueRule.remindersOff")
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("dueRule.error")
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
                    .accessibilityIdentifier("dueRule.save")
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle("Edit due date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                        .accessibilityIdentifier("dueRule.cancel")
                }
            }
            .onAppear {
                let rule = subject.dueRule
                dueDayText = rule.dueDay.map(String.init) ?? ""
                shiftRule = rule.shift
            }
        }
    }

    private var nextOccurrenceText: String? {
        guard let next = draftRule?.nextOccurrence(onOrAfter: now) else { return nil }
        return "Next due date: \(DateMath.mediumString(next))"
    }

    private func save() {
        let requested: DueRule
        do {
            requested = DueRule(dueDay: try DueRuleEditService.parseDueDay(dueDayText), shift: shiftRule)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }

        let outcome: DueRuleEditService.Outcome
        do {
            outcome = try DueRuleEditService.apply(
                requested, to: subject, now: now, context: modelContext
            )
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }

        guard outcome.needsReconcile else {
            // Nothing changed, so there is nothing to reconcile — and
            // stamping a fresh effective date for a no-op edit would blank
            // the item's already-drawn history for no reason.
            dismiss()
            return
        }

        isSaving = true
        Task {
            await notificationScheduler.rescheduleAll(
                context: modelContext,
                dateProvider: appEnvironment.dateProvider,
                trigger: .dueDateEdit
            )
            isSaving = false
            dismiss()
        }
    }
}
