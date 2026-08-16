import XCTest
import SwiftData
@testable import PaydayPlaybook

/// The Checking Accounts workspace (V3-02/V3-03): the figures each card shows,
/// the reconciliation rule, planned movements, and the archive blockers.
///
/// Every value here is invented (V3-12).
final class AccountsWorkspaceTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        ModelContext(try TestSupport.makeContainer())
    }

    private func makeAccount(
        _ context: ModelContext,
        name: String,
        balance: String,
        roles: Set<AccountRole> = [.spending],
        protected: String? = nil
    ) throws -> CashAccount {
        let repository = CashAccountRepository(context: context)
        let account = try repository.create(
            name: name, currentBalance: TestSupport.money(balance),
            roles: roles, now: TestSupport.fixedToday.now
        )
        if let protected {
            try repository.update(
                account, protectedAmount: TestSupport.money(protected),
                now: TestSupport.fixedToday.now
            )
        }
        return account
    }

    // MARK: - Card figures

    func testCardShowsBalanceProtectedAndAvailable() throws {
        let context = try makeContext()
        _ = try makeAccount(context, name: "Everyday", balance: "1800.00", protected: "500.00")

        let state = try AccountsWorkspaceLoader(
            context: context, dateProvider: TestSupport.fixedToday
        ).load()

        let card = try XCTUnwrap(state.cards.first)
        XCTAssertEqual(card.currentBalance, TestSupport.money("1800.00"))
        XCTAssertEqual(card.protectedAmount, TestSupport.money("500.00"))
        XCTAssertEqual(card.availableBalance, TestSupport.money("1300.00"))
        XCTAssertEqual(state.totalAvailable, TestSupport.money("1300.00"))
        XCTAssertTrue(card.isDefaultIncome, "The only account receives income")
    }

    /// Protected above the balance must not produce negative available cash —
    /// the plan's spendable figure floors at zero.
    func testAvailableNeverGoesNegative() throws {
        let context = try makeContext()
        _ = try makeAccount(context, name: "Tight", balance: "100.00", protected: "400.00")

        let state = try AccountsWorkspaceLoader(
            context: context, dateProvider: TestSupport.fixedToday
        ).load()
        XCTAssertEqual(state.cards.first?.availableBalance, .zero)
        XCTAssertEqual(state.totalAvailable, .zero)
    }

    func testTotalsSumAcrossAccounts() throws {
        let context = try makeContext()
        _ = try makeAccount(context, name: "Everyday", balance: "1200.00", protected: "200.00")
        _ = try makeAccount(context, name: "Bills", balance: "800.50", roles: [.reserves], protected: "0.50")

        let state = try AccountsWorkspaceLoader(
            context: context, dateProvider: TestSupport.fixedToday
        ).load()
        XCTAssertEqual(state.totalBalance, TestSupport.money("2000.50"))
        XCTAssertEqual(state.totalProtected, TestSupport.money("200.50"))
        XCTAssertEqual(state.totalAvailable, TestSupport.money("1800.00"))
    }

    // MARK: - Reconciliation (V3-03)

    /// Without an authoritative snapshot there is nothing to reconcile
    /// against, and the card says so rather than claiming agreement.
    func testUnconfirmedBalanceReportsItselfAsUnconfirmed() throws {
        let context = try makeContext()
        _ = try makeAccount(context, name: "Everyday", balance: "1000.00")

        let state = try AccountsWorkspaceLoader(
            context: context, dateProvider: TestSupport.fixedToday
        ).load()
        XCTAssertEqual(state.cards.first?.reconciliation, .notConfirmed)
        XCTAssertEqual(state.attentionCount, 0, "Unconfirmed is not an alarm")
    }

    func testMovementsAfterAConfirmedBalanceStillReconcile() throws {
        let context = try makeContext()
        let account = try makeAccount(context, name: "Everyday", balance: "1000.00")
        let ledger = CashLedgerService(context: context, dateProvider: TestSupport.fixedToday)

        try ledger.adjustBalance(of: account, to: TestSupport.money("1000.00"))
        try ledger.deposit(into: account, amount: TestSupport.money("250.00"))
        try ledger.withdraw(from: account, amount: TestSupport.money("75.25"))

        let reconciliation = try AccountReconciliationService(context: context)
            .reconciliation(for: account)
        guard case .reconciled = reconciliation else {
            return XCTFail("Expected reconciled, got \(reconciliation)")
        }
        XCTAssertEqual(account.currentBalance, TestSupport.money("1174.75"))
    }

    /// A balance changed outside the ledger — which is what an import, a
    /// migration, or an old direct edit does — is exactly the divergence the
    /// attention state exists to surface.
    func testBalanceChangedOutsideTheLedgerNeedsAttention() throws {
        let context = try makeContext()
        let account = try makeAccount(context, name: "Everyday", balance: "1000.00")
        let ledger = CashLedgerService(context: context, dateProvider: TestSupport.fixedToday)
        try ledger.adjustBalance(of: account, to: TestSupport.money("1000.00"))

        // Not through the ledger: no row explains this.
        account.currentBalance = TestSupport.money("1120.00")
        try context.save()

        let reconciliation = try AccountReconciliationService(context: context)
            .reconciliation(for: account)
        guard case .needsAttention(let difference, let derived, _) = reconciliation else {
            return XCTFail("Expected needsAttention, got \(reconciliation)")
        }
        XCTAssertEqual(difference, TestSupport.money("120.00"))
        XCTAssertEqual(derived, TestSupport.money("1000.00"))
        XCTAssertTrue(reconciliation.isAttention)
    }

    /// Recording the real balance is the documented way out of the attention
    /// state, and it must not rewrite what was already recorded.
    func testRecordingTheRealBalanceClearsAttentionWithoutErasingHistory() throws {
        let context = try makeContext()
        let account = try makeAccount(context, name: "Everyday", balance: "1000.00")
        let ledger = CashLedgerService(context: context, dateProvider: TestSupport.fixedToday)
        try ledger.adjustBalance(of: account, to: TestSupport.money("1000.00"))
        account.currentBalance = TestSupport.money("1120.00")
        try context.save()

        try ledger.adjustBalance(of: account, to: TestSupport.money("1120.00"))

        let reconciliation = try AccountReconciliationService(context: context)
            .reconciliation(for: account)
        guard case .reconciled = reconciliation else {
            return XCTFail("Expected reconciled, got \(reconciliation)")
        }
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<BalanceSnapshot>()).count, 2,
            "Both stated balances are kept — the earlier one is never edited away"
        )
        // No ledger row: the app can see that the balance is now 1,120 but it
        // never saw money move, so it records the stated figure and does not
        // invent a movement to explain it.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), 0)
    }

    /// The counterpart to the case above: when the app's own recorded balance
    /// is the stale one, the correction *is* written as its own dated row.
    func testAStatedBalanceThatDiffersWritesItsDifferenceAsANewRow() throws {
        let context = try makeContext()
        let account = try makeAccount(context, name: "Everyday", balance: "1000.00")
        let ledger = CashLedgerService(context: context, dateProvider: TestSupport.fixedToday)

        try ledger.adjustBalance(of: account, to: TestSupport.money("1120.00"))

        let rows = try context.fetch(FetchDescriptor<LedgerEntry>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.type, .accountAdjustment)
        XCTAssertEqual(rows.first?.amount, TestSupport.money("120.00"))
        XCTAssertEqual(account.currentBalance, TestSupport.money("1120.00"))

        guard case .reconciled = try AccountReconciliationService(context: context)
            .reconciliation(for: account) else {
            return XCTFail("The account must reconcile immediately after its own correction")
        }
    }

    /// A transfer is one row that reads as negative on its source and positive
    /// on its destination, so both sides reconcile from the same row.
    func testTransferReconcilesBothSidesFromOneRow() throws {
        let context = try makeContext()
        let source = try makeAccount(context, name: "Everyday", balance: "1000.00")
        let destination = try makeAccount(context, name: "Bills", balance: "200.00", roles: [.reserves])
        let ledger = CashLedgerService(context: context, dateProvider: TestSupport.fixedToday)
        try ledger.adjustBalance(of: source, to: TestSupport.money("1000.00"))
        try ledger.adjustBalance(of: destination, to: TestSupport.money("200.00"))

        try ledger.transfer(from: source, to: destination, amount: TestSupport.money("150.00"))

        let reconciler = AccountReconciliationService(context: context)
        for account in [source, destination] {
            guard case .reconciled = try reconciler.reconciliation(for: account) else {
                return XCTFail("\(account.name) did not reconcile after the transfer")
            }
        }
        XCTAssertEqual(source.currentBalance, TestSupport.money("850.00"))
        XCTAssertEqual(destination.currentBalance, TestSupport.money("350.00"))
    }

    // MARK: - Activity presentation

    func testActivityResolvesTransferDirectionPerAccount() throws {
        let context = try makeContext()
        let source = try makeAccount(context, name: "Everyday", balance: "1000.00")
        let destination = try makeAccount(context, name: "Bills", balance: "200.00", roles: [.reserves])
        try CashLedgerService(context: context, dateProvider: TestSupport.fixedToday)
            .transfer(from: source, to: destination, amount: TestSupport.money("150.00"))

        let loader = AccountActivityLoader(context: context)
        let outgoing = try XCTUnwrap(try loader.rows(for: source).first)
        let incoming = try XCTUnwrap(try loader.rows(for: destination).first)

        XCTAssertEqual(outgoing.id, incoming.id, "One stored row, seen from both sides")
        XCTAssertEqual(outgoing.signedAmount, TestSupport.money("-150.00"))
        XCTAssertEqual(incoming.signedAmount, TestSupport.money("150.00"))
        XCTAssertEqual(outgoing.counterpartName, "Bills")
        XCTAssertEqual(incoming.counterpartName, "Everyday")
        XCTAssertTrue(outgoing.accessibilityLabel.contains("to Bills"))
        XCTAssertTrue(incoming.accessibilityLabel.contains("from Everyday"))
    }

    func testBalanceHistoryKeepsEveryStatedFigureNewestFirst() throws {
        let context = try makeContext()
        let account = try makeAccount(context, name: "Everyday", balance: "1000.00")
        let ledger = CashLedgerService(context: context, dateProvider: TestSupport.fixedToday)
        try ledger.adjustBalance(
            of: account, to: TestSupport.money("1000.00"),
            effectiveDate: TestSupport.date(2054, 8, 1)
        )
        try ledger.adjustBalance(
            of: account, to: TestSupport.money("1400.00"),
            effectiveDate: TestSupport.date(2054, 8, 20)
        )

        let history = try AccountActivityLoader(context: context).balanceHistory(for: account)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.first?.amount, TestSupport.money("1400.00"))
        XCTAssertEqual(history.last?.amount, TestSupport.money("1000.00"))
    }

    // MARK: - Archive blockers

    func testTheOnlyAccountCannotBeArchivedAndSaysWhy() throws {
        let context = try makeContext()
        let account = try makeAccount(context, name: "Everyday", balance: "1000.00")

        let blockers = try AccountReconciliationService(context: context)
            .archiveBlockers(for: account)
        XCTAssertEqual(blockers.map(\.reason), [.lastActiveAccount])
        XCTAssertFalse(blockers[0].detail.isEmpty, "A blocker always says what to do next")
    }

    func testIncomeAccountAndBillsPaidFromItBlockArchiveWithNamedReasons() throws {
        let context = try makeContext()
        let income = try makeAccount(context, name: "Everyday", balance: "1000.00", roles: [.income, .spending])
        _ = try makeAccount(context, name: "Bills", balance: "200.00", roles: [.reserves])
        try ObligationRepository(context: context).create(
            name: "Rent", amount: TestSupport.money("1400.00"), cadence: .monthly,
            dueDay: 1, accountID: income.id, now: TestSupport.fixedToday.now
        )

        let blockers = try AccountReconciliationService(context: context)
            .archiveBlockers(for: income)
        XCTAssertTrue(blockers.contains { $0.reason == .defaultIncome })
        XCTAssertTrue(blockers.contains { $0.reason == .obligationsPaidFrom })
        XCTAssertTrue(
            blockers.contains { $0.detail.contains("Rent") },
            "The blocker names the bill so the user can go and change it"
        )
    }

    func testAnUnreferencedAccountArchivesAndRestores() throws {
        let context = try makeContext()
        _ = try makeAccount(context, name: "Everyday", balance: "1000.00", roles: [.income, .spending])
        let spare = try makeAccount(context, name: "Spare", balance: "50.00", roles: [.reserves])
        let repository = CashAccountRepository(context: context)

        XCTAssertEqual(try AccountReconciliationService(context: context).archiveBlockers(for: spare), [])
        XCTAssertTrue(try repository.archiveIfAllowed(spare, now: TestSupport.fixedToday.now))

        var state = try AccountsWorkspaceLoader(
            context: context, dateProvider: TestSupport.fixedToday
        ).load()
        XCTAssertEqual(state.cards.count, 1)
        XCTAssertEqual(state.archivedCount, 1)

        try repository.restore(spare, now: TestSupport.fixedToday.now)
        state = try AccountsWorkspaceLoader(
            context: context, dateProvider: TestSupport.fixedToday
        ).load()
        XCTAssertEqual(state.cards.count, 2)
        XCTAssertEqual(state.archivedCount, 0)
    }

    // MARK: - Planned movement

    func testNextPlannedMovementPrefersTheSoonestOfPaycheckAndBill() throws {
        let context = try makeContext()
        let account = try makeAccount(context, name: "Everyday", balance: "1000.00", roles: [.income, .spending])
        try ObligationRepository(context: context).create(
            name: "Rent", amount: TestSupport.money("1400.00"), cadence: .monthly,
            dueDay: 1, accountID: account.id, now: TestSupport.fixedToday.now
        )

        let movement = try AccountReconciliationService(context: context)
            .nextPlannedMovement(for: account, now: TestSupport.fixedToday.now)
        let unwrapped = try XCTUnwrap(movement)
        XCTAssertEqual(unwrapped.kind, .bill, "No plan exists, so the bill is the only movement")
        XCTAssertEqual(unwrapped.label, "Rent")
        XCTAssertTrue(unwrapped.summary.contains("Rent"))
    }

    func testAnAccountWithNothingScheduledReportsNoMovement() throws {
        let context = try makeContext()
        _ = try makeAccount(context, name: "Everyday", balance: "1000.00", roles: [.income, .spending])
        let spare = try makeAccount(context, name: "Spare", balance: "50.00", roles: [.reserves])

        XCTAssertNil(
            try AccountReconciliationService(context: context)
                .nextPlannedMovement(for: spare, now: TestSupport.fixedToday.now)
        )
    }

    // MARK: - Reorder

    func testReorderKeepsUnnamedAccountsAfterTheNamedOnes() throws {
        let context = try makeContext()
        let first = try makeAccount(context, name: "A", balance: "10.00")
        let second = try makeAccount(context, name: "B", balance: "20.00")
        let third = try makeAccount(context, name: "C", balance: "30.00")

        try CashAccountRepository(context: context)
            .reorder([third.id, first.id], now: TestSupport.fixedToday.now)

        let state = try AccountsWorkspaceLoader(
            context: context, dateProvider: TestSupport.fixedToday
        ).load()
        XCTAssertEqual(state.cards.map(\.name), ["C", "A", "B"])
        XCTAssertEqual(second.name, "B")
    }

    // MARK: - Accessibility copy

    /// VoiceOver reads one coherent sentence per card, and nothing on a card
    /// is conveyed by colour alone.
    func testCardAccessibilityLabelNamesEveryFigureItShows() throws {
        let context = try makeContext()
        _ = try makeAccount(context, name: "Everyday", balance: "1800.00", protected: "500.00")

        let state = try AccountsWorkspaceLoader(
            context: context, dateProvider: TestSupport.fixedToday
        ).load()
        let label = try XCTUnwrap(state.cards.first?.accessibilityLabel)

        XCTAssertTrue(label.contains("Everyday"))
        XCTAssertTrue(label.contains(MoneyFormat.string(TestSupport.money("1800.00"))))
        XCTAssertTrue(label.contains("Protected"))
        XCTAssertTrue(label.contains("Available"))
        XCTAssertTrue(label.contains("Receives your paycheck"))
        XCTAssertTrue(label.contains("not confirmed yet"))
    }

    /// No message anywhere in the reconciliation vocabulary blames the user.
    func testReconciliationCopyCarriesNoShameLanguage() {
        let banned = ["overspent", "you failed", "bad", "wrong of you", "irresponsible", "should have"]
        let messages = [
            AccountReconciliation.notConfirmed.message,
            AccountReconciliation.reconciled(asOf: TestSupport.fixedToday.now).message,
            AccountReconciliation.needsAttention(
                difference: TestSupport.money("120.00"),
                derivedBalance: TestSupport.money("1000.00"),
                asOf: TestSupport.fixedToday.now
            ).message
        ]
        for message in messages {
            for phrase in banned {
                XCTAssertFalse(
                    message.lowercased().contains(phrase),
                    "\"\(phrase)\" appeared in: \(message)"
                )
            }
        }
    }
}
