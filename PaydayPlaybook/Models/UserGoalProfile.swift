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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// MVP_LAYOUT §6 names this model `UserProfile`; the storage type is
/// `UserGoalProfile`. Either name resolves to the same model.
typealias UserProfile = UserGoalProfile
