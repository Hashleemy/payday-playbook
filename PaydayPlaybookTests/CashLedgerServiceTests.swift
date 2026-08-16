import XCTest
import SwiftData
@testable import PaydayPlaybook

/// T-3 / T-4 (V3-04): cash-account movements. Transfers reconcile atomically,
/// adjustments leave audit evidence, and no operation rewrites history.
final class CashLedgerServiceTests: XCTestCase {

    private func makeAccounts() throws -> (ModelContext, CashLedgerService, CashAccount, CashAccount) {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let repository = CashAccountRepository(context: context)
        let spending = try repository.create(
            name: "Everyday", currentBalance: TestSupport.money("1000.00"),
            roles: [.income, .spending], now: TestSupport.fixedToday.now
        )
        let reserves = try repository.create(
            name: "Reserves", currentBalance: TestSupport.money("400.00"),
            roles: [.reserves], now: TestSupport.fixedToday.now
        )
        let service = CashLedgerService(context: context, dateProvider: TestSupport.fixedToday)
        return (context, service, spending, reserves)
    }

    // MARK: - Deposits and withdrawals

    func testDepositAndWithdrawalMoveTheBalanceAndRecordProvenance() throws {
        let (context, service, spending, _) = try makeAccounts()

        let deposit = try service.deposit(into: spending, amount: TestSupport.money("250.00"))
        XCTAssertEqual(spending.currentBalance, TestSupport.money("1250.00"))
        XCTAssertEqual(deposit.type, .accountDeposit)
        XCTAssertEqual(deposit.destinationAccountID, spending.id)
        XCTAssertNil(deposit.sourceAccountID)
        XCTAssertEqual(deposit.provenance, .user)
        XCTAssertEqual(spending.balanceAsOf, deposit.effectiveDate)

        let withdrawal = try service.withdraw(from: spending, amount: TestSupport.money("50.00"))
        XCTAssertEqual(spending.currentBalance, TestSupport.money("1200.00"))
        XCTAssertEqual(withdrawal.type, .accountWithdrawal)
        XCTAssertEqual(withdrawal.sourceAccountID, spending.id)
        XCTAssertNil(withdrawal.destinationAccountID)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), 2)
    }

    func testZeroAndNegativeAmountsAreRefused() throws {
        let (context, service, spending, _) = try makeAccounts()
        for amount in [Decimal.zero, TestSupport.money("-5.00")] {
            XCTAssertThrowsError(try service.deposit(into: spending, amount: amount)) { error in
                XCTAssertEqual(error as? CashLedgerService.LedgerError, .amountNotPositive)
            }
        }
        XCTAssertEqual(spending.currentBalance, TestSupport.money("1000.00"))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), 0)
    }

    func testArchivedAccountsRefuseNewActivity() throws {
        let (_, service, spending, reserves) = try makeAccounts()
        let repository = CashAccountRepository(context: spending.modelContext!)
        try repository.archive(reserves)

        XCTAssertThrowsError(try service.deposit(into: reserves, amount: TestSupport.money("10.00")))
        XCTAssertThrowsError(
            try service.transfer(from: spending, to: reserves, amount: TestSupport.money("10.00"))
        )
        XCTAssertEqual(reserves.currentBalance, TestSupport.money("400.00"))
    }

    // MARK: - T-3: paired transfers reconcile atomically

    /// One row carries the whole movement, so both sides always agree.
    func testTransferIsASingleRowThatBalancesBothAccounts() throws {
        let (context, service, spending, reserves) = try makeAccounts()

        let entry = try service.transfer(
            from: spending, to: reserves, amount: TestSupport.money("300.00")
        )

        XCTAssertEqual(spending.currentBalance, TestSupport.money("700.00"))
        XCTAssertEqual(reserves.currentBalance, TestSupport.money("700.00"))

        // Exactly one row — a pair could half-exist; this cannot.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), 1)
        XCTAssertEqual(entry.type, .accountTransfer)
        XCTAssertEqual(entry.sourceAccountID, spending.id)
        XCTAssertEqual(entry.destinationAccountID, reserves.id)

        // The one row reads as negative on the source and positive on the
        // destination, which is what lets it present as a paired movement.
        XCTAssertEqual(CashLedgerService.signedAmount(of: entry, for: spending.id),
                       TestSupport.money("-300.00"))
        XCTAssertEqual(CashLedgerService.signedAmount(of: entry, for: reserves.id),
                       TestSupport.money("300.00"))

        // R-16: a transfer moves money, it never creates or destroys any.
        XCTAssertEqual(
            CashLedgerService.signedAmount(of: entry, for: spending.id)
                + CashLedgerService.signedAmount(of: entry, for: reserves.id),
            .zero
        )
    }

    func testTransferTotalsReconcileAcrossManyMovements() throws {
        let (_, service, spending, reserves) = try makeAccounts()
        let openingTotal = spending.currentBalance + reserves.currentBalance

        for amount in ["100.00", "25.50", "8.99", "300.00"] {
            _ = try service.transfer(from: spending, to: reserves, amount: TestSupport.money(amount))
        }
        _ = try service.transfer(from: reserves, to: spending, amount: TestSupport.money("40.00"))

        XCTAssertEqual(spending.currentBalance + reserves.currentBalance, openingTotal,
                       "transfers must not change the total cash held")

        let spendingActivity = try service.activity(for: spending)
        let reservesActivity = try service.activity(for: reserves)
        XCTAssertEqual(spendingActivity.count, 5)
        XCTAssertEqual(reservesActivity.count, 5)
        XCTAssertEqual(
            CashLedgerService.netMovement(of: spendingActivity, for: spending.id)
                + CashLedgerService.netMovement(of: reservesActivity, for: reserves.id),
            .zero
        )
    }

    func testTransferToTheSameAccountIsRefused() throws {
        let (context, service, spending, _) = try makeAccounts()
        XCTAssertThrowsError(
            try service.transfer(from: spending, to: spending, amount: TestSupport.money("10.00"))
        ) { error in
            XCTAssertEqual(error as? CashLedgerService.LedgerError, .sameAccountTransfer)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), 0)
    }

    // MARK: - T-4: adjustments are auditable and never rewrite history

    func testAdjustmentWritesTheDifferenceAndASnapshotWithoutTouchingHistory() throws {
        let (context, service, spending, _) = try makeAccounts()

        // Some history to protect.
        let earlier = try service.deposit(into: spending, amount: TestSupport.money("200.00"))
        let earlierAmount = earlier.amount
        let earlierDate = earlier.effectiveDate
        XCTAssertEqual(spending.currentBalance, TestSupport.money("1200.00"))

        // The user says the real balance is lower than the app believes.
        let stated = TestSupport.money("1150.00")
        let when = TestSupport.date(2054, 8, 12)
        let result = try service.adjustBalance(
            of: spending, to: stated, effectiveDate: when,
            note: "bank fee", auditNote: "reconciled against statement"
        )

        // The delta is recorded, signed, as its own dated row.
        let entry = try XCTUnwrap(result.entry)
        XCTAssertEqual(entry.type, .accountAdjustment)
        XCTAssertEqual(entry.amount, TestSupport.money("-50.00"))
        XCTAssertEqual(entry.effectiveDate, when)
        XCTAssertEqual(entry.auditNote, "reconciled against statement")
        XCTAssertTrue(entry.type.allowsNegativeAmount)

        // The stated figure is preserved as authoritative evidence.
        XCTAssertEqual(result.snapshot.amount, stated)
        XCTAssertTrue(result.snapshot.isAuthoritative)
        XCTAssertEqual(result.snapshot.cashAccountID, spending.id)
        XCTAssertEqual(result.snapshot.effectiveDate, when)

        // The account now reflects the stated balance, dated.
        XCTAssertEqual(spending.currentBalance, stated)
        XCTAssertEqual(spending.balanceAsOf, when)

        // The earlier row is untouched — history explains the gap, it is not
        // edited away.
        XCTAssertEqual(earlier.amount, earlierAmount)
        XCTAssertEqual(earlier.effectiveDate, earlierDate)
        XCTAssertFalse(earlier.isDeleted)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), 2)
    }

    func testUpwardAdjustmentRecordsAPositiveDelta() throws {
        let (_, service, spending, _) = try makeAccounts()
        let result = try service.adjustBalance(of: spending, to: TestSupport.money("1075.25"))
        XCTAssertEqual(try XCTUnwrap(result.entry).amount, TestSupport.money("75.25"))
        XCTAssertEqual(spending.currentBalance, TestSupport.money("1075.25"))
    }

    /// Confirming a balance that already matches is still a fact worth
    /// keeping — but no money moved, so no ledger row is written.
    func testConfirmingAnUnchangedBalanceWritesEvidenceButNoLedgerRow() throws {
        let (context, service, spending, _) = try makeAccounts()
        let result = try service.adjustBalance(of: spending, to: TestSupport.money("1000.00"))

        XCTAssertNil(result.entry)
        XCTAssertEqual(result.snapshot.amount, TestSupport.money("1000.00"))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BalanceSnapshot>()), 1)
        XCTAssertNotNil(spending.balanceAsOf)
    }

    func testRepeatedAdjustmentsAccumulateAsSeparateEvidence() throws {
        let (context, service, spending, _) = try makeAccounts()
        _ = try service.adjustBalance(of: spending, to: TestSupport.money("900.00"),
                                      effectiveDate: TestSupport.date(2054, 8, 11))
        _ = try service.adjustBalance(of: spending, to: TestSupport.money("950.00"),
                                      effectiveDate: TestSupport.date(2054, 8, 12))

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BalanceSnapshot>()), 2,
                       "snapshots are append-only; a later one never replaces an earlier one")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), 2)
        XCTAssertEqual(spending.currentBalance, TestSupport.money("950.00"))
    }

    // MARK: - Activity and archive safeguards

    func testActivityIsNewestFirstAndScopedToTheAccount() throws {
        let (_, service, spending, reserves) = try makeAccounts()
        _ = try service.deposit(into: spending, amount: TestSupport.money("10.00"),
                                effectiveDate: TestSupport.date(2054, 8, 11))
        _ = try service.deposit(into: reserves, amount: TestSupport.money("20.00"),
                                effectiveDate: TestSupport.date(2054, 8, 12))
        _ = try service.transfer(from: spending, to: reserves, amount: TestSupport.money("30.00"),
                                 effectiveDate: TestSupport.date(2054, 8, 13))

        let spendingActivity = try service.activity(for: spending)
        XCTAssertEqual(spendingActivity.count, 2, "the reserves-only deposit is not listed")
        XCTAssertEqual(spendingActivity.map(\.effectiveDate),
                       [TestSupport.date(2054, 8, 13), TestSupport.date(2054, 8, 11)])
        XCTAssertEqual(try service.activity(for: spending, limit: 1).count, 1)
    }

    /// Archiving keeps history: the rows stay and still reference the account.
    func testArchivingKeepsHistoryAndTheLastAccountCannotBeArchived() throws {
        let (context, service, spending, reserves) = try makeAccounts()
        _ = try service.transfer(from: spending, to: reserves, amount: TestSupport.money("100.00"))

        let repository = CashAccountRepository(context: context)
        XCTAssertTrue(try repository.canArchive(reserves))
        XCTAssertTrue(try repository.archiveIfAllowed(reserves))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), 1,
                       "archiving is not deletion — the movement stays on the ledger")
        XCTAssertEqual(try service.activity(for: reserves).count, 1)

        // The last remaining account cannot be archived; something must be
        // able to receive income.
        XCTAssertFalse(try repository.canArchive(spending))
        XCTAssertFalse(try repository.archiveIfAllowed(spending))
        XCTAssertFalse(spending.isArchived)
        XCTAssertTrue(spending.isDefaultIncome)
    }

    func testRestoringAnArchivedAccountKeepsTheExistingDefaultIncome() throws {
        let (context, _, spending, reserves) = try makeAccounts()
        let repository = CashAccountRepository(context: context)
        try repository.archive(reserves)
        try repository.restore(reserves)

        XCTAssertFalse(reserves.isArchived)
        XCTAssertTrue(spending.isDefaultIncome)
        XCTAssertFalse(reserves.isDefaultIncome)
        XCTAssertEqual(try repository.activeAccounts().filter(\.isDefaultIncome).count, 1)
    }

    // MARK: - Protected cash

    func testAvailableCashExcludesProtectedAmounts() throws {
        let (context, _, spending, reserves) = try makeAccounts()
        let repository = CashAccountRepository(context: context)
        try repository.update(spending, protectedAmount: TestSupport.money("600.00"))

        let snapshots = try repository.accountSnapshots()
        let spendingSnapshot = try XCTUnwrap(snapshots.first { $0.id == spending.id })
        XCTAssertEqual(spendingSnapshot.availableBalance, TestSupport.money("400.00"))

        // 1,000 − 600 protected, plus the reserves account's 400.
        XCTAssertEqual(try repository.totalAvailableCash(), TestSupport.money("800.00"))
        _ = reserves
    }

    func testProtectedAmountNeverPushesAvailableCashNegative() throws {
        let (context, _, spending, _) = try makeAccounts()
        let repository = CashAccountRepository(context: context)
        try repository.update(spending, protectedAmount: TestSupport.money("5000.00"))

        let snapshot = try XCTUnwrap(repository.accountSnapshots().first { $0.id == spending.id })
        XCTAssertEqual(snapshot.availableBalance, .zero)
    }

    func testNegativeProtectedAmountIsRefused() throws {
        let (context, _, spending, _) = try makeAccounts()
        let repository = CashAccountRepository(context: context)
        XCTAssertThrowsError(try repository.update(spending, protectedAmount: TestSupport.money("-1.00")))
        XCTAssertEqual(spending.protectedAmount, .zero)
    }

    // MARK: - Reordering

    func testReorderPlacesNamedAccountsFirstAndKeepsTheRestStable() throws {
        let (context, _, spending, reserves) = try makeAccounts()
        let repository = CashAccountRepository(context: context)
        let third = try repository.create(
            name: "Savings", currentBalance: .zero, roles: [.reserves],
            now: TestSupport.fixedToday.now
        )

        try repository.reorder([reserves.id])

        let ordered = try repository.activeAccounts()
        XCTAssertEqual(ordered.first?.id, reserves.id)
        XCTAssertEqual(ordered.map(\.id).dropFirst(), [spending.id, third.id],
                       "accounts the caller did not name keep their relative order")
    }
}
