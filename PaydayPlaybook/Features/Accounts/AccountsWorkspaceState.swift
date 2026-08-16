import Foundation
import SwiftData

/// Everything the Accounts tab renders, assembled once per load (V3-02).
///
/// Assembled in a `.task`, never in a view body: reconciliation walks the
/// ledger and planned movements read the plan graph, and a SwiftUI body can be
/// evaluated many times per frame. The workspace holds the finished values so
/// rendering is pure layout.
struct AccountsWorkspaceState {
    /// One account, with everything §5.1 says a card must show.
    struct AccountCard: Identifiable, Equatable {
        var id: UUID
        var name: String
        var roles: [AccountRole]
        var currentBalance: Decimal
        /// When the balance was last known true. Nil means never stated, and
        /// the card says so rather than implying a freshness it cannot support.
        var balanceAsOf: Date?
        var protectedAmount: Decimal
        var availableBalance: Decimal
        var isDefaultIncome: Bool
        var updatedAt: Date
        var nextMovement: PlannedAccountMovement?
        var reconciliation: AccountReconciliation
        var archiveBlockers: [ArchiveBlocker]

        var canArchive: Bool { archiveBlockers.isEmpty }

        var rolesSummary: String {
            guard !roles.isEmpty else { return "No role yet" }
            return roles.map(\.displayName).joined(separator: " · ")
        }

        var balanceAsOfText: String {
            guard let balanceAsOf else { return "Not confirmed yet" }
            return "As of \(DateFormat.medium(balanceAsOf))"
        }

        /// The whole card as one sentence, so VoiceOver reads a coherent
        /// summary instead of a pile of unlabelled numbers.
        var accessibilityLabel: String {
            var parts = [
                name,
                rolesSummary,
                "Balance \(MoneyFormat.string(currentBalance)), \(balanceAsOfText.lowercased())"
            ]
            if protectedAmount > 0 {
                parts.append("Protected \(MoneyFormat.string(protectedAmount))")
            }
            parts.append("Available \(MoneyFormat.string(availableBalance))")
            if isDefaultIncome { parts.append("Receives your paycheck") }
            if let nextMovement { parts.append("Next: \(nextMovement.summary)") }
            if reconciliation.isAttention { parts.append("Needs attention: \(reconciliation.message)") }
            return parts.joined(separator: ". ")
        }
    }

    var cards: [AccountCard] = []
    var archivedCount = 0
    /// Sum of `availableBalance` across active accounts.
    var totalAvailable: Decimal = .zero
    var totalProtected: Decimal = .zero
    var totalBalance: Decimal = .zero
    /// Accounts whose entered balance and ledger disagree.
    var attentionCount: Int { cards.filter(\.reconciliation.isAttention).count }
    var isEmpty: Bool { cards.isEmpty }

    /// A-02 cap, carried from onboarding so both surfaces agree.
    static let accountCap = AccountsStepView.accountCap
    var isAtCap: Bool { cards.count >= Self.accountCap }
}

// MARK: - Loader

struct AccountsWorkspaceLoader {
    let context: ModelContext
    let dateProvider: DateProviding

    init(context: ModelContext, dateProvider: DateProviding = SystemDateProvider()) {
        self.context = context
        self.dateProvider = dateProvider
    }

    func load() throws -> AccountsWorkspaceState {
        let repository = CashAccountRepository(context: context)
        let reconciler = AccountReconciliationService(context: context)
        let now = dateProvider.now
        let accounts = try repository.activeAccounts()

        var state = AccountsWorkspaceState()
        state.cards = try accounts.map { account in
            let snapshot = CashAccountSnapshot(account)
            return AccountsWorkspaceState.AccountCard(
                id: account.id,
                name: account.name,
                roles: AccountRole.allCases.filter { account.roles.contains($0) },
                currentBalance: account.currentBalance,
                balanceAsOf: account.balanceAsOf,
                protectedAmount: account.protectedAmount,
                availableBalance: snapshot.availableBalance,
                isDefaultIncome: account.isDefaultIncome,
                updatedAt: account.updatedAt,
                nextMovement: try reconciler.nextPlannedMovement(for: account, now: now),
                reconciliation: try reconciler.reconciliation(for: account),
                archiveBlockers: try reconciler.archiveBlockers(for: account)
            )
        }
        state.archivedCount = try context.fetch(FetchDescriptor<CashAccount>())
            .filter(\.isArchived).count
        state.totalBalance = state.cards.reduce(Decimal.zero) { $0 + $1.currentBalance }.rounded2
        state.totalProtected = state.cards.reduce(Decimal.zero) { $0 + $1.protectedAmount }.rounded2
        state.totalAvailable = state.cards.reduce(Decimal.zero) { $0 + $1.availableBalance }.rounded2
        return state
    }
}

// MARK: - Activity presentation

/// One row of an account's activity, resolved to that account's point of view.
///
/// A transfer is a single stored row (Agent 2's design), so the *same* row
/// reads as money out on one account and money in on the other. Resolving that
/// here means the list never has to reason about direction while scrolling.
struct AccountActivityRow: Identifiable, Equatable {
    var id: UUID
    var date: Date
    var createdAt: Date
    var typeName: String
    /// Signed for this account: negative is money leaving.
    var signedAmount: Decimal
    var note: String?
    var auditNote: String?
    var provenance: LedgerProvenance?
    /// The other side of a transfer, when there is one.
    var counterpartName: String?

    var symbolName: String {
        if counterpartName != nil { return "arrow.left.arrow.right" }
        return signedAmount < 0 ? "arrow.up.right" : "arrow.down.left"
    }

    var amountText: String {
        let sign = signedAmount < 0 ? "−" : "+"
        return "\(sign)\(MoneyFormat.string(abs(signedAmount)))"
    }

    var detailText: String {
        var parts: [String] = [DateFormat.medium(date)]
        if let counterpartName {
            parts.append(signedAmount < 0 ? "to \(counterpartName)" : "from \(counterpartName)")
        }
        if let provenance, let description = Self.provenanceDescription(provenance) {
            parts.append(description)
        }
        return parts.joined(separator: " · ")
    }

    var accessibilityLabel: String {
        var parts = [typeName, amountText, detailText]
        if let note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: ", ")
    }

    /// Nil for `.user`: "you entered this" is the unremarkable case and
    /// labelling every row with it is noise. A nil *provenance* is likewise
    /// unlabelled — it means the row predates the column, which is a fact
    /// about the schema, not about the money.
    static func provenanceDescription(_ provenance: LedgerProvenance) -> String? {
        switch provenance {
        case .user: return nil
        case .checkIn: return "from a payday check-in"
        case .migration: return "carried over by an upgrade"
        case .importRestore: return "restored from a backup"
        }
    }
}

struct AccountActivityLoader {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func rows(for account: CashAccount, limit: Int? = nil) throws -> [AccountActivityRow] {
        let names = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<CashAccount>()).map { ($0.id, $0.name) }
        )
        let entries = try CashLedgerService(context: context).activity(for: account, limit: limit)
        return entries.map { entry in
            let counterpartID = entry.type == .accountTransfer
                ? (entry.sourceAccountID == account.id ? entry.destinationAccountID : entry.sourceAccountID)
                : nil
            return AccountActivityRow(
                id: entry.id,
                date: entry.effectiveDate,
                createdAt: entry.createdAt,
                typeName: entry.type.displayName,
                signedAmount: CashLedgerService.signedAmount(of: entry, for: account.id),
                note: entry.note,
                auditNote: entry.auditNote,
                provenance: entry.provenance,
                counterpartName: counterpartID.flatMap { names[$0] }
            )
        }
    }

    /// Balance history: every authoritative snapshot for the account, newest
    /// first. Corrections are included — the point of an append-only history is
    /// that you can see what was believed and when it changed.
    func balanceHistory(for account: CashAccount) throws -> [BalanceSnapshot] {
        let accountID = account.id
        return try context.fetch(FetchDescriptor<BalanceSnapshot>())
            .filter { $0.cashAccountID == accountID }
            .sorted { ($0.effectiveDate, $0.createdAt) > ($1.effectiveDate, $1.createdAt) }
    }
}
