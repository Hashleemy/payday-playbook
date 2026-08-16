import Foundation
import SwiftData

/// Everything the Accounts workspace needs to know about one account beyond
/// its stored columns: whether the entered balance still agrees with the
/// ledger, what the plan expects to move next, and whether archiving it would
/// break something the user has already set up (V3-02/V3-03).
///
/// Read-only. Nothing here writes a row — the workspace calls
/// `CashLedgerService` for that, so there is exactly one place money moves.

// MARK: - Reconciliation

/// How the entered balance compares with what the ledger can account for.
///
/// The comparison is only possible against an authoritative `BalanceSnapshot`:
/// that is the last point the user said "this is true", and every row after it
/// has a signed effect. Without one there is nothing to reconcile *against* —
/// which is reported as its own state rather than as agreement, because
/// "nobody has checked" and "checked and correct" are different facts.
enum AccountReconciliation: Equatable {
    /// No authoritative snapshot yet: the balance is what was typed, carried
    /// forward. Informational, not a problem.
    case notConfirmed
    /// The ledger accounts for the entered balance exactly.
    case reconciled(asOf: Date)
    /// The entered balance and the ledger disagree by `difference`
    /// (entered − derived). Positive means the account holds more than the
    /// rows explain.
    case needsAttention(difference: Decimal, derivedBalance: Decimal, asOf: Date)

    var isAttention: Bool {
        if case .needsAttention = self { return true }
        return false
    }

    /// One calm sentence. Never blames the user for a gap the app cannot see.
    var message: String {
        switch self {
        case .notConfirmed:
            return "This balance hasn't been confirmed against your bank yet."
        case .reconciled(let asOf):
            return "Matches the recorded activity as of \(DateFormat.medium(asOf))."
        case .needsAttention(let difference, let derived, let asOf):
            let direction = difference > 0 ? "more" : "less"
            return "This account holds \(MoneyFormat.string(abs(difference))) \(direction) than the activity since \(DateFormat.medium(asOf)) accounts for. The activity adds up to \(MoneyFormat.string(derived)). Recording a balance update will line them up."
        }
    }
}

// MARK: - Planned movement

/// The next thing the plan or the user's bills expect to happen on an account.
struct PlannedAccountMovement: Equatable {
    enum Kind: String, Equatable {
        case paycheck
        case bill

        var symbolName: String {
            switch self {
            case .paycheck: return "dollarsign.circle.fill"
            case .bill: return "house"
            }
        }
    }

    var kind: Kind
    var date: Date
    var amount: Decimal
    var label: String

    /// "+$1,200.00 · Paycheck · Mar 14" — read out in full by VoiceOver.
    var summary: String {
        let sign = kind == .paycheck ? "+" : "−"
        return "\(sign)\(MoneyFormat.string(amount)) · \(label) · \(DateFormat.medium(date))"
    }
}

// MARK: - Archive

/// Why an account cannot be archived yet. Each reason names the thing that
/// still points at it, so the user can go and change it rather than being told
/// "no" with no route forward (§5.1).
struct ArchiveBlocker: Identifiable, Equatable {
    enum Reason: String {
        case lastActiveAccount
        case defaultIncome
        case obligationsPaidFrom
        case activePlanIncome
    }

    var id: String { "\(reason.rawValue)-\(detail)" }
    let reason: Reason
    let title: String
    let detail: String
}

// MARK: - Service

struct AccountReconciliationService {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: Reconciliation

    /// Compares the entered balance against the last authoritative snapshot
    /// plus every movement recorded after it.
    ///
    /// Rows are matched by `createdAt`, not `effectiveDate`: a back-dated
    /// correction is still a fact learned *after* the snapshot, and ordering by
    /// when it was recorded is what makes the arithmetic reproducible.
    ///
    /// **Rows stamped at the same instant as the snapshot count as after it,
    /// except the snapshot's own correction.** `adjustBalance` writes the
    /// snapshot and its explaining row in one save, so they share a timestamp;
    /// that row is already inside the stated balance and would otherwise be
    /// counted twice. Everything else at that instant belongs after, because
    /// the stated balance is what the user reports having *seen* — anything
    /// recorded in the same tick was recorded by the same code path, running
    /// after they said it. A strict comparison instead of this rule silently
    /// dropped every movement whenever the clock did not advance between
    /// saves.
    func reconciliation(for account: CashAccount) throws -> AccountReconciliation {
        let accountID = account.id
        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
            .filter { $0.cashAccountID == accountID && $0.isAuthoritative }
            .sorted { ($0.effectiveDate, $0.createdAt) < ($1.effectiveDate, $1.createdAt) }

        guard let anchor = snapshots.last else { return .notConfirmed }

        let subsequent = try context.fetch(FetchDescriptor<LedgerEntry>())
            .filter { entry in
                guard entry.type.isCashAccountMovement else { return false }
                guard entry.sourceAccountID == accountID || entry.destinationAccountID == accountID else {
                    return false
                }
                guard entry.createdAt >= anchor.createdAt else { return false }
                return !Self.isCompanionRow(entry, of: anchor)
            }

        let derived = (anchor.amount + CashLedgerService.netMovement(of: subsequent, for: accountID)).rounded2
        let difference = (account.currentBalance - derived).rounded2
        if difference == 0 {
            return .reconciled(asOf: anchor.effectiveDate)
        }
        return .needsAttention(
            difference: difference, derivedBalance: derived, asOf: anchor.effectiveDate
        )
    }

    /// The adjustment row `adjustBalance` wrote alongside this snapshot: same
    /// account, same instant, same effective date. Its amount is the delta the
    /// stated balance already reflects.
    private static func isCompanionRow(_ entry: LedgerEntry, of snapshot: BalanceSnapshot) -> Bool {
        entry.type == .accountAdjustment
            && entry.createdAt == snapshot.createdAt
            && entry.effectiveDate == snapshot.effectiveDate
            && entry.destinationAccountID == snapshot.cashAccountID
    }

    // MARK: Planned movement

    /// The soonest planned paycheck or bill on this account, on or after
    /// `now`. Nil when nothing is scheduled — which the card says plainly
    /// rather than showing an empty row.
    func nextPlannedMovement(for account: CashAccount, now: Date) throws -> PlannedAccountMovement? {
        let today = DateMath.startOfDay(now)
        var candidates: [PlannedAccountMovement] = []

        if let paycheck = try nextPaycheck(for: account, onOrAfter: today) {
            candidates.append(paycheck)
        }
        candidates.append(contentsOf: try nextBills(for: account, onOrAfter: today))

        return candidates.min { ($0.date, $0.label) < ($1.date, $1.label) }
    }

    /// Income lands in the default income account, and only there — that is
    /// the invariant `CashAccountRepository` maintains.
    private func nextPaycheck(for account: CashAccount, onOrAfter day: Date) throws -> PlannedAccountMovement? {
        guard account.isDefaultIncome else { return nil }
        guard let plan = try context.fetch(FetchDescriptor<PlanVersion>())
            .first(where: \.isActive) else { return nil }
        let planID = plan.id
        let next = try context.fetch(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
        )
        .filter { DateMath.startOfDay($0.date) >= day }
        .min { ($0.date, $0.sequenceNumber) < ($1.date, $1.sequenceNumber) }

        guard let next else { return nil }
        return PlannedAccountMovement(
            kind: .paycheck, date: next.date, amount: next.plannedIncome, label: "Paycheck"
        )
    }

    /// Bills the user marked as paid from this account. A bill with no due day
    /// has no date to show, so it is left out rather than given an invented one.
    private func nextBills(for account: CashAccount, onOrAfter day: Date) throws -> [PlannedAccountMovement] {
        let accountID = account.id
        let obligations = try context.fetch(
            FetchDescriptor<RecurringObligation>(
                predicate: #Predicate { !$0.isArchived && $0.accountID == accountID }
            )
        )
        return obligations.compactMap { obligation in
            guard let dueDay = obligation.dueDay else { return nil }
            let date = DueDateRule.nextOccurrence(dueDay: dueDay, onOrAfter: day)
            return PlannedAccountMovement(
                kind: .bill, date: date, amount: obligation.amount, label: obligation.name
            )
        }
    }

    // MARK: Archive

    /// Everything still pointing at this account. Empty means archiving is
    /// safe; otherwise the workspace explains each reason instead of failing
    /// silently (§5.1).
    func archiveBlockers(for account: CashAccount) throws -> [ArchiveBlocker] {
        var blockers: [ArchiveBlocker] = []
        let repository = CashAccountRepository(context: context)

        if try !repository.canArchive(account) {
            blockers.append(ArchiveBlocker(
                reason: .lastActiveAccount,
                title: "It's your only active account",
                detail: "Your paycheck has to land somewhere. Add another account first, then archive this one."
            ))
        }

        if account.isDefaultIncome, try repository.activeAccounts().count > 1 {
            blockers.append(ArchiveBlocker(
                reason: .defaultIncome,
                title: "It receives your paycheck",
                detail: "Choose a different account to receive income, then archive this one."
            ))
        }

        let accountID = account.id
        let obligations = try context.fetch(
            FetchDescriptor<RecurringObligation>(
                predicate: #Predicate { !$0.isArchived && $0.accountID == accountID }
            )
        ).sorted { $0.name < $1.name }
        if !obligations.isEmpty {
            let names = obligations.map(\.name).joined(separator: ", ")
            blockers.append(ArchiveBlocker(
                reason: .obligationsPaidFrom,
                title: obligations.count == 1 ? "A bill is paid from it" : "\(obligations.count) bills are paid from it",
                detail: "\(names) — point them at another account first, in Bills & Debts."
            ))
        }

        if let plan = try context.fetch(FetchDescriptor<PlanVersion>()).first(where: \.isActive),
           plan.incomeAccountID == account.id,
           !account.isDefaultIncome {
            blockers.append(ArchiveBlocker(
                reason: .activePlanIncome,
                title: "Your active plan routes income here",
                detail: "\(plan.name) was generated with this account receiving income. Generate a new plan after moving income, and its history stays intact either way."
            ))
        }

        return blockers
    }
}

// MARK: - Date presentation

/// Dates in the one format the accounts surfaces use, so a card, a sheet, and
/// a VoiceOver label never disagree about how a day is spelled.
enum DateFormat {
    static func medium(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func mediumWithWeekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }
}
