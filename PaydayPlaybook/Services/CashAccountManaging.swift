import Foundation

/// Cash-account state as plain values, with no storage type in sight.
///
/// This is the Agent 2 ↔ Agent 3 boundary for accounts: callers that only
/// need to *read* account state — the calculation engine, scenario
/// comparison, report generation — take this instead of `CashAccount`, so
/// nothing outside the data layer has to import SwiftData or hold a live
/// model object whose values can change under it mid-calculation.
struct CashAccountSnapshot: Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var currentBalance: Decimal
    /// Cash held back from the payday budget on this account (schema 3).
    var protectedAmount: Decimal
    /// When the balance was last known true; nil means never stated.
    var balanceAsOf: Date?
    var roles: Set<AccountRole>
    var isDefaultIncome: Bool
    var isArchived: Bool
    var sortOrder: Int

    /// Balance the plan may actually spend down.
    var availableBalance: Decimal {
        max(.zero, (currentBalance - protectedAmount).rounded2)
    }
}

/// Read and mutate cash accounts without naming a storage type.
///
/// `CashAccountRepository` is the store-backed implementation; tests and
/// previews can supply an in-memory one without a `ModelContext`.
protocol CashAccountManaging {
    func accountSnapshots() throws -> [CashAccountSnapshot]
    func defaultIncomeSnapshot() throws -> CashAccountSnapshot?
    func spendingSnapshot() throws -> CashAccountSnapshot?
    /// Total spendable cash across active accounts, net of protected amounts.
    func totalAvailableCash() throws -> Decimal
}

extension CashAccountSnapshot {
    init(_ account: CashAccount) {
        self.init(
            id: account.id,
            name: account.name,
            currentBalance: account.currentBalance,
            protectedAmount: account.protectedAmount,
            balanceAsOf: account.balanceAsOf,
            roles: account.roles,
            isDefaultIncome: account.isDefaultIncome,
            isArchived: account.isArchived,
            sortOrder: account.sortOrder
        )
    }
}

extension CashAccountRepository: CashAccountManaging {
    func accountSnapshots() throws -> [CashAccountSnapshot] {
        try activeAccounts().map(CashAccountSnapshot.init)
    }

    func defaultIncomeSnapshot() throws -> CashAccountSnapshot? {
        try defaultIncomeAccount().map(CashAccountSnapshot.init)
    }

    func spendingSnapshot() throws -> CashAccountSnapshot? {
        try spendingAccount().map(CashAccountSnapshot.init)
    }

    func totalAvailableCash() throws -> Decimal {
        try accountSnapshots()
            .reduce(Decimal.zero) { $0 + $1.availableBalance }
            .rounded2
    }
}
