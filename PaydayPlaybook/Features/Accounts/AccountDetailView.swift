import SwiftUI
import SwiftData

/// One account in full: the card's figures, the four money actions, recent
/// activity, and balance history (§5.1, §8.2).
///
/// Takes an account `id` rather than the model object so a deep link, or a
/// return from a sheet that archived something, resolves against the store
/// instead of holding a reference to a row that may no longer be shown.
struct AccountDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @Query private var accounts: [CashAccount]

    let accountID: UUID

    @State private var card: AccountsWorkspaceState.AccountCard?
    @State private var activity: [AccountActivityRow] = []
    @State private var history: [BalanceSnapshot] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var movement: AccountMovementTarget?
    @State private var editing: AccountEditorTarget?
    @State private var showArchiveConfirm = false
    @State private var showArchiveBlocked = false

    private var account: CashAccount? {
        accounts.first { $0.id == accountID }
    }

    private static let recentActivityLimit = 12

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading activity")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("account.detail.loading")
            } else if let account, let card {
                content(account: account, card: card)
            } else {
                EmptyStateView(
                    title: "This account is no longer here",
                    message: "It may have been removed on another screen. Everything it recorded is still in your history.",
                    symbolName: "questionmark.folder"
                )
            }
        }
        .navigationTitle(account?.name ?? "Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let account {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { editing = .existing(account) }
                        .accessibilityIdentifier("account.detail.edit")
                }
            }
        }
        .sheet(item: $movement, onDismiss: reload) { target in
            AccountMovementSheet(target: target)
        }
        .sheet(item: $editing, onDismiss: reload) { target in
            AccountEditorView(
                target: target,
                allowsDelete: false,
                showsProtectedAmount: true,
                balanceEditable: false
            )
        }
        .alert("Archive this account?", isPresented: $showArchiveConfirm) {
            Button("Archive", role: .destructive) { archive() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its activity and balance history stay exactly as they are. It just stops being offered for new movements, and you can restore it any time.")
        }
        .task { reload() }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(account: CashAccount, card: AccountsWorkspaceState.AccountCard) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                balanceHeader(card: card)
                AccountReconciliationBadge(reconciliation: card.reconciliation)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if case .needsAttention = card.reconciliation {
                    Button {
                        movement = .adjustment(account)
                    } label: {
                        Label("Record what the balance really is", systemImage: "equal.circle")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("account.detail.reconcile")
                }

                actionGrid(account: account, card: card)

                if let movement = card.nextMovement {
                    plannedMovementSection(movement)
                }

                activitySection(account: account)
                historySection

                archiveSection(card: card)

                if let error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
        }
        .refreshable { reload() }
        .sheet(isPresented: $showArchiveBlocked) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(card.archiveBlockers) { blocker in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(blocker.title)
                                    .font(.subheadline.weight(.medium))
                                Text(blocker.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding()
                }
                .navigationTitle("Can't archive yet")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("OK") { showArchiveBlocked = false }
                    }
                }
            }
        }
    }

    private func balanceHeader(card: AccountsWorkspaceState.AccountCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.rolesSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            MoneyText(amount: card.currentBalance, font: .largeTitle.weight(.semibold))
            Text(card.balanceAsOfText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if card.isDefaultIncome {
                Label("Gets your paycheck", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.mint)
            }
            Divider()
            SetupSummaryRow(label: "Protected", value: MoneyFormat.string(card.protectedAmount))
            SetupSummaryRow(label: "Available to the plan", value: MoneyFormat.string(card.availableBalance))
            Text("Last updated \(DateFormat.medium(card.updatedAt))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(card.accessibilityLabel)
        .accessibilityIdentifier("account.detail.header")
    }

    private func actionGrid(
        account: CashAccount,
        card: AccountsWorkspaceState.AccountCard
    ) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                actionButton("Deposit", "arrow.down.left", "account.action.deposit") {
                    movement = .deposit(account)
                }
                actionButton("Withdraw", "arrow.up.right", "account.action.withdrawal") {
                    movement = .withdrawal(account)
                }
            }
            HStack(spacing: 8) {
                if accounts.filter({ !$0.isArchived }).count > 1 {
                    actionButton("Transfer", "arrow.left.arrow.right", "account.action.transfer") {
                        movement = .transfer(account)
                    }
                }
                actionButton("Update balance", "equal.circle", "account.action.adjustment") {
                    movement = .adjustment(account)
                }
            }
            if !card.isDefaultIncome {
                Button("Make this the paycheck account") { setDefaultIncome(account) }
                    .font(.footnote)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("account.action.makeDefault")
            }
        }
    }

    private func actionButton(
        _ title: String,
        _ symbol: String,
        _ identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(identifier)
    }

    private func plannedMovementSection(_ movement: PlannedAccountMovement) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Next planned movement")
                .font(.subheadline.weight(.medium))
                .accessibilityAddTraits(.isHeader)
            Label {
                Text(movement.summary)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: movement.kind.symbolName)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            Text("From your plan and bills. It hasn't happened yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account.detail.plannedMovement")
    }

    // MARK: Activity

    private func activitySection(account: CashAccount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity")
                    .font(.subheadline.weight(.medium))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if activity.count >= Self.recentActivityLimit {
                    NavigationLink("See all") {
                        AccountActivityListView(accountID: accountID)
                    }
                    .font(.footnote)
                    .accessibilityIdentifier("account.detail.allActivity")
                }
            }

            if activity.isEmpty {
                EmptyStateView(
                    title: "Nothing recorded yet",
                    message: "Deposits, withdrawals, transfers, and balance updates show up here, newest first.",
                    symbolName: "list.bullet.rectangle"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(activity) { row in
                        AccountActivityRowView(row: row)
                        if row.id != activity.last?.id { Divider() }
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .accessibilityIdentifier("account.detail.activity")
    }

    // MARK: Balance history

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Balance history")
                .font(.subheadline.weight(.medium))
                .accessibilityAddTraits(.isHeader)

            if history.isEmpty {
                Text("No balance has been confirmed yet. When you update the balance, each figure you state is kept here with its date.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(history) { snapshot in
                        BalanceHistoryRowView(snapshot: snapshot)
                        if snapshot.id != history.last?.id { Divider() }
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .accessibilityIdentifier("account.detail.history")
    }

    // MARK: Archive

    private func archiveSection(card: AccountsWorkspaceState.AccountCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(role: card.canArchive ? .destructive : nil) {
                if card.canArchive { showArchiveConfirm = true } else { showArchiveBlocked = true }
            } label: {
                Label(
                    card.canArchive ? "Archive this account" : "Why can't I archive this?",
                    systemImage: card.canArchive ? "archivebox" : "questionmark.circle"
                )
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("account.detail.archive")

            if !card.canArchive, let first = card.archiveBlockers.first {
                Text(first.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private func reload() {
        guard let account else {
            isLoading = false
            return
        }
        do {
            let state = try AccountsWorkspaceLoader(
                context: modelContext, dateProvider: appEnvironment.dateProvider
            ).load()
            card = state.cards.first { $0.id == accountID }
            let loader = AccountActivityLoader(context: modelContext)
            activity = try loader.rows(for: account, limit: Self.recentActivityLimit)
            history = try loader.balanceHistory(for: account)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func setDefaultIncome(_ account: CashAccount) {
        do {
            try CashAccountRepository(context: modelContext).setDefaultIncome(account)
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func archive() {
        guard let account else { return }
        do {
            let archived = try CashAccountRepository(context: modelContext)
                .archiveIfAllowed(account, now: appEnvironment.dateProvider.now)
            if archived {
                dismiss()
            } else {
                showArchiveBlocked = true
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Full activity list

struct AccountActivityListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var accounts: [CashAccount]
    let accountID: UUID

    @State private var rows: [AccountActivityRow] = []
    @State private var error: String?

    var body: some View {
        List {
            if rows.isEmpty && error == nil {
                EmptyStateView(
                    title: "Nothing recorded yet",
                    message: "Every deposit, withdrawal, transfer, and balance update lands here.",
                    symbolName: "list.bullet.rectangle"
                )
                .listRowSeparator(.hidden)
            }
            ForEach(rows) { row in
                AccountActivityRowView(row: row)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("account.activityList")
        .task {
            guard let account = accounts.first(where: { $0.id == accountID }) else { return }
            do {
                rows = try AccountActivityLoader(context: modelContext).rows(for: account)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Rows

struct AccountActivityRowView: View {
    let row: AccountActivityRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.symbolName)
                .foregroundStyle(row.signedAmount < 0 ? Color.secondary : Color.mint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.typeName)
                    .font(.footnote.weight(.medium))
                Text(row.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = row.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(row.amountText)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
    }
}

struct BalanceHistoryRowView: View {
    let snapshot: BalanceSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: snapshot.isAuthoritative ? "checkmark.seal" : "circle.dotted")
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(DateFormat.medium(snapshot.effectiveDate))
                    .font(.footnote.weight(.medium))
                Text(snapshot.sourceType.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let note = snapshot.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            MoneyText(amount: snapshot.amount, font: .footnote.weight(.semibold))
        }
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(MoneyFormat.string(snapshot.amount)) as of \(DateFormat.medium(snapshot.effectiveDate)), \(snapshot.sourceType.displayName)"
        )
    }
}
