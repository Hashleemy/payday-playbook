import Foundation

/// The single R-12 implementation (V4-04). Every utilization a user can see —
/// badges, insights, plan rows, engine results, onboarding previews — routes
/// through this one function, so the same card can never read differently on
/// two screens.
///
/// The rules it encodes:
/// - utilization is current revolving balance ÷ credit limit, in exact
///   `Decimal` — never integer math, never binary floating point;
/// - a missing or non-positive limit means "unknown", expressed as nil —
///   never 0%;
/// - a balance above the limit is a real state and yields a value above 1;
/// - original principal is never an input.
enum UtilizationMath {
    /// At or above this, utilization is informational (R-12/A-07). Declared
    /// once; every badge, insight, and engine level consumes it.
    static let informationalThreshold = Decimal(string: "0.3")!
    /// At or above this, utilization needs attention (R-12/A-07).
    static let attentionThreshold = Decimal(string: "0.9")!

    /// `balance ÷ limit`, or nil when no positive limit exists. Full
    /// `Decimal` precision; callers round only at display boundaries.
    static func utilization(balance: Decimal, limit: Decimal?) -> Decimal? {
        guard let limit, limit > 0 else { return nil }
        return balance / limit
    }

    /// The one display rounding for a utilization ratio: nearest whole
    /// percent, "<1%" for a non-zero ratio that would otherwise read as a
    /// false 0%, values above the limit rendered past 100%, and negative
    /// (overpayment/correction) balances clamped to 0%.
    ///
    /// Never route the ratio through `NSDecimalNumber.intValue` /
    /// `Int(truncating:)`: a full-width division mantissa (any
    /// non-terminating balance ÷ limit) garbles it — 948.27 ÷ 950.00 came
    /// back as 0, which is the "0% of limit" defect this replaces (V4-04).
    static func wholePercentString(_ utilization: Decimal) -> String {
        guard utilization > 0 else { return "0%" }
        var scaled = utilization * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded > 0 else { return "<1%" }
        return "\(rounded)%"
    }
}
