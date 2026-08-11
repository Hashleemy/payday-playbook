import XCTest
import SwiftData
@testable import PaydayPlaybook

/// V2-04 / V2-05: every debt type with its own rules, and due-date edits
/// persisting prospectively without touching any baseline value.
final class DebtTypeTests: XCTestCase {

    // MARK: - Per-type validation (§4.7 field matrix)

    private func validate(
        type: DebtType,
        minimum: Decimal? = TestSupport.money("50.00"),
        creditLimit: Decimal? = nil,
        dueDay: Int? = 15,
        lastFour: String? = nil,
        balance: Decimal = TestSupport.money("1000.00"),
        apr: Decimal = TestSupport.money("0.1999")
    ) throws {
        try ModelValidation.validateDebt(
            type: type, displayName: "Test debt", currentBalance: balance,
            originalPrincipal: nil, apr: apr, minimumAmount: minimum,
            creditLimit: creditLimit, dueDayOfMonth: dueDay, lastFour: lastFour
        )
    }

    func testEveryTypeCreatesWithItsOwnRules() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        for (index, type) in DebtType.allCases.enumerated() {
            let debt = DebtAccount(
                planID: "T\(index)", displayName: type.displayName,
                startingBalance: TestSupport.money("1000.00"),
                apr: TestSupport.money("0.1000"),
                minimumAmount: type.requiresEnteredMinimum ? TestSupport.money("50.00") : nil,
                priority: index, debtType: type,
                creditLimit: type.supportsCreditLimit ? TestSupport.money("5000.00") : nil
            )
            context.insert(debt)
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<DebtAccount>())
        XCTAssertEqual(fetched.count, DebtType.allCases.count)
        XCTAssertEqual(Set(fetched.map(\.debtType)), Set(DebtType.allCases))
        for debt in fetched where debt.debtType != .creditCard {
            XCTAssertNil(debt.creditLimit)
            XCTAssertNotNil(debt.minimumAmount)
        }
    }

    func testCreditCardMayLeaveMinimumBlank() throws {
        try validate(type: .creditCard, minimum: nil)
    }

    func testInstallmentTypesRequireEnteredMinimum() {
        for type in DebtType.allCases where type.requiresEnteredMinimum {
            XCTAssertThrowsError(try validate(type: type, minimum: nil), "\(type)") { error in
                XCTAssertEqual(error as? ModelValidationError, .missingMinimum(type))
            }
            XCTAssertThrowsError(try validate(type: type, minimum: .zero), "\(type)") { error in
                XCTAssertEqual(error as? ModelValidationError, .missingMinimum(type))
            }
        }
    }

    func testCreditLimitOnlyOnCards() throws {
        try validate(type: .creditCard, creditLimit: TestSupport.money("8000.00"))
        for type in DebtType.allCases where !type.supportsCreditLimit {
            XCTAssertThrowsError(
                try validate(type: type, creditLimit: TestSupport.money("8000.00")), "\(type)"
            ) { error in
                XCTAssertEqual(error as? ModelValidationError, .creditLimitOnNonCard(type))
            }
        }
    }

    func testZeroAPRIsAllowedNegativeIsNot() throws {
        try validate(type: .medicalDebt, apr: .zero)
        XCTAssertThrowsError(try validate(type: .medicalDebt, apr: TestSupport.money("-0.01")))
    }

    func testDueDayBoundsAndLastFourPrivacy() throws {
        try validate(type: .creditCard, dueDay: 31)
        XCTAssertThrowsError(try validate(type: .creditCard, dueDay: 0))
        XCTAssertThrowsError(try validate(type: .creditCard, dueDay: 32))
        try validate(type: .creditCard, lastFour: "1234")
        XCTAssertThrowsError(try validate(type: .creditCard, lastFour: "12345")) { error in
            XCTAssertEqual(error as? ModelValidationError, .lastFourInvalid)
        }
        XCTAssertThrowsError(try validate(type: .creditCard, lastFour: "12a4"))
    }

    // MARK: - Display helpers

    func testUtilizationOnlyWithACardLimit() {
        let card = DebtAccount(
            planID: "U", displayName: "Card", startingBalance: TestSupport.money("3000.00"),
            apr: TestSupport.money("0.2499"), priority: 1,
            debtType: .creditCard, creditLimit: TestSupport.money("10000.00")
        )
        XCTAssertEqual(card.utilization(currentBalance: TestSupport.money("3000.00")), TestSupport.money("0.3"))
        card.creditLimit = nil
        XCTAssertNil(card.utilization(currentBalance: TestSupport.money("3000.00")))

        let loan = DebtAccount(
            planID: "L", displayName: "Loan", startingBalance: TestSupport.money("3000.00"),
            apr: TestSupport.money("0.07"), minimumAmount: TestSupport.money("200.00"),
            priority: 2, debtType: .autoLoan
        )
        XCTAssertNil(loan.utilization(currentBalance: TestSupport.money("3000.00")))
    }

    func testPrincipalBasisFallsBackToStartingBalance() {
        let debt = DebtAccount(
            planID: "P", displayName: "Loan", startingBalance: TestSupport.money("4200.00"),
            apr: TestSupport.money("0.06"), minimumAmount: TestSupport.money("120.00"),
            priority: 1, debtType: .studentLoan
        )
        XCTAssertEqual(debt.principalBasis, TestSupport.money("4200.00"))
        debt.originalPrincipal = TestSupport.money("10000.00")
        XCTAssertEqual(debt.principalBasis, TestSupport.money("10000.00"))
    }

    func testDerivedStatus() {
        let debt = DebtAccount(
            planID: "S", displayName: "Card", startingBalance: TestSupport.money("100.00"),
            apr: TestSupport.money("0.20"), priority: 1
        )
        XCTAssertEqual(debt.status(isPaidOff: false), .active)
        XCTAssertEqual(debt.status(isPaidOff: true), .paidOff)
        debt.isArchived = true
        XCTAssertEqual(debt.status(isPaidOff: true), .archived)
    }

    // MARK: - Due-date edits are prospective (V2-11 data layer)

    func testDueDayEditPersistsWithoutTouchingBaseline() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context)
        let plan = try XCTUnwrap(PlanSeeder.existingBaseline(context: context))
        let itemsBefore = try TestSupport.planItems(context, plan: plan)
            .map { ($0.date, $0.plannedCardBudget, $0.plannedTargetDebtID) }

        let debt = try XCTUnwrap(context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        XCTAssertNil(debt.dueDayOfMonth)
        debt.dueDayOfMonth = 27
        debt.updatedAt = TestSupport.fixedToday.now
        try context.save()

        // Persists across "relaunch"…
        let fresh = ModelContext(container)
        let reloaded = try XCTUnwrap(fresh.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" })
        XCTAssertEqual(reloaded.dueDayOfMonth, 27)

        // …and no baseline plan value moved (prospective only).
        let itemsAfter = try TestSupport.planItems(fresh, plan: plan)
            .map { ($0.date, $0.plannedCardBudget, $0.plannedTargetDebtID) }
        XCTAssertEqual(itemsBefore.map(\.0), itemsAfter.map(\.0))
        XCTAssertEqual(itemsBefore.map(\.1), itemsAfter.map(\.1))
        XCTAssertEqual(itemsBefore.map(\.2), itemsAfter.map(\.2))
    }
}
