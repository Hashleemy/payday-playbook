import XCTest
import SwiftData
@testable import PaydayPlaybook

/// T-19 (V4-02): setup inputs are canonical and derivations follow them.
///
/// The invalidation key is `SetupInputFingerprint` — row IDs plus their
/// last-edit stamps across every input family — so a content edit that keeps
/// row counts equal still invalidates, and the Review step's commit guard
/// (`OnboardingProgressService.finish(verifying:)`) makes persisting a plan
/// preview whose inputs have since changed impossible at the service
/// boundary, not by view-tree accident.
///
/// All values are fictional (V3-12).
final class ReactiveSetupTests: XCTestCase {

    /// A complete, generatable setup: one account, profile, biweekly income,
    /// one bill, two cards and a loan — enough for order and totals to have
    /// something to react with.
    private func makeCompleteSetup() throws -> (ModelContainer, ModelContext) {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let day0 = TestSupport.date(2054, 8, 1)
        try CashAccountRepository(context: context).create(
            name: "Everyday", currentBalance: TestSupport.money("1100.00"),
            roles: [.income, .spending], now: day0
        )
        try GoalProfileRepository(context: context).save(
            goalText: "Debt-free before the move", targetDebtFreeDate: nil,
            posture: .steady,
            protectedFloor: TestSupport.money("500.00"),
            allowanceCap: TestSupport.money("200.00"),
            now: day0
        )
        try IncomeRepository(context: context).save(
            cadence: .biweekly, anchorPayday: TestSupport.date(2054, 9, 4),
            takeHome: TestSupport.money("2100.00"), monthlyDay: nil,
            semimonthlyFirstDay: nil, semimonthlySecondDay: nil,
            destinationAccountID: nil, now: day0
        )
        try ObligationRepository(context: context).create(
            name: "Rent", amount: TestSupport.money("1300.00"),
            cadence: .monthly, dueDay: 1, now: day0
        )
        let debts = DebtRepository(context: context)
        try debts.create(
            type: .creditCard, displayName: "Card Alpha",
            currentBalance: TestSupport.money("2600.00"), apr: TestSupport.money("0.1799"),
            minimumAmount: TestSupport.money("60.00"),
            creditLimit: TestSupport.money("5000.00"), dueDayOfMonth: 5, now: day0
        )
        try debts.create(
            type: .creditCard, displayName: "Card Beta",
            currentBalance: TestSupport.money("900.00"), apr: TestSupport.money("0.2499"),
            minimumAmount: TestSupport.money("35.00"),
            creditLimit: TestSupport.money("2000.00"), dueDayOfMonth: 17, now: day0
        )
        try debts.create(
            type: .autoLoan, displayName: "Auto Loan",
            currentBalance: TestSupport.money("6400.00"), apr: TestSupport.money("0.0649"),
            minimumAmount: TestSupport.money("310.00"),
            originalPrincipal: TestSupport.money("11000.00"), dueDayOfMonth: 20, now: day0
        )
        return (container, context)
    }

    private func fingerprint(_ context: ModelContext) throws -> SetupInputFingerprint {
        try SetupInputFingerprint.capture(context: context)
    }

    private func debt(named name: String, in context: ModelContext) throws -> DebtAccount {
        try XCTUnwrap(
            context.fetch(FetchDescriptor<DebtAccount>()).first { $0.displayName == name }
        )
    }

    // MARK: - The fingerprint is a content key

    func testFingerprintIsStableWhenNothingChanges() throws {
        let (container, context) = try makeCompleteSetup()
        let first = try fingerprint(context)
        XCTAssertEqual(first, try fingerprint(context))
        // And across a relaunch-style fresh context on the same store.
        XCTAssertEqual(first, try fingerprint(ModelContext(container)))
    }

    func testEveryInputFamilyEditChangesTheFingerprint() throws {
        let (_, context) = try makeCompleteSetup()
        var last = try fingerprint(context)
        var day = 2

        func assertChanged(_ what: String, _ mutate: () throws -> Void) throws {
            try mutate()
            let now = try fingerprint(context)
            XCTAssertNotEqual(now, last, "\(what) must change the fingerprint")
            last = now
        }
        // Repository edits stamp `updatedAt = now`; each edit uses a fresh
        // moment the way live edits do.
        func nextMoment() -> Date {
            day += 1
            return TestSupport.date(2054, 8, day)
        }

        try assertChanged("editing the goal profile") {
            try GoalProfileRepository(context: context).save(
                goalText: "Debt-free before the move", targetDebtFreeDate: nil,
                posture: .steady,
                protectedFloor: TestSupport.money("650.00"),
                allowanceCap: TestSupport.money("200.00"),
                now: nextMoment()
            )
        }
        try assertChanged("editing an account balance") {
            let repository = CashAccountRepository(context: context)
            let account = try XCTUnwrap(repository.activeAccounts().first)
            try repository.update(
                account, currentBalance: TestSupport.money("1300.00"), now: nextMoment()
            )
        }
        try assertChanged("editing income") {
            try IncomeRepository(context: context).save(
                cadence: .biweekly, anchorPayday: TestSupport.date(2054, 9, 11),
                takeHome: TestSupport.money("2100.00"), monthlyDay: nil,
                semimonthlyFirstDay: nil, semimonthlySecondDay: nil,
                destinationAccountID: nil, now: nextMoment()
            )
        }
        try assertChanged("adding a future income change") {
            let repository = IncomeRepository(context: context)
            let schedule = try XCTUnwrap(repository.activeSchedule())
            try repository.addChange(
                to: schedule, effectiveDate: TestSupport.date(2054, 11, 6),
                newTakeHome: TestSupport.money("2250.00"), now: nextMoment()
            )
        }
        try assertChanged("editing a bill amount") {
            let repository = ObligationRepository(context: context)
            let bill = try XCTUnwrap(repository.activeObligations().first)
            try repository.update(
                bill, name: bill.name, amount: TestSupport.money("1350.00"),
                cadence: bill.cadence, dueDay: bill.dueDay, accountID: bill.accountID,
                isEssential: bill.isEssential, now: nextMoment()
            )
        }
        try assertChanged("editing a debt balance") {
            let card = try debt(named: "Card Alpha", in: context)
            try DebtRepository(context: context).update(
                card, type: card.debtType, displayName: card.displayName,
                currentBalance: TestSupport.money("2350.00"), apr: card.apr,
                minimumAmount: card.minimumAmount, originalPrincipal: card.originalPrincipal,
                creditLimit: card.creditLimit, dueDayOfMonth: card.dueDayOfMonth,
                prepayment: card.prepayment, note: card.setupNote, now: nextMoment()
            )
        }
        try assertChanged("archiving a debt") {
            let card = try debt(named: "Card Beta", in: context)
            try DebtRepository(context: context).archive(card, now: nextMoment())
        }
        try assertChanged("deleting a bill") {
            let repository = ObligationRepository(context: context)
            try repository.delete(try XCTUnwrap(repository.activeObligations().first))
        }
        try assertChanged("adding a debt") {
            try DebtRepository(context: context).create(
                type: .medicalDebt, displayName: "Clinic Bill",
                currentBalance: TestSupport.money("400.00"), apr: .zero,
                minimumAmount: TestSupport.money("50.00"), now: nextMoment()
            )
        }
    }

    /// The count-keyed-observer regression: an edit that keeps every row
    /// count identical still changes the key, and the derived Bills & Debts
    /// state rebuilt from the store reflects it.
    func testSameCountEditInvalidatesAndReloadsTheDerivedState() throws {
        let (_, context) = try makeCompleteSetup()
        let before = try fingerprint(context)
        let stateBefore = try BillsAndDebtsLoader(context: context).load()

        let card = try debt(named: "Card Alpha", in: context)
        try DebtRepository(context: context).update(
            card, type: card.debtType, displayName: card.displayName,
            currentBalance: TestSupport.money("3100.00"), apr: card.apr,
            minimumAmount: card.minimumAmount, originalPrincipal: card.originalPrincipal,
            creditLimit: card.creditLimit, dueDayOfMonth: card.dueDayOfMonth,
            prepayment: card.prepayment, note: card.setupNote,
            now: TestSupport.date(2054, 8, 2)
        )

        XCTAssertNotEqual(try fingerprint(context), before)
        let stateAfter = try BillsAndDebtsLoader(context: context).load()
        XCTAssertEqual(stateAfter.debts.count, stateBefore.debts.count, "Same row count by design")
        XCTAssertNotEqual(stateAfter.debtPrincipalTotal, stateBefore.debtPrincipalTotal)
        XCTAssertEqual(
            stateAfter.debtPrincipalTotal - stateBefore.debtPrincipalTotal,
            TestSupport.money("500.00")
        )
    }

    /// A pay-cadence edit reaches the reserve smoothing (income is an input
    /// of the Bills & Debts preview even though it lives on another step).
    func testCadenceEditReachesTheReservePreview() throws {
        let (_, context) = try makeCompleteSetup()
        let biweekly = try BillsAndDebtsLoader(context: context).load()
        XCTAssertEqual(biweekly.payCadence, .biweekly)

        try IncomeRepository(context: context).save(
            cadence: .monthly, anchorPayday: TestSupport.date(2054, 9, 1),
            takeHome: TestSupport.money("4200.00"), monthlyDay: 1,
            semimonthlyFirstDay: nil, semimonthlySecondDay: nil,
            destinationAccountID: nil, now: TestSupport.date(2054, 8, 2)
        )

        let monthly = try BillsAndDebtsLoader(context: context).load()
        XCTAssertEqual(monthly.payCadence, .monthly)
        // R-04: $1300 monthly ≈ $600.00 per biweekly check, $1300.00 monthly.
        XCTAssertEqual(biweekly.billReservePerPaycheck, TestSupport.money("600.00"))
        XCTAssertEqual(monthly.billReservePerPaycheck, TestSupport.money("1300.00"))
    }

    // MARK: - Commit-staleness guard

    func testCommitRefusesAPreviewWhoseInputsChanged() throws {
        let (_, context) = try makeCompleteSetup()
        let captured = try fingerprint(context)
        let preview = try PlanGenerationService.generate(
            context: context, asOf: TestSupport.date(2054, 8, 10)
        )

        // The user goes back and corrects a balance after Generate.
        let card = try debt(named: "Card Alpha", in: context)
        try DebtRepository(context: context).update(
            card, type: card.debtType, displayName: card.displayName,
            currentBalance: TestSupport.money("1900.00"), apr: card.apr,
            minimumAmount: card.minimumAmount, originalPrincipal: card.originalPrincipal,
            creditLimit: card.creditLimit, dueDayOfMonth: card.dueDayOfMonth,
            prepayment: card.prepayment, note: card.setupNote,
            now: TestSupport.date(2054, 8, 11)
        )

        let service = OnboardingProgressService(
            context: context, dateProvider: TestSupport.fixedToday
        )
        XCTAssertThrowsError(try service.finish(
            planName: PlanContract.generatedPlanName,
            input: preview.input, result: preview.rows,
            verifying: captured
        )) { error in
            XCTAssertEqual(error as? OnboardingProgressService.FinishError, .staleInputs)
        }

        // The stale preview persisted nothing at all.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PaydayPlanItem>()), 0)
        let progress = try context.fetch(FetchDescriptor<OnboardingProgress>()).first
        XCTAssertNil(progress?.completedAt)
    }

    func testCommitSucceedsWhenInputsAreUnchanged() throws {
        let (_, context) = try makeCompleteSetup()
        let captured = try fingerprint(context)
        let preview = try PlanGenerationService.generate(
            context: context, asOf: TestSupport.date(2054, 8, 10)
        )

        let plan = try OnboardingProgressService(
            context: context, dateProvider: TestSupport.fixedToday
        ).finish(
            planName: PlanContract.generatedPlanName,
            input: preview.input, result: preview.rows,
            verifying: captured
        )
        XCTAssertTrue(plan.isActive)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), 1)
    }

    // MARK: - Back, edit, forward: the regenerated preview follows the store

    func testRegeneratedPreviewDerivesFromTheEditedBalance() throws {
        let (_, context) = try makeCompleteSetup()
        let asOf = TestSupport.date(2054, 8, 10)
        let before = try PlanGenerationService.generate(context: context, asOf: asOf)

        let card = try debt(named: "Card Alpha", in: context)
        try DebtRepository(context: context).update(
            card, type: card.debtType, displayName: card.displayName,
            currentBalance: TestSupport.money("1600.00"), apr: card.apr,
            minimumAmount: card.minimumAmount, originalPrincipal: card.originalPrincipal,
            creditLimit: card.creditLimit, dueDayOfMonth: card.dueDayOfMonth,
            prepayment: card.prepayment, note: card.setupNote,
            now: TestSupport.date(2054, 8, 11)
        )
        let after = try PlanGenerationService.generate(context: context, asOf: asOf)

        let cardID = card.id
        XCTAssertEqual(
            after.input.debts.first { $0.id == cardID }?.currentBalance,
            TestSupport.money("1600.00")
        )
        XCTAssertNotEqual(
            before.rows.totalEstimatedInterest, after.rows.totalEstimatedInterest,
            "A $1000 lower revolving balance changes the projected interest"
        )
        XCTAssertLessThanOrEqual(after.rows.paycheckCount, before.rows.paycheckCount)
        // And the fresh fingerprint commits cleanly — the guard only ever
        // refuses previews older than the store.
        let plan = try OnboardingProgressService(
            context: context, dateProvider: TestSupport.fixedToday
        ).finish(
            planName: PlanContract.generatedPlanName,
            input: after.input, result: after.rows,
            verifying: try fingerprint(context)
        )
        XCTAssertEqual(
            try PlanningSnapshotCoder.decode(XCTUnwrap(plan.inputSnapshotData)),
            after.input
        )
    }

    func testAPRChangeRetargetsTheAttackOrder() throws {
        let (_, context) = try makeCompleteSetup()
        let asOf = TestSupport.date(2054, 8, 10)
        let alpha = try debt(named: "Card Alpha", in: context)
        let beta = try debt(named: "Card Beta", in: context)

        let before = try PlanGenerationService.generate(context: context, asOf: asOf)
        XCTAssertEqual(
            before.result.paychecks.first?.targetDebtID, beta.id,
            "Card Beta's 24.99% APR leads the avalanche at first"
        )

        // Back to the debts step: Card Alpha's promo ended at 29.99%.
        try DebtRepository(context: context).update(
            alpha, type: alpha.debtType, displayName: alpha.displayName,
            currentBalance: alpha.startingBalance, apr: TestSupport.money("0.2999"),
            minimumAmount: alpha.minimumAmount, originalPrincipal: alpha.originalPrincipal,
            creditLimit: alpha.creditLimit, dueDayOfMonth: alpha.dueDayOfMonth,
            prepayment: alpha.prepayment, note: alpha.setupNote,
            now: TestSupport.date(2054, 8, 11)
        )
        let after = try PlanGenerationService.generate(context: context, asOf: asOf)
        XCTAssertEqual(
            after.result.paychecks.first?.targetDebtID, alpha.id,
            "The regenerated preview attacks the new highest APR first"
        )
        XCTAssertNotEqual(before.rows.totalEstimatedInterest, after.rows.totalEstimatedInterest)
        XCTAssertNotEqual(before.result.payoffOrder, after.result.payoffOrder)
    }

    func testIncomeEditMovesTheFuturePaydays() throws {
        let (_, context) = try makeCompleteSetup()
        let asOf = TestSupport.date(2054, 8, 10)
        let repository = IncomeRepository(context: context)

        let before = try PlanGenerationService.generate(context: context, asOf: asOf)
        let scheduleBefore = try XCTUnwrap(repository.activeSchedule())
        let previewBefore = RemindersStepView.upcomingPaydays(for: scheduleBefore)
        XCTAssertEqual(previewBefore.first, TestSupport.date(2054, 9, 4))
        XCTAssertEqual(before.rows.paydays.first?.date, TestSupport.date(2054, 9, 4))
        XCTAssertEqual(before.rows.paydays.first?.income, TestSupport.money("2100.00"))

        // Back to the income step: new anchor, new amount.
        try repository.save(
            cadence: .biweekly, anchorPayday: TestSupport.date(2054, 9, 11),
            takeHome: TestSupport.money("2300.00"), monthlyDay: nil,
            semimonthlyFirstDay: nil, semimonthlySecondDay: nil,
            destinationAccountID: nil, now: TestSupport.date(2054, 8, 11)
        )
        let after = try PlanGenerationService.generate(context: context, asOf: asOf)
        let scheduleAfter = try XCTUnwrap(repository.activeSchedule())
        let previewAfter = RemindersStepView.upcomingPaydays(for: scheduleAfter)

        XCTAssertEqual(previewAfter.first, TestSupport.date(2054, 9, 11))
        XCTAssertEqual(after.rows.paydays.first?.date, TestSupport.date(2054, 9, 11))
        XCTAssertEqual(after.rows.paydays.first?.income, TestSupport.money("2300.00"))
        XCTAssertNotEqual(previewBefore, previewAfter)
    }

    func testDueDayEditReachesTheRegeneratedPlanInput() throws {
        let (_, context) = try makeCompleteSetup()
        let asOf = TestSupport.date(2054, 8, 10)
        let card = try debt(named: "Card Beta", in: context)
        let cardID = card.id
        let before = try fingerprint(context)

        try DebtRepository(context: context).update(
            card, type: card.debtType, displayName: card.displayName,
            currentBalance: card.startingBalance, apr: card.apr,
            minimumAmount: card.minimumAmount, originalPrincipal: card.originalPrincipal,
            creditLimit: card.creditLimit, dueDayOfMonth: 28,
            prepayment: card.prepayment, note: card.setupNote,
            now: TestSupport.date(2054, 8, 11)
        )

        XCTAssertNotEqual(try fingerprint(context), before)
        let regenerated = try PlanGenerationService.generate(context: context, asOf: asOf)
        XCTAssertEqual(
            regenerated.input.debts.first { $0.id == cardID }?.dueDayOfMonth, 28,
            "The regenerated snapshot carries the edited due day downstream"
        )
    }

    // MARK: - Previews are write-free; navigation persists nothing

    func testPreviewNavigationPersistsNoPlanAndTouchesNoInput() throws {
        let (_, context) = try makeCompleteSetup()
        let before = try fingerprint(context)

        // Generate, "go back and forward", generate again — the preview path
        // is pure, so nothing lands in the store and no input is touched.
        _ = try PlanGenerationService.generate(context: context, asOf: TestSupport.date(2054, 8, 10))
        _ = try PlanGenerationService.generate(context: context, asOf: TestSupport.date(2054, 8, 10))

        XCTAssertEqual(try fingerprint(context), before, "Previewing never mutates an input")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PaydayPlanItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Milestone>()), 0)
    }

    /// Repeated previews plus one commit yield exactly one plan version —
    /// preview navigation can never mint extras (idempotent finish is pinned
    /// separately in OnboardingProgressTests).
    func testManyPreviewsOneCommitOnePlanVersion() throws {
        let (_, context) = try makeCompleteSetup()
        for _ in 0..<3 {
            _ = try PlanGenerationService.generate(context: context, asOf: TestSupport.date(2054, 8, 10))
        }
        let final = try PlanGenerationService.generate(context: context, asOf: TestSupport.date(2054, 8, 10))
        try OnboardingProgressService(context: context, dateProvider: TestSupport.fixedToday).finish(
            planName: PlanContract.generatedPlanName,
            input: final.input, result: final.rows,
            verifying: try fingerprint(context)
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), 1)
    }
}
