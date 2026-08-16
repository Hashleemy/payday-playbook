import SwiftUI
import SwiftData

/// The Checking Accounts workspace — the fifth tab (V3-02).
///
/// Everything on screen comes from `AccountsWorkspaceState`, assembled in a
/// `.task` and refreshed when a sheet commits. No balance arithmetic,
/// reconciliation, or repository call happens inside a view body.
struct AccountsTabView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var router: AppRouter

    /// Observed so the list refreshes when a sheet writes; the *values* shown
    /// still come from the loaded state.
    @Query private var accounts: [CashAccount]

    @State private var state = AccountsWorkspaceState()
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var isReordering = false
    @State private var editing: AccountEditorTarget?
    @State private var movement: AccountMovementTarget?
    @State private var archiveTarget: CashAccount?
    @State private var blockedArchive: AccountsWorkspaceState.AccountCard?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading your accounts")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("accounts.loading")
                } else if let loadError {
                    AccountsLoadFailure(message: loadError) { reload() }
                } else if state.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .navigationTitle("Accounts")
            .toolbar { toolbar }
            .sheet(item: $editing, onDismiss: reload) { target in
                AccountEditorView(
                    target: target,
                    allowsDelete: false,
                    showsProtectedAmount: true,
                    // In the workspace a balance change is a dated fact with a
                    // ledger consequence, so it goes through the adjustment
                    // sheet. Onboarding still types an opening balance freely —
                    // there is no history to reconcile against yet.
                    balanceEditable: target.account == nil
                )
            }
            .sheet(item: $movement, onDismiss: reload) { target in
                AccountMovementSheet(target: target)
            }
            .alert(
                "Archive \(archiveTarget?.name ?? "this account")?",
                isPresented: Binding(
                    get: { archiveTarget != nil },
                    set: { if !$0 { archiveTarget = nil } }
                )
            ) {
                Button("Archive", role: .destructive) { confirmArchive() }
                Button("Cancel", role: .cancel) { archiveTarget = nil }
            } message: {
                Text("Its balance history and activity stay exactly as they are. The account just stops being offered for new activity, and you can restore it any time.")
            }
            .sheet(item: $blockedArchive) { card in
                ArchiveBlockedSheet(card: card)
            }
        }
        .task { reload() }
        .onChange(of: accounts.count) { _, _ in reload() }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(spacing: 12) {
                AccountsSummaryHeader(state: state)

                if state.attentionCount > 0 {
                    AccountsAttentionBanner(count: state.attentionCount)
                }

                if isReordering {
                    AccountsReorderList(
                        cards: state.cards,
                        onMove: move,
                        onDone: { isReordering = false }
                    )
                } else {
                    ForEach(state.cards) { card in
                        NavigationLink {
                            AccountDetailView(accountID: card.id)
                        } label: {
                            AccountCardView(card: card)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { cardActions(for: card) }
                        .accessibilityIdentifier("accounts.card.\(card.name)")
                    }
                }

                if !isReordering {
                    addButton
                    if state.archivedCount > 0 {
                        NavigationLink {
                            ArchivedAccountsView()
                        } label: {
                            Label(
                                "\(state.archivedCount) archived account\(state.archivedCount == 1 ? "" : "s")",
                                systemImage: "archivebox"
                            )
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("accounts.archived")
                    }
                }
            }
            .padding()
        }
        .refreshable { reload() }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 16) {
                EmptyStateView(
                    title: "No accounts yet",
                    message: "Add the checking account your paycheck lands in. Only a name and the balance you type — never an account number or a login.",
                    symbolName: "building.columns"
                )
                addButton
            }
            .padding()
        }
    }

    private var addButton: some View {
        Group {
            if state.isAtCap {
                Text("That's the \(AccountsWorkspaceState.accountCap)-account limit. Archive one to add another.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    editing = .new
                } label: {
                    Label("Add a checking account", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("accounts.add")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if state.cards.count > 1 {
                Button(isReordering ? "Done" : "Reorder") {
                    isReordering.toggle()
                }
                .accessibilityIdentifier("accounts.reorderToggle")
                .accessibilityHint(isReordering ? "Stops reordering" : "Rearrange the order accounts appear in")
            }
        }
    }

    @ViewBuilder
    private func cardActions(for card: AccountsWorkspaceState.AccountCard) -> some View {
        if let account = account(for: card.id) {
            Button {
                movement = .deposit(account)
            } label: { Label("Record a deposit", systemImage: "arrow.down.left") }
            Button {
                movement = .withdrawal(account)
            } label: { Label("Record a withdrawal", systemImage: "arrow.up.right") }
            if state.cards.count > 1 {
                Button {
                    movement = .transfer(account)
                } label: { Label("Transfer money", systemImage: "arrow.left.arrow.right") }
            }
            Button {
                movement = .adjustment(account)
            } label: { Label("Update the balance", systemImage: "equal.circle") }
            Button {
                editing = .existing(account)
            } label: { Label("Edit account", systemImage: "pencil") }
            if !card.isDefaultIncome {
                Button {
                    setDefaultIncome(account)
                } label: { Label("Make this the paycheck account", systemImage: "dollarsign.circle") }
            }
            Divider()
            Button(role: card.canArchive ? .destructive : nil) {
                if card.canArchive {
                    archiveTarget = account
                } else {
                    blockedArchive = card
                }
            } label: {
                Label(
                    card.canArchive ? "Archive account" : "Why can't I archive this?",
                    systemImage: card.canArchive ? "archivebox" : "questionmark.circle"
                )
            }
        }
    }

    // MARK: - Actions

    private func account(for id: UUID) -> CashAccount? {
        accounts.first { $0.id == id }
    }

    private func reload() {
        do {
            state = try AccountsWorkspaceLoader(
                context: modelContext, dateProvider: appEnvironment.dateProvider
            ).load()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = state.cards
        ordered.move(fromOffsets: source, toOffset: destination)
        do {
            try CashAccountRepository(context: modelContext).reorder(
                ordered.map(\.id), now: appEnvironment.dateProvider.now
            )
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func setDefaultIncome(_ account: CashAccount) {
        do {
            try CashAccountRepository(context: modelContext).setDefaultIncome(account)
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func confirmArchive() {
        guard let account = archiveTarget else { return }
        archiveTarget = nil
        do {
            let archived = try CashAccountRepository(context: modelContext)
                .archiveIfAllowed(account, now: appEnvironment.dateProvider.now)
            if !archived {
                blockedArchive = state.cards.first { $0.id == account.id }
            }
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Summary header

private struct AccountsSummaryHeader: View {
    let state: AccountsWorkspaceState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SetupSummaryRow(label: "Total balance", value: MoneyFormat.string(state.totalBalance))
                .font(.subheadline.weight(.medium))
            if state.totalProtected > 0 {
                SetupSummaryRow(label: "Protected", value: MoneyFormat.string(state.totalProtected))
                    .font(.subheadline)
            }
            SetupSummaryRow(label: "Available to the plan", value: MoneyFormat.string(state.totalAvailable))
                .font(.subheadline)
            Text("Available is what's left once each account's protected amount is set aside.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("accounts.summary")
    }
}

private struct AccountsAttentionBanner: View {
    let count: Int

    var body: some View {
        Label {
            Text("\(count) account\(count == 1 ? "" : "s") \(count == 1 ? "doesn't" : "don't") match the activity recorded. Open one to see the difference and line it up.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("accounts.attentionBanner")
    }
}

// MARK: - Card

struct AccountCardView: View {
    let card: AccountsWorkspaceState.AccountCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.name)
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(card.rolesSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    MoneyText(amount: card.currentBalance, font: .body.weight(.semibold))
                    Text(card.balanceAsOfText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if card.isDefaultIncome {
                Label("Gets your paycheck", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.mint)
            }

            Divider()

            VStack(spacing: 4) {
                SetupSummaryRow(label: "Protected", value: MoneyFormat.string(card.protectedAmount))
                SetupSummaryRow(label: "Available", value: MoneyFormat.string(card.availableBalance))
            }
            .font(.footnote)

            if let movement = card.nextMovement {
                Label {
                    Text("Next: \(movement.summary)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: movement.kind.symbolName)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            } else {
                Text("No planned movement on this account yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            AccountReconciliationBadge(reconciliation: card.reconciliation)

            HStack(spacing: 4) {
                Spacer(minLength: 0)
                Text("Open")
                    .font(.footnote)
                Image(systemName: "chevron.right")
                    .font(.footnote)
            }
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        // One element per card: VoiceOver reads the whole summary, then the
        // hint says what activating it does.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(card.accessibilityLabel)
        .accessibilityHint("Opens this account's detail, activity, and balance history")
    }
}

/// Reconciliation state as text plus an icon — never colour alone, so it
/// survives high-contrast and colour-blind use.
struct AccountReconciliationBadge: View {
    let reconciliation: AccountReconciliation

    var body: some View {
        Label {
            Text(reconciliation.message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbolName)
                .accessibilityHidden(true)
        }
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
    }

    private var symbolName: String {
        switch reconciliation {
        case .notConfirmed: return "clock.badge.questionmark"
        case .reconciled: return "checkmark.seal"
        case .needsAttention: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch reconciliation {
        case .notConfirmed: return .secondary
        case .reconciled: return .secondary
        case .needsAttention: return .orange
        }
    }
}

// MARK: - Reorder

private struct AccountsReorderList: View {
    let cards: [AccountsWorkspaceState.AccountCard]
    let onMove: (IndexSet, Int) -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drag to change the order accounts appear in. Nothing about your money changes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(cards) { card in
                    HStack {
                        Text(card.name)
                        Spacer(minLength: 8)
                        MoneyText(amount: card.currentBalance, font: .footnote)
                    }
                    .frame(minHeight: 44)
                    .accessibilityLabel("\(card.name), \(MoneyFormat.string(card.currentBalance))")
                }
                .onMove(perform: onMove)
            }
            .environment(\.editMode, .constant(.active))
            .frame(minHeight: CGFloat(max(cards.count, 1)) * 56)
            .scrollDisabled(true)
            .listStyle(.plain)
            .accessibilityIdentifier("accounts.reorderList")

            Button("Done reordering", action: onDone)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }
}

// MARK: - Blocked archive

private struct ArchiveBlockedSheet: View {
    @Environment(\.dismiss) private var dismiss
    let card: AccountsWorkspaceState.AccountCard

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(card.name) is still being used, so archiving it now would leave your setup pointing at an account that isn't there.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(card.archiveBlockers) { blocker in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(blocker.title, systemImage: "arrow.turn.down.right")
                                .font(.subheadline.weight(.medium))
                            Text(blocker.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .accessibilityElement(children: .combine)
                    }

                    Text("Nothing has changed. Sort any of these out and the archive option becomes available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
            }
            .navigationTitle("Can't archive yet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("accounts.archiveBlocked")
    }
}

// MARK: - Archived accounts

struct ArchivedAccountsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @Query private var accounts: [CashAccount]
    @State private var error: String?

    private var archived: [CashAccount] {
        accounts.filter(\.isArchived)
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }

    var body: some View {
        List {
            if archived.isEmpty {
                EmptyStateView(
                    title: "Nothing archived",
                    message: "Archived accounts keep all their history and can be restored at any time.",
                    symbolName: "archivebox"
                )
                .listRowSeparator(.hidden)
            }
            ForEach(archived) { account in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(account.name)
                        Spacer(minLength: 8)
                        MoneyText(amount: account.currentBalance, font: .footnote)
                    }
                    Button("Restore") { restore(account) }
                        .font(.footnote)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("accounts.restore.\(account.name)")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(account.name), archived, balance \(MoneyFormat.string(account.currentBalance))")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("Archived accounts")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func restore(_ account: CashAccount) {
        do {
            try CashAccountRepository(context: modelContext)
                .restore(account, now: appEnvironment.dateProvider.now)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Failure

private struct AccountsLoadFailure: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Your accounts couldn't be loaded")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again", action: onRetry)
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("accounts.loadFailure")
    }
}
