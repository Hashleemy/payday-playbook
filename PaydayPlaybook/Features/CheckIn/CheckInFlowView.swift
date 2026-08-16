import SwiftUI
import SwiftData

/// Five-step guided payday check-in with a persistent reconciliation summary.
/// Planned values prefill the fields; nothing becomes an actual record until
/// the user saves a draft or marks the payday complete.
struct CheckInFlowView: View {
    let planItem: PaydayPlanItem

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var notificationScheduler: NotificationScheduler

    @State private var step = 1
    @State private var income: Decimal?
    @State private var outsideFunds: Decimal?
    @State private var incomeNote = ""
    @State private var c1Kept: Decimal?
    @State private var allowanceSpent: Decimal?
    @State private var c1Balance: Decimal?
    @State private var c2Transfer: Decimal?
    @State private var carReserve: Decimal?
    @State private var trainReserve: Decimal?
    @State private var cardPayments: [String: Decimal] = [:]
    @State private var reportedBalances: [String: Decimal] = [:]
    @State private var exception = ""
    @State private var completionError: String?
    @State private var isCompleted = false
    @State private var loaded = false
    @State private var debts: [AccountBalanceService.DebtBalance] = []
    @State private var existingCheckIn: PaydayCheckIn?
    @State private var priorC2Available: Decimal = .zero

    private let stepTitles = ["Income", "Checking 1", "Checking 2", "Card payments", "Reconcile"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isCompleted {
                    completedSummary
                } else {
                    stepHeader
                    stepBody
                    navigationBar
                    summaryBar
                }
            }
            .navigationTitle("Payday #\(planItem.sequenceNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                if !isCompleted {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Save Draft") { saveDraft(); dismiss() }
                            .accessibilityIdentifier("checkin.saveDraft")
                    }
                }
            }
            .onAppear(perform: loadDraft)
        }
    }

    // MARK: - Steps

    private var stepHeader: some View {
        VStack(spacing: 4) {
            Text("Step \(step) of 5 — \(stepTitles[step - 1])")
                .font(.subheadline.weight(.semibold))
            SwiftUI.ProgressView(value: Double(step), total: 5)
                .accessibilityLabel("Step \(step) of 5")
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var stepBody: some View {
        Form {
            switch step {
            case 1: incomeStep
            case 2: checking1Step
            case 3: checking2Step
            case 4: cardsStep
            default: reconcileStep
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var incomeStep: some View {
        Group {
            Section("Planned") {
                LabeledContent("Planned take-home") {
                    MoneyText(amount: planItem.plannedIncome)
                }
            }
            Section("What actually arrived") {
                MoneyField(label: "Actual take-home", value: $income)
                    .accessibilityIdentifier("checkin.income")
                MoneyField(label: "Outside funds used (optional)", value: $outsideFunds)
                TextField("Note — overtime, deduction, correction (optional)", text: $incomeNote, axis: .vertical)
            }
        }
    }

    private var checking1Step: some View {
        Group {
            Section("Planned") {
                LabeledContent("Keep in Checking 1") {
                    MoneyText(amount: planItem.plannedC1Keep)
                }
                if planItem.plannedBufferAdd > 0 {
                    LabeledContent("Includes buffer addition") {
                        MoneyText(amount: planItem.plannedBufferAdd)
                    }
                }
                LabeledContent("Allowance cap") {
                    MoneyText(amount: planItem.plannedAllowance)
                }
            }
            Section("What you actually did") {
                MoneyField(label: "Actually kept in C1", value: $c1Kept)
                    .accessibilityIdentifier("checkin.c1Kept")
                MoneyField(label: "Spending since last check (optional)", value: $allowanceSpent)
                MoneyField(label: "Current C1 balance", value: $c1Balance)
                    .accessibilityIdentifier("checkin.c1Balance")
            }
            Section {
                LabeledContent("Protected floor") {
                    MoneyText(amount: protectedFloor)
                }
                LabeledContent("No-spend ceiling after this check") {
                    MoneyText(amount: planItem.plannedC1NoSpendCeiling, color: .blue)
                }
                Text("The ceiling is the maximum if no allowance had ever been spent — it is not your actual balance.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var checking2Step: some View {
        Group {
            Section("Planned") {
                LabeledContent("Move to Checking 2") {
                    MoneyText(amount: planItem.plannedC2Transfer)
                }
                LabeledContent("Car reserve") {
                    MoneyText(amount: planItem.plannedCarReserve)
                }
                LabeledContent("Train reserve") {
                    MoneyText(amount: planItem.plannedTrainReserve)
                }
            }
            Section("What you actually did") {
                MoneyField(label: "Actual transfer to C2", value: $c2Transfer)
                    .accessibilityIdentifier("checkin.c2Transfer")
                MoneyField(label: "Actual car reserve", value: $carReserve)
                MoneyField(label: "Actual train reserve", value: $trainReserve)
            }
            Section {
                LabeledContent("Remaining for cards") {
                    MoneyText(amount: remainingForCards, font: .body.weight(.semibold))
                }
            }
        }
    }

    private var remainingForCards: Decimal {
        ((c2Transfer ?? 0) - (carReserve ?? 0) - (trainReserve ?? 0)).rounded2
    }

    /// The user's own protected floor, preferring their current profile
    /// setting and falling back to the value frozen into the plan that owns
    /// this payday. Previously a fixed constant, which displayed one user's
    /// floor to everyone.
    private var protectedFloor: Decimal {
        if let profile = try? modelContext.fetch(FetchDescriptor<UserGoalProfile>()).first,
           profile.protectedFloor > 0 {
            return profile.protectedFloor
        }
        let planVersionID = planItem.planVersionID
        let plan = (try? modelContext.fetch(
            FetchDescriptor<PlanVersion>(predicate: #Predicate { $0.id == planVersionID })
        ).first) ?? nil
        return plan?.protectedBuffer ?? .zero
    }

    private var cardsStep: some View {
        Group {
            Section("Planned") {
                LabeledContent("Total card budget") {
                    MoneyText(amount: planItem.plannedCardBudget)
                }
                LabeledContent("Recommended target") {
                    Text("Card \(planItem.plannedTargetDebtID)")
                        .font(.body.weight(.semibold))
                }
            }
            Section("Actual payments — edit each amount") {
                ForEach(debts, id: \.debt.planID) { item in
                    MoneyField(
                        label: "\(item.debt.displayName)\(item.isPaidOff ? " (paid off)" : "")",
                        value: paymentBinding(item.debt.planID)
                    )
                    .accessibilityIdentifier("checkin.payment.\(item.debt.planID)")
                }
            }
            Section {
                LabeledContent("Payments total") {
                    MoneyText(amount: paymentsTotal, font: .body.weight(.semibold))
                }
                LabeledContent(allocationLabel) {
                    MoneyText(
                        amount: allocationDelta < 0 ? -allocationDelta : allocationDelta,
                        color: allocationDelta < 0 ? .red : .secondary
                    )
                }
            }
        }
    }

    private var paymentsTotal: Decimal {
        cardPayments.values.reduce(Decimal.zero, +).rounded2
    }

    /// Positive = money left unallocated toward cards; negative = overallocated.
    private var allocationDelta: Decimal {
        (remainingForCards - paymentsTotal).rounded2
    }

    private var allocationLabel: String {
        allocationDelta < 0 ? "Overallocated" : "Unallocated card money"
    }

    private func paymentBinding(_ planID: String) -> Binding<Decimal?> {
        Binding(
            get: { cardPayments[planID] },
            set: { cardPayments[planID] = $0 }
        )
    }

    private var reconcileStep: some View {
        Group {
            Section("Does the money reconcile?") {
                LabeledContent("Take-home + outside funds") {
                    MoneyText(amount: ((income ?? 0) + (outsideFunds ?? 0)).rounded2)
                }
                LabeledContent("Kept in C1") {
                    MoneyText(amount: (c1Kept ?? 0).rounded2)
                }
                LabeledContent("Moved to C2") {
                    MoneyText(amount: (c2Transfer ?? 0).rounded2)
                }
                LabeledContent("Unallocated") {
                    MoneyText(
                        amount: unallocated,
                        color: unallocated == 0 ? .mint : (unallocated < 0 ? .red : .orange)
                    )
                }
            }
            Section("Plan versus actual") {
                PlanActualRow(label: "Income", planned: planItem.plannedIncome, actual: income)
                PlanActualRow(label: "C1 keep", planned: planItem.plannedC1Keep, actual: c1Kept)
                PlanActualRow(label: "C2 transfer", planned: planItem.plannedC2Transfer, actual: c2Transfer)
                PlanActualRow(
                    label: "Fixed reserve",
                    planned: planItem.plannedCarReserve + planItem.plannedTrainReserve,
                    actual: (carReserve == nil && trainReserve == nil) ? nil : ((carReserve ?? 0) + (trainReserve ?? 0))
                )
                PlanActualRow(label: "Card payments", planned: planItem.plannedCardBudget, actual: paymentsTotal)
            }
            Section("Post-payment balances (optional)") {
                Text("Enter the balance shown by each issuer after your payments posted. These become authoritative for the forecast.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(debts, id: \.debt.planID) { item in
                    if (cardPayments[item.debt.planID] ?? 0) > 0 {
                        MoneyField(
                            label: "\(item.debt.displayName) balance now",
                            value: reportedBalanceBinding(item.debt.planID)
                        )
                    }
                }
            }
            if needsException {
                Section("Explain the difference") {
                    ForEach(validationIssues.filter { !$0.isBlocking }, id: \.message) { issue in
                        Label(issue.message, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    TextField("Why doesn't this check reconcile?", text: $exception, axis: .vertical)
                        .accessibilityIdentifier("checkin.exception")
                }
            }
            if let completionError {
                Section {
                    Label(completionError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func reportedBalanceBinding(_ planID: String) -> Binding<Decimal?> {
        Binding(
            get: { reportedBalances[planID] },
            set: { reportedBalances[planID] = $0 }
        )
    }

    private var unallocated: Decimal {
        ((income ?? 0) + (outsideFunds ?? 0) - (c1Kept ?? 0) - (c2Transfer ?? 0)).rounded2
    }

    /// Single source of truth: the same validation that gates completion.
    private var validationIssues: [ReconciliationService.Issue] {
        ReconciliationService.validate(draftAmounts(), priorC2Available: max(priorC2Available, .zero))
    }

    private var needsException: Bool {
        validationIssues.contains { !$0.isBlocking }
    }

    /// Always-visible step navigation. Completion lives here too so the
    /// primary action is never hidden by a scrolled-away form row.
    private var navigationBar: some View {
        HStack(spacing: 10) {
            if step > 1 {
                Button("Back") { step -= 1 }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("checkin.back")
            }
            if step < 5 {
                Button {
                    step += 1
                } label: {
                    Text("Next")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("checkin.next")
            } else {
                Button {
                    complete()
                } label: {
                    Text("Mark Payday Complete")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("checkin.complete")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var summaryBar: some View {
        VStack(spacing: 2) {
            Divider()
            HStack {
                summaryCell("In", (income ?? 0) + (outsideFunds ?? 0))
                summaryCell("Kept", c1Kept ?? 0)
                summaryCell("Moved", c2Transfer ?? 0)
                summaryCell("Cards", paymentsTotal)
                summaryCell("Open", unallocated)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.thinMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Summary: received \(MoneyFormat.string((income ?? 0) + (outsideFunds ?? 0))), kept \(MoneyFormat.string(c1Kept ?? 0)), moved \(MoneyFormat.string(c2Transfer ?? 0)), card payments \(MoneyFormat.string(paymentsTotal)), unallocated \(MoneyFormat.string(unallocated))")
    }

    private func summaryCell(_ label: String, _ amount: Decimal) -> some View {
        VStack(spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(MoneyFormat.string(amount))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }

    private var completedSummary: some View {
        List {
            Section {
                Label(
                    existingCheckIn?.status == .needsAttention
                        ? "Completed with an exception"
                        : "Payday complete",
                    systemImage: existingCheckIn?.status == .needsAttention
                        ? "exclamationmark.circle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.headline)
                .foregroundStyle(existingCheckIn?.status == .needsAttention ? .orange : .mint)
                if let completedAt = existingCheckIn?.completedAt {
                    Text("Recorded \(completedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Recorded amounts") {
                PlanActualRow(label: "Income", planned: planItem.plannedIncome, actual: existingCheckIn?.actualIncome)
                PlanActualRow(label: "C1 keep", planned: planItem.plannedC1Keep, actual: existingCheckIn?.actualC1Kept)
                PlanActualRow(label: "C2 transfer", planned: planItem.plannedC2Transfer, actual: existingCheckIn?.actualC2Transfer)
                PlanActualRow(
                    label: "Reserves",
                    planned: planItem.plannedCarReserve + planItem.plannedTrainReserve,
                    actual: ((existingCheckIn?.actualCarReserve ?? 0) + (existingCheckIn?.actualTrainReserve ?? 0))
                )
            }
            if let exception = existingCheckIn?.reconciliationException {
                Section("Exception") {
                    Text(exception)
                }
            }
        }
    }

    // MARK: - Data

    private func loadDraft() {
        guard !loaded else { return }
        loaded = true
        let balanceService = appEnvironment.balanceService(context: modelContext)
        debts = (try? balanceService.debtBalances()) ?? []
        priorC2Available = (try? balanceService.checking2State().availableForDebt) ?? .zero

        let itemID = planItem.id
        let checkIn = try? modelContext.fetch(
            FetchDescriptor<PaydayCheckIn>(predicate: #Predicate { $0.paydayPlanItemID == itemID })
        ).first

        if let checkIn {
            existingCheckIn = checkIn
            if checkIn.status == .completed || checkIn.status == .needsAttention {
                isCompleted = true
                return
            }
            step = min(max(checkIn.currentStep, 1), 5)
            income = checkIn.actualIncome
            outsideFunds = checkIn.outsideFundsUsed
            c1Kept = checkIn.actualC1Kept
            c1Balance = checkIn.actualC1Balance
            allowanceSpent = checkIn.actualAllowanceSpent
            c2Transfer = checkIn.actualC2Transfer
            carReserve = checkIn.actualCarReserve
            trainReserve = checkIn.actualTrainReserve
            incomeNote = checkIn.note ?? ""
            exception = checkIn.reconciliationException ?? ""
            let checkInID = checkIn.id
            let payments = (try? modelContext.fetch(
                FetchDescriptor<CheckInCardPayment>(predicate: #Predicate { $0.checkInID == checkInID })
            )) ?? []
            for payment in payments {
                cardPayments[payment.debtPlanID] = payment.amount
                if let reported = payment.reportedBalanceAfter {
                    reportedBalances[payment.debtPlanID] = reported
                }
            }
        } else {
            prefillFromPlan()
        }
    }

    /// Prefills entry fields with planned values. These are field defaults the
    /// user confirms or edits — nothing is recorded until save/complete.
    private func prefillFromPlan() {
        income = planItem.plannedIncome
        c1Kept = planItem.plannedC1Keep
        // Expected C1 after keeping the planned amount; the user confirms or
        // corrects it on step 2.
        if let plan = (try? PlanRepository.currentPlan(context: modelContext)) ?? nil {
            let planVersionID = plan.id
            let items = ((try? modelContext.fetch(
                FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planVersionID })
            )) ?? [])
            if let c1 = try? appEnvironment.balanceService(context: modelContext)
                .checking1State(plan: plan, planItems: items) {
                c1Balance = (c1.actualBalance + planItem.plannedC1Keep).rounded2
            }
        }
        c2Transfer = planItem.plannedC2Transfer
        carReserve = planItem.plannedCarReserve
        trainReserve = planItem.plannedTrainReserve

        // Recommended split mirrors the plan rules: minimums to non-target
        // active cards, then the remainder attacks in avalanche order, rolling
        // past any card it fully retires.
        var remaining = planItem.plannedCardBudget
        var suggested: [String: Decimal] = [:]
        var payable: [String: Decimal] = Dictionary(
            uniqueKeysWithValues: debts.filter { !$0.isPaidOff }.map { ($0.debt.planID, $0.balance) }
        )
        for item in debts where !item.isPaidOff && item.debt.planID != planItem.plannedTargetDebtID {
            let minimum = (item.debt.minimumAmount ?? estimatedMinimum(for: item)).rounded2
            let capped = min(minimum, item.balance, max(remaining, 0)).rounded2
            if capped > 0 {
                suggested[item.debt.planID] = capped
                payable[item.debt.planID]? -= capped
                remaining -= capped
            }
        }
        let attackOrder = [planItem.plannedTargetDebtID]
            + debts.map(\.debt.planID).filter { $0 != planItem.plannedTargetDebtID }
        for planID in attackOrder {
            guard remaining > 0 else { break }
            guard let capacity = payable[planID], capacity > 0 else { continue }
            let attack = min(remaining, capacity).rounded2
            suggested[planID, default: .zero] += attack
            payable[planID]? -= attack
            remaining -= attack
        }
        cardPayments = suggested
    }

    private func estimatedMinimum(for item: AccountBalanceService.DebtBalance) -> Decimal {
        max(PlanContract.minimumPaymentFloor, (item.balance * PlanContract.minimumPaymentRate))
    }

    private func draftAmounts() -> ReconciliationService.DraftAmounts {
        ReconciliationService.DraftAmounts(
            actualIncome: income,
            outsideFundsUsed: outsideFunds ?? .zero,
            actualC1Kept: c1Kept,
            actualC1Balance: c1Balance,
            actualAllowanceSpent: allowanceSpent,
            actualC2Transfer: c2Transfer,
            actualCarReserve: carReserve,
            actualTrainReserve: trainReserve,
            cardPayments: cardPayments.compactMapValues { $0 },
            reportedBalances: reportedBalances.filter { (cardPayments[$0.key] ?? .zero) > 0 }
        )
    }

    private func ensureCheckIn() -> PaydayCheckIn {
        if let existingCheckIn { return existingCheckIn }
        let checkIn = PaydayCheckIn(paydayPlanItemID: planItem.id)
        modelContext.insert(checkIn)
        existingCheckIn = checkIn
        return checkIn
    }

    private func saveDraft() {
        let checkIn = ensureCheckIn()
        checkIn.actualIncome = income
        checkIn.outsideFundsUsed = outsideFunds
        checkIn.actualC1Kept = c1Kept
        checkIn.actualC1Balance = c1Balance
        checkIn.actualAllowanceSpent = allowanceSpent
        checkIn.actualC2Transfer = c2Transfer
        checkIn.actualCarReserve = carReserve
        checkIn.actualTrainReserve = trainReserve
        checkIn.note = incomeNote.isEmpty ? nil : incomeNote
        checkIn.reconciliationException = exception.isEmpty ? nil : exception
        checkIn.currentStep = step
        checkIn.updatedAt = Date()

        persistPaymentRows(checkIn: checkIn)
        try? modelContext.save()
    }

    private func persistPaymentRows(checkIn: PaydayCheckIn) {
        let checkInID = checkIn.id
        let existing = (try? modelContext.fetch(
            FetchDescriptor<CheckInCardPayment>(predicate: #Predicate { $0.checkInID == checkInID })
        )) ?? []
        for row in existing { modelContext.delete(row) }
        for (planID, amount) in cardPayments {
            modelContext.insert(CheckInCardPayment(
                checkInID: checkIn.id,
                debtPlanID: planID,
                amount: amount,
                reportedBalanceAfter: reportedBalances[planID]
            ))
        }
    }

    private func complete() {
        completionError = nil
        let checkIn = ensureCheckIn()
        checkIn.note = incomeNote.isEmpty ? nil : incomeNote
        persistPaymentRows(checkIn: checkIn)

        guard let plan = (try? PlanRepository.currentPlan(context: modelContext)) ?? nil else {
            completionError = "The plan could not be loaded."
            return
        }

        let debtsByID = Dictionary(uniqueKeysWithValues: debts.map { ($0.debt.planID, $0.debt) })

        do {
            let result = try ReconciliationService.completeCheckIn(
                context: modelContext,
                checkIn: checkIn,
                planItem: planItem,
                plan: plan,
                draft: draftAmounts(),
                debtsByPlanID: debtsByID,
                priorC2Available: max(priorC2Available, .zero),
                exception: exception.isEmpty ? nil : exception,
                now: appEnvironment.dateProvider.now
            )
            _ = result

            let varianceNote = varianceContext()
            _ = try? appEnvironment.reforecastService(context: modelContext)
                .reforecast(trigger: .paydayCompleted, varianceContext: varianceNote)
            try? appEnvironment.milestoneService(context: modelContext).refreshAchievements()

            notificationScheduler.cancelPaydayReminders(itemID: planItem.id)
            Task {
                await notificationScheduler.rescheduleAll(
                    context: modelContext,
                    dateProvider: appEnvironment.dateProvider
                )
            }
            isCompleted = true
        } catch {
            completionError = error.localizedDescription
        }
    }

    private func varianceContext() -> String? {
        let delta = (planItem.plannedCardBudget - paymentsTotal).rounded2
        if delta > 0 {
            return "This payday's card contributions were \(MoneyFormat.string(delta)) below plan."
        } else if delta < 0 {
            return "This payday's card contributions were \(MoneyFormat.string(-delta)) above plan."
        }
        return nil
    }
}
