import XCTest
@testable import PaydayPlaybook

/// T-21 (V4-04): the single R-12 implementation, pinned at the contract
/// level, plus the V4-01 semantic predicate the validation surfaces share.
final class UtilizationMathTests: XCTestCase {

    // MARK: - Unknown stays unknown (never 0%)

    func testNilLimitIsUnknown() {
        XCTAssertNil(UtilizationMath.utilization(balance: Decimal(string: "950")!, limit: nil))
    }

    func testZeroLimitIsUnknown() {
        XCTAssertNil(UtilizationMath.utilization(balance: Decimal(string: "950")!, limit: 0))
    }

    func testNegativeLimitIsUnknown() {
        XCTAssertNil(UtilizationMath.utilization(balance: Decimal(string: "950")!, limit: Decimal(string: "-100")!))
    }

    // MARK: - Exact Decimal ratios

    func testExactRatio() {
        let value = UtilizationMath.utilization(
            balance: Decimal(string: "950")!, limit: Decimal(string: "1000")!
        )
        XCTAssertEqual(value, Decimal(string: "0.95")!)
    }

    func testZeroBalanceIsZeroPercentOnlyWhenTrulyZero() {
        XCTAssertEqual(
            UtilizationMath.utilization(balance: 0, limit: Decimal(string: "1000")!),
            0
        )
    }

    func testOverLimitExceedsOne() {
        let value = UtilizationMath.utilization(
            balance: Decimal(string: "1100")!, limit: Decimal(string: "1000")!
        )
        XCTAssertEqual(value, Decimal(string: "1.1")!)
    }

    // MARK: - Thresholds declared once

    func testThresholdConstants() {
        XCTAssertEqual(UtilizationMath.informationalThreshold, Decimal(string: "0.3")!)
        XCTAssertEqual(UtilizationMath.attentionThreshold, Decimal(string: "0.9")!)
    }

    // MARK: - Model convenience forwards to the canonical implementation

    func testCardForwardsToCanonicalMath() {
        let card = DebtAccount(
            planID: "A", displayName: "Test Card", startingBalance: Decimal(string: "950")!,
            apr: Decimal(string: "0.2399")!, priority: 1,
            debtType: .creditCard, creditLimit: Decimal(string: "1000")!
        )
        XCTAssertEqual(
            card.utilization(currentBalance: Decimal(string: "950")!),
            Decimal(string: "0.95")!
        )
    }

    func testNonCardNeverHasUtilization() {
        let loan = DebtAccount(
            planID: "B", displayName: "Test Loan", startingBalance: Decimal(string: "5000")!,
            apr: Decimal(string: "0.06")!, priority: 2,
            debtType: .autoLoan, creditLimit: Decimal(string: "1000")!
        )
        XCTAssertNil(loan.utilization(currentBalance: Decimal(string: "5000")!))
    }

    // MARK: - V4-01: the shared original-principal predicate

    func testOriginalPrincipalRelevancePerType() {
        XCTAssertFalse(DebtType.creditCard.usesOriginalPrincipal)
        XCTAssertTrue(DebtType.personalLoan.usesOriginalPrincipal)
        XCTAssertTrue(DebtType.autoLoan.usesOriginalPrincipal)
        XCTAssertTrue(DebtType.studentLoan.usesOriginalPrincipal)
        XCTAssertTrue(DebtType.medicalDebt.usesOriginalPrincipal)
        XCTAssertTrue(DebtType.other.usesOriginalPrincipal)
    }

    func testPresentationForwardsToSemanticPredicate() {
        for type in DebtType.allCases {
            XCTAssertEqual(type.showsOriginalPrincipal, type.usesOriginalPrincipal)
        }
    }
}
