import SwiftUI
import SwiftData

/// Side-by-side detail against Balanced, with the assumptions and warnings
/// that belong to each side (§8.6).
///
/// Reads two already-computed results. It never calls the engine, so opening a
/// comparison costs nothing beyond layout.
struct ScenarioComparisonView: View {
    @Environment(\.dismiss) private var dismiss

    let result: ScenarioResult
    let balanced: ScenarioResult?
    let onApply: () -> Void

    private var isBalanced: Bool { result.kind == .balanced }

    /// The other side of the comparison. Nil when this *is* Balanced, or when
    /// Balanced could not be computed — and the screen then shows one column
    /// rather than inventing a second.
    private var other: ScenarioResult? {
        guard !isBalanced, let balanced, balanced.isComputable else { return nil }
        return balanced
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(result.kind.summaryLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !result.isComputable {
                        ScenarioMissingInputsPanel(missing: result.missingInputs)
                    } else {
                        comparisonTable
                        if !isBalanced && other == nil {
                            Text("Balanced can't be worked out yet, so there's nothing to compare against. The figures above still stand on their own.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !result.assumptions.isEmpty {
                            section("What this assumes") {
                                NoteList(notes: result.assumptions)
                            }
                        }
                        if !result.warnings.isEmpty {
                            section("Worth knowing") {
                                NoteList(
                                    notes: result.warnings,
                                    tint: .orange,
                                    symbol: "exclamationmark.triangle"
                                )
                            }
                        }
                        applyRow
                    }
                }
                .padding()
            }
            .navigationTitle(result.kind.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("scenarios.comparison.\(result.kind.rawValue)")
    }

    // MARK: - Table

    private var comparisonTable: some View {
        VStack(spacing: 0) {
            if let other {
                ComparisonHeaderRow(
                    left: result.kind.displayName,
                    right: other.kind.displayName
                )
                Divider()
            }
            ForEach(rows, id: \.label) { row in
                ComparisonRow(label: row.label, left: row.left, right: row.right)
                if row.label != rows.last?.label { Divider() }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("scenarios.comparisonTable")
    }

    private struct Row {
        let label: String
        let left: String
        let right: String?
    }

    private var rows: [Row] {
        func figures(_ scenario: ScenarioResult?) -> (String, String, String, String, String)? {
            guard let scenario, scenario.isComputable else { return nil }
            return (
                scenario.payoffDate.map(DateFormat.medium) ?? "Not within the horizon",
                scenario.duration.map { "\($0.months) months" } ?? "—",
                MoneyFormat.string(scenario.estimatedTotalInterest),
                MoneyFormat.string(scenario.periodicDebtContribution),
                MoneyFormat.string(scenario.cashRetainedPerPaycheck)
            )
        }

        guard let mine = figures(result) else { return [] }
        let theirs = figures(other)

        var rows = [
            Row(label: "Debt-free", left: mine.0, right: theirs?.0),
            Row(label: "Time to finish", left: mine.1, right: theirs?.1),
            Row(label: "Estimated interest", left: mine.2, right: theirs?.2),
            Row(label: "To debt per paycheck", left: mine.3, right: theirs?.3),
            Row(label: "Cash kept per paycheck", left: mine.4, right: theirs?.4)
        ]
        if let minimum = result.minimumEndingCash {
            rows.append(
                Row(
                    label: "Lowest cash point",
                    left: MoneyFormat.string(minimum),
                    right: other?.minimumEndingCash.map(MoneyFormat.string)
                )
            )
        }
        rows.append(
            Row(
                label: "Total paid",
                left: MoneyFormat.string(result.totalPaid),
                right: other.map { MoneyFormat.string($0.totalPaid) }
            )
        )
        return rows
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var applyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Use this plan", action: onApply)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("scenarios.comparison.apply")
                .accessibilityHint("You'll be asked to confirm before anything changes")
            Text("Nothing has changed yet. You'll see exactly what would happen before it does.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Table rows

private struct ComparisonHeaderRow: View {
    let left: String
    let right: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Spacer(minLength: 0)
            Text(left)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(right)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
        .accessibilityHidden(true)
    }
}

/// One line of the table. Left is this scenario, right is Balanced when there
/// is one — collapsed into a single VoiceOver sentence so a comparison is read
/// as a comparison rather than as four loose numbers.
private struct ComparisonRow: View {
    let label: String
    let left: String
    let right: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(left)
                .font(.footnote.weight(.medium))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
            if let right {
                Text(right)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            right.map { "\(label): \(left), compared with \($0) for Balanced" }
                ?? "\(label): \(left)"
        )
    }
}

// MARK: - Apply

/// The confirmation step before a scenario becomes a plan (V3-15, §8.6).
///
/// It restates what will change and when, and it is the only path to
/// `ScenarioPlanActivationService.apply`. Applying creates a new version; the
/// previous plan and all history stay exactly where they are.
struct ApplyScenarioView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var notificationScheduler: NotificationScheduler

    let result: ScenarioResult
    let definition: StoredScenarioDefinition
    let baseInput: StoredPlanInput

    @State private var summary: ScenarioPlanActivationService.ApplySummary?
    @State private var error: String?
    @State private var isApplying = false
    @State private var didApply = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if didApply {
                        successState
                    } else if let summary {
                        confirmation(summary)
                    } else if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ProgressView("Checking what would change")
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                }
                .padding()
            }
            .navigationTitle(didApply ? "Plan created" : "Use \(result.kind.displayName)?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didApply ? "Done" : "Cancel") { dismiss() }
                        .accessibilityIdentifier("scenarios.applyCancel")
                }
                if !didApply {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create plan", action: apply)
                            .disabled(summary == nil || isApplying)
                            .accessibilityIdentifier("scenarios.applyConfirm")
                    }
                }
            }
            .task {
                guard summary == nil, !didApply else { return }
                do {
                    summary = try ScenarioPlanActivationService(
                        context: modelContext, dateProvider: appEnvironment.dateProvider
                    ).summary(for: result, definition: definition)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        .accessibilityIdentifier("scenarios.apply")
    }

    private func confirmation(_ summary: ScenarioPlanActivationService.ApplySummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Here's exactly what happens if you go ahead.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 4) {
                SetupSummaryRow(label: "New plan", value: summary.planName)
                SetupSummaryRow(label: "Built from", value: summary.scenarioName)
                SetupSummaryRow(label: "Starts", value: DateFormat.medium(summary.effectiveDate))
                if let payoff = summary.payoffDate {
                    SetupSummaryRow(label: "Debt-free", value: DateFormat.medium(payoff))
                }
                SetupSummaryRow(
                    label: "Estimated interest",
                    value: MoneyFormat.string(summary.estimatedInterest),
                    isEstimate: true
                )
            }
            .font(.subheadline)
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("scenarios.applySummary")

            if let replaced = summary.replacesPlanNamed {
                SetupExplainer(
                    text: "\(replaced) stops being your active plan. It isn't deleted or edited — every payday, payment, and check-in you've recorded stays exactly as it is, and you can still open it.",
                    systemImage: "clock.arrow.circlepath"
                )
            }
            SetupExplainer(
                text: "Your reminders are rebuilt to match the new schedule. Anything already completed stays completed.",
                systemImage: "bell"
            )

            if isApplying {
                ProgressView("Creating your plan")
                    .frame(maxWidth: .infinity)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("scenarios.applyError")
            }
        }
    }

    private var successState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.mint)
                .accessibilityHidden(true)
            Text("Your new plan is active")
                .font(.headline)
            Text("Everything you'd recorded before is still there. You can switch back by creating a plan from a different scenario at any time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scenarios.applySuccess")
    }

    private func apply() {
        isApplying = true
        error = nil
        do {
            try ScenarioPlanActivationService(
                context: modelContext, dateProvider: appEnvironment.dateProvider
            ).apply(result: result, definition: definition, baseInput: baseInput)
            didApply = true

            // Applying a scenario activates a new plan version, which is the
            // same event `PlanActivationView` handles — so it does the same two
            // things, deliberately in step with it. The confirmation copy above
            // promises the reminders are rebuilt, and reminders are derived from
            // the active plan's paydays; without this the promise is false until
            // the next foreground pass. The forecast is refreshed for the same
            // reason: it would otherwise keep projecting the superseded plan.
            try? appEnvironment.reforecastService(context: modelContext)
                .reforecast(trigger: .planEdit, varianceContext: "Scenario applied as a new plan version.")
            let context = modelContext
            let dateProvider = appEnvironment.dateProvider
            Task {
                await notificationScheduler.rescheduleAll(
                    context: context, dateProvider: dateProvider, trigger: .planActivation
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
        isApplying = false
    }
}
