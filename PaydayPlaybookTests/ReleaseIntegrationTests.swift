import XCTest
import SwiftData
@testable import PaydayPlaybook

/// Integration defects that only exist in the merged v0.2.0 tree.
///
/// Every test here pins a bug that no single agent branch could have caught,
/// because the two halves of each bug arrived from different branches. They
/// are release-gate regressions: if one of these fails, the plan a user sees
/// is not the plan the app saved, or a screen is showing someone else's money.
@MainActor
final class ReleaseIntegrationTests: XCTestCase {

    // MARK: - One store→engine conversion

    /// `GeneratedPlanService` (presentation) kept its own copy of the
    /// store→engine conversion, written before the snapshot carried `asOf`.
    /// Ignoring it meant regenerating a plan for display used a different
    /// accrual anchor than the run that produced the saved plan.
    func testPresentationBridgeHonoursTheSnapshotAsOfStamp() throws {
        var snapshot = Self.biweeklySnapshot()
        snapshot.asOf = TestSupport.date(2054, 8, 3)

        let input = try GeneratedPlanService.engineInput(from: snapshot)

        XCTAssertEqual(input.asOf, TestSupport.date(2054, 8, 3))
        XCTAssertEqual(
            input,
            try PlanGenerationService.engineInput(from: snapshot),
            "Both bridges must build the same engine input from the same snapshot."
        )
    }

    /// An explicit `asOf` (live preview "as of today") still overrides the
    /// stored stamp — the preview screen depends on it.
    func testExplicitAsOfOverridesTheStoredStamp() throws {
        var snapshot = Self.biweeklySnapshot()
        snapshot.asOf = TestSupport.date(2054, 8, 3)

        let input = try GeneratedPlanService.engineInput(
            from: snapshot, asOf: TestSupport.date(2054, 8, 10)
        )
        XCTAssertEqual(input.asOf, TestSupport.date(2054, 8, 10))
    }

    /// Semimonthly days entered as (15, 1) are the same paydays as (1, 15).
    /// The generation bridge normalises; the presentation copy did not, so a
    /// user who entered them in that order saw a different payday schedule
    /// than the one that was saved.
    func testReversedSemimonthlyDaysNormaliseIdenticallyOnBothBridges() throws {
        var snapshot = Self.biweeklySnapshot()
        snapshot.cadence = .semimonthly
        snapshot.semimonthlyPayDay1 = 15
        snapshot.semimonthlyPayDay2 = 1

        let input = try GeneratedPlanService.engineInput(from: snapshot)

        XCTAssertEqual(input.income.cadence, .semimonthly(firstDay: 1, secondDay: 15))
    }

    /// Missing pay days must raise the actionable error, not silently default
    /// to the 1st and 15th and render a schedule the user never chose.
    func testMissingSemimonthlyDaysFailLoudlyOnBothBridges() throws {
        var snapshot = Self.biweeklySnapshot()
        snapshot.cadence = .semimonthly
        snapshot.semimonthlyPayDay1 = nil
        snapshot.semimonthlyPayDay2 = nil

        XCTAssertThrowsError(try GeneratedPlanService.engineInput(from: snapshot)) { error in
            XCTAssertEqual(
                error as? PlanGenerationService.GenerationError,
                .missingPayDay(cadence: "twice-a-month")
            )
        }
    }

    /// The tri-state must reach the engine intact. Collapsing `.unknown` to a
    /// boolean loses the "ask the user to confirm" warning that the saved plan
    /// carries, so the plan screen would quietly drop it.
    func testUnknownPrepaymentSurvivesIntoTheEngineInput() throws {
        var snapshot = Self.biweeklySnapshot()
        snapshot.debts[1].prepayment = .unknown

        let input = try GeneratedPlanService.engineInput(from: snapshot)

        XCTAssertEqual(input.debts[1].prepayment, .unknown)
        let result = try AvalanchePlanEngine.generatePlan(input)
        XCTAssertTrue(
            result.warnings.contains { $0.code == .prepaymentEligibilityUnknown },
            "An unknown-prepayment debt must still raise its confirm-me warning."
        )
    }

    // MARK: - One install's money never leaks into another's

    /// `ReforecastService.currentIncome` once fell through to a hard-coded
    /// income constant, so a freshly onboarded user saw someone else's
    /// paycheck as their own on Today, Settings and the Phase II screen.
    /// The constant is gone; this pins the behaviour it was hiding.
    func testCurrentIncomeReportsThisUsersPaycheck() throws {
        let takeHome = TestSupport.money("1500.00")
        let fixture = try DashboardFixtures.generatedPlan(takeHome: takeHome)

        let income = try ReforecastService.currentIncome(
            context: fixture.context,
            on: TestSupport.date(2054, 8, 20)
        )

        XCTAssertEqual(income, takeHome)
        XCTAssertNotEqual(
            income, DebugBaselineFixture.firstIncome,
            "A generated plan must never report another plan's income."
        )
    }

    /// The migrated baseline keeps reporting its own stored income — the fix
    /// above must not disturb the existing user.
    func testMigratedBaselineStillReportsItsStoredIncome() throws {
        let fixture = try DashboardFixtures.legacyMigrated()
        let plan = try XCTUnwrap(PlanRepository.legacyBaseline(context: fixture.context))
        let planID = plan.id
        let storedRules = try fixture.context.fetch(
            FetchDescriptor<IncomeRule>(predicate: #Predicate { $0.planVersionID == planID })
        ).sorted { $0.effectiveDate < $1.effectiveDate }
        let firstRule = try XCTUnwrap(storedRules.first)

        let income = try ReforecastService.currentIncome(
            context: fixture.context,
            on: firstRule.effectiveDate
        )

        XCTAssertEqual(income, firstRule.netPaycheckAmount)
    }

    // MARK: - Fixtures

    private static func biweeklySnapshot() -> StoredPlanInput {
        StoredPlanInput(
            calculationVersion: 2,
            cadence: .biweekly,
            monthlyPayDay: nil,
            semimonthlyPayDay1: nil,
            semimonthlyPayDay2: nil,
            nextPayday: TestSupport.date(2054, 8, 20),
            baseTakeHome: TestSupport.money("2400.00"),
            incomeChanges: [],
            spendingStartingBalance: TestSupport.money("1500.00"),
            protectedFloor: TestSupport.money("1000.00"),
            allowanceCap: TestSupport.money("300.00"),
            firstCheckBufferAdd: .zero,
            obligations: [],
            debts: [
                PlanningDebt(
                    id: UUID(), displayID: "D1", name: "Blue Card", debtType: .creditCard,
                    currentBalance: TestSupport.money("1100.00"), apr: TestSupport.money("0.2600"),
                    minimumAmount: nil, isExtraPrincipalEligible: true,
                    creditLimit: TestSupport.money("2000.00"), dueDayOfMonth: 12,
                    originalPrincipal: nil
                ),
                PlanningDebt(
                    id: UUID(), displayID: "D2", name: "Car Note", debtType: .autoLoan,
                    currentBalance: TestSupport.money("8000.00"), apr: TestSupport.money("0.0625"),
                    minimumAmount: TestSupport.money("310.00"), isExtraPrincipalEligible: true,
                    creditLimit: nil, dueDayOfMonth: 5,
                    originalPrincipal: TestSupport.money("12000.00")
                )
            ],
            paycheckCap: 600,
            timeZoneID: "America/New_York"
        )
    }
}
