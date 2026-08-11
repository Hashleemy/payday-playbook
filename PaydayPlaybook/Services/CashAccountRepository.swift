import Foundation
import SwiftData

/// Data access for `CashAccount` rows (V2-03). Owns the invariant that
/// exactly one non-archived account is the default income account whenever
/// any non-archived account exists — under add, edit, re-role, and archive.
struct CashAccountRepository {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Fetching

    func activeAccounts() throws -> [CashAccount] {
        try context.fetch(FetchDescriptor<CashAccount>(predicate: #Predicate { !$0.isArchived }))
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }

    func defaultIncomeAccount() throws -> CashAccount? {
        try activeAccounts().first(where: \.isDefaultIncome)
    }

    /// Accounts holding a given role, in display order.
    func accounts(withRole role: AccountRole) throws -> [CashAccount] {
        try activeAccounts().filter { $0.roles.contains(role) }
    }

    /// The primary spending account (first active account with the spending
    /// role, falling back to the first active account).
    func spendingAccount() throws -> CashAccount? {
        let active = try activeAccounts()
        return active.first(where: { $0.roles.contains(.spending) }) ?? active.first
    }

    // MARK: - Mutations

    /// Validates and inserts a new account. The first income-role account
    /// (or the first account at all) becomes the default income account.
    @discardableResult
    func create(
        name: String,
        currentBalance: Decimal,
        roles: Set<AccountRole>,
        now: Date = Date()
    ) throws -> CashAccount {
        try ModelValidation.validateCashAccount(name: name, currentBalance: currentBalance, roles: roles)
        let nextOrder = (try context.fetch(FetchDescriptor<CashAccount>()).map(\.sortOrder).max() ?? -1) + 1
        let account = CashAccount(
            name: name,
            currentBalance: currentBalance,
            roles: roles,
            isDefaultIncome: false,
            sortOrder: nextOrder,
            createdAt: now,
            updatedAt: now
        )
        context.insert(account)
        try ensureDefaultIncomeInvariant()
        try context.save()
        return account
    }

    func update(
        _ account: CashAccount,
        name: String? = nil,
        currentBalance: Decimal? = nil,
        roles: Set<AccountRole>? = nil,
        now: Date = Date()
    ) throws {
        try ModelValidation.validateCashAccount(
            name: name ?? account.name,
            currentBalance: currentBalance ?? account.currentBalance,
            roles: roles ?? account.roles
        )
        if let name { account.name = name }
        if let currentBalance { account.currentBalance = currentBalance }
        if let roles { account.roles = roles }
        account.updatedAt = now
        try ensureDefaultIncomeInvariant()
        try context.save()
    }

    /// Marks an account as the default income account, demoting all others.
    func setDefaultIncome(_ account: CashAccount) throws {
        for other in try context.fetch(FetchDescriptor<CashAccount>()) {
            other.isDefaultIncome = other.id == account.id
        }
        try ensureDefaultIncomeInvariant()
        try context.save()
    }

    /// Archives an account, keeping history. If it was the default income
    /// account, the default moves to another active account.
    func archive(_ account: CashAccount, now: Date = Date()) throws {
        account.isArchived = true
        account.isDefaultIncome = false
        account.updatedAt = now
        try ensureDefaultIncomeInvariant()
        try context.save()
    }

    // MARK: - Invariant

    /// Exactly one non-archived default income account whenever any
    /// non-archived account exists. Preference order for auto-assignment:
    /// income-role accounts first, then display order.
    func ensureDefaultIncomeInvariant() throws {
        let all = try context.fetch(FetchDescriptor<CashAccount>())
        let active = all
            .filter { !$0.isArchived }
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }

        // Archived rows never hold the default.
        for account in all where account.isArchived && account.isDefaultIncome {
            account.isDefaultIncome = false
        }

        guard !active.isEmpty else { return }

        let defaults = active.filter(\.isDefaultIncome)
        if defaults.count == 1 { return }

        if defaults.count > 1 {
            // Keep the first in display order, demote the rest.
            for account in defaults.dropFirst() {
                account.isDefaultIncome = false
            }
            return
        }

        // No default: prefer the first income-role account (§4.3).
        let candidate = active.first(where: { $0.roles.contains(.income) }) ?? active[0]
        candidate.isDefaultIncome = true
    }
}
