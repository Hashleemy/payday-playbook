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
    // Schema-3 cash-account movements (V3-04). Additive: every pre-existing
    // raw value still decodes to the case it always did.
    case accountDeposit
    case accountWithdrawal
    /// One row carries the whole transfer, holding both endpoints. Two linked
    /// rows can half-apply; one row cannot, so reconciliation has no partial
    /// state to detect or repair.
    case accountTransfer
    /// A dated correction of a stated balance. Never rewrites earlier rows —
    /// it records the delta that reconciles them to the new truth.
    case accountAdjustment

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
        case .accountDeposit: return "Deposit"
        case .accountWithdrawal: return "Withdrawal"
        case .accountTransfer: return "Transfer"
        case .accountAdjustment: return "Balance adjustment"
        }
    }

    /// Entry types allowed to carry a negative amount.
    var allowsNegativeAmount: Bool {
        switch self {
        case .refundReversal, .correction, .c1BalanceAdjustment, .accountAdjustment: return true
        default: return false
        }
    }

    /// Movements between the user's own cash accounts, as opposed to card
    /// payments and the legacy plan-shaped entries.
    var isCashAccountMovement: Bool {
        switch self {
        case .accountDeposit, .accountWithdrawal, .accountTransfer, .accountAdjustment: return true
        default: return false
        }
    }
}

/// How a ledger row came to exist (schema 3). Never backfilled: a nil
/// provenance means "written before this field existed", which is a fact
/// worth keeping rather than a gap worth guessing at.
enum LedgerProvenance: String, Codable, CaseIterable {
    /// The user entered it directly.
    case user
    /// Recorded as part of completing a payday check-in.
    case checkIn
    /// Written by a schema migration to preserve a pre-existing fact.
    case migration
    /// Restored from a backup or imported document.
    case importRestore
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
    /// `LedgerProvenance` raw value (schema 3). Optional and never backfilled.
    var provenanceRaw: String?

    var provenance: LedgerProvenance? {
        get { provenanceRaw.flatMap(LedgerProvenance.init(rawValue:)) }
        set { provenanceRaw = newValue?.rawValue }
    }

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
        auditNote: String? = nil,
        sourceAccountID: UUID? = nil,
        destinationAccountID: UUID? = nil,
        provenance: LedgerProvenance? = nil
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
        self.sourceAccountID = sourceAccountID
        self.destinationAccountID = destinationAccountID
        self.provenanceRaw = provenance?.rawValue
    }
}
