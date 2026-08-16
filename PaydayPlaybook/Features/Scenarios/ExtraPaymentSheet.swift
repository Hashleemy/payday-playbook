import SwiftUI
import SwiftData

/// "What if I pay extra?" (V3-04, R-20/R-21, §8.6).
///
/// A preview and nothing else. The insight service takes value types and
/// returns value types; no plan, ledger row, or reminder is touched by opening
/// or recalculating this sheet. The copy says so, in those words, because a
/// user should never have to wonder whether looking cost them something.
struct ExtraPaymentSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @Query private var debts: [DebtAccount]
    @Query private var accounts: [CashAccount]

    /// Pre-selected when opened from a debt's own detail screen.
    var initialDebtID: UUID?

    @State private var amount: Decimal?
    @State private var kind: ExtraPaymentKind = .oneTime
    @State private var targetDebtID: UUID?
    @State private var sourceAccountID: UUID?
    @State private var effectiveDate = Date()
    @State private var insight: ExtraPaymentInsight?
    @State private var isCalculating = false
    @State private var error: String?
    @State private var loaded = false

    private var activeDebts: [DebtAccount] {
        debts.filter { !$0.isArchived }
            .sorted { ($0.priority, $0.createdAt) < ($1.priority, $1.createdAt) }
    }

    private var activeAccounts: [CashAccount] {
        accounts.filter { !$0.isArchived }
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SetupExplainer(
                        text: "This works out what an extra payment would do. Nothing is scheduled, paid, or changed by looking.",
                        systemImage: "eye"
                    )

                    inputs

                    if isCalculating {
                        ProgressView("Working it out")
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .accessibilityIdentifier("extraPayment.calculating")
                    } else if let insight {
                        ExtraPaymentInsightView(insight: insight, debtNames: debtNames)
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("extraPayment.error")
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("What if I pay extra?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Show me") { calculate() }
                        .disabled((amount ?? 0) <= 0 || isCalculating)
                        .accessibilityIdentifier("extraPayment.calculate")
                }
            }
            .task {
                guard !loaded else { return }
                loaded = true
                effectiveDate = appEnvironment.dateProvider.now
                targetDebtID = initialDebtID
                sourceAccountID = try? CashAccountRepository(context: modelContext)
                    .spendingAccount()?.id
            }
        }
    }

    private var debtNames: [UUID: String] {
        Dictionary(uniqueKeysWithValues: activeDebts.map { ($0.id, $0.displayName) })
    }

    // MARK: - Inputs

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 16) {
            SetupMoneyField(
                title: "Extra amount",
                value: $amount,
                requirement: .required,
                help: "On top of what the plan already sends to debt.",
                error: (amount ?? 1) <= 0 ? "Enter an amount greater than zero." : nil,
                fieldIdentifier: "extraPayment.amount"
            )

            SetupField(title: "How often", requirement: .required) {
                Picker("How often", selection: $kind) {
                    Text("Just once").tag(ExtraPaymentKind.oneTime)
                    Text("Every paycheck").tag(ExtraPaymentKind.recurringPerPaycheck)
                    Text("Every month").tag(ExtraPaymentKind.recurringMonthly)
                }
                .pickerStyle(.segmented)
                .frame(minHeight: 44)
                .accessibilityIdentifier("extraPayment.kind")
            }

            SetupField(
                title: "Put it toward",
                requirement: .optional,
                help: "Left automatic, it goes to whichever debt the plan is attacking — the highest rate."
            ) {
                Picker("Target debt", selection: $targetDebtID) {
                    Text("Whichever costs most").tag(UUID?.none)
                    ForEach(activeDebts) { debt in
                        Text(debt.displayName).tag(UUID?.some(debt.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(minHeight: 44)
                .accessibilityIdentifier("extraPayment.target")
                .accessibilityLabel("Put it toward")
                .accessibilityValue(
                    targetDebtID.flatMap { debtNames[$0] } ?? "whichever costs most"
                )
            }

            if activeAccounts.count > 1 {
                SetupField(
                    title: "From",
                    requirement: .optional,
                    help: "Used to check the money is there. The estimate itself treats your cash as one pool."
                ) {
                    Picker("Source account", selection: $sourceAccountID) {
                        Text("Not set").tag(UUID?.none)
                        ForEach(activeAccounts) { account in
                            Text(account.name).tag(UUID?.some(account.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("extraPayment.source")
                }
            }

            SetupField(
                title: kind == .oneTime ? "On" : "Starting",
                requirement: .required,
                help: "It lands on the first payday on or after this date."
            ) {
                DatePicker("Effective date", selection: $effectiveDate, displayedComponents: .date)
                    .labelsHidden()
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("extraPayment.effectiveDate")
                    .accessibilityLabel(kind == .oneTime ? "Payment date" : "Start date")
                    .accessibilityValue(DateFormat.mediumWithWeekday(effectiveDate))
            }
        }
    }

    // MARK: - Calculate

    /// Runs off the view body — the insight is two full engine projections.
    private func calculate() {
        guard let amount, amount > 0 else { return }
        isCalculating = true
        error = nil
        let context = modelContext
        let dateProvider = appEnvironment.dateProvider
        let extra = StoredExtraPayment(
            id: UUID(),
            kind: kind,
            amount: amount,
            effectiveDate: effectiveDate,
            targetDebtID: targetDebtID,
            sourceAccountID: sourceAccountID
        )

        Task {
            do {
                let input = try PlanningInputBuilder(context: context).build(
                    asOf: DateMath.startOfDay(dateProvider.now)
                )
                insight = try ExtraPaymentInsightService().insight(from: input, extra: extra)
            } catch {
                insight = nil
                self.error = error.localizedDescription
            }
            isCalculating = false
        }
    }
}

// MARK: - Result

/// The R-20 insight rendered as a non-mutating preview.
struct ExtraPaymentInsightView: View {
    let insight: ExtraPaymentInsight
    var debtNames: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !insight.isComputable {
                ScenarioMissingInputsPanel(missing: insight.missingInputs)
            } else {
                headline
                figures
                if !insight.downstreamChanges.isEmpty {
                    downstream
                }
                if !insight.warnings.isEmpty {
                    section("Worth knowing") {
                        NoteList(
                            notes: insight.warnings,
                            tint: .orange,
                            symbol: "exclamationmark.triangle"
                        )
                    }
                }
                if !insight.assumptions.isEmpty {
                    section("What this assumes") {
                        NoteList(notes: insight.assumptions)
                    }
                }
                Text("A preview only. Nothing has been scheduled or paid.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("extraPayment.insight")
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headlineText)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let target = insight.targetDebtID, let name = debtNames[target] {
                Text(
                    insight.targetWasAutomatic
                        ? "It goes to \(name) first — the one costing you most."
                        : "It goes to \(name), as you chose."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Says what actually happened. When the engine withholds a comparison —
    /// because a projection never finished — the headline says that plainly
    /// instead of showing a zero that would read as "no benefit".
    private var headlineText: String {
        if let saved = insight.interestSaved, let days = insight.daysSaved, days > 0 {
            return "You'd finish \(days) day\(days == 1 ? "" : "s") sooner and pay \(MoneyFormat.string(saved)) less interest."
        }
        if let saved = insight.interestSaved, saved > 0 {
            return "You'd pay \(MoneyFormat.string(saved)) less interest."
        }
        return "Your balance drops by \(MoneyFormat.string(insight.projectedPrincipalReduction)), but the finish date can't be compared — one of the projections doesn't reach payoff inside the horizon."
    }

    private var figures: some View {
        VStack(spacing: 4) {
            if let before = insight.payoffDateBefore, let after = insight.payoffDateAfter {
                SetupSummaryRow(label: "Debt-free now", value: DateFormat.medium(before))
                SetupSummaryRow(label: "Debt-free with this", value: DateFormat.medium(after))
            }
            if let periods = insight.periodsSaved, periods > 0 {
                SetupSummaryRow(label: "Paychecks removed", value: "\(periods)")
            }
            SetupSummaryRow(
                label: "Interest now",
                value: MoneyFormat.string(insight.interestBefore),
                isEstimate: true
            )
            SetupSummaryRow(
                label: "Interest with this",
                value: MoneyFormat.string(insight.interestAfter),
                isEstimate: true
            )
            SetupSummaryRow(
                label: "Balance drops by",
                value: MoneyFormat.string(insight.projectedPrincipalReduction)
            )
            SetupSummaryRow(
                label: "Total paid now",
                value: MoneyFormat.string(insight.totalPaidBefore),
                isEstimate: true
            )
            SetupSummaryRow(
                label: "Total paid with this",
                value: MoneyFormat.string(insight.totalPaid),
                isEstimate: true
            )
        }
        .font(.subheadline)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extraPayment.figures")
    }

    private var downstream: some View {
        section("What it does to the others") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(insight.downstreamChanges, id: \.debtID) { change in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.name)
                            .font(.footnote.weight(.medium))
                        Text(Self.changeText(change))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(change.name): \(Self.changeText(change))")
                }
            }
        }
    }

    static func changeText(_ change: ExtraPaymentDownstreamChange) -> String {
        guard let days = change.daysChanged, days != 0 else {
            if change.payoffOrderBefore != change.payoffOrderAfter {
                return "Paid off in a different position in the order."
            }
            return "Unchanged."
        }
        let direction = days < 0 ? "sooner" : "later"
        return "Paid off \(abs(days)) day\(abs(days) == 1 ? "" : "s") \(direction)."
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
}
