import Foundation
import SwiftData

enum SnapshotSourceType: String, Codable, CaseIterable, Identifiable {
    case appEstimate
    case currentOnlineBalance
    case statementBalance
    case issuerPayoffQuote
    case userEntry

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appEstimate: return "App estimate"
        case .currentOnlineBalance: return "Current online balance"
        case .statementBalance: return "Statement balance"
        case .issuerPayoffQuote: return "Issuer payoff quote"
        case .userEntry: return "Manual entry"
        }
    }
}

enum CashAccountKind: String, Codable {
    case checking1
    case checking2
}

@Model
final class BalanceSnapshot {
    var id: UUID
    /// Either a debt account reference or a cash account kind — never both.
    var debtAccountID: UUID?
    var debtPlanID: String?
    var cashAccountRaw: String?
    var effectiveDate: Date
    var amount: Decimal
    var sourceTypeRaw: String
    var note: String?
    /// Authoritative snapshots override accumulated estimates from their effective date.
    var isAuthoritative: Bool
    var createdAt: Date
    /// Snapshots are append-only; corrections link back to the corrected snapshot.
    var correctsSnapshotID: UUID?
    var auditNote: String?

    var sourceType: SnapshotSourceType {
        get { SnapshotSourceType(rawValue: sourceTypeRaw) ?? .userEntry }
        set { sourceTypeRaw = newValue.rawValue }
    }

    var cashAccount: CashAccountKind? {
        get { cashAccountRaw.flatMap(CashAccountKind.init(rawValue:)) }
        set { cashAccountRaw = newValue?.rawValue }
    }

    init(
        id: UUID = UUID(),
        debtAccountID: UUID? = nil,
        debtPlanID: String? = nil,
        cashAccount: CashAccountKind? = nil,
        effectiveDate: Date,
        amount: Decimal,
        sourceType: SnapshotSourceType,
        note: String? = nil,
        isAuthoritative: Bool = true,
        createdAt: Date = Date(),
        correctsSnapshotID: UUID? = nil,
        auditNote: String? = nil
    ) {
        self.id = id
        self.debtAccountID = debtAccountID
        self.debtPlanID = debtPlanID
        self.cashAccountRaw = cashAccount?.rawValue
        self.effectiveDate = effectiveDate
        self.amount = amount
        self.sourceTypeRaw = sourceType.rawValue
        self.note = note
        self.isAuthoritative = isAuthoritative
        self.createdAt = createdAt
        self.correctsSnapshotID = correctsSnapshotID
        self.auditNote = auditNote
    }
}
