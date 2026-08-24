import SwiftUI

// MARK: - Debt-type vocabulary (V2-04, V2-05)
//
// One place for every user-visible label that varies by debt type, so cards
// keep the 0.1.x "Card B" language while loans, student debt, and medical
// debt read in their own words.

extension DebtType {
    var iconSystemName: String {
        switch self {
        case .creditCard: return "creditcard.fill"
        case .personalLoan: return "banknote"
        case .autoLoan: return "car.fill"
        case .studentLoan: return "graduationcap.fill"
        case .medicalDebt: return "cross.case.fill"
        case .other: return "doc.text.fill"
        }
    }

    /// Short reference line for lists: cards keep the 0.1.x "Card B" form,
    /// other types read as their kind.
    func shortReference(planID: String) -> String {
        switch self {
        case .creditCard: return "Card \(planID)"
        default: return displayName
        }
    }

    /// Label for the balance figure (cards) versus remaining principal
    /// (installment debt).
    var balanceLabel: String {
        self == .creditCard ? "Current balance" : "Remaining principal"
    }

    var minimumLabel: String {
        self == .creditCard ? "Minimum payment" : "Contractual payment"
    }

    var dueDayLabel: String {
        self == .creditCard ? "Statement due day" : "Payment due day"
    }

    /// Whether the original-principal row is meaningful for this type.
    /// Forwards to the semantic model-layer predicate (V4-01) so editors,
    /// chips, and the completeness service can never disagree.
    var showsOriginalPrincipal: Bool {
        usesOriginalPrincipal
    }
}

// MARK: - Utilization badge (R-12)

/// Display-only utilization level; consumes the canonical R-12 thresholds
/// (< 30% ok, ≥ 30% informational, ≥ 90% needs attention) so a badge can
/// never warn at a level the engine or an insight would not (V4-04).
enum UtilizationDisplayLevel {
    case ok
    case elevated
    case critical

    static func level(for utilization: Decimal) -> UtilizationDisplayLevel {
        if utilization >= UtilizationMath.attentionThreshold { return .critical }
        if utilization >= UtilizationMath.informationalThreshold { return .elevated }
        return .ok
    }
}

/// A small capsule showing credit-card utilization with an accessible label.
/// Rendered only when a positive credit limit exists (never invents one).
/// Meaning is carried by the text, not only the color.
struct UtilizationBadge: View {
    let utilization: Decimal

    private var level: UtilizationDisplayLevel { .level(for: utilization) }

    private var percentText: String {
        "\(UtilizationMath.wholePercentString(utilization)) of limit"
    }

    private var color: Color {
        switch level {
        case .ok: return .secondary
        case .elevated: return .orange
        case .critical: return Color(red: 0.94, green: 0.45, blue: 0.40)
        }
    }

    private var caption: String {
        switch level {
        case .ok: return percentText
        case .elevated: return "\(percentText) — above 30%"
        case .critical: return "\(percentText) — needs attention"
        }
    }

    var body: some View {
        Text(caption)
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(level == .ok ? Color.secondary : color)
            .accessibilityLabel("Credit utilization \(caption)")
    }
}

// MARK: - Shared APR formatting

enum DebtFormat {
    /// "29.99%" — shared APR formatter (stored APRs are fractions).
    static func aprText(_ apr: Decimal) -> String {
        "\((apr * 100) as NSDecimalNumber)%"
    }
}
