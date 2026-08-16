import Foundation
import SwiftData

/// How aggressively the user wants to pay debt down (V2-02). Postures shape
/// suggested defaults and dashboard copy only — never post-generation math.
enum PayoffPosture: String, Codable, CaseIterable, Identifiable {
    case fullThrottle
    case steady
    case cushionFirst

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fullThrottle: return "Full throttle"
        case .steady: return "Steady"
        case .cushionFirst: return "Cushion first"
        }
    }
}

/// The user's goal, posture, and money guardrails captured in onboarding
/// (V2-02, V2-08, V2-09). The floor and allowance here are the user's current
/// settings; each generated `PlanVersion` freezes its own copy at generation.
@Model
final class UserGoalProfile {
    var id: UUID = UUID()
    /// Free-text goal, e.g. "debt-free before the wedding". Optional.
    var goalText: String?
    /// Optional target debt-free date; drives the R-13 goal-gap insight only.
    var targetDebtFreeDate: Date?
    var postureRaw: String = PayoffPosture.steady.rawValue
    /// Protected never-go-below floor on the spending account.
    var protectedFloor: Decimal = Decimal.zero
    /// Per-paycheck personal allowance cap — available, never assumed spent.
    var allowanceCap: Decimal = Decimal.zero
    /// Set when onboarding finished (or by migration for upgraded installs).
    var onboardingCompletedAt: Date?

    // MARK: - Schema-3 scenario inputs (V3-05)
    //
    // All optional with zero/nil defaults. An upgraded install reads exactly
    // as it did before until the user states one of these; nothing here is
    // inferred from existing data.

    /// Cash the plan must never spend down past, across all accounts. Distinct
    /// from `protectedFloor`, which is the single spending account's floor.
    var minimumProtectedCash: Decimal = Decimal.zero
    /// Savings the user intends to set aside each paycheck before debt attack.
    var plannedSavingsPerPaycheck: Decimal = Decimal.zero
    /// One-off cushion held back on top of the floor.
    var additionalCushionReserve: Decimal = Decimal.zero
    /// Upper bound the user accepts on a single extra payment. Zero means
    /// unset, not "no extra payments allowed".
    var extraPaymentCeiling: Decimal = Decimal.zero
    /// When the user explicitly confirmed a zero allowance. Without this, a
    /// zero allowance is indistinguishable from never having been asked, and
    /// the plan must not treat silence as consent to spend nothing.
    var zeroAllowanceConfirmedAt: Date?

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var posture: PayoffPosture {
        get { PayoffPosture(rawValue: postureRaw) ?? .steady }
        set { postureRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        goalText: String? = nil,
        targetDebtFreeDate: Date? = nil,
        posture: PayoffPosture = .steady,
        protectedFloor: Decimal = .zero,
        allowanceCap: Decimal = .zero,
        onboardingCompletedAt: Date? = nil,
        minimumProtectedCash: Decimal = .zero,
        plannedSavingsPerPaycheck: Decimal = .zero,
        additionalCushionReserve: Decimal = .zero,
        extraPaymentCeiling: Decimal = .zero,
        zeroAllowanceConfirmedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.goalText = goalText
        self.targetDebtFreeDate = targetDebtFreeDate
        self.postureRaw = posture.rawValue
        self.protectedFloor = protectedFloor
        self.allowanceCap = allowanceCap
        self.onboardingCompletedAt = onboardingCompletedAt
        self.minimumProtectedCash = minimumProtectedCash
        self.plannedSavingsPerPaycheck = plannedSavingsPerPaycheck
        self.additionalCushionReserve = additionalCushionReserve
        self.extraPaymentCeiling = extraPaymentCeiling
        self.zeroAllowanceConfirmedAt = zeroAllowanceConfirmedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// MVP_LAYOUT §6 names this model `UserProfile`; the storage type is
/// `UserGoalProfile`. Either name resolves to the same model.
typealias UserProfile = UserGoalProfile
