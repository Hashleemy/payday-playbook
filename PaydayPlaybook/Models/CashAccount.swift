import Foundation
import SwiftData

/// Role a cash account plays in the plan. One account may hold several roles;
/// a single-account setup carries all three.
enum AccountRole: String, Codable, CaseIterable, Identifiable {
    case income
    case spending
    case reserves

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .income: return "Receives income"
        case .spending: return "Day-to-day spending"
        case .reserves: return "Reserves"
        }
    }
}

/// A user-named checking account (V2-03). Only a name and a typed balance —
/// never an account number, routing number, or credential.
@Model
final class CashAccount {
    var id: UUID = UUID()
    var name: String = ""
    var currentBalance: Decimal = Decimal.zero
    /// Comma-separated `AccountRole` raw values, e.g. "income,spending".
    var rolesRaw: String = ""
    /// Exactly one non-archived account is the default income account,
    /// enforced by `CashAccountRepository` and covered by tests.
    var isDefaultIncome: Bool = false
    var sortOrder: Int = 0
    var isArchived: Bool = false
    /// Set only by migration: "checking1" / "checking2". Stable key that maps
    /// legacy `MoneyAccount`/`CashAccountKind` references onto this account.
    var legacyKindRaw: String?
    /// Cash held back from the payday budget on this account (schema 3).
    /// Per-account, so a multi-account setup can protect a reserve balance
    /// independently of the spending floor. Migration copies the profile's
    /// single `protectedFloor` onto the spending-role account and leaves
    /// every other account at zero.
    var protectedAmount: Decimal = Decimal.zero
    /// When `currentBalance` was last known to be true (schema 3). Nil means
    /// never stated — the balance is an estimate carried forward, and the UI
    /// says so rather than implying a freshness it cannot support.
    var balanceAsOf: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var roles: Set<AccountRole> {
        get { Set(rolesRaw.split(separator: ",").compactMap { AccountRole(rawValue: String($0)) }) }
        set { rolesRaw = newValue.map(\.rawValue).sorted().joined(separator: ",") }
    }

    var legacyKind: CashAccountKind? {
        get { legacyKindRaw.flatMap(CashAccountKind.init(rawValue:)) }
        set { legacyKindRaw = newValue?.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        currentBalance: Decimal,
        roles: Set<AccountRole>,
        isDefaultIncome: Bool = false,
        sortOrder: Int = 0,
        isArchived: Bool = false,
        legacyKind: CashAccountKind? = nil,
        protectedAmount: Decimal = .zero,
        balanceAsOf: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.currentBalance = currentBalance
        self.rolesRaw = roles.map(\.rawValue).sorted().joined(separator: ",")
        self.isDefaultIncome = isDefaultIncome
        self.sortOrder = sortOrder
        self.isArchived = isArchived
        self.legacyKindRaw = legacyKind?.rawValue
        self.protectedAmount = protectedAmount
        self.balanceAsOf = balanceAsOf
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// MVP_LAYOUT §6 names this model `CheckingAccount`; the storage type is
/// `CashAccount`. Either name resolves to the same model.
typealias CheckingAccount = CashAccount
