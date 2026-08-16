import SwiftUI
import SwiftData

/// The Payoff Scenarios calculator (V3-05/V3-06, §8.6).
///
/// Preloads the user's saved inputs, lets them override income, pay frequency,
/// and effective date without touching saved data, and renders exactly three
/// cards. Balanced carries the contracted "Recommended" badge and is never
/// applied automatically — applying is a separate, confirmed decision.
struct PayoffScenariosView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment

    @State private var state = ScenarioWorkspaceState()
    @State private var phase: Phase = .loading
    @State private var showOverrides = false
    @State private var comparing: ScenarioKind?
    @State private var applying: ScenarioKind?

    private enum Phase: Equatable {
        case loading
        case ready
        /// The snapshot cannot reach the engine at all — no card can exist.
        case unavailable(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .loading:
                    ProgressView("Working out your options")
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .accessibilityIdentifier("scenarios.loading")
                        .accessibilityLabel("Working out your options. This takes a moment.")
                case .unavailable(let message):
                    ScenariosUnavailable(message: message)
                case .ready:
                    readyContent
                }
            }
            .padding()
        }
        .navigationTitle("Payoff plans")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if phase == .ready {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Adjust") { showOverrides = true }
                        .accessibilityIdentifier("scenarios.adjust")
                        .accessibilityHint("Try different income, pay frequency, or start date without changing your saved setup")
                }
            }
        }
        .sheet(isPresented: $showOverrides) {
            ScenarioOverridesSheet(
                savedTakeHome: state.savedTakeHome,
                savedCadence: state.savedCadence,
                overrides: state.overrides,
                onApply: { overrides in
                    state.overrides = overrides
                    showOverrides = false
                    recalculate()
                },
                onReset: {
                    state.overrides = .init()
                    showOverrides = false
                    recalculate()
                }
            )
        }
        .sheet(item: $comparing) { kind in
            if let result = state.result(for: kind) {
                ScenarioComparisonView(
                    result: result,
                    balanced: state.balanced,
                    onApply: {
                        comparing = nil
                        applying = kind
                    }
                )
            }
        }
        .sheet(item: $applying) { kind in
            if let result = state.result(for: kind),
               let definition = state.definition(for: kind),
               let input = state.baseInput {
                ApplyScenarioView(result: result, definition: definition, baseInput: input)
            }
        }
        .task { await load() }
    }

    // MARK: - Ready content

    @ViewBuilder
    private var readyContent: some View {
        if let summary = state.overrides.summary(baseCadence: state.savedCadence) {
            Label {
                Text(summary)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("scenarios.overrideSummary")
        }

        Text("Three ways to finish, worked out from your own numbers. Nothing here changes your plan until you say so.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if state.allMissingInputs {
            ScenarioMissingInputsPanel(missing: state.distinctMissingInputs)
        }

        ForEach(state.results, id: \.kind) { result in
            ScenarioCardView(
                result: result,
                onCompare: { comparing = result.kind },
                onApply: { applying = result.kind }
            )
        }

        if state.results.contains(where: \.isComputable) {
            Text("Estimates, not promises. They assume your balances and rates are current and that nothing unexpected lands.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("scenarios.disclaimer")
        }
    }

    // MARK: - Loading

    /// The engine runs here, in a task, never in a body — three scenarios is
    /// over a second of work on a large plan (Agent 3's benchmark).
    private func load() async {
        guard phase == .loading else { return }
        let context = modelContext
        let dateProvider = appEnvironment.dateProvider
        do {
            let loader = ScenarioWorkspaceLoader(context: context, dateProvider: dateProvider)
            var next = try loader.preload()
            try loader.calculate(into: &next)
            state = next
            phase = next.blockingError.map { Phase.unavailable($0) } ?? .ready
        } catch {
            phase = .unavailable(error.localizedDescription)
        }
    }

    private func recalculate() {
        phase = .loading
        Task {
            var next = state
            do {
                try ScenarioWorkspaceLoader(
                    context: modelContext, dateProvider: appEnvironment.dateProvider
                ).calculate(into: &next)
                state = next
                phase = next.blockingError.map { Phase.unavailable($0) } ?? .ready
            } catch {
                phase = .unavailable(error.localizedDescription)
            }
        }
    }
}

extension ScenarioKind: @retroactive Identifiable {
    public var id: String { rawValue }
}

// MARK: - Card

struct ScenarioCardView: View {
    let result: ScenarioResult
    let onCompare: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if result.isComputable {
                figures
                if !result.warnings.isEmpty {
                    NoteList(notes: result.warnings, tint: .orange, symbol: "exclamationmark.triangle")
                }
                actions
            } else {
                ScenarioMissingInputsPanel(missing: result.missingInputs, compact: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    result.kind.isRecommended ? Color.accentColor : Color.clear,
                    lineWidth: result.kind.isRecommended ? 2 : 0
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scenarios.card.\(result.kind.rawValue)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: result.kind.symbolName)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(result.kind.displayName)
                    .font(.headline)
                if result.kind.isRecommended {
                    // Text, not colour alone — the badge still reads in high
                    // contrast and to VoiceOver.
                    Text("Recommended")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            Text(result.kind.summaryLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(
            result.kind.isRecommended
                ? "\(result.kind.displayName), recommended. \(result.kind.summaryLine)"
                : "\(result.kind.displayName). \(result.kind.summaryLine)"
        )
    }

    private var figures: some View {
        VStack(spacing: 4) {
            if let payoffDate = result.payoffDate, let duration = result.duration {
                SetupSummaryRow(label: "Debt-free", value: DateFormat.medium(payoffDate))
                SetupSummaryRow(
                    label: "About",
                    value: "\(duration.months) month\(duration.months == 1 ? "" : "s") · \(duration.paychecks) paychecks"
                )
            } else if result.notPayableAsConfigured {
                SetupSummaryRow(label: "Debt-free", value: "Not within the horizon")
            }
            SetupSummaryRow(
                label: "Estimated interest",
                value: MoneyFormat.string(result.estimatedTotalInterest),
                isEstimate: true
            )
            SetupSummaryRow(
                label: "To debt each paycheck",
                value: MoneyFormat.string(result.periodicDebtContribution)
            )
            SetupSummaryRow(
                label: "Cash kept each paycheck",
                value: MoneyFormat.string(result.cashRetainedPerPaycheck)
            )
            if let minimum = result.minimumEndingCash {
                SetupSummaryRow(
                    label: "Lowest cash point",
                    value: MoneyFormat.string(minimum)
                )
            }
            if let delta = result.deltaVsBalanced, result.kind != .balanced {
                Divider()
                SetupSummaryRow(
                    label: delta.interestDelta <= 0 ? "Interest saved vs Balanced" : "Extra interest vs Balanced",
                    value: MoneyFormat.string(abs(delta.interestDelta))
                )
                SetupSummaryRow(
                    label: delta.timeDelta <= 0 ? "Sooner than Balanced" : "Later than Balanced",
                    value: "\(abs(delta.timeDelta)) day\(abs(delta.timeDelta) == 1 ? "" : "s")"
                )
            }
        }
        .font(.subheadline)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Compare", action: onCompare)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("scenarios.compare.\(result.kind.rawValue)")
                .accessibilityHint("Opens a side-by-side comparison against Balanced")
            // The recommended card gets the filled button; the others get the
            // bordered one. Emphasis only — every card offers the same action.
            Group {
                if result.kind.isRecommended {
                    Button("Use this plan", action: onApply)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Use this plan", action: onApply)
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("scenarios.apply.\(result.kind.rawValue)")
            .accessibilityHint("Asks you to confirm before creating a new plan version")
        }
    }
}

// MARK: - Missing inputs

/// The honest-input state (V3-06/R-24): names what is still needed and where
/// to answer it. Never a substituted default dressed up as a result.
struct ScenarioMissingInputsPanel: View {
    let missing: [ScenarioMissingInput]
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compact {
                Text("A few answers are still missing")
                    .font(.subheadline.weight(.medium))
                    .accessibilityAddTraits(.isHeader)
            }
            Text(compact
                 ? "This one needs a little more before it can answer honestly:"
                 : "These plans work from your own numbers, so they'd rather ask than guess.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(missing, id: \.self) { item in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.message)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                        if let destination = item.destinationTitle {
                            Text("In \(destination)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: item.symbolName)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 0 : 12)
        .background(
            compact ? Color.clear : Color.accentColor.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .accessibilityIdentifier("scenarios.missingInputs")
    }
}

extension ScenarioMissingInput: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(field)
        hasher.combine(message)
        hasher.combine(debtID)
    }
}

// MARK: - Notes

/// Warnings and assumptions. Each carries a machine-readable code from the
/// engine, so the icon is chosen here rather than parsed out of the sentence.
struct NoteList: View {
    let notes: [PlanningNote]
    var tint: Color = .secondary
    var symbol = "info.circle"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(notes, id: \.message) { note in
                Label {
                    Text(note.message)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: symbol)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(tint)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Overrides

/// R-18 overrides. Applies to a copy of the snapshot; the sheet says so, so a
/// user is never left wondering whether they just edited their real income.
struct ScenarioOverridesSheet: View {
    @Environment(\.dismiss) private var dismiss

    let savedTakeHome: Decimal
    let savedCadence: PayCadence
    let overrides: ScenarioWorkspaceState.Overrides
    let onApply: (ScenarioWorkspaceState.Overrides) -> Void
    let onReset: () -> Void

    @State private var takeHome: Decimal?
    @State private var cadence: PayCadence = .biweekly
    @State private var effectiveDate = Date()
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SetupExplainer(
                        text: "Try different numbers here to see what changes. Your saved income and pay schedule stay exactly as they are.",
                        systemImage: "lock.open.rotation"
                    )

                    SetupMoneyField(
                        title: "Take-home per paycheck",
                        value: $takeHome,
                        requirement: .optional,
                        help: "Saved: \(MoneyFormat.string(savedTakeHome)). Leave it to model what you actually earn.",
                        fieldIdentifier: "scenarios.override.takeHome"
                    )

                    SetupField(
                        title: "How often you're paid",
                        requirement: .optional,
                        help: "Changing this re-bases the payday timeline on the date below, because a new cadence has no meaning against the old anchor."
                    ) {
                        Picker("Pay frequency", selection: $cadence) {
                            ForEach(PayCadence.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("scenarios.override.cadence")
                        .accessibilityLabel("Pay frequency")
                        .accessibilityValue(cadence.displayName)
                    }

                    SetupField(
                        title: "Start from",
                        requirement: .optional,
                        help: "The date a plan built from these numbers would begin."
                    ) {
                        DatePicker("Start from", selection: $effectiveDate, displayedComponents: .date)
                            .labelsHidden()
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("scenarios.override.effectiveDate")
                            .accessibilityLabel("Start from")
                            .accessibilityValue(DateFormat.mediumWithWeekday(effectiveDate))
                    }

                    Button("Reset to my saved numbers", action: onReset)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("scenarios.override.reset")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Try different numbers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Recalculate") {
                        onApply(
                            .init(
                                takeHome: takeHome,
                                cadence: cadence == savedCadence ? nil : cadence,
                                effectiveDate: effectiveDate
                            )
                        )
                    }
                    .accessibilityIdentifier("scenarios.override.apply")
                }
            }
            .task {
                guard !loaded else { return }
                loaded = true
                takeHome = overrides.takeHome
                cadence = overrides.cadence ?? savedCadence
                effectiveDate = overrides.effectiveDate ?? Date()
            }
        }
    }
}

// MARK: - Unavailable

private struct ScenariosUnavailable: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Not enough set up yet")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Finish your income and accounts setup and these plans will fill themselves in.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scenarios.unavailable")
    }
}
