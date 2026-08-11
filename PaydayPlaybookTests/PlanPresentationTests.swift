import XCTest
import SwiftData
@testable import PaydayPlaybook

/// The Generated Plan screen (V2-10, V2-14, R-15): input summary, comparison
/// honesty, scenario previews, three-truths separation, and activation.
@MainActor
final class PlanPresentationTests: XCTestCase {

    private func load(_ fixture: DashboardFixtures.Generated) -> PlanViewData {
        PlanViewDataLoader.load(
            plan: fixture.plan,
            context: fixture.context,
            environment: DashboardFixtures.environment()
        )
    }

    // MARK: - Summary of inputs and recommendation

    func testPlanSummarisesItsOwnInputsAndAssumptions() throws {
        let fixture = try DashboardFixtures.generatedPlan()
        let data = load(fixture)

        XCTAssertEqual(data.calculationVersion, 2)
        XCTAssertTrue(data.generatedFromProfile)
        XCTAssertEqual(data.cadenceText, PayCadence.biweekly.displayName)
        XCTAssertEqual(data.firstPaydayText, DateMath.mediumString(TestSupport.date(2026, 8, 20)))
        XCTAssertTrue(data.takeHomeText.contains("2,094"))
        XCTAssertEqual(data.protectedFloor, TestSupport.money("1000.00"))
        XCTAssertEqual(data.allowanceCap, TestSupport.money("300.00"))

        // Obligations show their smoothed per-paycheck reserve (R-04).
        let rent = try XCTUnwrap(data.obligationLines.first { $0.name == "Rent" })
        XCTAssertEqual(rent.perPaycheck, TestSupport.money("335.08"))
        let transit = try XCTUnwrap(data.obligationLines.first { $0.name == "Transit pass" })
        XCTAssertEqual(transit.perPaycheck, TestSupport.money("51.23"))

        // Accounts by name and role.
        XCTAssertEqual(Set(data.accountLines.map(\.name)), ["Everyday Checking", "Bills & Debt"])

        // Assumptions are stated, never implied.
        XCTAssertFalse(data.assumptionLines.isEmpty)
    }

    func testRecommendedOrderIsHighestAPRFirstWithPrincipalTotals() throws {
        let fixture = try DashboardFixtures.generatedPlan()
        let data = load(fixture)

        let aprs = data.debtRows.map(\.apr)
        // 0% APR sorts last (R-08); everything else descends.
        let interestBearing = aprs.filter { $0 > 0 }
        XCTAssertEqual(interestBearing, interestBearing.sorted(by: >))
        XCTAssertEqual(data.debtRows.last?.apr, .zero, "0% debt sorts behind interest-bearing ones.")

        XCTAssertEqual(
            data.totalPrincipalNow,
            fixture.debts.reduce(Decimal.zero) { $0 + $1.startingBalance }.rounded2
        )
        XCTAssertFalse(data.avalancheExplanation.isEmpty)
    }

    func testInstallmentDebtsShowOriginalPrincipalAndCardsShowUtilization() throws {
        let fixture = try DashboardFixtures.generatedPlan()
        let data = load(fixture)

        let car = try XCTUnwrap(data.debtRows.first { $0.planID == "C" })
        XCTAssertEqual(car.debtType, .autoLoan)
        XCTAssertEqual(car.originalPrincipal, TestSupport.money("14000.00"))
        XCTAssertNil(car.utilization, "Only cards carry utilization.")

        let card = try XCTUnwrap(data.debtRows.first { $0.planID == "A" })
        // 1049 / 2000 = 0.5245
        XCTAssertEqual(try XCTUnwrap(card.utilization), TestSupport.money("0.5245"))

        let cardWithoutLimit = try XCTUnwrap(data.debtRows.first { $0.planID == "B" })
        XCTAssertNil(cardWithoutLimit.utilization, "No limit entered means no utilization claimed.")

        let medical = try XCTUnwrap(data.debtRows.first { $0.planID == "E" })
        XCTAssertFalse(medical.receivesExtraPrincipal, "Ineligible debts are shown as minimums-only.")

        // The whole-portfolio original principal is withheld while any debt
        // is missing one, rather than being partially summed.
        XCTAssertNil(data.totalOriginalPrincipal)
    }

    // MARK: - Minimums-only comparison honesty

    func testMinimumOnlyComparisonAppearsWhenEveryMinimumIsEntered() throws {
        let fixture = try DashboardFixtures.generatedPlan(debtSpecs: DashboardFixtures.DebtSpec.cardsOnly)
        let data = load(fixture)

        let minimumInterest = try XCTUnwrap(data.minimumOnlyInterest)
        XCTAssertGreaterThan(minimumInterest, data.totalEstimatedInterest)
        let saved = try XCTUnwrap(data.interestSaved)
        XCTAssertGreaterThan(saved, .zero)
        XCTAssertNil(data.minimumOnlyUnavailableReason, "Nothing to explain when the comparison is valid.")
    }

    func testMinimumOnlyComparisonIsExplainedNotGuessedWhenInputsAreInsufficient() throws {
        // An installment debt with no entered minimum: the engine withholds
        // the comparison and the screen must say why.
        let specs: [DashboardFixtures.DebtSpec] = [
            .init(planID: "A", name: "Blue Card", type: .creditCard,
                  balance: TestSupport.money("1049.00"), apr: TestSupport.money("0.2999"),
                  minimum: nil, dueDay: 12, creditLimit: TestSupport.money("2000.00"),
                  originalPrincipal: nil),
            .init(planID: "C", name: "Car Note", type: .autoLoan,
                  balance: TestSupport.money("8500.00"), apr: TestSupport.money("0.0649"),
                  minimum: nil, dueDay: 8, creditLimit: nil,
                  originalPrincipal: TestSupport.money("14000.00"))
        ]
        let fixture = try DashboardFixtures.generatedPlan(debtSpecs: specs)
        let data = load(fixture)

        XCTAssertNil(data.interestSaved, "No savings figure is claimed without sufficient input.")
        let reason = try XCTUnwrap(data.minimumOnlyUnavailableReason)
        XCTAssertFalse(reason.isEmpty)
    }

    // MARK: - Three truths never mix

    func testBaselineActualAndReforecastComeFromSeparateSources() throws {
        let fixture = try DashboardFixtures.generatedPlan()
        let data = load(fixture)

        // Baseline: the plan's own stored rows.
        XCTAssertEqual(data.baselineRows.count, data.paycheckCount)
        XCTAssertGreaterThan(data.baselineRows.count, 0)
        XCTAssertTrue(data.baselineRows.allSatisfy { !$0.isActualRecord })

        // Actual: nothing recorded yet, so nothing shown — the plan's numbers
        // never stand in for actuals.
        XCTAssertTrue(data.actualRows.isEmpty)

        // Reforecast: a separate projection with its own rows.
        XCTAssertFalse(data.reforecastRows.isEmpty)
        XCTAssertNotNil(data.reforecastPayoffDate)

        // Selecting a track switches the source, not the stored data.
        XCTAssertEqual(data.rows(for: .baseline).count, data.baselineRows.count)
        XCTAssertTrue(data.rows(for: .actual).isEmpty)
        XCTAssertEqual(data.rows(for: .reforecast).count, data.reforecastRows.count)
    }

    func testRecordingAnActualNeverChangesTheBaselineRows() throws {
        let fixture = try DashboardFixtures.generatedPlan()
        let before = load(fixture)
        let baselineBefore = before.baselineRows.map { [$0.income, $0.keepInSpending, $0.debtBudget, $0.debtAfter] }

        // The user confirms a much lower balance on the top debt.
        let debt = try XCTUnwrap(fixture.debts.first)
        fixture.context.insert(BalanceSnapshot(
            debtAccountID: debt.id,
            debtPlanID: debt.planID,
            effectiveDate: TestSupport.date(2026, 8, 9),
            amount: TestSupport.money("10.00"),
            sourceType: .currentOnlineBalance,
            isAuthoritative: true
        ))
        try fixture.context.save()

        let after = load(fixture)
        let baselineAfter = after.baselineRows.map { [$0.income, $0.keepInSpending, $0.debtBudget, $0.debtAfter] }
        XCTAssertEqual(baselineBefore, baselineAfter, "The baseline is immutable under any actual entry.")
        XCTAssertEqual(before.payoffDate, after.payoffDate)
        XCTAssertEqual(before.totalEstimatedInterest, after.totalEstimatedInterest)

        // The reforecast, however, does move.
        XCTAssertNotEqual(before.reforecastInterest, after.reforecastInterest)
    }

    func testCompletedCheckInAppearsOnlyInTheActualTrack() throws {
        let fixture = try DashboardFixtures.generatedPlan()
        let items = try TestSupport.planItems(fixture.context, plan: fixture.plan)
        let first = try XCTUnwrap(items.first)

        let checkIn = PaydayCheckIn(paydayPlanItemID: first.id, status: .completed)
        checkIn.actualIncome = TestSupport.money("2094.00")
        checkIn.actualC1Kept = TestSupport.money("380.00")
        checkIn.actualC2Transfer = TestSupport.money("1714.00")
        checkIn.actualC1Balance = TestSupport.money("1280.00")
        fixture.context.insert(checkIn)
        try fixture.context.save()

        let data = load(fixture)
        XCTAssertEqual(data.actualRows.count, 1)
        let actual = try XCTUnwrap(data.actualRows.first)
        XCTAssertTrue(actual.isActualRecord)
        XCTAssertEqual(actual.income, TestSupport.money("2094.00"))
        XCTAssertEqual(actual.keepInSpending, TestSupport.money("380.00"))
        XCTAssertEqual(actual.endingCash, TestSupport.money("1280.00"))

        // The matching baseline row keeps the planned values, unchanged.
        let planned = try XCTUnwrap(data.baselineRows.first { $0.sequence == actual.sequence })
        XCTAssertEqual(planned.income, first.plannedIncome)
        XCTAssertNotEqual(planned.keepInSpending, actual.keepInSpending)
    }

    // MARK: - Scenarios

    func testScenariosArePreviewsThatNeverTouchTheActivePlan() throws {
        let fixture = try DashboardFixtures.generatedPlan(debtSpecs: DashboardFixtures.DebtSpec.cardsOnly)
        let planID = fixture.plan.id
        let itemsBefore = try TestSupport.planItems(fixture.context, plan: fixture.plan)
            .map { [$0.plannedCardBudget, $0.plannedDebtAfter] }
        let interestBefore = fixture.plan.baselineModeledInterest
        let payoffBefore = fixture.plan.baselinePayoffDate

        let data = load(fixture)
        XCTAssertFalse(data.scenarios.isEmpty)
        XCTAssertNotNil(data.scenarioNote)

        // A higher floor never finishes sooner than the plan itself.
        if let higherFloor = data.scenarios.first(where: { $0.title.contains("Protected floor 1,500") }) {
            XCTAssertGreaterThanOrEqual(higherFloor.interestDelta, .zero)
        }

        // Nothing was written: same plan row, same items, no extra versions.
        let plans = try fixture.context.fetch(FetchDescriptor<PlanVersion>())
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.id, planID)
        XCTAssertEqual(fixture.plan.baselineModeledInterest, interestBefore)
        XCTAssertEqual(fixture.plan.baselinePayoffDate, payoffBefore)
        let itemsAfter = try TestSupport.planItems(fixture.context, plan: fixture.plan)
            .map { [$0.plannedCardBudget, $0.plannedDebtAfter] }
        XCTAssertEqual(itemsBefore, itemsAfter)
    }

    // MARK: - Activation

    func testActivationCreatesANewVersionAndLosesNoHistory() throws {
        let fixture = try DashboardFixtures.generatedPlan()
        let originalPlan = fixture.plan
        let originalItems = try TestSupport.planItems(fixture.context, plan: originalPlan)
            .map { [$0.plannedIncome, $0.plannedCardBudget, $0.plannedDebtAfter, $0.plannedC1NoSpendCeiling] }
        let originalName = originalPlan.name
        let originalInterest = originalPlan.baselineModeledInterest

        // Existing history that must survive untouched.
        let first = try XCTUnwrap(try TestSupport.planItems(fixture.context, plan: originalPlan).first)
        let checkIn = PaydayCheckIn(paydayPlanItemID: first.id, status: .completed)
        checkIn.actualIncome = TestSupport.money("2094.00")
        fixture.context.insert(checkIn)
        fixture.context.insert(LedgerEntry(
            effectiveDate: TestSupport.date(2026, 8, 20),
            type: .cardPayment,
            amount: TestSupport.money("500.00"),
            debtAccountID: fixture.debts[0].id,
            debtPlanID: fixture.debts[0].planID,
            paydayCheckInID: checkIn.id
        ))
        try fixture.context.save()
        let milestonesBefore = try fixture.context.fetchCount(FetchDescriptor<Milestone>())

        // The user raises the allowance, then activates a new version.
        let profile = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<UserGoalProfile>()).first)
        profile.allowanceCap = TestSupport.money("400.00")
        try fixture.context.save()

        let service = GeneratedPlanService(context: fixture.context, dateProvider: DashboardFixtures.today)
        let preview = try service.previewFromCurrentInputs()
        let newPlan = try service.activate(preview)

        // A distinct new version, active; the old one still exists, inactive.
        XCTAssertNotEqual(newPlan.id, originalPlan.id)
        XCTAssertNotEqual(newPlan.name, originalName)
        XCTAssertTrue(newPlan.isActive)
        XCTAssertFalse(originalPlan.isActive)
        XCTAssertFalse(newPlan.isOriginalBaseline, "Only the first plan of an install is its baseline.")

        // The old version's every stored value is unchanged.
        XCTAssertEqual(originalPlan.name, originalName)
        XCTAssertEqual(originalPlan.baselineModeledInterest, originalInterest)
        XCTAssertEqual(originalPlan.allowanceCap, TestSupport.money("300.00"))
        let itemsAfter = try TestSupport.planItems(fixture.context, plan: originalPlan)
            .map { [$0.plannedIncome, $0.plannedCardBudget, $0.plannedDebtAfter, $0.plannedC1NoSpendCeiling] }
        XCTAssertEqual(originalItems, itemsAfter)

        // History survives in full.
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<PaydayCheckIn>()), 1)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<LedgerEntry>()), 1)
        XCTAssertGreaterThanOrEqual(
            try fixture.context.fetchCount(FetchDescriptor<Milestone>()),
            milestonesBefore
        )

        // The new version reflects the new allowance.
        XCTAssertEqual(newPlan.allowanceCap, TestSupport.money("400.00"))
        XCTAssertGreaterThan(try TestSupport.planItems(fixture.context, plan: newPlan).count, 0)
    }

    func testActivationAlwaysPicksAFreeName() throws {
        let fixture = try DashboardFixtures.generatedPlan()
        let service = GeneratedPlanService(context: fixture.context, dateProvider: DashboardFixtures.today)

        let second = try service.activate(try service.previewFromCurrentInputs())
        let third = try service.activate(try service.previewFromCurrentInputs())

        let names = try fixture.context.fetch(FetchDescriptor<PlanVersion>()).map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "Plan names never collide.")
        XCTAssertNotEqual(second.name, third.name)
        XCTAssertTrue(third.isActive)
        XCTAssertFalse(second.isActive)
    }

    // MARK: - Legacy plan on the plan screen

    func testLegacyPlanIsViewableExactlyWithoutCalcV2Claims() throws {
        let legacy = try DashboardFixtures.legacyMigrated()
        let data = PlanViewDataLoader.load(
            plan: legacy.plan,
            context: legacy.context,
            environment: DashboardFixtures.environment()
        )

        XCTAssertEqual(data.calculationVersion, 1)
        XCTAssertEqual(data.planName, PlanContract.planName)
        XCTAssertEqual(data.baselineRows.count, PlanContract.paydayCount)
        XCTAssertEqual(data.payoffDate, PlanContract.baselinePayoffDate)
        XCTAssertEqual(data.totalEstimatedInterest, PlanContract.baselineModeledInterest)

        // The first and last stored paydays read exactly as seeded.
        let first = try XCTUnwrap(data.baselineRows.first)
        XCTAssertEqual(first.income, PlanContract.firstIncome)
        XCTAssertEqual(first.keepInSpending, TestSupport.money("400.00"))
        XCTAssertEqual(first.debtBudget, PlanContract.firstCheckCardBudget)
        XCTAssertEqual(first.obligationReserveTotal, PlanContract.totalFixedReserve)
        let last = try XCTUnwrap(data.baselineRows.last)
        XCTAssertEqual(last.sequence, PlanContract.paydayCount)
        XCTAssertEqual(last.debtAfter, .zero)
        XCTAssertEqual(last.endingCash, PlanContract.baselineNoSpendCeiling)

        // No calc-v2-only claims are made about a calc-v1 plan.
        XCTAssertNil(data.interestSaved)
        XCTAssertNotNil(data.minimumOnlyUnavailableReason)
        XCTAssertTrue(data.scenarios.isEmpty)
        XCTAssertNotNil(data.scenarioNote)
    }
}
