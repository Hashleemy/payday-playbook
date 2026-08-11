import Foundation
import SwiftData

enum LedgerEntryType: String, Codable, CaseIterable, Identifiable {
    case cardPayment
    case c1BufferAddition
    case c1Spending
    case c1BalanceAdjustment
    case c2Transfer
    case carReserveContribution
    case carReserveUse
    case trainReserveContribution
    case trainReserveUse
    case windfall
    case refundReversal
    case correction

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cardPayment: return "Card payment"
        case .c1BufferAddition: return "C1 buffer addition"
        case .c1Spending: return "C1 spending"
        case .c1BalanceAdjustment: return "C1 balance adjustment"
        case .c2Transfer: return "C2 transfer"
        case .carReserveContribution: return "Car reserve contribution"
        case .carReserveUse: return "Car reserve use"
        case .trainReserveContribution: return "Train reserve contribution"
        case .trainReserveUse: return "Train reserve use"
        case .windfall: return "Windfall"
        case .refundReversal: return "Refund / reversal"
        case .correction: return "Correction"
        }
    }

    /// Entry types allowed to carry a negative amount.
    var allowsNegativeAmount: Bool {
        switch self {
        case .refundReversal, .correction, .c1BalanceAdjustment: return true
        default: return false
        }
    }
}

enum MoneyAccount: String, Codable, CaseIterable {
    case external
    case checking1
    case checking2
    case card
}

@Model
final class LedgerEntry {
    var id: UUID
    var effectiveDate: Date
    var createdAt: Date
    var updatedAt: Date
    var typeRaw: String
    var amount: Decimal
    var sourceAccountRaw: String?
    var destinationAccountRaw: String?
    var debtAccountID: UUID?
    var debtPlanID: String?
    var paydayCheckInID: UUID?
    var note: String?
    var isCorrection: Bool
    var correctsEntryID: UUID?
    /// Explanation preserved when an entry is edited after creation.
    var auditNote: String?
    /// Schema-2 references to `CashAccount` rows. Migration fills these from
    /// the legacy checking1/checking2 raws, which stay untouched beside them.
    var sourceAccountID: UUID?
    var destinationAccountID: UUID?

    var type: LedgerEntryType {
        get { LedgerEntryType(rawValue: typeRaw) ?? .correction }
        set { typeRaw = newValue.rawValue }
    }

    var sourceAccount: MoneyAccount? {
        get { sourceAccountRaw.flatMap(MoneyAccount.init(rawValue:)) }
        set { sourceAccountRaw = newValue?.rawValue }
    }

    var destinationAccount: MoneyAccount? {
        get { destinationAccountRaw.flatMap(MoneyAccount.init(rawValue:)) }
        set { destinationAccountRaw = newValue?.rawValue }
    }

    init(
        id: UUID = UUID(),
        effectiveDate: Date,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        type: LedgerEntryType,
        amount: Decimal,
        sourceAccount: MoneyAccount? = nil,
        destinationAccount: MoneyAccount? = nil,
        debtAccountID: UUID? = nil,
        debtPlanID: String? = nil,
        paydayCheckInID: UUID? = nil,
        note: String? = nil,
        isCorrection: Bool = false,
        correctsEntryID: UUID? = nil,
        auditNote: String? = nil
    ) {
        self.id = id
        self.effectiveDate = effectiveDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.typeRaw = type.rawValue
        self.amount = amount
        self.sourceAccountRaw = sourceAccount?.rawValue
        self.destinationAccountRaw = destinationAccount?.rawValue
        self.debtAccountID = debtAccountID
        self.debtPlanID = debtPlanID
        self.paydayCheckInID = paydayCheckInID
        self.note = note
        self.isCorrection = isCorrection
        self.correctsEntryID = correctsEntryID
        self.auditNote = auditNote
    }
}
