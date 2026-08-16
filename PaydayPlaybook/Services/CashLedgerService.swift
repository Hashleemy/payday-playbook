import Foundation
import SwiftData

/// Money movements on the user's own cash accounts (V3-04): deposits,
/// withdrawals, transfers between accounts, and dated corrections to a stated
/// balance.
///
/// Two rules shape everything here.
///
/// **History is append-only.** No operation edits or deletes an earlier
/// ledger row. A balance the user says is wrong is reconciled by writing the
/// difference, not by going back and changing what was recorded — so the
/// ledger stays a record of what was believed and when, and any figure on
/// screen can be traced to the rows that produced it.
///
/// **A transfer is one row, not two.** It carries both endpoints. Two linked
/// rows can half-exist after an interrupted save, and every reader then needs
/// to detect and repair that; with a single row the movement either happened
/// or it did not, and reconciliation has no partial state to reason about.
struct CashLedgerService {
    let context: ModelContext
    let dateProvider: DateProviding

    init(context: ModelContext, dateProvider: DateProviding = SystemDateProvider()) {
        self.context = context
        self.dateProvider = dateProvider
    }

    enum LedgerError: LocalizedError, Equatable {
        case amountNotPositive
        case sameAccountTransfer
        case accountArchived(String)

        var errorDescription: String? {
            switch self {
            case .amountNotPositive:
                return "Enter an amount greater than zero."
            case .sameAccountTransfer:
                return "Choose two different accounts for a transfer."
            case .accountArchived(let name):
                return "\(name) is archived. Restore it before recording new activity."
            }
        }
    }

    // MARK: - Deposits and withdrawals

    /// Records money arriving in an account.
    @discardableResult
    func deposit(
        into account: CashAccount,
        amount: Decimal,
        effectiveDate: Date? = nil,
        note: String? = nil,
        provenance: LedgerProvenance = .user
    ) throws -> LedgerEntry {
        try requirePositive(amount)
        try requireActive(account)
        let now = dateProvider.now
        let entry = LedgerEntry(
            effectiveDate: effectiveDate ?? now,
            createdAt: now,
            updatedAt: now,
            type: .accountDeposit,
            amount: amount,
            note: note,
            destinationAccountID: account.id,
            provenance: provenance
        )
        context.insert(entry)
        apply(delta: amount, to: account, asOf: entry.effectiveDate, now: now)
        try context.save()
        return entry
    }

    /// Records money leaving an account.
    @discardableResult
    func withdraw(
        from account: CashAccount,
        amount: Decimal,
        effectiveDate: Date? = nil,
        note: String? = nil,
        provenance: LedgerProvenance = .user
    ) throws -> LedgerEntry {
        try requirePositive(amount)
        try requireActive(account)
        let now = dateProvider.now
        let entry = LedgerEntry(
            effectiveDate: effectiveDate ?? now,
            createdAt: now,
            updatedAt: now,
            type: .accountWithdrawal,
            amount: amount,
            note: note,
            sourceAccountID: account.id,
            provenance: provenance
        )
        context.insert(entry)
        apply(delta: -amount, to: account, asOf: entry.effectiveDate, now: now)
        try context.save()
        return entry
    }

    // MARK: - Transfers

    /// Moves money between two of the user's accounts as a single movement.
    ///
    /// Both balances change in one save, so the pair can never be observed
    /// half-applied: if the save fails, neither moved.
    @discardableResult
    func transfer(
        from source: CashAccount,
        to destination: CashAccount,
        amount: Decimal,
        effectiveDate: Date? = nil,
        note: String? = nil,
        provenance: LedgerProvenance = .user
    ) throws -> LedgerEntry {
        try requirePositive(amount)
        guard source.id != destination.id else { throw LedgerError.sameAccountTransfer }
        try requireActive(source)
        try requireActive(destination)

        let now = dateProvider.now
        let entry = LedgerEntry(
            effectiveDate: effectiveDate ?? now,
            createdAt: now,
            updatedAt: now,
            type: .accountTransfer,
            amount: amount,
            note: note,
            sourceAccountID: source.id,
            destinationAccountID: destination.id,
            provenance: provenance
        )
        context.insert(entry)
        apply(delta: -amount, to: source, asOf: entry.effectiveDate, now: now)
        apply(delta: amount, to: destination, asOf: entry.effectiveDate, now: now)
        try context.save()
        return entry
    }

    // MARK: - Adjustments

    /// Corrects an account to a balance the user says is true as of a date.
    ///
    /// Writes the *difference* as a dated ledger row and an authoritative
    /// `BalanceSnapshot` recording the stated figure. Nothing earlier is
    /// rewritten: the adjustment explains the gap rather than pretending it
    /// was never there, so "what did the app think, and when did we find out
    /// otherwise" stays answerable.
    ///
    /// A no-op adjustment (the stated balance already matches) still writes a
    /// snapshot — the user confirming a balance is itself a fact worth
    /// keeping — but writes no ledger row, because no money moved.
    @discardableResult
    func adjustBalance(
        of account: CashAccount,
        to statedBalance: Decimal,
        effectiveDate: Date? = nil,
        note: String? = nil,
        auditNote: String? = nil,
        sourceType: SnapshotSourceType = .userEntry,
        provenance: LedgerProvenance = .user
    ) throws -> (entry: LedgerEntry?, snapshot: BalanceSnapshot) {
        try requireActive(account)
        let now = dateProvider.now
        let when = effectiveDate ?? now
        let delta = (statedBalance - account.currentBalance).rounded2

        let snapshot = BalanceSnapshot(
            cashAccount: nil,
            effectiveDate: when,
            amount: statedBalance,
            sourceType: sourceType,
            note: note,
            isAuthoritative: true,
            createdAt: now,
            auditNote: auditNote
        )
        snapshot.cashAccountID = account.id
        context.insert(snapshot)

        var entry: LedgerEntry?
        if delta != 0 {
            let row = LedgerEntry(
                effectiveDate: when,
                createdAt: now,
                updatedAt: now,
                type: .accountAdjustment,
                amount: delta,
                note: note,
                auditNote: auditNote,
                // The signed amount says which way the correction went; the
                // account reference is the same either way.
                destinationAccountID: account.id,
                provenance: provenance
            )
            context.insert(row)
            entry = row
        }

        account.currentBalance = statedBalance
        account.balanceAsOf = when
        account.updatedAt = now
        try context.save()
        return (entry, snapshot)
    }

    // MARK: - Queries

    /// Every cash movement touching an account, newest first.
    func activity(for account: CashAccount, limit: Int? = nil) throws -> [LedgerEntry] {
        let accountID = account.id
        let all = try context.fetch(FetchDescriptor<LedgerEntry>())
            .filter { $0.sourceAccountID == accountID || $0.destinationAccountID == accountID }
            .sorted { ($0.effectiveDate, $0.createdAt) > ($1.effectiveDate, $1.createdAt) }
        guard let limit else { return all }
        return Array(all.prefix(limit))
    }

    /// The signed effect of an entry on a given account. A transfer reads as
    /// negative on its source and positive on its destination from the one
    /// row, which is what lets a single row present as a paired movement.
    static func signedAmount(of entry: LedgerEntry, for accountID: UUID) -> Decimal {
        switch entry.type {
        case .accountTransfer:
            if entry.sourceAccountID == accountID { return -entry.amount }
            if entry.destinationAccountID == accountID { return entry.amount }
            return .zero
        case .accountWithdrawal:
            return entry.sourceAccountID == accountID ? -entry.amount : .zero
        case .accountDeposit:
            return entry.destinationAccountID == accountID ? entry.amount : .zero
        case .accountAdjustment:
            // Already signed: a downward correction carries a negative amount.
            return entry.destinationAccountID == accountID ? entry.amount : .zero
        default:
            return .zero
        }
    }

    /// Sum of cash movements on an account over the given rows.
    static func netMovement(of entries: [LedgerEntry], for accountID: UUID) -> Decimal {
        entries.reduce(Decimal.zero) { $0 + signedAmount(of: $1, for: accountID) }.rounded2
    }

    // MARK: - Helpers

    private func apply(delta: Decimal, to account: CashAccount, asOf: Date, now: Date) {
        account.currentBalance = (account.currentBalance + delta).rounded2
        account.balanceAsOf = asOf
        account.updatedAt = now
    }

    private func requirePositive(_ amount: Decimal) throws {
        guard amount > 0 else { throw LedgerError.amountNotPositive }
    }

    private func requireActive(_ account: CashAccount) throws {
        guard !account.isArchived else { throw LedgerError.accountArchived(account.name) }
    }
}
