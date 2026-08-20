import XCTest
@testable import PaydayPlaybook

/// T-21 (V4-04): the canonical display rounding, pinned on the exact inputs
/// of the reported "0% of limit" defect.
///
/// Root cause of that defect: the badge formatted the percent with
/// `Int(truncating: (utilization * 100) as NSDecimalNumber)`. A terminating
/// ratio (850 ÷ 1000) survives that, but any non-terminating balance ÷ limit
/// division carries a full-width 38-digit mantissa, and `NSDecimalNumber`'s
/// integer accessor garbles it — 948.27 ÷ 950.00 came back as 0. Cards close
/// to their limit almost always divide non-terminating, which is why the
/// nonsense clustered there. These tests pin the replacement.
final class UtilizationDisplayTests: XCTestCase {

    private func ratio(_ balance: String, _ limit: String) -> Decimal {
        UtilizationMath.utilization(
            balance: Decimal(string: balance)!,
            limit: Decimal(string: limit)!
        )!
    }

    // MARK: - The regression pin: near-limit balances never read 0%

    func testNearLimitNonTerminatingRatioNeverRendersZeroPercent() {
        // The defect's shape: a non-terminating division truncated to "0%".
        XCTAssertEqual(UtilizationMath.wholePercentString(ratio("948.27", "950.00")), "100%")
        XCTAssertEqual(UtilizationMath.wholePercentString(ratio("933.10", "935.00")), "100%")
        XCTAssertEqual(UtilizationMath.wholePercentString(ratio("2847.99", "2900")), "98%")
    }

    // MARK: - Contract cases

    func testCleanRatioRendersExactWholePercent() {
        XCTAssertEqual(UtilizationMath.wholePercentString(ratio("850", "1000")), "85%")
    }

    func testFractionalRatioKeepsFullPrecisionUntilDisplay() {
        // The helper itself never pre-rounds: the raw ratio round-trips to
        // the cent, and only the display string rounds.
        let value = ratio("850.33", "1000.50")
        XCTAssertEqual((value * Decimal(string: "1000.50")!).rounded2, Decimal(string: "850.33")!)
        XCTAssertEqual(UtilizationMath.wholePercentString(value), "85%")
    }

    func testZeroBalanceWithValidLimitIsZeroPercent() {
        XCTAssertEqual(UtilizationMath.wholePercentString(ratio("0", "1000")), "0%")
    }

    func testOverLimitRendersAboveOneHundredPercent() {
        XCTAssertEqual(UtilizationMath.wholePercentString(ratio("1234.56", "1000")), "123%")
        XCTAssertEqual(UtilizationDisplayLevel.level(for: ratio("1234.56", "1000")), .critical)
    }

    func testSmallNonZeroRatioRendersUnderOnePercentNeverFalseZero() {
        XCTAssertEqual(UtilizationMath.wholePercentString(ratio("4", "1000")), "<1%")
        XCTAssertEqual(UtilizationMath.wholePercentString(ratio("0.04", "1000")), "<1%")
        // Half a percent and up rounds to the nearest whole percent.
        XCTAssertEqual(UtilizationMath.wholePercentString(ratio("5", "1000")), "1%")
    }

    func testNegativeCorrectionBalanceClampsToZeroPercent() {
        XCTAssertEqual(UtilizationMath.wholePercentString(ratio("-50", "1000")), "0%")
    }

    func testRoundsToNearestNeverTruncates() {
        // 99.9% must not truncate down to 99 silently different from its
        // rounded value — nearest whole percent, half away from zero.
        XCTAssertEqual(UtilizationMath.wholePercentString(ratio("999.99", "1000")), "100%")
        XCTAssertEqual(UtilizationMath.wholePercentString(ratio("994", "1000")), "99%")
    }

    // MARK: - Warnings consume the same canonical value

    func testDisplayLevelBoundariesAreTheCanonicalThresholds() {
        XCTAssertEqual(UtilizationDisplayLevel.level(for: UtilizationMath.informationalThreshold), .elevated)
        XCTAssertEqual(UtilizationDisplayLevel.level(for: UtilizationMath.attentionThreshold), .critical)
        XCTAssertEqual(UtilizationDisplayLevel.level(for: UtilizationMath.informationalThreshold - Decimal(string: "0.0001")!), .ok)
        XCTAssertEqual(UtilizationDisplayLevel.level(for: UtilizationMath.attentionThreshold - Decimal(string: "0.0001")!), .elevated)
    }

    func testWarningAndBadgeAgreeOnTheDefectInput() {
        // The reported inconsistency: a "needs attention" warning beside a
        // percentage that contradicted it. One value now feeds both.
        let value = ratio("948.27", "950.00")
        XCTAssertEqual(UtilizationDisplayLevel.level(for: value), .critical)
        XCTAssertGreaterThanOrEqual(value, UtilizationMath.attentionThreshold)
        XCTAssertEqual(UtilizationMath.wholePercentString(value), "100%")
    }
}
