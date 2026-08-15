import XCTest
import SwiftData
@testable import PaydayPlaybook

/// The setup layer behind the onboarding screens: the repositories each step
/// writes through, resume at every step boundary, validation and boundary
/// values, and the completeness rules that drive the review list and the
/// upgrade checklist.
final class OnboardingSetupTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        ModelContext(try TestSupport.makeContainer())
    }

    // MARK: - Resume at every step boundary (V2-01)

    func testResumeLandsOnTheRightStepAfterEveryBoundary() throws {
        let container = try TestSupport.makeContainer()
        let expectedResume: [(completed: OnboardingStep, resume: OnboardingStep)] = [
            (.welcome, .goals),
            (.goals, .accounts),
            (.accounts, .debts),
            (.debts, .income),
            (.income, .obligations),
            (.obligations, .notifications),
            (.notifications, .review),
            (.review, .finished)
        ]

        for (completed, resume) in expectedResume {
            // Each iteration is a fresh "launch" on the same store.
            let service = OnboardingProgressService(
                context: ModelContext(container), dateProvider: TestSupport.fixedToday
            )
            try service.markStepCompleted(completed)

            let relaunched = OnboardingProgressService(
                context: ModelContext(container), dateProvider: TestSupport.fixedToday
            )
            XCTAssertEqual(
                try relaunched.resumeStep(), resume,
                "After completing \(completed.rawValue) the flow must resume at \(resume.rawValue)"
            )
        }
    }

    func testStepOrderMatchesTheMissionFlow() {
        XCTAssertEqual(
            OnboardingStep.userFacing,
            [.welcome, .goals, .accounts, .debts, .income, .obligations, .notifications, .review]
        )
        XCTAssertEqual(OnboardingStep.welcome.displayIndex, 1)
        XCTAssertEqual(OnboardingStep.review.displayIndex, 8)
        XCTAssertFalse(OnboardingStep.welcome.showsProgress)
        XCTAssertTrue(OnboardingStep.debts.showsProgress)
    }

    /// Answers live in real rows, so a mid-step kill keeps everything the
    /// user had already saved — not just the completed steps.
    func testAnswersSurviveAnInterruptionMidStep() throws {
        let container = try TestSupport.makeContainer()

        // The user fills in goals and two accounts, then the app is killed
        // before the debts step is ever completed.
        let firstLaunch = ModelContext(container)
        try GoalProfileRepository(context: firstLaunch).save(
            goalText: "Debt-free before the wedding",
            targetDebtFreeDate: TestSupport.date(2055, 6, 1),
            posture: .fullThrottle,
            protectedFloor: TestSupport.money("500.00"),
            allowanceCap: TestSupport.money("150.00")
        )
        let accounts = CashAccountRepository(context: firstLaunch)
        try accounts.create(name: "Everyday", currentBalance: TestSupport.money("1700.00"), roles: [.income, .spending])
        try accounts.create(name: "Bills", currentBalance: TestSupport.money("300.00"), roles: [.reserves])
        try OnboardingProgressService(context: firstLaunch, dateProvider: TestSupport.fixedToday)
            .markStepCompleted(.accounts)

        // Relaunch.
        let secondLaunch = ModelContext(container)
        XCTAssertEqual(
            try OnboardingProgressService(context: secondLaunch, dateProvider: TestSupport.fixedToday).resumeStep(),
            .debts
        )
        let profile = try XCTUnwrap(try GoalProfileRepository(context: secondLaunch).profile())
        XCTAssertEqual(profile.goalText, "Debt-free before the wedding")
        XCTAssertEqual(profile.posture, .fullThrottle)
        XCTAssertEqual(profile.protectedFloor, TestSupport.money("500.00"))
        XCTAssertEqual(try CashAccountRepository(context: secondLaunch).activeAccounts().count, 2)
    }

    // MARK: - Multiple accounts and the default-income invariant (V2-03)

    func testMultipleAccountsKeepExactlyOneDefaultIncome() throws {
        let context = try makeContext()
        let repository = CashAccountRepository(context: context)

        let everyday = try repository.create(
            name: "Everyday", currentBalance: TestSupport.money("1500.00"), roles: [.income, .spending]
        )
        XCTAssertTrue(everyday.isDefaultIncome, "The first account takes the income role")

        let bills = try repository.create(
            name: "Bills", currentBalance: .zero, roles: [.reserves]
        )
        let savings = try repository.create(
            name: "Savings", currentBalance: TestSupport.money("50.00"), roles: [.reserves]
        )
        XCTAssertEqual(try repository.activeAccounts().filter(\.isDefaultIncome).count, 1)

        // Moving the default moves it exactly once.
        try repository.setDefaultIncome(bills)
        XCTAssertEqual(try repository.defaultIncomeAccount()?.id, bills.id)
        XCTAssertEqual(try repository.activeAccounts().filter(\.isDefaultIncome).count, 1)

        // Archiving the default hands it to another active account.
        try repository.archive(bills)
        let remainingDefault = try XCTUnwrap(try repository.defaultIncomeAccount())
        XCTAssertNotEqual(remainingDefault.id, bills.id)
        XCTAssertEqual(try repository.activeAccounts().filter(\.isDefaultIncome).count, 1)
        _ = savings
    }

    func testAccountValidationRejectsBlankNamesNegativeBalancesAndNoRoles() throws {
        let context = try makeContext()
        let repository = CashAccountRepository(context: context)

        XCTAssertThrowsError(try repository.create(name: "   ", currentBalance: .zero, roles: [.spending])) {
            XCTAssertEqual($0 as? ModelValidationError, .emptyName)
        }
        XCTAssertThrowsError(
            try repository.create(name: "Checking", currentBalance: TestSupport.money("-5.00"), roles: [.spending])
        ) {
            XCTAssertEqual($0 as? ModelValidationError, .negativeAmount(field: "The balance"))
        }
        XCTAssertThrowsError(try repository.create(name: "Checking", currentBalance: .zero, roles: [])) {
            XCTAssertEqual($0 as? ModelValidationError, .noRoles)
        }
        XCTAssertEqual(try repository.activeAccounts().count, 0, "No invalid row was written")
    }

    // MARK: - Every debt type: add, edit, remove (V2-04, V2-05)

    func testEveryDebtTypeRoundTripsThroughCreateEditAndRemove() throws {
        let context = try makeContext()
        let repository = DebtRepository(context: context)

        for type in DebtType.allCases {
            let debt = try repository.create(
                type: type,
                displayName: "\(type.displayName) account",
                currentBalance: TestSupport.money("1000.00"),
                apr: TestSupport.money("0.1500"),
                // Installment types require an entered minimum; cards may not.
                minimumAmount: type.requiresEnteredMinimum ? TestSupport.money("75.00") : nil,
                originalPrincipal: type == .creditCard ? nil : TestSupport.money("1500.00"),
                creditLimit: type == .creditCard ? TestSupport.money("4000.00") : nil,
                dueDayOfMonth: 12,
                prepayment: .eligible,
                note: "entered in setup"
            )
            XCTAssertEqual(debt.debtType, type)
            XCTAssertNotNil(debt.debtTypeConfirmedAt, "Picking a type counts as confirming it")
            XCTAssertEqual(debt.setupNote, "entered in setup")

            try repository.update(
                debt, type: type, displayName: "Renamed \(type.rawValue)",
                currentBalance: TestSupport.money("1500.00"),
                apr: TestSupport.money("0.1200"),
                minimumAmount: type.requiresEnteredMinimum ? TestSupport.money("80.00") : nil,
                originalPrincipal: type == .creditCard ? nil : TestSupport.money("1500.00"),
                creditLimit: type == .creditCard ? TestSupport.money("4500.00") : nil,
                dueDayOfMonth: 3, prepayment: .eligible, note: nil
            )
            XCTAssertEqual(debt.displayName, "Renamed \(type.rawValue)")
            XCTAssertEqual(debt.startingBalance, TestSupport.money("1500.00"))
            XCTAssertEqual(debt.dueDayOfMonth, 3)
            XCTAssertNil(debt.setupNote)

            try repository.delete(debt)
        }
        XCTAssertEqual(try repository.activeDebts().count, 0)
    }

    func testDebtPlanIDsAreUniqueAndNeverCollideWithTemplateLetters() throws {
        let context = try makeContext()
        let repository = DebtRepository(context: context)
        var ids: Set<String> = []
        for index in 1...5 {
            let debt = try repository.create(
                type: .creditCard, displayName: "Card \(index)",
                currentBalance: TestSupport.money("100.00"), apr: .zero, minimumAmount: nil
            )
            ids.insert(debt.planID)
        }
        XCTAssertEqual(ids.count, 5, "Every generated plan ID is distinct")
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("D") })
        // Legacy 0.1.x plan IDs were bare single letters. Generated IDs are
        // "D"-prefixed and longer, so the two namespaces cannot collide.
        let legacyStyleIDs = Set("ABCDEFGHIJ".map(String.init))
        XCTAssertTrue(ids.isDisjoint(with: legacyStyleIDs))
    }

    func testInstallmentDebtsRequireAnEnteredMinimumAndCardsDoNot() throws {
        let context = try makeContext()
        let repository = DebtRepository(context: context)

        XCTAssertThrowsError(
            try repository.create(
                type: .autoLoan, displayName: "Car", currentBalance: TestSupport.money("9000.00"),
                apr: TestSupport.money("0.0699"), minimumAmount: nil
            )
        ) {
            XCTAssertEqual($0 as? ModelValidationError, .missingMinimum(.autoLoan))
        }

        // A card with no minimum is fine — R-06 estimates it.
        let card = try repository.create(
            type: .creditCard, displayName: "Blue card",
            currentBalance: TestSupport.money("500.00"),
            apr: TestSupport.money("0.2499"), minimumAmount: nil
        )
        XCTAssertNil(card.minimumAmount)
    }

    func testCreditLimitRulesAndUtilization() throws {
        let context = try makeContext()
        let repository = DebtRepository(context: context)

        // A limit on a non-card is refused outright.
        XCTAssertThrowsError(
            try repository.create(
                type: .studentLoan, displayName: "Loan",
                currentBalance: TestSupport.money("5000.00"), apr: TestSupport.money("0.05"),
                minimumAmount: TestSupport.money("100.00"),
                creditLimit: TestSupport.money("1000.00")
            )
        ) {
            XCTAssertEqual($0 as? ModelValidationError, .creditLimitOnNonCard(.studentLoan))
        }

        // A zero limit is refused rather than dividing by zero later.
        XCTAssertThrowsError(
            try repository.create(
                type: .creditCard, displayName: "Zero limit",
                currentBalance: TestSupport.money("100.00"), apr: .zero,
                minimumAmount: nil, creditLimit: .zero
            )
        ) {
            XCTAssertEqual($0 as? ModelValidationError, .zeroOrNegativeAmount(field: "The credit limit"))
        }

        let card = try repository.create(
            type: .creditCard, displayName: "Blue",
            currentBalance: TestSupport.money("2500.00"), apr: TestSupport.money("0.2499"),
            minimumAmount: nil, creditLimit: TestSupport.money("5000.00")
        )
        XCTAssertEqual(card.utilization(currentBalance: card.startingBalance), Decimal(string: "0.5"))
    }

    /// The unknown-limit path: explicitly marked, so the app stops asking and
    /// simply shows no utilization.
    func testUnknownCreditLimitIsMarkedAndSuppressesUtilization() throws {
        let context = try makeContext()
        let card = try DebtRepository(context: context).create(
            type: .creditCard, displayName: "Store card",
            currentBalance: TestSupport.money("400.00"), apr: TestSupport.money("0.2600"),
            minimumAmount: nil, creditLimit: nil, creditLimitMarkedUnknown: true
        )
        XCTAssertNil(card.creditLimit)
        XCTAssertTrue(card.creditLimitMarkedUnknown)
        XCTAssertNil(card.utilization(currentBalance: card.startingBalance))

        // And the checklist stops nagging about it.
        let gaps = try SetupCompletenessService(context: context).gaps()
        XCTAssertFalse(gaps.contains { $0.kind == .creditLimit && $0.subjectID == card.id })
    }

    // MARK: - Income cadences (V2-06)

    func testAllFourCadencesSaveAndReload() throws {
        let context = try makeContext()
        let repository = IncomeRepository(context: context)
        let account = try CashAccountRepository(context: context).create(
            name: "Everyday", currentBalance: .zero, roles: [.income, .spending]
        )

        let cases: [(PayCadence, Int?, Int?, Int?)] = [
            (.weekly, nil, nil, nil),
            (.biweekly, nil, nil, nil),
            (.semimonthly, nil, 1, 15),
            (.monthly, 31, nil, nil)
        ]
        for (cadence, monthlyDay, firstDay, secondDay) in cases {
            let schedule = try repository.save(
                cadence: cadence,
                anchorPayday: TestSupport.date(2054, 9, 4),
                takeHome: TestSupport.money("1500.00"),
                monthlyDay: monthlyDay,
                semimonthlyFirstDay: firstDay,
                semimonthlySecondDay: secondDay,
                destinationAccountID: account.id
            )
            XCTAssertEqual(schedule.cadence, cadence)
            XCTAssertEqual(schedule.monthlyDay, monthlyDay)
            XCTAssertEqual(schedule.semimonthlyFirstDay, firstDay)
            XCTAssertEqual(schedule.semimonthlySecondDay, secondDay)
            // Re-saving edits the one live schedule instead of stacking rows.
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<IncomeSchedule>()), 1)
        }
    }

    func testIncomeValidationCoversBoundaryValues() throws {
        let context = try makeContext()
        let repository = IncomeRepository(context: context)

        XCTAssertThrowsError(try repository.save(
            cadence: .biweekly, anchorPayday: TestSupport.date(2054, 9, 4),
            takeHome: .zero, monthlyDay: nil,
            semimonthlyFirstDay: nil, semimonthlySecondDay: nil, destinationAccountID: nil
        )) {
            XCTAssertEqual($0 as? ModelValidationError, .zeroOrNegativeAmount(field: "The take-home amount"))
        }

        XCTAssertThrowsError(try repository.save(
            cadence: .monthly, anchorPayday: TestSupport.date(2054, 9, 4),
            takeHome: TestSupport.money("1000.00"), monthlyDay: 0,
            semimonthlyFirstDay: nil, semimonthlySecondDay: nil, destinationAccountID: nil
        )) {
            XCTAssertEqual($0 as? ModelValidationError, .invalidDay(0))
        }

        XCTAssertThrowsError(try repository.save(
            cadence: .monthly, anchorPayday: TestSupport.date(2054, 9, 4),
            takeHome: TestSupport.money("1000.00"), monthlyDay: 32,
            semimonthlyFirstDay: nil, semimonthlySecondDay: nil, destinationAccountID: nil
        )) {
            XCTAssertEqual($0 as? ModelValidationError, .invalidDay(32))
        }

        XCTAssertThrowsError(try repository.save(
            cadence: .semimonthly, anchorPayday: TestSupport.date(2054, 9, 4),
            takeHome: TestSupport.money("1000.00"), monthlyDay: nil,
            semimonthlyFirstDay: 15, semimonthlySecondDay: 15, destinationAccountID: nil
        )) {
            XCTAssertEqual($0 as? ModelValidationError, .duplicateSemimonthlyDays)
        }

        // Day 31 is the "last day" sentinel and must be accepted.
        XCTAssertNoThrow(try repository.save(
            cadence: .monthly, anchorPayday: TestSupport.date(2054, 9, 4),
            takeHome: TestSupport.money("0.01"), monthlyDay: 31,
            semimonthlyFirstDay: nil, semimonthlySecondDay: nil, destinationAccountID: nil
        ))
    }

    func testFutureIncomeChangesPersistAndDelete() throws {
        let context = try makeContext()
        let repository = IncomeRepository(context: context)
        let schedule = try repository.save(
            cadence: .biweekly, anchorPayday: TestSupport.date(2054, 8, 20),
            takeHome: TestSupport.money("2400.00"), monthlyDay: nil,
            semimonthlyFirstDay: nil, semimonthlySecondDay: nil, destinationAccountID: nil
        )
        let change = try repository.addChange(
            to: schedule, effectiveDate: TestSupport.date(2054, 12, 10),
            newTakeHome: TestSupport.money("2500.00"), note: "raise"
        )
        XCTAssertEqual(try repository.changes(for: schedule).count, 1)

        XCTAssertThrowsError(try repository.addChange(
            to: schedule, effectiveDate: TestSupport.date(2055, 1, 1), newTakeHome: .zero
        ))

        try repository.delete(change)
        XCTAssertEqual(try repository.changes(for: schedule).count, 0)
    }

    // MARK: - Obligations (V2-07)

    func testObligationSmoothingPreviewMatchesTheSharedRule() throws {
        let context = try makeContext()
        let repository = ObligationRepository(context: context)
        let car = try repository.create(
            name: "Car", amount: TestSupport.money("700.00"), cadence: .monthly
        )
        let train = try repository.create(
            name: "Train pass", amount: TestSupport.money("150.00"), cadence: .monthly
        )

        // The exact reductions the contract names.
        XCTAssertEqual(
            ObligationMath.perPaycheckReserve(
                amount: car.amount, cadence: car.cadence, paychecksPerYear: 26
            ),
            TestSupport.money("323.08")
        )
        XCTAssertEqual(
            ObligationMath.perPaycheckReserve(
                amount: train.amount, cadence: train.cadence, paychecksPerYear: 26
            ),
            TestSupport.money("69.23")
        )
    }

    func testNonEssentialObligationsStayOutOfTheGeneratorInput() throws {
        let context = try makeContext()
        try CashAccountRepository(context: context).create(
            name: "Everyday", currentBalance: TestSupport.money("1000.00"), roles: [.income, .spending]
        )
        try GoalProfileRepository(context: context).save(
            goalText: nil, targetDebtFreeDate: nil, posture: .steady,
            protectedFloor: .zero, allowanceCap: .zero
        )
        try IncomeRepository(context: context).save(
            cadence: .biweekly, anchorPayday: TestSupport.date(2054, 9, 3),
            takeHome: TestSupport.money("2000.00"), monthlyDay: nil,
            semimonthlyFirstDay: nil, semimonthlySecondDay: nil, destinationAccountID: nil
        )
        let obligations = ObligationRepository(context: context)
        try obligations.create(name: "Rent", amount: TestSupport.money("1700.00"), cadence: .monthly)
        try obligations.create(
            name: "Streaming", amount: TestSupport.money("15.00"), cadence: .monthly, isEssential: false
        )

        let input = try PlanningInputBuilder(context: context).build()
        XCTAssertEqual(input.obligations.map(\.name), ["Rent"])
    }

    func testObligationValidationRejectsBlankNamesAndZeroAmounts() throws {
        let context = try makeContext()
        let repository = ObligationRepository(context: context)
        XCTAssertThrowsError(try repository.create(name: " ", amount: TestSupport.money("10.00"), cadence: .monthly)) {
            XCTAssertEqual($0 as? ModelValidationError, .emptyName)
        }
        XCTAssertThrowsError(try repository.create(name: "Rent", amount: .zero, cadence: .monthly)) {
            XCTAssertEqual($0 as? ModelValidationError, .zeroOrNegativeAmount(field: "The amount"))
        }
        XCTAssertThrowsError(
            try repository.create(name: "Rent", amount: TestSupport.money("10.00"), cadence: .monthly, dueDay: 0)
        ) {
            XCTAssertEqual($0 as? ModelValidationError, .invalidDay(0))
        }
    }

    // MARK: - Goal profile (V2-02, V2-08, V2-09)

    func testGoalProfileSavesOnceAndRejectsNegativeGuardrails() throws {
        let context = try makeContext()
        let repository = GoalProfileRepository(context: context)

        try repository.save(
            goalText: "  ", targetDebtFreeDate: nil, posture: .cushionFirst,
            protectedFloor: TestSupport.money("2000.00"), allowanceCap: TestSupport.money("300.00")
        )
        let profile = try repository.profile()
        XCTAssertNil(profile.goalText, "Whitespace-only goals are stored as no goal")
        XCTAssertEqual(profile.posture, .cushionFirst)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserGoalProfile>()), 1)

        XCTAssertThrowsError(try repository.save(
            goalText: nil, targetDebtFreeDate: nil, posture: .steady,
            protectedFloor: TestSupport.money("-1.00"), allowanceCap: .zero
        ))
        XCTAssertThrowsError(try repository.save(
            goalText: nil, targetDebtFreeDate: nil, posture: .steady,
            protectedFloor: .zero, allowanceCap: TestSupport.money("-1.00")
        ))
        // Zero is a legitimate answer for both.
        XCTAssertNoThrow(try repository.save(
            goalText: nil, targetDebtFreeDate: nil, posture: .steady,
            protectedFloor: .zero, allowanceCap: .zero
        ))
    }

    /// V2-02: posture changes copy and suggestions only. Identical numbers
    /// under different postures must generate identical plans.
    func testPostureDoesNotChangeGeneratedMath() throws {
        func generate(_ posture: PayoffPosture) throws -> StoredPlanResult {
            let context = try makeContext()
            try CashAccountRepository(context: context).create(
                name: "Everyday", currentBalance: TestSupport.money("1000.00"), roles: [.income, .spending]
            )
            try GoalProfileRepository(context: context).save(
                goalText: nil, targetDebtFreeDate: nil, posture: posture,
                protectedFloor: TestSupport.money("500.00"),
                allowanceCap: TestSupport.money("200.00")
            )
            try IncomeRepository(context: context).save(
                cadence: .biweekly, anchorPayday: TestSupport.date(2054, 9, 3),
                takeHome: TestSupport.money("2000.00"), monthlyDay: nil,
                semimonthlyFirstDay: nil, semimonthlySecondDay: nil, destinationAccountID: nil
            )
            try DebtRepository(context: context).create(
                type: .creditCard, displayName: "Card",
                currentBalance: TestSupport.money("3000.00"),
                apr: TestSupport.money("0.2499"), minimumAmount: TestSupport.money("60.00")
            )
            return try PlanGenerationService.generate(
                context: context, asOf: TestSupport.date(2054, 8, 30)
            ).rows
        }

        let fullThrottle = try generate(.fullThrottle)
        let steady = try generate(.steady)
        let cushionFirst = try generate(.cushionFirst)
        XCTAssertEqual(fullThrottle, steady)
        XCTAssertEqual(steady, cushionFirst)
    }

    // MARK: - Completeness: review list and upgrade checklist

    func testEmptyStoreReportsBlockersForEveryRequiredAnswer() throws {
        let context = try makeContext()
        let gaps = try SetupCompletenessService(context: context).gaps()
        let blockerKinds = Set(gaps.filter(\.isBlocker).map(\.kind))
        XCTAssertTrue(blockerKinds.contains(.goals))
        XCTAssertTrue(blockerKinds.contains(.accountRoles))
        XCTAssertTrue(blockerKinds.contains(.income))
        // Blockers sort ahead of the optional ones.
        XCTAssertTrue(gaps.first?.isBlocker ?? false)
    }

    func testCompleteSetupHasNoBlockersLeft() throws {
        let context = try makeContext()
        try CashAccountRepository(context: context).create(
            name: "Everyday", currentBalance: TestSupport.money("1000.00"), roles: [.income, .spending]
        )
        try GoalProfileRepository(context: context).save(
            goalText: "Debt-free", targetDebtFreeDate: nil, posture: .steady,
            protectedFloor: TestSupport.money("1000.00"), allowanceCap: TestSupport.money("300.00")
        )
        try IncomeRepository(context: context).save(
            cadence: .biweekly, anchorPayday: TestSupport.date(2054, 9, 3),
            takeHome: TestSupport.money("2000.00"), monthlyDay: nil,
            semimonthlyFirstDay: nil, semimonthlySecondDay: nil, destinationAccountID: nil
        )
        try ObligationRepository(context: context).create(
            name: "Rent", amount: TestSupport.money("1700.00"), cadence: .monthly, dueDay: 1
        )
        try DebtRepository(context: context).create(
            type: .creditCard, displayName: "Card",
            currentBalance: TestSupport.money("2000.00"), apr: TestSupport.money("0.2499"),
            minimumAmount: TestSupport.money("50.00"), originalPrincipal: TestSupport.money("2500.00"),
            creditLimit: TestSupport.money("5000.00"), dueDayOfMonth: 14
        )

        let gaps = try SetupCompletenessService(context: context).gaps()
        XCTAssertTrue(gaps.filter(\.isBlocker).isEmpty, "Nothing should block: \(gaps.map(\.title))")
    }

    func testMissingDefaultIncomeAccountIsABlocker() throws {
        let context = try makeContext()
        let repository = CashAccountRepository(context: context)
        let account = try repository.create(
            name: "Everyday", currentBalance: TestSupport.money("500.00"), roles: [.spending]
        )
        // Force the invalid state the invariant normally prevents.
        account.isDefaultIncome = false
        try context.save()

        let gaps = try SetupCompletenessService(context: context).gaps()
        XCTAssertTrue(gaps.contains { $0.kind == .defaultIncomeAccount && $0.isBlocker })
    }

    func testInstallmentDebtWithoutAMinimumBlocksAndCardWithoutOneOnlyWarns() throws {
        let context = try makeContext()
        let loan = DebtAccount(
            planID: "D1", displayName: "Car", startingBalance: TestSupport.money("9000.00"),
            apr: TestSupport.money("0.0699"), minimumAmount: nil, priority: 1, debtType: .autoLoan
        )
        context.insert(loan)
        let card = DebtAccount(
            planID: "D2", displayName: "Blue", startingBalance: TestSupport.money("1500.00"),
            apr: TestSupport.money("0.2499"), minimumAmount: nil, priority: 2
        )
        context.insert(card)
        try context.save()

        let gaps = try SetupCompletenessService(context: context).gaps()
        let loanGap = try XCTUnwrap(gaps.first { $0.kind == .estimatedMinimum && $0.subjectID == loan.id })
        XCTAssertTrue(loanGap.isBlocker)
        let cardGap = try XCTUnwrap(gaps.first { $0.kind == .estimatedMinimum && $0.subjectID == card.id })
        XCTAssertFalse(cardGap.isBlocker)
    }

    func testUnknownPrepaymentAppearsInTheChecklist() throws {
        let context = try makeContext()
        let loan = try DebtRepository(context: context).create(
            type: .personalLoan, displayName: "Consolidation",
            currentBalance: TestSupport.money("4000.00"), apr: TestSupport.money("0.1199"),
            minimumAmount: TestSupport.money("150.00"),
            originalPrincipal: TestSupport.money("5000.00"),
            dueDayOfMonth: 5, prepayment: .unknown
        )
        let gaps = try SetupCompletenessService(context: context).gaps()
        let gap = try XCTUnwrap(gaps.first { $0.kind == .extraPrincipalEligibility })
        XCTAssertEqual(gap.subjectID, loan.id)
        XCTAssertFalse(gap.isBlocker, "An unknown restriction never blocks — it just withholds extra")
    }
}
