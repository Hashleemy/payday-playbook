import SwiftUI
import SwiftData

/// Explicit "Save & Activate New Plan Version" flow (F-13, V2-10).
///
/// Generates a preview from the user's *current* inputs, shows what would
/// change, and commits only on an explicit action. Activation inserts a new
/// `PlanVersion` — no existing plan, check-in, ledger entry, or milestone is
/// edited or deleted; the previous version simply stops being active.
struct PlanActivationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var notificationScheduler: NotificationScheduler

    @State private var preview: GeneratedPlanService.PlanPreview?
    @State private var loadError: String?
    @State private var activationError: String?
    @State private var activatedName: String?
    @State private var isWorking = false
    @State private var nextName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let activatedName {
                        successCard(activatedName)
                    } else if let loadError {
                        blockedCard(loadError)
                    } else if let preview {
                        previewCards(preview)
                    } else {
                        DashboardCard(title: "Working it out", systemImage: "hourglass") {
                            Text("Building a plan from your current setup…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("New plan version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(activatedName == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard preview == nil, activatedName == nil else { return }
        let service = GeneratedPlanService(context: modelContext, dateProvider: appEnvironment.dateProvider)
        do {
            preview = try service.previewFromCurrentInputs()
            nextName = try GeneratedPlanService.nextPlanName(context: modelContext)
        } catch let error as PlanningInputBuilder.BuilderError {
            loadError = "\(error.errorDescription ?? "Some setup is missing.") Finish that in Settings, then come back — nothing has been changed."
        } catch let error as AvalanchePlanEngine.PlanningValidationError {
            loadError = "\(validationMessage(error)) Your existing plan is untouched."
        } catch {
            loadError = "A plan couldn't be generated from the current setup. Your existing plan is untouched."
        }
    }

    private func validationMessage(_ error: AvalanchePlanEngine.PlanningValidationError) -> String {
        switch error {
        case .noIncome:
            return "Income setup is missing a take-home amount."
        case .negativeAmount:
            return "One of the entered amounts is negative."
        case .invalidCadence:
            return "The pay cadence settings are incomplete."
        case .invalidDueDay:
            return "A due day is outside the 1–31 range."
        }
    }

    @ViewBuilder
    private func previewCards(_ preview: GeneratedPlanService.PlanPreview) -> some View {
        let result = preview.result

        DashboardCard(title: "This would become \(nextName)", systemImage: "doc.badge.plus") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Projected debt-free")
                    Spacer()
                    Text(result.forecastPayoffDate.map(DateMath.mediumString) ?? "Not inside the horizon")
                        .font(.subheadline.weight(.semibold))
                }
                HStack {
                    Text("Paychecks")
                    Spacer()
                    Text("\(result.paycheckCount)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                HStack {
                    Text("Total estimated interest")
                    Spacer()
                    MoneyText(amount: result.estimatedTotalInterest, font: .subheadline.weight(.semibold))
                }
                if let saved = result.minimumOnlyComparison?.interestSaved {
                    HStack {
                        Text("Estimated interest saved vs. minimums only")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        MoneyText(amount: saved, color: .mint)
                    }
                }
                Text("Estimates, not guarantees.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }

        if !result.warnings.isEmpty {
            DashboardCard(title: "Worth knowing first", systemImage: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, note in
                        Label(note.message, systemImage: "info.circle")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        DashboardCard(title: "What happens when you activate", systemImage: "checkmark.shield") {
            VStack(alignment: .leading, spacing: 8) {
                bullet("A new plan version, \(nextName), is created and becomes active.")
                bullet("Your existing plan versions keep every value — nothing is edited or deleted.")
                bullet("Check-ins, ledger entries, balance history, and milestones are untouched.")
                if let error = activationError {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    activate(preview)
                } label: {
                    Text(isWorking ? "Saving…" : "Save & Activate \(nextName)")
                }
                .buttonStyle(.primaryAction)
                .disabled(isWorking)
                .accessibilityIdentifier("plan.confirmActivate")
            }
            .font(.subheadline)
        }
    }

    private func bullet(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle")
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func successCard(_ name: String) -> some View {
        DashboardCard(title: "\(name) is active", systemImage: "checkmark.seal") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your new plan is in place. Every earlier version and all of your history are exactly as they were.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                }
                .buttonStyle(.primaryAction)
            }
        }
    }

    private func blockedCard(_ message: String) -> some View {
        DashboardCard(title: "Not enough to build a plan", systemImage: "questionmark.circle") {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func activate(_ preview: GeneratedPlanService.PlanPreview) {
        isWorking = true
        activationError = nil
        let service = GeneratedPlanService(context: modelContext, dateProvider: appEnvironment.dateProvider)
        do {
            let plan = try service.activate(preview)
            activatedName = plan.name
            // Due dates and paydays moved: refresh reminders and the forecast.
            try? appEnvironment.reforecastService(context: modelContext)
                .reforecast(trigger: .planEdit, varianceContext: "New plan version activated.")
            let context = modelContext
            let dateProvider = appEnvironment.dateProvider
            Task { await notificationScheduler.rescheduleAll(context: context, dateProvider: dateProvider, trigger: .planActivation) }
        } catch {
            activationError = "The new plan version couldn't be saved. Nothing was changed — you can try again."
        }
        isWorking = false
    }
}
