import XCTest
import SwiftData
@testable import PaydayPlaybook

/// The Agent 2 ↔ Agent 3 boundary: R-04 smoothing, money-exact DTO coding,
/// deterministic input snapshots, and R-08 ordering at persistence.
final class PlanningContractTests: XCTestCase {

    // MARK: - R-04 smoothing (required test 1)

    func testSmoothingReproducesLemsReserves() {
        XCTAssertEqual(
            ObligationMath.perPaycheckReserve(amount: TestSupport.money("726.00"), cadence: .monthly, paychecksPerYear: 26),
            TestSupport.money("335.08")
        )
        XCTAssertEqual(
            ObligationMath.perPaycheckReserve(amount: TestSupport.money("111.00"), cadence: .monthly, paychecksPerYear: 26),
            TestSupport.money("51.23")
        )
    }

    func testSmoothingAcrossCadencesToTheCent() {
        // Weekly obligation, biweekly pay: 50 × 52 / 26 = 100.00
        XCTAssertEqual(
            ObligationMath.perPaycheckReserve(amount: TestSupport.money("50.00"), cadence: .weekly, paychecksPerYear: 26),
            TestSupport.money("100.00")
        )
        // Quarterly, biweekly: 300 × 4 / 26 = 46.1538… → 46.15
        XCTAssertEqual(
            ObligationMath.perPaycheckReserve(amount: TestSupport.money("300.00"), cadence: .quarterly, paychecksPerYear: 26),
            TestSupport.money("46.15")
        )
        // Semiannual, monthly pay: 240 × 2 / 12 = 40.00
        XCTAssertEqual(
            ObligationMath.perPaycheckReserve(amount: TestSupport.money("240.00"), cadence: .semiannual, paychecksPerYear: 12),
            TestSupport.money("40.00")
        )
        // Annual, weekly pay: 520 × 1 / 52 = 10.00
        XCTAssertEqual(
            ObligationMath.perPaycheckReserve(amount: TestSupport.money("520.00"), cadence: .annual, paychecksPerYear: 52),
            TestSupport.money("10.00")
        )
        // Monthly, semimonthly pay: 100 × 12 / 24 = 50.00
        XCTAssertEqual(
            ObligationMath.perPaycheckReserve(amount: TestSupport.money("100.00"), cadence: .monthly, paychecksPerYear: 24),
            TestSupport.money("50.00")
        )
        // Biweekly obligation, monthly pay: 80 × 26 / 12 = 173.333… → 173.33
        XCTAssertEqual(
            ObligationMath.perPaycheckReserve(amount: TestSupport.money("80.00"), cadence: .biweekly, paychecksPerYear: 12),
            TestSupport.money("173.33")
        )
    }

    func testPaychecksPerYearMatchesR03() {
        XCTAssertEqual(PayCadence.weekly.paychecksPerYear, 52)
        XCTAssertEqual(PayCadence.biweekly.paychecksPerYear, 26)
        XCTAssertEqual(PayCadence.semimonthly.paychecksPerYear, 24)
        XCTAssertEqual(PayCadence.monthly.paychecksPerYear, 12)
    }

    // MARK: - Money-exact DTO coding

    private func sampleInput() -> StoredPlanInput {
        StoredPlanInput(
            calculationVersion: 2,
            cadence: .semimonthly,
            monthlyPayDay: nil,
            semimonthlyPayDay1: 1,
            semimonthlyPayDay2: 31,
            nextPayday: TestSupport.date(2026, 9, 1),
            baseTakeHome: TestSupport.money("2094.00"),
            incomeChanges: [
                PlanningIncomeChange(effectiveDate: TestSupport.date(2026, 12, 10), amount: TestSupport.money("2190.00"))
            ],
            spendingStartingBalance: TestSupport.money("900.00"),
            protectedFloor: TestSupport.money("1000.00"),
            allowanceCap: TestSupport.money("300.00"),
            firstCheckBufferAdd: TestSupport.money("100.00"),
            obligations: [
                PlanningObligation(id: UUID(), name: "Car", amount: TestSupport.money("726.00"), cadence: .monthly, dueDay: nil)
            ],
            debts: [
                PlanningDebt(
                    id: UUID(), displayID: "B", name: "Card B", debtType: .creditCard,
                    currentBalance: TestSupport.money("1049.00"), apr: TestSupport.money("0.2999"),
                    minimumAmount: nil, isExtraPrincipalEligible: true,
                    creditLimit: nil, dueDayOfMonth: nil, originalPrincipal: nil
                ),
                PlanningDebt(
                    id: UUID(), displayID: "L", name: "Loan", debtType: .personalLoan,
                    currentBalance: TestSupport.money("0.10"), apr: TestSupport.money("0.0725"),
                    minimumAmount: TestSupport.money("17.50"), isExtraPrincipalEligible: false,
                    creditLimit: nil, dueDayOfMonth: 31, originalPrincipal: TestSupport.money("5000.00")
                )
            ],
            paycheckCap: 600,
            timeZoneID: "America/New_York"
        )
    }

    func testPlanningInputRoundTripsExactly() throws {
        let input = sampleInput()
        let data = try PlanningSnapshotCoder.encode(input)
        let decoded = try PlanningSnapshotCoder.decode(data)
        XCTAssertEqual(decoded, input)
        // The classic binary-float traps survive exactly.
        XCTAssertEqual(decoded.debts[0].apr, TestSupport.money("0.2999"))
        XCTAssertEqual(decoded.debts[1].currentBalance, TestSupport.money("0.10"))

        // Money is encoded as strings, never JSON numbers.
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"0.2999\""))
        XCTAssertTrue(json.contains("\"2094\"") || json.contains("\"2094.00\""))
    }

    func testSnapshotEncodingIsDeterministic() throws {
        let input = sampleInput()
        XCTAssertEqual(try PlanningSnapshotCoder.encode(input), try PlanningSnapshotCoder.encode(input))
    }

    func testPlanningResultRoundTripsExactly() throws {
        let payday = PlanningPayday(
            sequence: 1, date: TestSupport.date(2026, 9, 1),
            income: TestSupport.money("2094.00"),
            keepInSpending: TestSupport.money("400.00"),
            transferToReserves: TestSupport.money("1694.00"),
            allowance: TestSupport.money("300.00"),
            floorTopUp: TestSupport.money("100.00"),
            obligationReserves: [PlanningObligationReserve(obligationID: UUID(), amount: TestSupport.money("335.08"))],
            debtBudget: TestSupport.money("1307.69"),
            targetDebtID: "B",
            perDebtBalancesAfter: ["B": .zero, "D": TestSupport.money("4987.00")],
            totalDebtAfter: TestSupport.money("28665.71"),
            noSpendCeiling: TestSupport.money("1300.00"),
            shortfallAmount: TestSupport.money("84.00")
        )
        let result = StoredPlanResult(
            calculationVersion: 2,
            paydays: [payday],
            payoffDate: nil,
            totalEstimatedInterest: TestSupport.money("3461.16"),
            paycheckCount: 1,
            debtPayoffs: [PlanningDebtPayoff(debtID: "B", payoffDate: TestSupport.date(2026, 9, 1))],
            cappedAtPaycheckLimit: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StoredPlanResult.self, from: encoder.encode(result))
        XCTAssertEqual(decoded, result)
        XCTAssertNil(decoded.payoffDate)
        XCTAssertTrue(decoded.cappedAtPaycheckLimit)
        XCTAssertEqual(decoded.paydays[0].perDebtBalancesAfter["D"], TestSupport.money("4987.00"))
        XCTAssertEqual(decoded.paydays[0].shortfallAmount, TestSupport.money("84.00"))
    }

    // MARK: - R-08 ordering at persistence

    func testAvalancheOrderPersistedPerR08() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)

        func debt(_ id: String, apr: String, balance: String) -> PlanningDebt {
            PlanningDebt(
                id: UUID(), displayID: id, name: id, debtType: .personalLoan,
                currentBalance: TestSupport.money(balance), apr: TestSupport.money(apr),
                minimumAmount: TestSupport.money("25.00"), isExtraPrincipalEligible: true,
                creditLimit: nil, dueDayOfMonth: nil, originalPrincipal: nil
            )
        }
        var input = sampleInput()
        input.debts = [
            debt("zero", apr: "0", balance: "100.00"),      // 0% sorts last
            debt("lowTie", apr: "0.20", balance: "50.00"),  // tie → lower balance first
            debt("highTie", apr: "0.20", balance: "500.00"),
            debt("top", apr: "0.29", balance: "9000.00")
        ]
        let result = StoredPlanResult(
            calculationVersion: 2, paydays: [], payoffDate: nil,
            totalEstimatedInterest: .zero, paycheckCount: 0,
            debtPayoffs: [], cappedAtPaycheckLimit: false
        )
        let plan = try PlanPersister(context: context).insertPlanGraph(
            named: "Order test", input: input, result: result, isOriginalBaseline: false
        )
        try context.save()
        XCTAssertEqual(plan.avalancheOrder, ["top", "lowTie", "highTie", "zero"])
    }
}
