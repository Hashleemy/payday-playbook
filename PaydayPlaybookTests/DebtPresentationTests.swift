import XCTest
import SwiftData
@testable import PaydayPlaybook

/// V2-04 / V2-05 / R-12: every debt type renders with its own vocabulary, and
/// utilization is shown only when a real limit exists.
@MainActor
final class DebtPresentationTests: XCTestCase {

    // MARK: - Type-specific labels

    func testEveryDebtTypeHasItsOwnLabelsAndIcon() {
        for type in DebtType.allCases {
            XCTAssertFalse(type.displayName.isEmpty)
            XCTAssertFalse(type.iconSystemName.isEmpty)
            XCTAssertFalse(type.minimumLabel.isEmpty)
            XCTAssertFalse(type.dueDayLabel.isEmpty)
        }

        // Cards keep the 0.1.x vocabulary; nothing else is called a card.
        XCTAssertEqual(DebtType.creditCard.shortReference(planID: "B"), "Card B")
        XCTAssertEqual(DebtType.autoLoan.shortReference(planID: "C"), "Car note / auto loan")
        XCTAssertEqual(DebtType.studentLoan.shortReference(planID: "D"), "Student loan")
        XCTAssertEqual(DebtType.medicalDebt.shortReference(planID: "E"), "Medical debt")
        XCTAssertEqual(DebtType.personalLoan.shortReference(planID: "F"), "Personal loan")
        XCTAssertEqual(DebtType.other.shortReference(planID: "G"), "Other")

        XCTAssertEqual(DebtType.creditCard.minimumLabel, "Minimum payment")
        XCTAssertEqual(DebtType.autoLoan.minimumLabel, "Contractual payment")
        XCTAssertEqual(DebtType.creditCard.dueDayLabel, "Statement due day")
        XCTAssertEqual(DebtType.studentLoan.dueDayLabel, "Payment due day")
        XCTAssertEqual(DebtType.creditCard.balanceLabel, "Current balance")
        XCTAssertEqual(DebtType.personalLoan.balanceLabel, "Remaining principal")

        // Only installment debt shows an original-principal row.
        XCTAssertFalse(DebtType.creditCard.showsOriginalPrincipal)
        for type in DebtType.allCases where type != .creditCard {
            XCTAssertTrue(type.showsOriginalPrincipal, "\(type) should show original principal.")
        }

        // Icons are distinct enough to distinguish types at a glance.
        XCTAssertEqual(Set(DebtType.allCases.map(\.iconSystemName)).count, DebtType.allCases.count)
    }

    func testAllSixTypesSurviveGenerationAndRenderInThePlan() throws {
        let specs: [DashboardFixtures.DebtSpec] = [
            .init(planID: "A", name: "Blue Card", type: .creditCard,
                  balance: TestSupport.money("1000.00"), apr: TestSupport.money("0.2999"),
                  minimum: TestSupport.money("35.00"), dueDay: 12,
                  creditLimit: TestSupport.money("2000.00"), originalPrincipal: nil),
            .init(planID: "B", name: "Signature Loan", type: .personalLoan,
                  balance: TestSupport.money("3000.00"), apr: TestSupport.money("0.1200"),
                  minimum: TestSupport.money("150.00"), dueDay: 3, creditLimit: nil,
                  originalPrincipal: TestSupport.money("5000.00")),
            .init(planID: "C", name: "Car Note", type: .autoLoan,
                  balance: TestSupport.money("8500.00"), apr: TestSupport.money("0.0649"),
                  minimum: TestSupport.money("320.00"), dueDay: 8, creditLimit: nil,
                  originalPrincipal: TestSupport.money("14000.00")),
            .init(planID: "D", name: "Student Loan", type: .studentLoan,
                  balance: TestSupport.money("6200.00"), apr: TestSupport.money("0.0499"),
                  minimum: TestSupport.money("145.00"), dueDay: 21, creditLimit: nil,
                  originalPrincipal: TestSupport.money("9000.00")),
            .init(planID: "E", name: "Clinic Bill", type: .medicalDebt,
                  balance: TestSupport.money("1200.00"), apr: .zero,
                  minimum: TestSupport.money("50.00"), dueDay: nil, creditLimit: nil,
                  originalPrincipal: nil),
            .init(planID: "F", name: "Family Loan", type: .other,
                  balance: TestSupport.money("2000.00"), apr: TestSupport.money("0.0300"),
                  minimum: TestSupport.money("100.00"), dueDay: 15, creditLimit: nil,
                  originalPrincipal: TestSupport.money("2500.00"))
        ]
        let fixture = try DashboardFixtures.generatedPlan(debtSpecs: specs)
        let data = PlanViewDataLoader.load(
            plan: fixture.plan,
            context: fixture.context,
            environment: DashboardFixtures.environment()
        )

        XCTAssertEqual(data.debtRows.count, 6)
        XCTAssertEqual(Set(data.debtRows.map(\.debtType)), Set(DebtType.allCases))
        for row in data.debtRows {
            XCTAssertFalse(row.name.isEmpty)
            XCTAssertGreaterThan(row.currentBalance, .zero)
            XCTAssertEqual(row.priority, data.debtRows.firstIndex(where: { $0.id == row.id })! + 1)
        }

        // Every type also reaches the dashboard's target/reference vocabulary.
        let state = TodayState.load(context: fixture.context, environment: DashboardFixtures.environment())
        XCTAssertEqual(state.debtBalances.count, 6)
        XCTAssertEqual(Set(state.debtBalances.map(\.debt.debtType)), Set(DebtType.allCases))
    }

    // MARK: - Utilization boundaries

    func testUtilizationBoundariesMatchTheR12Thresholds() {
        XCTAssertEqual(UtilizationDisplayLevel.level(for: TestSupport.money("0.2999")), .ok)
        XCTAssertEqual(UtilizationDisplayLevel.level(for: TestSupport.money("0.30")), .elevated)
        XCTAssertEqual(UtilizationDisplayLevel.level(for: TestSupport.money("0.8999")), .elevated)
        XCTAssertEqual(UtilizationDisplayLevel.level(for: TestSupport.money("0.90")), .critical)
        XCTAssertEqual(UtilizationDisplayLevel.level(for: TestSupport.money("1.50")), .critical)
        XCTAssertEqual(UtilizationDisplayLevel.level(for: .zero), .ok)
    }

    func testUtilizationIsWithheldWithoutARealLimit() throws {
        let noLimit = DebtAccount(
            planID: "A", displayName: "Store Card",
            startingBalance: TestSupport.money("500.00"), apr: TestSupport.money("0.25"),
            priority: 1, debtType: .creditCard, creditLimit: nil
        )
        XCTAssertNil(noLimit.utilization(currentBalance: TestSupport.money("500.00")))

        let zeroLimit = DebtAccount(
            planID: "B", displayName: "Odd Card",
            startingBalance: TestSupport.money("500.00"), apr: TestSupport.money("0.25"),
            priority: 2, debtType: .creditCard, creditLimit: .zero
        )
        XCTAssertNil(zeroLimit.utilization(currentBalance: TestSupport.money("500.00")),
                     "A zero limit never divides by zero, and never shows a number.")

        let loanWithLimit = DebtAccount(
            planID: "C", displayName: "Car Note",
            startingBalance: TestSupport.money("500.00"), apr: TestSupport.money("0.06"),
            minimumAmount: TestSupport.money("100.00"), priority: 3,
            debtType: .autoLoan, creditLimit: TestSupport.money("1000.00")
        )
        XCTAssertNil(loanWithLimit.utilization(currentBalance: TestSupport.money("500.00")),
                     "Utilization is a credit-card concept only.")
    }

    func testUtilizationOverTheLimitStillRendersAsANumber() {
        let overLimit = DebtAccount(
            planID: "A", displayName: "Maxed Card",
            startingBalance: TestSupport.money("2400.00"), apr: TestSupport.money("0.25"),
            priority: 1, debtType: .creditCard, creditLimit: TestSupport.money("2000.00")
        )
        let utilization = overLimit.utilization(currentBalance: TestSupport.money("2400.00"))
        XCTAssertEqual(utilization, TestSupport.money("1.2"))
        XCTAssertEqual(UtilizationDisplayLevel.level(for: try! XCTUnwrap(utilization)), .critical)
    }

    // MARK: - Percent paid uses the principal basis

    func testPercentPaidBasisFallsBackToTheStartingBalance() {
        let withOriginal = DebtAccount(
            planID: "C", displayName: "Car Note",
            startingBalance: TestSupport.money("8500.00"), apr: TestSupport.money("0.0649"),
            minimumAmount: TestSupport.money("320.00"), priority: 1,
            debtType: .autoLoan, originalPrincipal: TestSupport.money("14000.00")
        )
        XCTAssertEqual(withOriginal.principalBasis, TestSupport.money("14000.00"))

        let withoutOriginal = DebtAccount(
            planID: "A", displayName: "Blue Card",
            startingBalance: TestSupport.money("1049.00"), apr: TestSupport.money("0.2999"),
            priority: 2, debtType: .creditCard
        )
        XCTAssertEqual(withoutOriginal.principalBasis, TestSupport.money("1049.00"),
                       "A missing original principal is never fabricated.")
    }

    // MARK: - APR formatting

    func testAPRFormattingIsSharedAndExact() {
        XCTAssertEqual(DebtFormat.aprText(TestSupport.money("0.2999")), "29.99%")
        XCTAssertEqual(DebtFormat.aprText(.zero), "0%")
        XCTAssertEqual(DebtFormat.aprText(TestSupport.money("0.0649")), "6.49%")
    }
}
