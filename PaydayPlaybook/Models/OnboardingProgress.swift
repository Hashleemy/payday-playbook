import Foundation
import SwiftData

/// Ordered onboarding steps (V2-01). Raw values are persisted; the order is
/// given by `sortIndex` so cases can be renamed only with a data migration.
enum OnboardingStep: String, Codable, CaseIterable, Identifiable {
    case none
    case welcome
    case goals
    case accounts
    case income
    case obligations
    case floorAndAllowance
    case debts
    case review
    case notifications
    case finished

    var id: String { rawValue }

    var sortIndex: Int {
        OnboardingStep.allCases.firstIndex(of: self) ?? 0
    }

    /// The step to resume at when this is the last completed step.
    var next: OnboardingStep {
        let all = OnboardingStep.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return .finished }
        return all[index + 1]
    }
}

/// Persisted onboarding progress (V2-01). Steps write their answers into the
/// real rows (`UserGoalProfile`, `CashAccount`, `IncomeSchedule`,
/// `RecurringObligation`, `DebtAccount`) as the user continues, so resuming
/// re-reads the store and duplicates are structurally impossible; this row
/// only tracks position and completion.
@Model
final class OnboardingProgress {
    var id: UUID = UUID()
    var lastCompletedStepRaw: String = OnboardingStep.none.rawValue
    var startedAt: Date = Date()
    var updatedAt: Date = Date()
    /// Set exactly once, atomically with plan generation.
    var completedAt: Date?

    var lastCompletedStep: OnboardingStep {
        get { OnboardingStep(rawValue: lastCompletedStepRaw) ?? .none }
        set { lastCompletedStepRaw = newValue.rawValue }
    }

    var resumeStep: OnboardingStep {
        completedAt == nil ? lastCompletedStep.next : .finished
    }

    init(
        id: UUID = UUID(),
        lastCompletedStep: OnboardingStep = .none,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.lastCompletedStepRaw = lastCompletedStep.rawValue
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

/// MVP_LAYOUT §6 names this model `OnboardingState`; the storage type is
/// `OnboardingProgress`. Either name resolves to the same model.
typealias OnboardingState = OnboardingProgress
