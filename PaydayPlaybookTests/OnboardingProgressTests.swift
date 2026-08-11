import XCTest
import SwiftData
@testable import PaydayPlaybook

/// V2-01: every step boundary persists and resumes; finishing twice creates
/// no duplicate plans, accounts, obligations, or debts.
final class OnboardingProgressTests: XCTestCase {

    private func makeService(_ container: ModelContainer) -> OnboardingProgressService {
        OnboardingProgressService(context: ModelContext(container), dateProvider: TestSupport.fixedToday)
    }

    // MARK: - Step persistence and resume

    func testStepsPersistAndResumeAcrossRelaunches() throws {
        let container = try TestSupport.makeContainer()

        let service = makeService(container)
        XCTAssertEqual(try service.resumeStep(), .welcome)
        try service.markStepCompleted(.welcome)
        try service.markStepCompleted(.goals)
        XCTAssertEqual(try service.resumeStep(), .accounts)

        // "Relaunch": a new context on the same store resumes exactly there.
        let relaunched = makeService(container)
        XCTAssertEqual(try relaunched.resumeStep(), .accounts)
        try relaunched.markStepCompleted(.accounts)
        XCTAssertEqual(try relaunched.resumeStep(), .income)

        // Only one progress row ever exists.
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OnboardingProgress>()), 1)
    }

    func testRevisitingAnEarlierStepNeverRegressesProgress() throws {
        let container = try TestSupport.makeContainer()
        let service = makeService(container)
        try service.markStepCompleted(.welcome)
        try service.markStepCompleted(.goals)
        try service.markStepCompleted(.accounts)
        try service.markStepCompleted(.income)
        // The user goes back and re-saves the goals step.
        try service.markStepCompleted(.goals)
        XCTAssertEqual(try service.resumeStep(), .obligations)
    }

    // MARK: - Atomic, duplicate-proof finish

    private func lemStyleFixture() -> (StoredPlanInput, StoredPlanResult) {
        let debtID = UUID()
        let obligationID = UUID()
        let input = StoredPlanInput(
            calculationVersion: 2,
            cadence: .biweekly,
            monthlyPayDay: nil, semimonthlyPayDay1: nil, semimonthlyPayDay2: nil,
            nextPayday: TestSupport.date(2026, 9, 1),
            baseTakeHome: TestSupport.money("2000.00"),
            incomeChanges: [
                PlanningIncomeChange(effectiveDate: TestSupport.date(2026, 10, 1), amount: TestSupport.money("2100.00"))
            ],
            spendingStartingBalance: TestSupport.money("800.00"),
            protectedFloor: TestSupport.money("500.00"),
            allowanceCap: TestSupport.money("200.00"),
            firstCheckBufferAdd: .zero,
            obligations: [
                PlanningObligation(id: obligationID, name: "Rent", amount: TestSupport.money("1200.00"), cadence: .monthly, dueDay: 1)
            ],
            debts: [
                PlanningDebt(
                    id: debtID, displayID: "A", name: "Visa", debtType: .creditCard,
                    currentBalance: TestSupport.money("3000.00"), apr: TestSupport.money("0.2499"),
                    minimumAmount: nil, isExtraPrincipalEligible: true,
                    creditLimit: TestSupport.money("5000.00"), dueDayOfMonth: 12, originalPrincipal: nil
                )
            ],
            paycheckCap: 600,
            timeZoneID: TimeZone.current.identifier
        )
        let paydays = (1...2).map { seq in
            PlanningPayday(
                sequence: seq,
                date: TestSupport.date(2026, 9, seq == 1 ? 1 : 15),
                income: TestSupport.money("2000.00"),
                keepInSpending: TestSupport.money("200.00"),
                transferToReserves: TestSupport.money("1800.00"),
                allowance: TestSupport.money("200.00"),
                floorTopUp: .zero,
                obligationReserves: [
                    PlanningObligationReserve(obligationID: obligationID, amount: TestSupport.money("553.85"))
                ],
                debtBudget: TestSupport.money("1246.15"),
                targetDebtID: "A",
                perDebtBalancesAfter: ["A": TestSupport.money(seq == 1 ? "1782.60" : "553.52")],
                totalDebtAfter: TestSupport.money(seq == 1 ? "1782.60" : "553.52"),
                noSpendCeiling: TestSupport.money(seq == 1 ? "1000.00" : "1200.00"),
                shortfallAmount: nil
            )
        }
        let result = StoredPlanResult(
            calculationVersion: 2,
            paydays: paydays,
            payoffDate: TestSupport.date(2026, 9, 15),
            totalEstimatedInterest: TestSupport.money("57.42"),
            paycheckCount: 2,
            debtPayoffs: [PlanningDebtPayoff(debtID: "A", payoffDate: TestSupport.date(2026, 9, 15))],
            cappedAtPaycheckLimit: false
        )
        return (input, result)
    }

    func testFinishPersistsPlanAtomicallyAndCompletesOnboarding() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let service = OnboardingProgressService(context: context, dateProvider: TestSupport.fixedToday)
        let (input, result) = lemStyleFixture()

        let plan = try service.finish(planName: "Plan v1", input: input, result: result)

        XCTAssertEqual(plan.name, "Plan v1")
        XCTAssertTrue(plan.isOriginalBaseline)
        XCTAssertTrue(plan.isActive)
        XCTAssertTrue(plan.generatedFromProfile)
        XCTAssertEqual(plan.calculationVersion, 2)
        XCTAssertEqual(plan.payCadence, .biweekly)
        XCTAssertEqual(plan.protectedBuffer, TestSupport.money("500.00"))
        XCTAssertEqual(plan.allowanceCap, TestSupport.money("200.00"))

        // The input snapshot makes the plan reproducible.
        let snapshot = try XCTUnwrap(plan.inputSnapshotData)
        XCTAssertEqual(try PlanningSnapshotCoder.decode(snapshot), input)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PaydayPlanItem>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlannedCardBalance>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlannedObligationReserve>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<IncomeRule>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Milestone>()), 2)

        let settings = try XCTUnwrap(context.fetch(FetchDescriptor<AppSettings>()).first)
        XCTAssertTrue(settings.onboardingComplete)
        XCTAssertEqual(settings.seedSchemaVersion, 2)
        let progress = try XCTUnwrap(context.fetch(FetchDescriptor<OnboardingProgress>()).first)
        XCTAssertNotNil(progress.completedAt)

        // Plan items carry the generated values.
        let items = try TestSupport.planItems(context, plan: plan)
        XCTAssertEqual(items.first?.plannedCardBudget, TestSupport.money("1246.15"))
        XCTAssertEqual(items.first?.plannedTargetDebtID, "A")
        XCTAssertNil(items.first?.shortfallAmount)
        XCTAssertFalse(items.first?.needsAttention ?? true)
    }

    func testDoubleFinishCreatesNoDuplicates() throws {
        let container = try TestSupport.makeContainer()
        let service = makeService(container)
        let (input, result) = lemStyleFixture()

        let first = try service.finish(planName: "Plan v1", input: input, result: result)
        // A relaunch mid-generation retries finish (same idempotency bar as
        // the 0.1.x seeder).
        let relaunched = makeService(container)
        let second = try relaunched.finish(planName: "Plan v1", input: input, result: result)
        XCTAssertEqual(first.id, second.id)

        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PaydayPlanItem>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlannedCardBalance>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlannedObligationReserve>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<IncomeRule>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Milestone>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OnboardingProgress>()), 1)
    }

    func testShortfallFlagPersistsOnGeneratedItems() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let service = OnboardingProgressService(context: context, dateProvider: TestSupport.fixedToday)
        var (input, result) = lemStyleFixture()
        result.paydays[1].shortfallAmount = TestSupport.money("84.00")

        let plan = try service.finish(planName: "Plan v1", input: input, result: result)
        let items = try TestSupport.planItems(context, plan: plan)
        XCTAssertNil(items[0].shortfallAmount)
        XCTAssertEqual(items[1].shortfallAmount, TestSupport.money("84.00"))
        XCTAssertTrue(items[1].needsAttention)
        _ = input
    }
}
