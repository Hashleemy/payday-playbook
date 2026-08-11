import SwiftUI
import SwiftData

/// Which fields a debt type asks for (§4.7). Kept beside the form rather
/// than on the model: these are presentation rules, and the engine's own
/// requirements live in `ModelValidation`.
struct DebtFormRules {
    let type: DebtType

    /// Installment debts have a known original principal and a contractual
    /// payment; cards and medical bills often don't.
    var originalPrincipal: FieldRequirement {
        switch type {
        case .personalLoan, .autoLoan, .studentLoan: return .required
        case .creditCard, .medicalDebt, .other: return .optional
        }
    }

    /// Only credit cards may leave the minimum blank (R-06 estimates it).
    var minimum: FieldRequirement {
        type.requiresEnteredMinimum ? .required : .optional
    }

    var dueDay: FieldRequirement {
        switch type {
        case .creditCard, .personalLoan, .autoLoan, .studentLoan: return .required
        case .medicalDebt, .other: return .optional
        }
    }

    var showsCreditLimit: Bool { type.supportsCreditLimit }

    /// Loans are where a prepayment penalty can exist; cards never have one.
    var showsPrepaymentQuestion: Bool { type != .creditCard }

    var namePlaceholder: String {
        switch type {
        case .creditCard: return "Blue card"
        case .personalLoan: return "Consolidation loan"
        case .autoLoan: return "Car payment"
        case .studentLoan: return "Student loan"
        case .medicalDebt: return "Hospital bill"
        case .other: return "Other debt"
        }
    }

    var balanceLabel: String {
        type == .creditCard ? "Balance today" : "Principal left"
    }

    var minimumLabel: String {
        type == .creditCard ? "Minimum payment" : "Monthly payment"
    }

    var minimumHelp: String {
        type == .creditCard
            ? "Leave this blank and the app estimates it from the balance. Your statement's number is always better."
            : "The contractual amount you owe each period."
    }

    var symbolName: String {
        switch type {
        case .creditCard: return "creditcard"
        case .personalLoan: return "banknote"
        case .autoLoan: return "car"
        case .studentLoan: return "graduationcap"
        case .medicalDebt: return "cross.case"
        case .other: return "doc.text"
        }
    }
}

/// Steps 4 and 5 — the debt type picker and the type-specific detail form
/// (§4.7; V2-04, V2-05).
struct DebtsStepView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var debts: [DebtAccount]

    let onContinue: () -> Void
    let onBack: () -> Void

    @State private var showTypePicker = false
    @State private var editing: DebtEditorTarget?

    private var activeDebts: [DebtAccount] {
        debts.filter { !$0.isArchived }
            .sorted { ($0.priority, $0.createdAt) < ($1.priority, $1.createdAt) }
    }

    var body: some View {
        OnboardingScaffold(
            title: "What are you paying off?",
            subtitle: "Add each debt with the numbers from your latest statement. Estimates are fine — you can correct them any time.",
            continueTitle: activeDebts.isEmpty ? "I have no debts" : "Continue",
            continueIdentifier: "onboarding.debtsContinue",
            onBack: onBack,
            onContinue: onContinue
        ) {
            if activeDebts.isEmpty {
                EmptyStateView(
                    title: "No debts added",
                    message: "Add one for each card, loan, or bill you're paying down. If you have none, you can continue — the plan will still handle your bills, floor, and allowance.",
                    symbolName: "creditcard"
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(activeDebts) { debt in
                        SetupDebtRow(debt: debt) { editing = .existing(debt) }
                    }
                }
                DebtsTotalRow(debts: activeDebts)
            }

            Button {
                showTypePicker = true
            } label: {
                Label("Add a debt", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("debts.add")

            SetupExplainer(
                text: "The app pays every minimum first, then sends everything left to the highest-rate debt. Rates and balances decide the order — nothing else.",
                systemImage: "arrow.down.right.circle"
            )
        }
        .sheet(isPresented: $showTypePicker) {
            DebtTypePickerView { type in
                showTypePicker = false
                editing = .new(type)
            }
        }
        .sheet(item: $editing) { target in
            DebtEditorView(target: target, allowsDelete: true)
        }
    }
}

// MARK: - Rows

private struct SetupDebtRow: View {
    let debt: DebtAccount
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: DebtFormRules(type: debt.debtType).symbolName)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(debt.displayName)
                        .font(.body.weight(.medium))
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let utilization = utilizationText {
                        Text(utilization)
                            .font(.caption)
                            .foregroundStyle(utilizationColor)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    MoneyText(amount: debt.startingBalance, font: .body.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the debt editor")
        .accessibilityIdentifier("debts.row.\(debt.displayName)")
    }

    private var detail: String {
        var parts = [debt.debtType.displayName, "\(SetupPercentField.percentString(debt.apr))% APR"]
        if let minimum = debt.minimumAmount {
            parts.append("min \(MoneyFormat.string(minimum))")
        } else if debt.debtType == .creditCard {
            parts.append("min estimated")
        }
        return parts.joined(separator: " · ")
    }

    private var utilizationText: String? {
        guard debt.debtType == .creditCard else { return nil }
        guard let utilization = debt.utilization(currentBalance: debt.startingBalance) else {
            return debt.creditLimit == nil ? "Credit limit unknown" : nil
        }
        let percent = (utilization * 100).rounded2
        return "\(MoneyFormat.editingString(percent))% of the limit used"
    }

    private var utilizationColor: Color {
        guard let utilization = debt.utilization(currentBalance: debt.startingBalance) else {
            return .secondary
        }
        if utilization >= Decimal(string: "0.9")! { return .orange }
        if utilization >= Decimal(string: "0.3")! { return .yellow }
        return .secondary
    }

    private var accessibilityLabel: String {
        var parts = [debt.displayName, MoneyFormat.string(debt.startingBalance), detail]
        if let utilizationText { parts.append(utilizationText) }
        return parts.joined(separator: ", ")
    }
}

private struct DebtsTotalRow: View {
    let debts: [DebtAccount]

    var body: some View {
        SetupSummaryRow(
            label: "\(debts.count) debt\(debts.count == 1 ? "" : "s")",
            value: MoneyFormat.string(debts.reduce(Decimal.zero) { $0 + $1.startingBalance })
        )
        .font(.subheadline.weight(.medium))
    }
}

// MARK: - Type picker (step 4)

struct DebtTypePickerView: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (DebtType) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    Text("Each kind of debt asks for slightly different details.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(DebtType.allCases) { type in
                        Button {
                            onSelect(type)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: DebtFormRules(type: type).symbolName)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 28)
                                    .accessibilityHidden(true)
                                Text(type.displayName)
                                    .font(.body.weight(.medium))
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                            .padding(12)
                            .background(
                                Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("debtType.\(type.rawValue)")
                    }
                }
                .padding()
            }
            .navigationTitle("What kind of debt?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Editor (step 5)

enum DebtEditorTarget: Identifiable {
    case new(DebtType)
    case existing(DebtAccount)

    var id: String {
        switch self {
        case .new(let type): return "new-\(type.rawValue)"
        case .existing(let debt): return debt.id.uuidString
        }
    }

    var debt: DebtAccount? {
        switch self {
        case .new: return nil
        case .existing(let debt): return debt
        }
    }

    var type: DebtType {
        switch self {
        case .new(let type): return type
        case .existing(let debt): return debt.debtType
        }
    }
}

struct DebtEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment

    let target: DebtEditorTarget
    var allowsDelete = false

    @State private var type: DebtType = .creditCard
    @State private var name = ""
    @State private var balance: Decimal?
    @State private var originalPrincipal: Decimal?
    @State private var apr: Decimal?
    @State private var minimum: Decimal?
    @State private var dueDay: Int?
    @State private var creditLimit: Decimal?
    @State private var limitUnknown = false
    @State private var prepayment: PrepaymentEligibility = .eligible
    @State private var note = ""
    @State private var isActive = true
    @State private var error: String?
    @State private var loaded = false

    private var rules: DebtFormRules { DebtFormRules(type: type) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SetupField(
                        title: "What do you call it?",
                        requirement: .required,
                        help: "A nickname is plenty. Never the full account number."
                    ) {
                        TextField(rules.namePlaceholder, text: $name)
                            .textFieldStyle(.roundedBorder)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("debt.name")
                    }

                    SetupMoneyField(
                        title: rules.balanceLabel,
                        value: $balance,
                        requirement: .required,
                        help: "What you owe on it today.",
                        error: balanceError
                    )
                    .accessibilityIdentifier("debt.balance")

                    if rules.originalPrincipal != .optional || originalPrincipal != nil || type != .creditCard {
                        SetupMoneyField(
                            title: "Original amount borrowed",
                            value: $originalPrincipal,
                            requirement: rules.originalPrincipal,
                            help: "Used to show how far you've come. It never changes a payment.",
                            error: originalPrincipalError
                        )
                        .accessibilityIdentifier("debt.originalPrincipal")
                    }

                    SetupPercentField(
                        title: "Interest rate (APR)",
                        rate: $apr,
                        requirement: .required,
                        help: type == .medicalDebt
                            ? "Often 0% on medical bills — that's a valid answer."
                            : "From your statement. 0% is fine if it's a promo or interest-free.",
                        error: aprError
                    )
                    .accessibilityIdentifier("debt.apr")

                    SetupMoneyField(
                        title: rules.minimumLabel,
                        value: $minimum,
                        requirement: rules.minimum,
                        help: rules.minimumHelp,
                        error: minimumError
                    )
                    .accessibilityIdentifier("debt.minimum")

                    SetupDayField(
                        title: "Payment due day",
                        day: $dueDay,
                        requirement: rules.dueDay,
                        help: "The day of the month it's due. Change it any time and the calendar and reminders follow.",
                        error: dueDayError
                    )

                    if rules.showsCreditLimit {
                        creditLimitSection
                    }

                    if rules.showsPrepaymentQuestion {
                        prepaymentSection
                    }

                    SetupField(
                        title: "Note",
                        requirement: .optional,
                        help: "Anything you want to remember about this debt."
                    ) {
                        TextField("Optional", text: $note, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("debt.note")
                    }

                    if target.debt != nil {
                        Toggle("Still paying this off", isOn: $isActive)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("debt.active")
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if allowsDelete, let debt = target.debt {
                        Button(role: .destructive) {
                            delete(debt)
                        } label: {
                            Label("Remove this debt", systemImage: "trash")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("debt.delete")
                    }
                }
                .padding()
            }
            .navigationTitle(target.debt == nil ? "New \(type.displayName.lowercased())" : "Edit debt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!isValid)
                        .accessibilityIdentifier("debt.save")
                }
            }
            .task {
                guard !loaded else { return }
                loaded = true
                load()
            }
        }
    }

    // MARK: Card limit and utilization

    private var creditLimitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SetupMoneyField(
                title: "Credit limit",
                value: $creditLimit,
                requirement: limitUnknown ? .unknown : .required,
                help: "Used to show how much of the card is in use. It never changes a payment.",
                error: creditLimitError
            )
            .disabled(limitUnknown)
            .accessibilityIdentifier("debt.creditLimit")

            Toggle("I don't know the limit", isOn: $limitUnknown)
                .frame(minHeight: 44)
                .accessibilityIdentifier("debt.limitUnknown")
                .onChange(of: limitUnknown) { _, unknown in
                    if unknown { creditLimit = nil }
                }

            if let utilization = utilizationPreview {
                SetupSummaryRow(label: "Card in use", value: utilization)
                    .font(.subheadline)
            } else if limitUnknown {
                Text("Without a limit the app can't show card usage — everything else still works.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var utilizationPreview: String? {
        guard let creditLimit, creditLimit > 0, let balance else { return nil }
        let percent = ((balance / creditLimit) * 100).rounded2
        var text = "\(MoneyFormat.editingString(percent))%"
        if percent >= 90 {
            text += " — that's high; paying it down helps your credit score too"
        } else if percent >= 30 {
            text += " — above 30%"
        }
        return text
    }

    // MARK: Prepayment

    private var prepaymentSection: some View {
        SetupField(
            title: "Can you pay extra toward the principal?",
            requirement: .required,
            help: "Some loans charge a fee for paying early. If you're not sure, say so — the app will stick to the required payment until you confirm."
        ) {
            Picker("Extra principal", selection: $prepayment) {
                Text("Yes, extra is allowed").tag(PrepaymentEligibility.eligible)
                Text("No, there's a prepayment penalty").tag(PrepaymentEligibility.ineligible)
                Text("I'm not sure").tag(PrepaymentEligibility.unknown)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier("debt.prepayment")
        }
    }

    // MARK: Validation

    private var balanceError: String? {
        guard let balance else { return nil }
        return balance < 0 ? "The balance can't be negative." : nil
    }

    private var originalPrincipalError: String? {
        guard let originalPrincipal else { return nil }
        if originalPrincipal < 0 { return "The original amount can't be negative." }
        if let balance, originalPrincipal < balance {
            return "The original amount is less than what's left. Double-check one of them."
        }
        return nil
    }

    private var aprError: String? {
        guard let apr else { return nil }
        if apr < 0 { return "The APR can't be negative." }
        if apr > 1 { return "That reads as \(SetupPercentField.percentString(apr))%. Enter the rate as a percent, like 24.99." }
        return nil
    }

    private var minimumError: String? {
        if rules.minimum == .required, let minimum, minimum <= 0 {
            return "\(type.displayName) needs its contractual payment amount."
        }
        guard let minimum else { return nil }
        if minimum < 0 { return "The payment can't be negative." }
        if let balance, minimum > balance, balance > 0 {
            return "That's more than the balance. It'll just pay the debt off."
        }
        return nil
    }

    private var dueDayError: String? {
        guard rules.dueDay == .required, dueDay == nil else { return nil }
        return nil // Surfaced as a review-step "missing detail", never a block.
    }

    private var creditLimitError: String? {
        guard !limitUnknown, let creditLimit else { return nil }
        if creditLimit <= 0 { return "The credit limit needs to be more than zero." }
        if let balance, balance > creditLimit {
            return "The balance is over the limit. That's possible — just double-check it."
        }
        return nil
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let balance, balance >= 0 else { return false }
        guard let apr, apr >= 0, apr <= 1 else { return false }
        if rules.minimum == .required {
            guard let minimum, minimum > 0 else { return false }
        }
        if let minimum, minimum < 0 { return false }
        if !limitUnknown, let creditLimit, creditLimit <= 0 { return false }
        if let originalPrincipal, originalPrincipal < 0 { return false }
        return true
    }

    // MARK: Persistence

    private func load() {
        type = target.type
        guard let debt = target.debt else {
            // A card whose limit hasn't been asked for yet starts "unknown"
            // only after the user says so — required until then.
            return
        }
        name = debt.displayName
        balance = debt.startingBalance
        originalPrincipal = debt.originalPrincipal
        apr = debt.apr
        minimum = debt.minimumAmount
        dueDay = debt.dueDayOfMonth
        creditLimit = debt.creditLimit
        limitUnknown = debt.creditLimitMarkedUnknown
        prepayment = debt.prepayment
        note = debt.setupNote ?? ""
        isActive = !debt.isArchived
    }

    private func save() {
        let repository = DebtRepository(context: modelContext)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let debt = target.debt {
                try repository.update(
                    debt, type: type, displayName: name, currentBalance: balance ?? .zero,
                    apr: apr ?? .zero, minimumAmount: minimum,
                    originalPrincipal: originalPrincipal,
                    creditLimit: limitUnknown ? nil : creditLimit,
                    dueDayOfMonth: dueDay, prepayment: prepayment,
                    note: trimmedNote.isEmpty ? nil : trimmedNote,
                    creditLimitMarkedUnknown: limitUnknown,
                    isArchived: !isActive, now: appEnvironment.dateProvider.now
                )
            } else {
                try repository.create(
                    type: type, displayName: name, currentBalance: balance ?? .zero,
                    apr: apr ?? .zero, minimumAmount: minimum,
                    originalPrincipal: originalPrincipal,
                    creditLimit: limitUnknown ? nil : creditLimit,
                    dueDayOfMonth: dueDay, prepayment: prepayment,
                    note: trimmedNote.isEmpty ? nil : trimmedNote,
                    creditLimitMarkedUnknown: limitUnknown,
                    now: appEnvironment.dateProvider.now
                )
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ debt: DebtAccount) {
        do {
            try DebtRepository(context: modelContext).delete(debt)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
