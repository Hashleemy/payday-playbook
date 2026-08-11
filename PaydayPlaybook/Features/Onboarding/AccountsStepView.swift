import SwiftUI
import SwiftData

/// Step 3 — checking accounts (§4.3, V2-03). Name, balance, and roles only:
/// never an account number, routing number, or credential.
struct AccountsStepView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @Query private var accounts: [CashAccount]

    let onContinue: () -> Void
    let onBack: () -> Void

    @State private var editing: AccountEditorTarget?
    @State private var error: String?

    private var activeAccounts: [CashAccount] {
        accounts.filter { !$0.isArchived }
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }

    var body: some View {
        OnboardingScaffold(
            title: "Where does your money sit?",
            subtitle: "Add the checking accounts you actually use. One account is fine — it can hold every role.",
            continueEnabled: !activeAccounts.isEmpty,
            continueIdentifier: "onboarding.accountsContinue",
            onBack: onBack,
            onContinue: onContinue
        ) {
            SetupExplainer(
                text: "Only a name and the balance you type. The app never asks for account numbers, routing numbers, or logins.",
                systemImage: "lock.shield"
            )

            if activeAccounts.isEmpty {
                EmptyStateView(
                    title: "No accounts yet",
                    message: "Add the checking account your paycheck lands in.",
                    symbolName: "building.columns"
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(activeAccounts) { account in
                        AccountRow(
                            account: account,
                            isDefaultIncome: account.isDefaultIncome,
                            onEdit: { editing = .existing(account) },
                            onMakeDefault: { setDefaultIncome(account) }
                        )
                    }
                }
            }

            if activeAccounts.count >= AccountsStepView.accountCap {
                Text("That's the \(AccountsStepView.accountCap)-account limit. Archive one to add another.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

            if activeAccounts.count > 1 {
                SetupExplainer(
                    text: "The account marked \"Gets your paycheck\" is where income lands. Exactly one account holds that role.",
                    systemImage: "arrow.down.circle"
                )
            }

            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .sheet(item: $editing) { target in
            AccountEditorView(target: target, allowsDelete: true)
        }
    }

    /// A-02: practical cap so the picker stays usable on a phone.
    static let accountCap = 10

    private func setDefaultIncome(_ account: CashAccount) {
        do {
            try CashAccountRepository(context: modelContext).setDefaultIncome(account)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Row

private struct AccountRow: View {
    let account: CashAccount
    let isDefaultIncome: Bool
    let onEdit: () -> Void
    let onMakeDefault: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onEdit) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name)
                            .font(.body.weight(.medium))
                        Text(rolesSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    MoneyText(amount: account.currentBalance, font: .body.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(account.name), \(MoneyFormat.string(account.currentBalance)), \(rolesSummary)")
            .accessibilityHint("Opens the account editor")
            .accessibilityIdentifier("accounts.row.\(account.name)")

            if isDefaultIncome {
                Label("Gets your paycheck", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.mint)
            } else {
                Button("Make this the paycheck account", action: onMakeDefault)
                    .font(.caption)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("accounts.makeDefault.\(account.name)")
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var rolesSummary: String {
        let roles = AccountRole.allCases.filter { account.roles.contains($0) }
        guard !roles.isEmpty else { return "No role yet" }
        return roles.map(\.displayName).joined(separator: " · ")
    }
}

// MARK: - Editor

enum AccountEditorTarget: Identifiable {
    case new
    case existing(CashAccount)

    var id: String {
        switch self {
        case .new: return "new"
        case .existing(let account): return account.id.uuidString
        }
    }

    var account: CashAccount? {
        switch self {
        case .new: return nil
        case .existing(let account): return account
        }
    }
}

/// Add/edit sheet shared by onboarding and Settings. `allowsDelete` is true
/// during onboarding (nothing references the account yet) and false
/// afterwards, where accounts are archived so history survives (§4.8).
struct AccountEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment

    let target: AccountEditorTarget
    var allowsDelete = false

    @State private var name = ""
    @State private var balance: Decimal?
    @State private var roles: Set<AccountRole> = [.spending]
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SetupField(
                        title: "Account name",
                        requirement: .required,
                        help: "Whatever you call it — \"Everyday checking\", \"Bills\".",
                        error: nameError
                    ) {
                        TextField("Everyday checking", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("account.name")
                    }

                    SetupMoneyField(
                        title: "Balance today",
                        value: $balance,
                        requirement: .required,
                        help: "What's in it right now. You can update it any time.",
                        error: balanceError
                    )
                    .accessibilityIdentifier("account.balance")

                    SetupField(
                        title: "What this account is for",
                        requirement: .required,
                        help: "Pick every role that applies — one account can do all three.",
                        error: roles.isEmpty ? "Pick at least one role for this account." : nil
                    ) {
                        VStack(spacing: 4) {
                            ForEach(AccountRole.allCases) { role in
                                Toggle(isOn: roleBinding(role)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(role.displayName)
                                        Text(Self.roleDetail(role))
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("account.role.\(role.rawValue)")
                            }
                        }
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    if allowsDelete, let account = target.account {
                        Button(role: .destructive) {
                            delete(account)
                        } label: {
                            Label("Remove this account", systemImage: "trash")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("account.delete")
                    } else if let account = target.account {
                        Button {
                            archive(account)
                        } label: {
                            Label("Archive this account", systemImage: "archivebox")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("account.archive")
                    }
                }
                .padding()
            }
            .navigationTitle(target.account == nil ? "New account" : "Edit account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!isValid)
                        .accessibilityIdentifier("account.save")
                }
            }
            .task {
                guard !loaded else { return }
                loaded = true
                if let account = target.account {
                    name = account.name
                    balance = account.currentBalance
                    roles = account.roles
                }
            }
        }
    }

    static func roleDetail(_ role: AccountRole) -> String {
        switch role {
        case .income: return "Your paycheck lands here."
        case .spending: return "Day-to-day money and the protected floor."
        case .reserves: return "Bills, minimums, and debt payments."
        }
    }

    private func roleBinding(_ role: AccountRole) -> Binding<Bool> {
        Binding(
            get: { roles.contains(role) },
            set: { isOn in
                if isOn { roles.insert(role) } else { roles.remove(role) }
            }
        )
    }

    private var nameError: String? {
        name.isEmpty ? nil : (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "A name is needed." : nil)
    }

    private var balanceError: String? {
        guard let balance else { return nil }
        return balance < 0 ? "The balance can't be negative." : nil
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (balance ?? -1) >= 0
            && !roles.isEmpty
    }

    private func save() {
        let repository = CashAccountRepository(context: modelContext)
        do {
            if let account = target.account {
                try repository.update(
                    account, name: name, currentBalance: balance ?? .zero,
                    roles: roles, now: appEnvironment.dateProvider.now
                )
            } else {
                try repository.create(
                    name: name, currentBalance: balance ?? .zero,
                    roles: roles, now: appEnvironment.dateProvider.now
                )
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ account: CashAccount) {
        do {
            modelContext.delete(account)
            try CashAccountRepository(context: modelContext).ensureDefaultIncomeInvariant()
            try modelContext.save()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func archive(_ account: CashAccount) {
        do {
            try CashAccountRepository(context: modelContext)
                .archive(account, now: appEnvironment.dateProvider.now)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
