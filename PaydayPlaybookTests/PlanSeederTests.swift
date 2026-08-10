import XCTest
import SwiftData
@testable import PaydayPlaybook

/// Required tests 4–6, 10 and F-01/F-06 seeding acceptance.
final class PlanSeederTests: XCTestCase {

    func testSeedProducesExactPlanGraph() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let plan = try TestSupport.seed(context)

        XCTAssertTrue(plan.isOriginalBaseline)
        XCTAssertEqual(plan.name, "Original Plan v1")
        XCTAssertEqual(plan.firstPayday, TestSupport.date(2026, 8, 20))
        XCTAssertEqual(plan.payFrequencyDays, 14)
        XCTAssertEqual(plan.startingChecking1, TestSupport.money("900.00"))
        XCTAssertEqual(plan.protectedBuffer, TestSupport.money("1000.00"))
        XCTAssertEqual(plan.allowanceCap, TestSupport.money("300.00"))
        XCTAssertEqual(plan.carReservePerCheck, TestSupport.money("335.08"))
        XCTAssertEqual(plan.trainReservePerCheck, TestSupport.money("51.23"))
        XCTAssertEqual(plan.totalFixedReservePerCheck, TestSupport.money("386.31"))
        XCTAssertEqual(plan.baselinePayoffDate, TestSupport.date(2027, 6, 24))
        XCTAssertEqual(plan.baselineModeledInterest, TestSupport.money("3461.16"))
        XCTAssertEqual(plan.baselineNoSpendCeiling, TestSupport.money("7900.00"))
        XCTAssertEqual(plan.avalancheOrder, ["B", "D", "A", "F", "C", "E"])

        let debts = try context.fetch(FetchDescriptor<DebtAccount>())
            .sorted { $0.priority < $1.priority }
        XCTAssertEqual(debts.count, 6)
        XCTAssertEqual(debts.map(\.planID), ["B", "D", "A", "F", "C", "E"])
        let total = debts.reduce(Decimal.zero) { $0 + $1.startingBalance }
        XCTAssertEqual(total, TestSupport.money("29681.61"))
        XCTAssertEqual(debts.first?.apr, TestSupport.money("0.2999"))

        let items = try TestSupport.planItems(context, plan: plan)
        XCTAssertEqual(items.count, 23)
        XCTAssertEqual(items.first?.date, TestSupport.date(2026, 8, 20))
        XCTAssertEqual(items.last?.date, TestSupport.date(2027, 6, 24))
        XCTAssertEqual(items.last?.plannedDebtAfter, 0)

        // Per-card planned balances exist for every payday.
        let planned = try context.fetch(FetchDescriptor<PlannedCardBalance>())
        XCTAssertEqual(planned.count, 23 * 6)

        // Income rules: $2,094 from Aug 20, $2,190 from Dec 10.
        let planID = plan.id
        let rules = try context.fetch(
            FetchDescriptor<IncomeRule>(predicate: #Predicate { $0.planVersionID == planID })
        ).sorted { $0.effectiveDate < $1.effectiveDate }
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0].effectiveDate, TestSupport.date(2026, 8, 20))
        XCTAssertEqual(rules[0].netPaycheckAmount, TestSupport.money("2094.00"))
        XCTAssertEqual(rules[1].effectiveDate, TestSupport.date(2026, 12, 10))
        XCTAssertEqual(rules[1].netPaycheckAmount, TestSupport.money("2190.00"))

        // Milestones: 6 card payoffs, 5 amount thresholds, 1 debt-free.
        let milestones = try context.fetch(FetchDescriptor<Milestone>())
        XCTAssertEqual(milestones.filter { $0.type == .cardPaidOff }.count, 6)
        XCTAssertEqual(milestones.filter { $0.type == .amountEliminated }.count, 5)
        XCTAssertEqual(milestones.filter { $0.type == .debtFree }.count, 1)
    }

    // Required test 4: first check keeps $400, transfers $1,694, reserves
    // $386.31, budgets $1,307.69.
    func testFirstCheckAllocations() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let plan = try TestSupport.seed(context)
        let items = try TestSupport.planItems(context, plan: plan)
        let first = try XCTUnwrap(items.first)
        XCTAssertEqual(first.plannedC1Keep, TestSupport.money("400.00"))
        XCTAssertEqual(first.plannedBufferAdd, TestSupport.money("100.00"))
        XCTAssertEqual(first.plannedC2Transfer, TestSupport.money("1694.00"))
        XCTAssertEqual(first.plannedCarReserve + first.plannedTrainReserve, TestSupport.money("386.31"))
        XCTAssertEqual(first.plannedCardBudget, TestSupport.money("1307.69"))
        XCTAssertEqual(first.plannedTargetDebtID, "B")
        XCTAssertEqual(first.plannedDebtAfter, TestSupport.money("28665.71"))
        XCTAssertEqual(first.plannedC1NoSpendCeiling, TestSupport.money("1300.00"))
    }

    // Required test 5: checks 2–8 budget $1,407.69 to cards.
    func testChecks2Through8Budget() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let plan = try TestSupport.seed(context)
        let items = try TestSupport.planItems(context, plan: plan)
        for item in items where (2...8).contains(item.sequenceNumber) {
            XCTAssertEqual(item.plannedCardBudget, TestSupport.money("1407.69"), "check \(item.sequenceNumber)")
            XCTAssertEqual(item.plannedIncome, TestSupport.money("2094.00"), "check \(item.sequenceNumber)")
        }
    }

    // Required test 6: Dec 10, 2026 income becomes $2,190, budget $1,503.69.
    func testDecemberIncomeChange() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let plan = try TestSupport.seed(context)
        let items = try TestSupport.planItems(context, plan: plan)
        let ninth = try XCTUnwrap(items.first { $0.sequenceNumber == 9 })
        XCTAssertEqual(ninth.date, TestSupport.date(2026, 12, 10))
        XCTAssertEqual(ninth.plannedIncome, TestSupport.money("2190.00"))
        XCTAssertEqual(ninth.plannedCardBudget, TestSupport.money("1503.69"))
    }

    // Required test 10: the no-spend ceiling reaches $7,900 and climbs $300/check.
    func testNoSpendCeilingProgression() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let plan = try TestSupport.seed(context)
        let items = try TestSupport.planItems(context, plan: plan)
        for (index, item) in items.enumerated() {
            let expected = TestSupport.money("1300.00") + Decimal(index) * TestSupport.money("300.00")
            XCTAssertEqual(item.plannedC1NoSpendCeiling, expected, "check \(item.sequenceNumber)")
        }
        XCTAssertEqual(items.last?.plannedC1NoSpendCeiling, TestSupport.money("7900.00"))
    }

    // F-01: seeding twice produces no duplicates.
    func testSeedIsIdempotent() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context)
        let second = try PlanSeeder.seedIfNeeded(context: context)
        XCTAssertTrue(second.wasAlreadySeeded)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DebtAccount>()), 6)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PaydayPlanItem>()), 23)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlannedCardBalance>()), 23 * 6)
    }

    // F-01: an interrupted seed (partial graph) is replaced, not duplicated.
    func testInterruptedSeedRecovers() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let plan = try TestSupport.seed(context)

        // Simulate a crash that lost most payday rows.
        let items = try TestSupport.planItems(context, plan: plan)
        for item in items.dropFirst(3) { context.delete(item) }
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PaydayPlanItem>()), 3)

        let recovered = try PlanSeeder.seedIfNeeded(context: context)
        XCTAssertFalse(recovered.wasAlreadySeeded)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PaydayPlanItem>()), 23)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DebtAccount>()), 6)
    }

    // Seed data persists across "relaunches" (new contexts on one store).
    func testSeedPersistsAcrossContexts() throws {
        let container = try TestSupport.makeContainer()
        let first = ModelContext(container)
        try TestSupport.seed(first)

        let second = ModelContext(container)
        XCTAssertEqual(try second.fetchCount(FetchDescriptor<PaydayPlanItem>()), 23)
        XCTAssertEqual(try second.fetchCount(FetchDescriptor<DebtAccount>()), 6)
    }

    // The bundled JSON is validated against the plan contract; a tampered
    // resource must be rejected before insertion.
    func testTamperedSeedResourceFailsValidation() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "OriginalPlanV1", withExtension: "json"))
        let original = try String(contentsOf: url, encoding: .utf8)
        let tampered = original.replacingOccurrences(of: "\"1049.00\"", with: "\"1049.10\"")
        XCTAssertNotEqual(original, tampered)
        let seed = try JSONDecoder().decode(SeedPlan.self, from: Data(tampered.utf8))
        XCTAssertThrowsError(try SeedPlanLoader.validate(seed)) { error in
            guard case SeedPlanError.validationFailed = error else {
                return XCTFail("Expected validationFailed, got \(error)")
            }
        }
    }

    // Baseline plan rows match the engine's documented headline values and the
    // planned per-card balances agree with the seeded totals.
    func testPlannedPerCardBalancesSumToPlannedTotals() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let plan = try TestSupport.seed(context)
        let items = try TestSupport.planItems(context, plan: plan)
        let planned = try context.fetch(FetchDescriptor<PlannedCardBalance>())
        let byItem = Dictionary(grouping: planned, by: \.paydayPlanItemID)
        for item in items {
            let rows = byItem[item.id] ?? []
            XCTAssertEqual(rows.count, 6, "check \(item.sequenceNumber)")
            let sum = rows.reduce(Decimal.zero) { $0 + $1.balanceAfter }
            // Documented per-card cents differ from the documented total by at
            // most a cent on some rows (source-table rounding artifact).
            let delta = abs((sum - item.plannedDebtAfter).asDouble)
            XCTAssertLessThanOrEqual(delta, 0.02, "check \(item.sequenceNumber)")
        }
    }
}
