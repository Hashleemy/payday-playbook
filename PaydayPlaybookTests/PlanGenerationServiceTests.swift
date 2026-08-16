import XCTest
import SwiftData
@testable import PaydayPlaybook

/// The store → engine → persistence bridge (V2-10). Pins that onboarding
/// rows produce a real generated plan, that the two planning contracts map
/// onto each other without losing a cent, and that generation failures are
/// actionable.
final class PlanGenerationServiceTests: XCTestCase {

    // MARK: - Store fixtures

    /// Inserts the baseline fixture's inputs as onboarding rows: the same raw
    /// values the parity suite feeds the engine directly, but entered the way
    /// onboarding writes them (accounts, profile, schedule, obligations,
    /// debts). Generating from these must reproduce the fixture's plan.
    @discardableResult
    private func insertBaselineRows(_ context: ModelContext) throws -> [DebtAccount] {
        let spending = CashAccount(
            name: "Everyday checking",
            currentBalance: DebugBaselineFixture.startingSpendingBalance,
            roles: [.income, .spending],
            isDefaultIncome: true,
            sortOrder: 0
        )
        let reserves = CashAccount(
            name: "Bills & debt",
            currentBalance: .zero,
            roles: [.reserves],
            sortOrder: 1
        )
        context.insert(spending)
        context.insert(reserves)

        context.insert(UserGoalProfile(
            goalText: "Debt-free",
            posture: .steady,
            protectedFloor: DebugBaselineFixture.protectedFloor,
            allowanceCap: DebugBaselineFixture.allowancePerCheck
        ))

        let schedule = IncomeSchedule(
            cadence: .biweekly,
            anchorPayday: TestSupport.date(2054, 8, 20),
            destinationAccountID: spending.id,
            baseTakeHome: DebugBaselineFixture.firstIncome
        )
        context.insert(schedule)
        context.insert(IncomeChange(
            scheduleID: schedule.id,
            effectiveDate: TestSupport.date(2054, 12, 10),
            newTakeHome: DebugBaselineFixture.raisedIncome
        ))

        context.insert(RecurringObligation(
            name: "Car", amount: DebugBaselineFixture.carMonthly, cadence: .monthly,
            createdAt: TestSupport.date(2054, 8, 1)
        ))
        context.insert(RecurringObligation(
            name: "Transit pass", amount: DebugBaselineFixture.transitMonthly, cadence: .monthly,
            createdAt: TestSupport.date(2054, 8, 2)
        ))

        var debts: [DebtAccount] = []
        for (index, card) in DebugBaselineFixture.cards.enumerated() {
            let debt = DebtAccount(
                planID: "D\(index + 1)",
                displayName: "Card \(card.planID)",
                startingBalance: Decimal(string: card.balance)!,
                apr: Decimal(string: card.apr)!,
                priority: index + 1,
                createdAt: TestSupport.date(2054, 8, 1)
            )
            context.insert(debt)
            debts.append(debt)
        }
        try context.save()
        return debts
    }

    // MARK: - Baseline equivalence through the whole bridge

    func testBaselineRowsGenerateTheFixturePlan() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try insertBaselineRows(context)

        let generated = try PlanGenerationService.generate(
            context: context, asOf: TestSupport.date(2054, 8, 9)
        )

        // Headline values from the §3 contract (clean-Decimal engine truth;
        // the doc's final-payment cell carries a known float artifact).
        XCTAssertEqual(generated.rows.paycheckCount, 23)
        XCTAssertEqual(generated.rows.payoffDate, TestSupport.date(2055, 6, 24))
        XCTAssertEqual(generated.rows.totalEstimatedInterest, TestSupport.money("2617.18"))
        XCTAssertFalse(generated.rows.cappedAtPaycheckLimit)
        XCTAssertEqual(generated.rows.paydays.count, 23)

        // First check: the floor is already met, so nothing tops it up.
        let first = try XCTUnwrap(generated.rows.paydays.first)
        XCTAssertEqual(first.date, TestSupport.date(2054, 8, 20))
        XCTAssertEqual(first.keepInSpending, TestSupport.money("300.00"))
        XCTAssertEqual(first.floorTopUp, .zero)
        XCTAssertEqual(first.debtBudget, TestSupport.money("1707.69"))
        XCTAssertEqual(
            first.obligationReserves.map(\.amount).reduce(Decimal.zero, +),
            TestSupport.money("392.31")
        )

        // Final check and ceiling.
        let last = try XCTUnwrap(generated.rows.paydays.last)
        XCTAssertEqual(last.date, TestSupport.date(2055, 6, 24))
        XCTAssertGreaterThan(last.debtBudget, .zero)
        XCTAssertEqual(last.totalDebtAfter, .zero)
        XCTAssertEqual(last.noSpendCeiling, TestSupport.money("8400.00"))

        // Targets follow avalanche order by display ID: the fixture's cards
        // are APR-descending, so creation order D1...D6 is attack order.
        XCTAssertEqual(first.targetDebtID, "D1")
        XCTAssertEqual(last.targetDebtID, "D6")
        XCTAssertEqual(generated.rows.debtPayoffs.count, 6)
        XCTAssertEqual(
            generated.rows.debtPayoffs.first { $0.debtID == "D6" }?.payoffDate,
            TestSupport.date(2055, 6, 24)
        )
    }

    func testFinishPersistsGeneratedPlanAndSnapshotRegeneratesIdentically() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try insertBaselineRows(context)

        let generated = try PlanGenerationService.generate(
            context: context, asOf: TestSupport.date(2054, 8, 9)
        )
        let service = OnboardingProgressService(context: context, dateProvider: TestSupport.fixedToday)
        let plan = try service.finish(planName: "Plan v1", input: generated.input, result: generated.rows)

        // A plan generated now carries the release's stamp. The literal is
        // pinned once, in ReleaseIntegrationTests; here the point is that
        // generation stamps the current version rather than any fixed one.
        XCTAssertEqual(plan.calculationVersion, PlanContract.currentCalculationVersion)
        XCTAssertTrue(plan.generatedFromProfile)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PaydayPlanItem>()), 23)

        // The stored snapshot regenerates the identical plan (determinism
        // across the whole bridge, including the stored asOf).
        let reloaded = try XCTUnwrap(
            context.fetch(FetchDescriptor<PlanVersion>()).first { $0.name == "Plan v1" }
        )
        let regenerated = try XCTUnwrap(PlanGenerationService.regenerate(from: reloaded))
        XCTAssertEqual(regenerated.result, generated.result)
        XCTAssertEqual(regenerated.rows, generated.rows)
    }

    // MARK: - Cadence mapping

    func testCadenceMappingCoversAllFourAndNormalizesSemimonthly() throws {
        var snapshot = StoredPlanInput(
            calculationVersion: 2,
            cadence: .weekly,
            monthlyPayDay: nil, semimonthlyPayDay1: nil, semimonthlyPayDay2: nil,
            nextPayday: TestSupport.date(2054, 9, 1),
            baseTakeHome: TestSupport.money("1000.00"),
            incomeChanges: [],
            spendingStartingBalance: .zero,
            protectedFloor: .zero,
            allowanceCap: .zero,
            firstCheckBufferAdd: .zero,
            obligations: [],
            debts: [],
            paycheckCap: 600,
            timeZoneID: TimeZone.current.identifier
        )
        XCTAssertEqual(try PlanGenerationService.planningCadence(from: snapshot), .weekly)

        snapshot.cadence = .biweekly
        XCTAssertEqual(try PlanGenerationService.planningCadence(from: snapshot), .biweekly)

        snapshot.cadence = .monthly
        snapshot.monthlyPayDay = 31
        XCTAssertEqual(try PlanGenerationService.planningCadence(from: snapshot), .monthly(day: 31))

        // Reversed semimonthly days normalize to ascending.
        snapshot.cadence = .semimonthly
        snapshot.semimonthlyPayDay1 = 15
        snapshot.semimonthlyPayDay2 = 1
        XCTAssertEqual(
            try PlanGenerationService.planningCadence(from: snapshot),
            .semimonthly(firstDay: 1, secondDay: 15)
        )
    }

    func testMissingPayDaysThrowActionableErrors() throws {
        var snapshot = StoredPlanInput(
            calculationVersion: 2,
            cadence: .monthly,
            monthlyPayDay: nil, semimonthlyPayDay1: nil, semimonthlyPayDay2: nil,
            nextPayday: TestSupport.date(2054, 9, 1),
            baseTakeHome: TestSupport.money("1000.00"),
            incomeChanges: [],
            spendingStartingBalance: .zero,
            protectedFloor: .zero,
            allowanceCap: .zero,
            firstCheckBufferAdd: .zero,
            obligations: [],
            debts: [],
            paycheckCap: 600,
            timeZoneID: TimeZone.current.identifier
        )
        XCTAssertThrowsError(try PlanGenerationService.planningCadence(from: snapshot)) { error in
            XCTAssertEqual(
                error as? PlanGenerationService.GenerationError,
                .missingPayDay(cadence: "monthly")
            )
        }

        snapshot.cadence = .semimonthly
        snapshot.semimonthlyPayDay1 = 10
        snapshot.semimonthlyPayDay2 = 10
        XCTAssertThrowsError(try PlanGenerationService.planningCadence(from: snapshot)) { error in
            XCTAssertEqual(
                error as? PlanGenerationService.GenerationError,
                .samePayDays
            )
        }
    }

    // MARK: - Missing-input failures are actionable

    func testEmptyStoreFailsWithStepPointingErrors() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)

        XCTAssertThrowsError(
            try PlanGenerationService.generate(context: context, asOf: TestSupport.date(2054, 8, 9))
        ) { error in
            XCTAssertEqual(error as? PlanGenerationService.GenerationError, .missingIncome)
            XCTAssertTrue(
                (error as? PlanGenerationService.GenerationError)?
                    .errorDescription?.contains("Income step") ?? false
            )
        }
    }

    // MARK: - Prepayment tri-state

    func testUnknownPrepaymentWithholdsExtraAndWarns() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try insertBaselineRows(context)

        // Add a high-APR personal loan with unknown prepayment terms; the
        // engine must not send it extra principal and must ask to confirm.
        let loan = DebtAccount(
            planID: "D7",
            displayName: "Consolidation loan",
            startingBalance: TestSupport.money("2000.00"),
            apr: TestSupport.money("0.3500"),
            minimumAmount: TestSupport.money("100.00"),
            priority: 7,
            debtType: .personalLoan
        )
        loan.prepayment = .unknown
        XCTAssertEqual(loan.prepayment, .unknown)
        XCTAssertFalse(loan.isExtraPrincipalEligible)
        context.insert(loan)
        try context.save()

        let generated = try PlanGenerationService.generate(
            context: context, asOf: TestSupport.date(2054, 8, 9)
        )
        XCTAssertTrue(generated.result.warnings.contains {
            $0.code == .prepaymentEligibilityUnknown && $0.debtID == loan.id
        })
        // Highest APR in the book, but never the extra-principal target.
        for paycheck in generated.result.paychecks {
            let payment = paycheck.payments.first { $0.debtID == loan.id }
            XCTAssertEqual(payment?.extra ?? .zero, .zero)
        }
    }

    func testCreditCardsAreAlwaysPrepaymentEligible() {
        let card = DebtAccount(
            planID: "D1",
            displayName: "Visa",
            startingBalance: TestSupport.money("500.00"),
            apr: TestSupport.money("0.2499"),
            priority: 1
        )
        card.isExtraPrincipalEligible = false
        XCTAssertEqual(card.prepayment, .eligible)

        let loan = DebtAccount(
            planID: "D2",
            displayName: "Auto",
            startingBalance: TestSupport.money("9000.00"),
            apr: TestSupport.money("0.0699"),
            minimumAmount: TestSupport.money("310.00"),
            priority: 2,
            debtType: .autoLoan
        )
        XCTAssertEqual(loan.prepayment, .eligible)
        loan.prepayment = .ineligible
        XCTAssertEqual(loan.prepayment, .ineligible)
        XCTAssertFalse(loan.isExtraPrincipalEligible)
    }

    // MARK: - Result mapping details

    func testResultSnapshotMapsShortfallAndUnknownDebtsSafely() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)

        // A deliberately underwater setup: tiny paycheck, big obligations.
        let spending = CashAccount(
            name: "Checking", currentBalance: .zero,
            roles: [.income, .spending], isDefaultIncome: true
        )
        context.insert(spending)
        context.insert(UserGoalProfile(
            posture: .steady, protectedFloor: .zero, allowanceCap: TestSupport.money("50.00")
        ))
        context.insert(IncomeSchedule(
            cadence: .biweekly,
            anchorPayday: TestSupport.date(2054, 9, 3),
            baseTakeHome: TestSupport.money("300.00")
        ))
        context.insert(RecurringObligation(
            name: "Rent", amount: TestSupport.money("1400.00"), cadence: .monthly
        ))
        // Interest outruns the fixed minimum, so the balance grows and the
        // projection hits the 600-check horizon cap.
        context.insert(DebtAccount(
            planID: "D1", displayName: "Card",
            startingBalance: TestSupport.money("10000.00"),
            apr: TestSupport.money("0.9999"),
            minimumAmount: TestSupport.money("35.00"),
            priority: 1
        ))
        try context.save()

        let generated = try PlanGenerationService.generate(
            context: context, asOf: TestSupport.date(2054, 8, 30)
        )
        let first = try XCTUnwrap(generated.rows.paydays.first)
        let engineFirst = try XCTUnwrap(generated.result.paychecks.first)
        XCTAssertEqual(first.shortfallAmount, engineFirst.shortfall?.gap)
        XCTAssertNotNil(first.shortfallAmount)
        XCTAssertGreaterThan(try XCTUnwrap(first.shortfallAmount), .zero)
        // Underwater plans hit the horizon cap and say so.
        XCTAssertTrue(generated.rows.cappedAtPaycheckLimit)
    }
}
