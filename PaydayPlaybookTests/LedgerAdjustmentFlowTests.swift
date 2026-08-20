import XCTest
import SwiftData
@testable import PaydayPlaybook

/// T-23 (V4-06): the generic checking-account adjustment flow.
///
/// Menu copy, account preselection across 1–10 fictional accounts, both
/// adjustment types converging on `CashLedgerService.adjustBalance` with the
/// reconciliation companion-row invariant intact, the swept legacy labels,
/// and the byte-for-byte guarantee that legacy-shaped rows are never mutated
/// or double-counted by the new flow.
final class LedgerAdjustmentFlowTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        ModelContext(try TestSupport.makeContainer())
    }

    /// A service whose clock is pinned to the given day, so repeated
    /// operations get advancing `createdAt` stamps the way production saves
    /// do.
    private func service(_ context: ModelContext, day: Int) -> CashLedgerService {
        CashLedgerService(
            context: context,
            dateProvider: FixedDateProvider(fixed: TestSupport.date(2054, 8, day))
        )
    }

    @discardableResult
    private func makeAccount(
        _ context: ModelContext,
        name: String,
        balance: String = "1000.00",
        roles: Set<AccountRole> = [.income, .spending]
    ) throws -> CashAccount {
        try CashAccountRepository(context: context).create(
            name: name, currentBalance: TestSupport.money(balance),
            roles: roles, now: TestSupport.fixedToday.now
        )
    }

    // MARK: - Menu and adjustment-type copy

    func testMenuOffersExactlyCheckingAccountAdjustment() {
        XCTAssertEqual(CheckingAccountAdjustmentView.menuTitle, "Checking account adjustment")
    }

    func testAdjustmentTypePickerOffersExactlyTheTwoContractTypes() {
        XCTAssertEqual(
            CheckingAccountAdjustmentView.AdjustmentType.allCases.map(\.displayName),
            ["Set balance to…", "Adjust by amount"]
        )
    }

    // MARK: - Account selection

    func testSingleActiveAccountIsPreselected() throws {
        let context = try makeContext()
        let account = try makeAccount(context, name: "Everyday")
        let active = try CashAccountRepository(context: context).activeAccounts()
        XCTAssertEqual(CheckingAccountAdjustmentView.preselectedAccountID(in: active), account.id)
    }

    func testMultipleActiveAccountsRequireAnExplicitChoice() throws {
        let context = try makeContext()
        try makeAccount(context, name: "Everyday")
        try makeAccount(context, name: "Household", roles: [.spending])
        try makeAccount(context, name: "Reserve", roles: [.reserves])
        let active = try CashAccountRepository(context: context).activeAccounts()
        XCTAssertNil(CheckingAccountAdjustmentView.preselectedAccountID(in: active))
    }

    /// V4-06 acceptance: the form's account selection works for 1–10
    /// fictional accounts.
    func testPreselectionAcrossOneToTenAccounts() throws {
        for count in 1...10 {
            let context = try makeContext()
            for index in 1...count {
                try makeAccount(context, name: "Account \(index)", roles: [.spending])
            }
            let active = try CashAccountRepository(context: context).activeAccounts()
            XCTAssertEqual(active.count, count)
            XCTAssertEqual(active.map(\.name), (1...count).map { "Account \($0)" },
                           "accounts are offered in display order")
            if count == 1 {
                XCTAssertEqual(
                    CheckingAccountAdjustmentView.preselectedAccountID(in: active),
                    active.first?.id
                )
            } else {
                XCTAssertNil(CheckingAccountAdjustmentView.preselectedAccountID(in: active))
            }
        }
    }

    func testArchivedAccountsAreNotOffered() throws {
        let context = try makeContext()
        let everyday = try makeAccount(context, name: "Everyday")
        let reserve = try makeAccount(context, name: "Reserve", roles: [.reserves])
        let repository = CashAccountRepository(context: context)
        try repository.archive(reserve)

        let active = try repository.activeAccounts()
        XCTAssertEqual(active.map(\.id), [everyday.id])
        XCTAssertEqual(CheckingAccountAdjustmentView.preselectedAccountID(in: active), everyday.id)
    }

    // MARK: - Adjust by amount

    func testAdjustByAmountIncreaseWritesSignedDeltaAndSnapshot() throws {
        let context = try makeContext()
        let account = try makeAccount(context, name: "Everyday")
        let when = TestSupport.date(2054, 8, 12)

        let result = try service(context, day: 12).adjustBalance(
            of: account, by: TestSupport.money("75.25"),
            effectiveDate: when, note: "found cash", auditNote: "quick-add adjustment"
        )

        let entry = try XCTUnwrap(result.entry)
        XCTAssertEqual(entry.type, .accountAdjustment)
        XCTAssertEqual(entry.amount, TestSupport.money("75.25"))
        XCTAssertEqual(entry.effectiveDate, when)
        XCTAssertEqual(entry.destinationAccountID, account.id)
        XCTAssertNil(entry.sourceAccountID)
        XCTAssertEqual(entry.provenance, .user)
        XCTAssertEqual(entry.note, "found cash")
        XCTAssertEqual(entry.auditNote, "quick-add adjustment")

        XCTAssertEqual(result.snapshot.amount, TestSupport.money("1075.25"))
        XCTAssertTrue(result.snapshot.isAuthoritative)
        XCTAssertEqual(result.snapshot.cashAccountID, account.id)
        XCTAssertEqual(result.snapshot.effectiveDate, when)

        XCTAssertEqual(account.currentBalance, TestSupport.money("1075.25"))
        XCTAssertEqual(account.balanceAsOf, when)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BalanceSnapshot>()), 1)
    }

    func testAdjustByAmountDecreaseCarriesANegativeAmount() throws {
        let context = try makeContext()
        let account = try makeAccount(context, name: "Everyday")

        let result = try service(context, day: 12).adjustBalance(
            of: account, by: TestSupport.money("-50.00")
        )

        let entry = try XCTUnwrap(result.entry)
        XCTAssertEqual(entry.amount, TestSupport.money("-50.00"))
        XCTAssertTrue(entry.type.allowsNegativeAmount)
        XCTAssertEqual(result.snapshot.amount, TestSupport.money("950.00"))
        XCTAssertEqual(account.currentBalance, TestSupport.money("950.00"))
    }

    func testAdjustByZeroIsRefused() throws {
        let context = try makeContext()
        let account = try makeAccount(context, name: "Everyday")

        XCTAssertThrowsError(
            try service(context, day: 12).adjustBalance(of: account, by: .zero)
        ) { error in
            XCTAssertEqual(error as? CashLedgerService.LedgerError, .adjustmentAmountZero)
        }
        XCTAssertEqual(account.currentBalance, TestSupport.money("1000.00"))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BalanceSnapshot>()), 0)
    }

    func testAdjustmentsOnArchivedAccountsAreRefused() throws {
        let context = try makeContext()
        try makeAccount(context, name: "Everyday")
        let reserve = try makeAccount(context, name: "Reserve", roles: [.reserves])
        try CashAccountRepository(context: context).archive(reserve)

        let ledger = service(context, day: 12)
        XCTAssertThrowsError(try ledger.adjustBalance(of: reserve, by: TestSupport.money("10.00"))) { error in
            XCTAssertEqual(error as? CashLedgerService.LedgerError, .accountArchived("Reserve"))
        }
        XCTAssertThrowsError(try ledger.adjustBalance(of: reserve, to: TestSupport.money("500.00")))
        XCTAssertEqual(reserve.currentBalance, TestSupport.money("1000.00"))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), 0)
    }

    // MARK: - Convergence of the two types

    /// Both adjustment types write the identical snapshot-plus-companion-row
    /// shape, so reconciliation cannot tell them apart.
    func testBothAdjustmentTypesWriteTheSameCompanionRowShape() throws {
        let context = try makeContext()
        let everyday = try makeAccount(context, name: "Everyday")
        let household = try makeAccount(context, name: "Household", roles: [.spending])
        let ledger = service(context, day: 12)

        let set = try ledger.adjustBalance(of: everyday, to: TestSupport.money("1100.00"))
        let by = try ledger.adjustBalance(of: household, by: TestSupport.money("100.00"))

        for (result, account) in [(set, everyday), (by, household)] {
            let entry = try XCTUnwrap(result.entry)
            XCTAssertEqual(entry.type, .accountAdjustment)
            XCTAssertEqual(entry.amount, TestSupport.money("100.00"))
            XCTAssertEqual(entry.createdAt, result.snapshot.createdAt,
                           "snapshot and delta row must share createdAt — the companion-row invariant")
            XCTAssertEqual(entry.effectiveDate, result.snapshot.effectiveDate)
            XCTAssertEqual(entry.destinationAccountID, account.id)
            XCTAssertNil(entry.sourceAccountID)
            XCTAssertEqual(entry.provenance, .user)
            XCTAssertTrue(result.snapshot.isAuthoritative)
            XCTAssertEqual(result.snapshot.cashAccountID, account.id)
        }

        let reconciliation = AccountReconciliationService(context: context)
        for account in [everyday, household] {
            guard case .reconciled = try reconciliation.reconciliation(for: account) else {
                return XCTFail("\(account.name) should reconcile exactly after an adjustment")
            }
        }
    }

    func testReconciliationStaysReconciledAcrossAMixedSequence() throws {
        let context = try makeContext()
        let account = try makeAccount(context, name: "Everyday")

        try service(context, day: 11).deposit(into: account, amount: TestSupport.money("200.00"))
        try service(context, day: 12).adjustBalance(of: account, by: TestSupport.money("-50.00"))
        try service(context, day: 13).adjustBalance(of: account, to: TestSupport.money("1234.56"))
        try service(context, day: 14).adjustBalance(of: account, by: TestSupport.money("10.00"))

        XCTAssertEqual(account.currentBalance, TestSupport.money("1244.56"))
        guard case .reconciled = try AccountReconciliationService(context: context)
            .reconciliation(for: account) else {
            return XCTFail("the mixed sequence must still reconcile exactly")
        }
    }

    // MARK: - Effective dates

    func testBackdatedAdjustmentRespectsTheEffectiveDate() throws {
        let context = try makeContext()
        let account = try makeAccount(context, name: "Everyday")
        let backdate = TestSupport.date(2054, 7, 1)

        let result = try service(context, day: 12).adjustBalance(
            of: account, by: TestSupport.money("-25.00"), effectiveDate: backdate
        )

        XCTAssertEqual(try XCTUnwrap(result.entry).effectiveDate, backdate)
        XCTAssertEqual(result.snapshot.effectiveDate, backdate)
        XCTAssertEqual(account.currentBalance, TestSupport.money("975.00"))

        // The dashboard derivation agrees with the stored running balance.
        let states = try AccountBalanceService(context: context, dateProvider: TestSupport.fixedToday)
            .namedAccountStates(plan: nil, planItems: [])
        XCTAssertEqual(states.first { $0.account.id == account.id }?.balance,
                       TestSupport.money("975.00"))
    }

    func testFutureDatedAdjustmentIsAllowedAndDated() throws {
        let context = try makeContext()
        let account = try makeAccount(context, name: "Everyday")
        let future = TestSupport.date(2054, 9, 1)

        let result = try service(context, day: 12).adjustBalance(
            of: account, by: TestSupport.money("40.00"), effectiveDate: future
        )

        XCTAssertEqual(try XCTUnwrap(result.entry).effectiveDate, future)
        XCTAssertEqual(result.snapshot.effectiveDate, future)
        XCTAssertEqual(account.currentBalance, TestSupport.money("1040.00"))
    }

    func testNoteIsOptionalOnBothTypes() throws {
        let context = try makeContext()
        let account = try makeAccount(context, name: "Everyday")
        let ledger = service(context, day: 12)

        let without = try ledger.adjustBalance(of: account, by: TestSupport.money("5.00"))
        XCTAssertNil(try XCTUnwrap(without.entry).note)

        let with = try ledger.adjustBalance(of: account, to: TestSupport.money("2000.00"), note: "statement check")
        XCTAssertEqual(try XCTUnwrap(with.entry).note, "statement check")
    }

    func testConfirmingAnUnchangedBalanceOnANamedAccountWritesSnapshotOnly() throws {
        let context = try makeContext()
        let account = try makeAccount(context, name: "Household")

        let result = try service(context, day: 12).adjustBalance(
            of: account, to: TestSupport.money("1000.00")
        )

        XCTAssertNil(result.entry)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BalanceSnapshot>()), 1)
    }

    func testGenericAdjustmentTouchesOnlyTheSelectedAccount() throws {
        let context = try makeContext()
        let everyday = try makeAccount(context, name: "Everyday")
        let household = try makeAccount(context, name: "Household", balance: "500.00", roles: [.spending])
        let reserve = try makeAccount(context, name: "Reserve", balance: "400.00", roles: [.reserves])
        let ledger = service(context, day: 12)

        try ledger.adjustBalance(of: household, by: TestSupport.money("-100.00"))

        XCTAssertEqual(everyday.currentBalance, TestSupport.money("1000.00"))
        XCTAssertEqual(household.currentBalance, TestSupport.money("400.00"))
        XCTAssertEqual(reserve.currentBalance, TestSupport.money("400.00"))
        XCTAssertTrue(try ledger.activity(for: everyday).isEmpty)
        XCTAssertTrue(try ledger.activity(for: reserve).isEmpty)
        XCTAssertEqual(try ledger.activity(for: household).count, 1)
    }

    // MARK: - Legacy rows: readable, derivable, never mutated

    /// Every raw value old stores and backups can hold, pinned. Renaming any
    /// of these silently corrupts history (unknown raws decode as
    /// `.correction`), so a failure here is a schema break, not a style nit.
    func testEveryLegacyTypeRawStillDecodesToItsCase() {
        let pinned: [(String, LedgerEntryType)] = [
            ("cardPayment", .cardPayment),
            ("c1BufferAddition", .c1BufferAddition),
            ("c1Spending", .c1Spending),
            ("c1BalanceAdjustment", .c1BalanceAdjustment),
            ("c2Transfer", .c2Transfer),
            ("carReserveContribution", .carReserveContribution),
            ("carReserveUse", .carReserveUse),
            ("trainReserveContribution", .trainReserveContribution),
            ("trainReserveUse", .trainReserveUse),
            ("windfall", .windfall),
            ("refundReversal", .refundReversal),
            ("correction", .correction),
            ("accountDeposit", .accountDeposit),
            ("accountWithdrawal", .accountWithdrawal),
            ("accountTransfer", .accountTransfer),
            ("accountAdjustment", .accountAdjustment),
        ]
        XCTAssertEqual(pinned.count, LedgerEntryType.allCases.count,
                       "every case is pinned; additions must extend this list")
        for (raw, expected) in pinned {
            XCTAssertEqual(LedgerEntryType(rawValue: raw), expected)
            XCTAssertFalse(expected.displayName.isEmpty, "\(raw) must stay renderable")
        }
    }

    /// One row of every legacy shape a migrated store can hold.
    private func insertLegacyRows(_ context: ModelContext) throws -> [LedgerEntry] {
        let rows: [LedgerEntry] = [
            LedgerEntry(effectiveDate: TestSupport.date(2054, 6, 1), type: .cardPayment,
                        amount: TestSupport.money("120.00"), sourceAccount: .checking2,
                        destinationAccount: .card, debtPlanID: "B"),
            LedgerEntry(effectiveDate: TestSupport.date(2054, 6, 2), type: .c1BufferAddition,
                        amount: TestSupport.money("80.00"), sourceAccount: .external,
                        destinationAccount: .checking1),
            LedgerEntry(effectiveDate: TestSupport.date(2054, 6, 3), type: .c1Spending,
                        amount: TestSupport.money("15.50"), sourceAccount: .checking1,
                        destinationAccount: .external),
            LedgerEntry(effectiveDate: TestSupport.date(2054, 6, 4), type: .c1BalanceAdjustment,
                        amount: TestSupport.money("-20.00"), destinationAccount: .checking1,
                        auditNote: "legacy manual adjustment"),
            LedgerEntry(effectiveDate: TestSupport.date(2054, 6, 5), type: .c2Transfer,
                        amount: TestSupport.money("500.00"), sourceAccount: .checking1,
                        destinationAccount: .checking2),
            LedgerEntry(effectiveDate: TestSupport.date(2054, 6, 6), type: .carReserveContribution,
                        amount: TestSupport.money("100.00"), sourceAccount: .checking2,
                        destinationAccount: .checking2),
            LedgerEntry(effectiveDate: TestSupport.date(2054, 6, 7), type: .carReserveUse,
                        amount: TestSupport.money("40.00"), sourceAccount: .checking2,
                        destinationAccount: .external),
            LedgerEntry(effectiveDate: TestSupport.date(2054, 6, 8), type: .trainReserveContribution,
                        amount: TestSupport.money("60.00"), sourceAccount: .checking2,
                        destinationAccount: .checking2),
            LedgerEntry(effectiveDate: TestSupport.date(2054, 6, 9), type: .trainReserveUse,
                        amount: TestSupport.money("25.00"), sourceAccount: .checking2,
                        destinationAccount: .external),
            LedgerEntry(effectiveDate: TestSupport.date(2054, 6, 10), type: .windfall,
                        amount: TestSupport.money("300.00"), sourceAccount: .external,
                        destinationAccount: .checking2, note: "legacy windfall"),
            LedgerEntry(effectiveDate: TestSupport.date(2054, 6, 11), type: .refundReversal,
                        amount: TestSupport.money("30.00"), sourceAccount: .external,
                        destinationAccount: .card, debtPlanID: "B", auditNote: "legacy refund"),
            LedgerEntry(effectiveDate: TestSupport.date(2054, 6, 12), type: .correction,
                        amount: TestSupport.money("-5.00"), sourceAccount: .external,
                        destinationAccount: .checking1, isCorrection: true,
                        auditNote: "legacy correction"),
        ]
        for row in rows { context.insert(row) }
        try context.save()
        return rows
    }

    /// Every persisted property of a row, so the comparison is
    /// byte-for-byte in effect, not a spot check.
    private func fingerprint(_ entry: LedgerEntry) -> [String?] {
        [
            entry.id.uuidString,
            entry.effectiveDate.timeIntervalSinceReferenceDate.description,
            entry.createdAt.timeIntervalSinceReferenceDate.description,
            entry.updatedAt.timeIntervalSinceReferenceDate.description,
            entry.typeRaw,
            entry.amount.description,
            entry.sourceAccountRaw,
            entry.destinationAccountRaw,
            entry.debtAccountID?.uuidString,
            entry.debtPlanID,
            entry.paydayCheckInID?.uuidString,
            entry.note,
            entry.isCorrection.description,
            entry.correctsEntryID?.uuidString,
            entry.auditNote,
            entry.sourceAccountID?.uuidString,
            entry.destinationAccountID?.uuidString,
            entry.provenanceRaw,
        ]
    }

    /// V4-06 acceptance: after the generic flow runs, a migrated fixture's
    /// legacy rows are byte-identical — nothing edited, retyped, backfilled,
    /// or deleted.
    func testLegacyRowsAreByteIdenticalAfterGenericAdjustments() throws {
        let context = try makeContext()
        let legacy = try insertLegacyRows(context)
        let before = legacy.map(fingerprint)

        let account = try makeAccount(context, name: "Everyday")
        let ledger = service(context, day: 12)
        try ledger.adjustBalance(of: account, by: TestSupport.money("-12.34"))
        try ledger.adjustBalance(of: account, to: TestSupport.money("1500.00"))

        let after = legacy.map(fingerprint)
        XCTAssertEqual(before, after, "legacy rows must never be mutated by the generic flow")
        for row in legacy {
            XCTAssertNil(row.provenanceRaw, "provenance is never backfilled")
            XCTAssertFalse(row.isDeleted)
            XCTAssertFalse(row.type.displayName.isEmpty, "legacy rows must stay renderable")
        }
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<LedgerEntry>()),
            legacy.count + 2,
            "the flow appends its own rows and touches nothing else"
        )
    }

    /// The legacy raw-based derivations and the new account-ID-based rows
    /// never see each other, so nothing is double-counted in either
    /// direction.
    func testLegacyDerivationsAreUnaffectedByGenericAdjustments() throws {
        let context = try makeContext()
        try insertLegacyRows(context)
        let balances = AccountBalanceService(context: context, dateProvider: TestSupport.fixedToday)
        let beforeState = try balances.checking2State()

        let account = try makeAccount(context, name: "Everyday")
        let result = try service(context, day: 12).adjustBalance(
            of: account, by: TestSupport.money("999.99")
        )

        let afterState = try balances.checking2State()
        XCTAssertEqual(afterState.totalBalance, beforeState.totalBalance)
        XCTAssertEqual(afterState.carReserved, beforeState.carReserved)
        XCTAssertEqual(afterState.trainReserved, beforeState.trainReserved)
        XCTAssertEqual(afterState.availableForDebt, beforeState.availableForDebt)

        // The new row carries no legacy raws, so it is invisible to the
        // raw-based derivations — and the legacy rows carry no account IDs,
        // so they are invisible to the account-scoped ones.
        let entry = try XCTUnwrap(result.entry)
        XCTAssertNil(entry.sourceAccountRaw)
        XCTAssertNil(entry.destinationAccountRaw)
    }

    // MARK: - Swept legacy labels

    func testWindfallLabelsDeriveFromAccountRolesAndNames() throws {
        let context = try makeContext()
        try makeAccount(context, name: "Everyday")
        try makeAccount(context, name: "Reserve", roles: [.reserves])
        let accounts = try CashAccountRepository(context: context).activeAccounts()

        let labels = LegacyCheckingLabels.windfallLabels(in: accounts)
        XCTAssertEqual(labels.debt, "Apply to debt (Reserve)")
        XCTAssertEqual(labels.keep, "Keep in Everyday")
    }

    func testWindfallLabelsFallBackToLegacyWordingWithoutAccounts() {
        let labels = LegacyCheckingLabels.windfallLabels(in: [])
        XCTAssertEqual(labels.debt, "Apply to debt (Checking 2)")
        XCTAssertEqual(labels.keep, "Keep in Checking 1")
    }

    func testWindfallLabelsCollapseWhenOneAccountHoldsEveryRole() throws {
        let context = try makeContext()
        try makeAccount(context, name: "Everything", roles: [.income, .spending, .reserves])
        let accounts = try CashAccountRepository(context: context).activeAccounts()

        let labels = LegacyCheckingLabels.windfallLabels(in: accounts)
        XCTAssertEqual(labels.debt, "Apply to debt")
        XCTAssertEqual(labels.keep, "Keep in Everything")
    }

    func testWindfallLabelsIgnoreArchivedAccounts() throws {
        let context = try makeContext()
        try makeAccount(context, name: "Everyday")
        let reserve = try makeAccount(context, name: "Reserve", roles: [.reserves])
        try CashAccountRepository(context: context).archive(reserve)

        let all = try context.fetch(FetchDescriptor<CashAccount>())
        let labels = LegacyCheckingLabels.windfallLabels(in: all)
        XCTAssertEqual(labels.debt, "Apply to debt")
        XCTAssertEqual(labels.keep, "Keep in Everyday")
    }

    /// The founding install's migrated accounts are literally named
    /// "Checking 1" and "Checking 2", so the derived labels reproduce the
    /// legacy wording there without any special case.
    func testMigratedFoundingAccountsReproduceTheLegacyWording() throws {
        let context = try makeContext()
        try makeAccount(context, name: "Checking 1")
        try makeAccount(context, name: "Checking 2", roles: [.reserves])
        let accounts = try CashAccountRepository(context: context).activeAccounts()

        let labels = LegacyCheckingLabels.windfallLabels(in: accounts)
        XCTAssertEqual(labels.debt, "Apply to debt (Checking 2)")
        XCTAssertEqual(labels.keep, "Keep in Checking 1")
    }

    func testTargetLabelsStayDistinguishable() throws {
        let context = try makeContext()
        try makeAccount(context, name: "Everyday")
        try makeAccount(context, name: "Reserve", roles: [.reserves])
        let accounts = try CashAccountRepository(context: context).activeAccounts()
        let distinct = LegacyCheckingLabels.targetLabels(in: accounts)
        XCTAssertEqual(distinct.checking1, "Everyday")
        XCTAssertEqual(distinct.checking2, "Reserve")

        let soloContext = try makeContext()
        try makeAccount(soloContext, name: "Solo", roles: [.income, .spending, .reserves])
        let solo = try CashAccountRepository(context: soloContext).activeAccounts()
        let collapsed = LegacyCheckingLabels.targetLabels(in: solo)
        XCTAssertEqual(collapsed.checking1, "Solo")
        XCTAssertEqual(collapsed.checking2, "Solo (reserves)")
    }

    // MARK: - The Note entry is unaffected

    /// Notes persist as zero-amount `c1BalanceAdjustment` rows (soul.md
    /// amendment 6 keeps that path). They are not cash-account movements and
    /// have no signed effect on any account, so the generic flow cannot
    /// double-count them.
    func testZeroAmountNoteRowShapeIsUnchanged() throws {
        let context = try makeContext()
        let account = try makeAccount(context, name: "Everyday")
        let note = LedgerEntry(
            effectiveDate: TestSupport.date(2054, 8, 12),
            type: .c1BalanceAdjustment,
            amount: .zero,
            destinationAccount: .checking1,
            note: "remember the thing"
        )
        context.insert(note)
        try context.save()

        XCTAssertEqual(note.typeRaw, "c1BalanceAdjustment")
        XCTAssertFalse(note.type.isCashAccountMovement)
        XCTAssertEqual(CashLedgerService.signedAmount(of: note, for: account.id), .zero)
        XCTAssertTrue(try service(context, day: 12).activity(for: account).isEmpty)
    }
}
