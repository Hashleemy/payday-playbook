import SwiftUI
import SwiftData

/// The consolidated Bills & Debts page (V3-08, §5.2).
///
/// One page, one add button, two sections. Used unchanged by the onboarding
/// step and the Settings management screen — same rows, same editors, same
/// warnings — so the two can never drift apart.
///
/// Everything a v0.2 user could enter is still enterable: this screen hosts
/// the existing `ObligationEditorView` and `DebtEditorView` rather than
/// reimplementing their fields, which is what keeps every field, validation
/// rule, editable due date, debt type, and extra-principal question intact.
struct BillsAndDebtsView: View {
    @Environment(\.modelContext) private var modelContext

    /// Observed so any store change to an input of the loaded state — a row
    /// edit as much as an insert or delete — refreshes the page; the
    /// displayed values come from the loaded state, not from these queries.
    /// Income and accounts are observed too: the per-paycheck reserve
    /// preview smooths against the live pay cadence, and rows name their
    /// linked account (V4-02).
    @Query private var obligations: [RecurringObligation]
    @Query private var debts: [DebtAccount]
    @Query private var schedules: [IncomeSchedule]
    @Query private var accounts: [CashAccount]

    /// Shown on the Settings surface, hidden inside the onboarding scaffold,
    /// which supplies its own heading.
    var showsHeading = true
    /// Review copy explaining what these items do to available cash and to the
    /// three scenarios (§5.2 item 8).
    var showsReview = true

    @State private var state = BillsAndDebtsState()
    @State private var loadError: String?
    @State private var showTypeChooser = false
    @State private var editingBill: ObligationEditorTarget?
    @State private var editingDebt: DebtEditorTarget?
    @State private var reorderingDebts = false
    @State private var reorderingBills = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeading {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bills & debts")
                        .font(.title2.bold())
                    Text("Everything that has to get paid, in one place.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }

            if let loadError {
                Label(loadError, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("billsAndDebts.error")
            }

            BillsAndDebtsSummary(state: state)

            if state.incompleteCount > 0 {
                IncompleteBanner(count: state.incompleteCount)
            }

            billsSection
            debtsSection

            addButton

            if showsReview {
                BillsAndDebtsReview(state: state)
            }
        }
        .sheet(isPresented: $showTypeChooser) {
            AddBillOrDebtChooser(
                onBill: { showTypeChooser = false; editingBill = .new(nil) },
                onDebt: { type in showTypeChooser = false; editingDebt = .new(type) }
            )
        }
        .sheet(item: $editingBill, onDismiss: reload) { target in
            ObligationEditorView(target: target, allowsDelete: true)
        }
        .sheet(item: $editingDebt, onDismiss: reload) { target in
            DebtEditorView(target: target, allowsDelete: true)
        }
        .task { reload() }
        // Resuming an interrupted setup re-reads the store; the rows the user
        // already saved are simply there, so nothing is ever added twice.
        //
        // V4-02: keyed to a content fingerprint, not row counts — an edit
        // that changes an amount, a cadence, or a due day without changing
        // how many rows exist must still reload the derived state.
        .onChange(of: inputFingerprint) { _, _ in reload() }
    }

    /// Row IDs + `updatedAt` across every input of the loaded state.
    private var inputFingerprint: String {
        ((try? SetupInputFingerprint.capture(context: modelContext))?.value) ?? ""
    }

    // MARK: - Bills

    private var billsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeading(
                    title: "Bills",
                    subtitle: "Rent, car, insurance, utilities — the ones that aren't optional.",
                    count: state.bills.count
                )
                Spacer(minLength: 8)
                if state.bills.count > 1 {
                    Button(reorderingBills ? "Done" : "Reorder") {
                        reorderingBills.toggle()
                    }
                    .font(.footnote)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("billsAndDebts.reorderBills")
                    .accessibilityHint("Changes the order bills are listed in. It doesn't change what the plan sets aside.")
                }
            }

            if state.bills.isEmpty {
                EmptyStateView(
                    title: "No bills yet",
                    message: "Add the ones you must pay. The plan sets aside a slice of every paycheck for them before deciding what can go to debt.",
                    symbolName: "house"
                )
            } else if reorderingBills {
                ReorderList(
                    items: state.bills.map { ($0.id, $0.name, $0.amount) },
                    note: "Drag to change the listed order. The plan still spreads each bill evenly across your paychecks.",
                    identifier: "billsAndDebts.billReorderList",
                    onMove: moveBills
                )
            } else {
                ForEach(state.bills) { bill in
                    BillRowView(row: bill) { openBill(bill.id) }
                }
            }
        }
        .accessibilityIdentifier("billsAndDebts.bills")
    }

    // MARK: - Debts

    private var debtsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeading(
                    title: "Debts",
                    subtitle: "Cards, loans, and anything else you're paying down.",
                    count: state.debts.count
                )
                Spacer(minLength: 8)
                if state.debts.count > 1 {
                    Button(reorderingDebts ? "Done" : "Reorder") {
                        reorderingDebts.toggle()
                    }
                    .font(.footnote)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("billsAndDebts.reorderDebts")
                    .accessibilityHint("Changes the order debts are listed in. The payoff order still comes from interest rates.")
                }
            }

            if state.debts.isEmpty {
                EmptyStateView(
                    title: "No debts yet",
                    message: "Add one for each card, loan, or bill you're paying down. If you have none, that's a complete answer — the plan still handles your bills, floor, and allowance.",
                    symbolName: "creditcard"
                )
            } else if reorderingDebts {
                ReorderList(
                    items: state.debts.map { ($0.id, $0.name, $0.balance) },
                    note: "Drag to change the listed order. The payoff order is still decided by interest rate.",
                    identifier: "billsAndDebts.debtReorderList",
                    onMove: moveDebts
                )
            } else {
                ForEach(state.debts) { debt in
                    DebtRowView(row: debt) { openDebt(debt.id) }
                }
                Text("The plan pays every minimum first, then sends what's left to the highest rate. This order is for your reading only — rates and balances decide who gets attacked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("billsAndDebts.debts")
    }

    // MARK: - Add

    /// §5.2 item 4/5: exactly one add action, and the type choice comes first
    /// so the form that opens only ever shows relevant fields.
    private var addButton: some View {
        Button {
            showTypeChooser = true
        } label: {
            Label("Add bill or debt", systemImage: "plus.circle.fill")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("billsAndDebts.add")
    }

    // MARK: - Actions

    private func reload() {
        do {
            state = try BillsAndDebtsLoader(context: modelContext).load()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func openBill(_ id: UUID) {
        guard let obligation = obligations.first(where: { $0.id == id }) else { return }
        editingBill = .existing(obligation)
    }

    private func openDebt(_ id: UUID) {
        guard let debt = debts.first(where: { $0.id == id }) else { return }
        editingDebt = .existing(debt)
    }

    private func moveDebts(from source: IndexSet, to destination: Int) {
        var ordered = state.debts
        ordered.move(fromOffsets: source, toOffset: destination)
        do {
            try DebtRepository(context: modelContext).reorder(ordered.map(\.id))
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func moveBills(from source: IndexSet, to destination: Int) {
        var ordered = state.bills
        ordered.move(fromOffsets: source, toOffset: destination)
        do {
            try ObligationRepository(context: modelContext).reorder(ordered.map(\.id))
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Summary header

private struct BillsAndDebtsSummary: View {
    let state: BillsAndDebtsState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SetupSummaryRow(label: "Bills", value: MoneyFormat.string(state.billTotal))
            SetupSummaryRow(
                label: "Set aside each paycheck",
                value: MoneyFormat.string(state.billReservePerPaycheck)
            )
            Divider()
            SetupSummaryRow(label: "Debt minimums", value: MoneyFormat.string(state.debtMinimumTotal))
            SetupSummaryRow(label: "Debt balance", value: MoneyFormat.string(state.debtPrincipalTotal))
            if state.incompleteCount > 0 {
                SetupSummaryRow(
                    label: "Items missing a detail",
                    value: "\(state.incompleteCount)"
                )
            }
            if !state.incomeEntered {
                Text("Per-paycheck figures assume every two weeks until you enter your pay schedule.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("billsAndDebts.summary")
    }
}

private struct IncompleteBanner: View {
    let count: Int

    var body: some View {
        Label {
            Text("\(count) item\(count == 1 ? "" : "s") \(count == 1 ? "is" : "are") missing a detail. The plan still works — those numbers are estimates until you fill them in.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("billsAndDebts.incompleteBanner")
    }
}

// MARK: - Review

/// §5.2 item 8: what these totals do to available cash, and how they reach the
/// three scenarios. Descriptive — it never tells the user their numbers are
/// wrong or too high.
private struct BillsAndDebtsReview: View {
    let state: BillsAndDebtsState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What this changes")
                .font(.subheadline.weight(.medium))
                .accessibilityAddTraits(.isHeader)

            SetupExplainer(
                text: "Essential bills come out of each paycheck first, spread evenly so a big one never lands as a surprise. Right now that's \(MoneyFormat.string(state.billReservePerPaycheck)) per paycheck held back before any debt money.",
                systemImage: "tray.and.arrow.down"
            )
            SetupExplainer(
                text: "Every debt minimum is paid before anything extra. That's \(MoneyFormat.string(state.debtMinimumTotal)) of committed payments across \(state.debts.count) debt\(state.debts.count == 1 ? "" : "s").",
                systemImage: "checkmark.circle"
            )
            SetupExplainer(
                text: "Whatever is left after your floor, allowance, bills, and minimums is what the three payoff plans differ over — Fastest Safe sends all of it to debt, Balanced keeps your allowance and savings, More Cushion holds back more.",
                systemImage: "square.stack.3d.up"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("billsAndDebts.review")
    }
}

// MARK: - Rows

private struct SectionHeading: View {
    let title: String
    let subtitle: String
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(count) item\(count == 1 ? "" : "s"). \(subtitle)")
        .accessibilityAddTraits(.isHeader)
    }
}

private struct BillRowView: View {
    let row: BillsAndDebtsState.BillRow
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(.body.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(row.detailText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        MoneyText(amount: row.amount, font: .body.weight(.semibold))
                        Text("\(MoneyFormat.string(row.perPaycheckReserve)) per check")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !row.isEssential {
                    Text("Not essential — recorded, but left out of the plan's reserves")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                MissingFieldsNote(warnings: row.warnings)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint("Opens the bill editor")
        .accessibilityIdentifier("billsAndDebts.bill.\(row.name)")
    }
}

private struct DebtRowView: View {
    let row: BillsAndDebtsState.DebtRow
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: DebtFormRules(type: row.debtType).symbolName)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(.body.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(row.detailText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    MoneyText(amount: row.balance, font: .body.weight(.semibold))
                }
                if !row.isExtraPrincipalEligible {
                    Text(
                        row.prepayment == .ineligible
                            ? "Extra principal isn't allowed on this one — the plan pays the required amount."
                            : "Extra principal is on hold until you confirm there's no prepayment penalty."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                MissingFieldsNote(warnings: row.warnings)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint("Opens the debt editor")
        .accessibilityIdentifier("billsAndDebts.debt.\(row.name)")
    }
}

/// Inline missing-field note. Icon plus text, never colour alone.
private struct MissingFieldsNote: View {
    let warnings: [String]

    var body: some View {
        if !warnings.isEmpty {
            Label {
                Text("Still needs \(ListFormat.sentence(warnings)).")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "questionmark.circle")
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.orange)
        }
    }
}

/// "a, b, and c" — used wherever a warning names more than one field.
enum ListFormat {
    static func sentence(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + ", and " + (items.last ?? "")
        }
    }
}

// MARK: - Reorder

/// Drag-to-reorder for either section. Reordering is always presentation only,
/// and the note above the list says so — a user who drags a debt to the top
/// must not come away thinking they changed which one gets attacked.
private struct ReorderList: View {
    struct Item: Identifiable {
        let id: UUID
        let name: String
        let amount: Decimal
    }

    let items: [Item]
    let note: String
    let identifier: String
    let onMove: (IndexSet, Int) -> Void

    init(
        items: [(UUID, String, Decimal)],
        note: String,
        identifier: String,
        onMove: @escaping (IndexSet, Int) -> Void
    ) {
        self.items = items.map { Item(id: $0.0, name: $0.1, amount: $0.2) }
        self.note = note
        self.identifier = identifier
        self.onMove = onMove
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(items) { item in
                    HStack {
                        Text(item.name)
                        Spacer(minLength: 8)
                        MoneyText(amount: item.amount, font: .footnote)
                    }
                    .frame(minHeight: 44)
                    .accessibilityLabel("\(item.name), \(MoneyFormat.string(item.amount))")
                }
                .onMove(perform: onMove)
            }
            .environment(\.editMode, .constant(.active))
            .frame(minHeight: CGFloat(max(items.count, 1)) * 56)
            .scrollDisabled(true)
            .listStyle(.plain)
            .accessibilityIdentifier(identifier)
        }
    }
}

// MARK: - Type chooser

/// §5.2 item 5: bill or debt first, then only the relevant fields. Choosing
/// "debt" reuses the existing type picker, which is what keeps the
/// type-specific field rules (`DebtFormRules`) in one place.
struct AddBillOrDebtChooser: View {
    @Environment(\.dismiss) private var dismiss
    let onBill: () -> Void
    let onDebt: (DebtType) -> Void

    @State private var choosingDebtType = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if choosingDebtType {
                    VStack(spacing: 8) {
                        Text("Each kind of debt asks for slightly different details.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(DebtType.allCases) { type in
                            ChooserRow(
                                title: type.displayName,
                                detail: nil,
                                symbolName: DebtFormRules(type: type).symbolName,
                                identifier: "addChooser.debtType.\(type.rawValue)"
                            ) { onDebt(type) }
                        }
                    }
                    .padding()
                } else {
                    VStack(spacing: 8) {
                        Text("Which is it? The next screen only asks for what that kind actually needs.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        ChooserRow(
                            title: "A bill",
                            detail: "Something you pay again and again — rent, insurance, a subscription.",
                            symbolName: "house",
                            identifier: "addChooser.bill",
                            action: onBill
                        )
                        ChooserRow(
                            title: "A debt",
                            detail: "A balance you're paying down — a card, a loan, a medical bill.",
                            symbolName: "creditcard",
                            identifier: "addChooser.debt"
                        ) { choosingDebtType = true }
                    }
                    .padding()
                }
            }
            .navigationTitle(choosingDebtType ? "What kind of debt?" : "Add bill or debt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if choosingDebtType {
                        Button("Back") { choosingDebtType = false }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }
}

private struct ChooserRow: View {
    let title: String
    var detail: String?
    let symbolName: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbolName)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                    if let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detail.map { "\(title). \($0)" } ?? title)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Settings host

/// The Settings entry point (§8.8). Same page, wrapped in a scroll view and a
/// navigation title.
struct SettingsBillsAndDebtsView: View {
    var body: some View {
        ScrollView {
            BillsAndDebtsView(showsHeading: false, showsReview: true)
                .padding()
        }
        .navigationTitle("Bills & debts")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.billsAndDebts")
    }
}
