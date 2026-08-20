import SwiftUI
import SwiftData

/// Steps 9 and 10 — review the numbers, then generate and commit the plan
/// (§4.9, V2-10). Every projection is labeled an estimate, and anything the
/// app had to assume is listed before the button, not hidden behind it.
struct ReviewStepView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    // Every canonical input family is queried so an upstream edit — from any
    // surface, whether or not it changes a row count — re-renders this step
    // and re-runs the fingerprint check below (V4-02).
    @Query private var accounts: [CashAccount]
    @Query private var debts: [DebtAccount]
    @Query private var obligations: [RecurringObligation]
    @Query private var profiles: [UserGoalProfile]
    @Query private var schedules: [IncomeSchedule]
    @Query private var incomeChanges: [IncomeChange]

    let onBack: () -> Void
    let onFinish: () -> Void

    @State private var generated: PlanGenerationService.GeneratedPlan?
    /// The `SetupInputFingerprint` the preview was generated under. Commit
    /// verifies it; any input change invalidates the preview instead.
    @State private var generatedFingerprint: SetupInputFingerprint?
    @State private var generating = false
    @State private var error: String?
    @State private var staleNotice: String?
    @State private var gaps: [SetupGap] = []

    private var activeAccounts: [CashAccount] { accounts.filter { !$0.isArchived } }
    private var activeDebts: [DebtAccount] { debts.filter { !$0.isArchived } }
    private var essentialObligations: [RecurringObligation] {
        obligations.filter { !$0.isArchived && $0.isEssential }
    }
    private var activeSchedule: IncomeSchedule? { schedules.first { !$0.isArchived } }

    /// Live content fingerprint of the canonical inputs, re-evaluated on
    /// every render the queries above trigger.
    private var inputFingerprint: String {
        ((try? SetupInputFingerprint.capture(context: modelContext))?.value) ?? ""
    }

    var body: some View {
        OnboardingScaffold(
            title: generated == nil ? "Does this look right?" : "Your plan",
            subtitle: generated == nil
                ? "Everything you entered, in one place. Go back and change anything."
                : "Built from your numbers. Every projection is an estimate — real interest and posting dates will differ.",
            continueTitle: generated == nil ? "Generate My Plan" : "Use This Plan",
            continueEnabled: !generating && blockers.isEmpty,
            continueIdentifier: generated == nil ? "onboarding.generate" : "onboarding.usePlan",
            onBack: onBack,
            onContinue: { generated == nil ? generate() : commit() }
        ) {
            if let generated {
                GeneratedPlanSummary(plan: generated)
                estimateNote
            } else {
                inputSummary
                blockersSection
                gapsSection
            }

            if generating {
                HStack(spacing: 8) {
                    SwiftUI.ProgressView()
                    Text("Working out your plan…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            if let staleNotice {
                Label(staleNotice, systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("review.staleNotice")
            }

            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("review.error")
            }
        }
        .task { refreshGaps() }
        // V4-02: derived state follows the inputs by content, not by view
        // identity or row counts — a same-count edit still lands here.
        .onChange(of: inputFingerprint) { _, _ in refreshDerivedState() }
    }

    // MARK: - Input summary

    private var inputSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            summaryCard("Money coming in", systemImage: "arrow.down.circle") {
                if let schedule = activeSchedule {
                    SetupSummaryRow(label: "Take-home per check", value: MoneyFormat.string(schedule.baseTakeHome))
                    SetupSummaryRow(label: "How often", value: schedule.cadence.displayName)
                    SetupSummaryRow(label: "Next payday", value: DateMath.mediumString(schedule.anchorPayday))
                } else {
                    Text("No income entered yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            summaryCard("Cash on hand", systemImage: "building.columns") {
                ForEach(activeAccounts) { account in
                    SetupSummaryRow(label: account.name, value: MoneyFormat.string(account.currentBalance))
                }
                SetupSummaryRow(
                    label: "Total",
                    value: MoneyFormat.string(activeAccounts.reduce(Decimal.zero) { $0 + $1.currentBalance })
                )
                .font(.subheadline.weight(.semibold))
            }

            summaryCard("Your guardrails", systemImage: "shield") {
                // Render what exists — the review is read-only, and a missing
                // profile is already a blocker gap, never a row this screen
                // creates itself.
                let profile = profiles.first
                SetupSummaryRow(
                    label: "Protected floor",
                    value: MoneyFormat.string(profile?.protectedFloor ?? .zero)
                )
                SetupSummaryRow(
                    label: "Allowance per check",
                    value: MoneyFormat.string(profile?.allowanceCap ?? .zero)
                )
                Text("The allowance is available, not spent.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !essentialObligations.isEmpty {
                summaryCard("Essential bills", systemImage: "house") {
                    let cadence = activeSchedule?.cadence ?? .biweekly
                    ForEach(essentialObligations) { obligation in
                        SetupSummaryRow(
                            label: obligation.name,
                            value: MoneyFormat.string(obligation.amount) + " " + obligation.cadence.displayName.lowercased()
                        )
                    }
                    SetupSummaryRow(
                        label: "Set aside each check",
                        value: MoneyFormat.string(
                            essentialObligations.reduce(Decimal.zero) { running, obligation in
                                running + ObligationMath.perPaycheckReserve(
                                    amount: obligation.amount,
                                    cadence: obligation.cadence,
                                    paychecksPerYear: cadence.paychecksPerYear
                                )
                            }
                        )
                    )
                    .font(.subheadline.weight(.semibold))
                }
            }

            debtsCard
        }
    }

    private var debtsCard: some View {
        summaryCard("What you're paying off", systemImage: "creditcard") {
            if activeDebts.isEmpty {
                Text("No debts — the plan will still handle your bills, floor, and allowance.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(avalancheOrder) { debt in
                    SetupSummaryRow(
                        label: "\(debt.displayName) · \(SetupPercentField.percentString(debt.apr))%",
                        value: MoneyFormat.string(debt.startingBalance)
                    )
                }
                SetupSummaryRow(
                    label: "Total owed",
                    value: MoneyFormat.string(activeDebts.reduce(Decimal.zero) { $0 + $1.startingBalance })
                )
                .font(.subheadline.weight(.semibold))
                SetupSummaryRow(
                    label: "Minimums per month",
                    value: MoneyFormat.string(activeDebts.compactMap(\.minimumAmount).reduce(Decimal.zero, +))
                )
                if !cardsWithLimits.isEmpty {
                    SetupSummaryRow(
                        label: "Card limits",
                        value: MoneyFormat.string(cardsWithLimits.compactMap(\.creditLimit).reduce(Decimal.zero, +))
                    )
                    SetupSummaryRow(label: "Card usage", value: utilizationText)
                }
                Text("Highest rate first — this order costs the least interest.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var avalancheOrder: [DebtAccount] {
        activeDebts.sorted { lhs, rhs in
            if lhs.apr != rhs.apr {
                if lhs.apr == 0 { return false }
                if rhs.apr == 0 { return true }
                return lhs.apr > rhs.apr
            }
            if lhs.startingBalance != rhs.startingBalance {
                return lhs.startingBalance < rhs.startingBalance
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private var cardsWithLimits: [DebtAccount] {
        activeDebts.filter { $0.debtType == .creditCard && ($0.creditLimit ?? 0) > 0 }
    }

    private var utilizationText: String {
        // R-12/V4-04: the aggregate ratio goes through the one canonical
        // implementation like every per-card figure.
        let limit = cardsWithLimits.compactMap(\.creditLimit).reduce(Decimal.zero, +)
        let balance = cardsWithLimits.reduce(Decimal.zero) { $0 + $1.startingBalance }
        guard let utilization = UtilizationMath.utilization(balance: balance, limit: limit) else {
            return "—"
        }
        let percent = (utilization * 100).rounded2
        return "\(MoneyFormat.editingString(percent))% used"
    }

    // MARK: - What's missing

    private var blockers: [SetupGap] { gaps.filter(\.isBlocker) }
    private var softGaps: [SetupGap] { gaps.filter { !$0.isBlocker } }

    @ViewBuilder
    private var blockersSection: some View {
        if !blockers.isEmpty {
            summaryCard("Before we can build the plan", systemImage: "exclamationmark.circle") {
                ForEach(blockers) { gap in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gap.title).font(.subheadline.weight(.medium))
                        Text(gap.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityIdentifier("review.blockers")
        }
    }

    @ViewBuilder
    private var gapsSection: some View {
        if !softGaps.isEmpty {
            summaryCard("Estimated or not set", systemImage: "questionmark.circle") {
                Text("The plan works without these. Filling them in later makes it more accurate.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(softGaps) { gap in
                    SetupSummaryRow(label: gap.title, value: "")
                        .font(.footnote)
                }
            }
            .accessibilityIdentifier("review.gaps")
        }
    }

    private var estimateNote: some View {
        SetupExplainer(
            text: "These are estimates from your numbers, not a guarantee. Your card issuer's interest, statement minimums, and posting dates will differ — and the app updates its forecast whenever you enter a real balance.",
            systemImage: "info.circle"
        )
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func summaryCard<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Generate and commit

    private func refreshGaps() {
        gaps = (try? SetupCompletenessService(context: modelContext).gaps()) ?? []
    }

    /// Recomputes everything derived from the inputs, and drops a cached
    /// preview whose inputs have since changed (V4-02). The preview is
    /// cleared rather than silently rebuilt: the user confirms numbers they
    /// have actually seen, never a regeneration behind their back.
    private func refreshDerivedState() {
        refreshGaps()
        guard generated != nil,
              let captured = generatedFingerprint,
              let current = try? SetupInputFingerprint.capture(context: modelContext),
              current != captured
        else { return }
        invalidatePreview()
    }

    private func invalidatePreview() {
        generated = nil
        generatedFingerprint = nil
        staleNotice = "Some of your numbers changed since that preview was made, so it was cleared. Generate the plan again to see the current ones."
        refreshGaps()
    }

    private func generate() {
        generating = true
        error = nil
        staleNotice = nil
        do {
            // Fingerprint first: a mutation landing between the capture and
            // the engine run reads as a mismatch at commit and regenerates —
            // never the reverse, which would let a stale preview through.
            let fingerprint = try SetupInputFingerprint.capture(context: modelContext)
            generated = try PlanGenerationService.generate(
                context: modelContext,
                asOf: appEnvironment.dateProvider.now
            )
            generatedFingerprint = fingerprint
        } catch {
            self.error = error.localizedDescription
            refreshGaps()
        }
        generating = false
    }

    /// Commits atomically: the plan graph, settings, and progress row all
    /// land in one save, or nothing does and the user can retry (§4.0).
    /// The service re-verifies the fingerprint captured at Generate, so a
    /// preview outlived by its inputs can never persist (V4-02).
    private func commit() {
        guard let generated else { return }
        // A preview without its fingerprint has no provenance — treat it as
        // stale rather than letting it skip the guard.
        guard let generatedFingerprint else {
            invalidatePreview()
            return
        }
        do {
            try OnboardingProgressService(
                context: modelContext, dateProvider: appEnvironment.dateProvider
            ).finish(
                planName: PlanContract.generatedPlanName,
                input: generated.input,
                result: generated.rows,
                verifying: generatedFingerprint
            )
            onFinish()
        } catch OnboardingProgressService.FinishError.staleInputs {
            invalidatePreview()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Generated plan summary

private struct GeneratedPlanSummary: View {
    let plan: PlanGenerationService.GeneratedPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headline
            firstPlay
            if !plan.result.debtSummaries.isEmpty {
                payoffOrder
            }
            if !plan.result.warnings.isEmpty {
                warnings
            }
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let payoff = plan.rows.payoffDate {
                SetupSummaryRow(
                    label: "Projected debt-free",
                    value: DateMath.mediumString(payoff),
                    isEstimate: true
                )
                .font(.title3.weight(.semibold))
            } else if plan.rows.cappedAtPaycheckLimit {
                Label(
                    "With these numbers the debts don't finish paying off. Lowering the allowance or the floor, or adding income, changes that — and the plan still works meanwhile.",
                    systemImage: "exclamationmark.circle"
                )
                .font(.subheadline)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            SetupSummaryRow(
                label: "Paychecks to get there",
                value: "\(plan.rows.paycheckCount)",
                isEstimate: true
            )
            SetupSummaryRow(
                label: "Estimated interest",
                value: MoneyFormat.string(plan.rows.totalEstimatedInterest),
                isEstimate: true
            )
            if let comparison = plan.result.minimumOnlyComparison,
               let saved = comparison.interestSaved, saved > 0 {
                SetupSummaryRow(
                    label: "Saved vs. minimums only",
                    value: MoneyFormat.string(saved),
                    isEstimate: true
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("review.headline")
    }

    private var firstPlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your first payday")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let first = plan.rows.paydays.first {
                SetupSummaryRow(label: "On", value: DateMath.mediumString(first.date))
                SetupSummaryRow(label: "Keep in spending", value: MoneyFormat.string(first.keepInSpending))
                SetupSummaryRow(label: "Move to reserves", value: MoneyFormat.string(first.transferToReserves))
                if !first.obligationReserves.isEmpty {
                    SetupSummaryRow(
                        label: "Set aside for bills",
                        value: MoneyFormat.string(first.obligationReserves.reduce(Decimal.zero) { $0 + $1.amount })
                    )
                }
                SetupSummaryRow(label: "To your debts", value: MoneyFormat.string(first.debtBudget))
                if let target = firstTargetName {
                    SetupSummaryRow(label: "Attacking first", value: target)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var firstTargetName: String? {
        guard let targetID = plan.result.paychecks.first?.targetDebtID else { return nil }
        return plan.result.debtSummaries.first { $0.debtID == targetID }?.name
    }

    private var payoffOrder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Payoff order")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(orderedSummaries, id: \.debtID) { summary in
                SetupSummaryRow(
                    label: summary.name,
                    value: summary.payoffDate.map(DateMath.mediumString) ?? "not within the forecast",
                    isEstimate: true
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var orderedSummaries: [DebtPlanSummary] {
        let order = plan.result.payoffOrder
        return plan.result.debtSummaries.sorted { lhs, rhs in
            let lhsIndex = order.firstIndex(of: lhs.debtID) ?? Int.max
            let rhsIndex = order.firstIndex(of: rhs.debtID) ?? Int.max
            return lhsIndex < rhsIndex
        }
    }

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Worth knowing")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(plan.result.warnings.enumerated()), id: \.offset) { _, note in
                Label(note.message, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("review.warnings")
    }
}
