import Foundation
import SwiftData

/// Ordered onboarding steps (V2-01). Raw values are persisted; the order is
/// given by `sortIndex` so cases can be renamed only with a data migration.
///
/// The sequence follows the v0.2.0 onboarding mission: welcome → goal (with
/// floor and allowance folded in) → accounts → debts → income → obligations →
/// reminders preview → review → generate. This supersedes MVP_LAYOUT §4's
/// step table (income/obligations/floor before debts, notifications after
/// review) — recorded as a deviation in the Agent 4 report, not a silent
/// edit.
enum OnboardingStep: String, Codable, CaseIterable, Identifiable {
    case none
    case welcome
    case goals
    case accounts
    case debts
    case income
    case obligations
    case notifications
    case review
    case finished
    /// Schema-3 combined bills-and-debts step (V3-01). Declared here so the
    /// raw value is persistable now; it is deliberately **not** in
    /// `flowOrder` yet — see the note there.
    case billsAndDebts

    var id: String { rawValue }

    /// The traversal order, stated explicitly rather than derived from
    /// `allCases`.
    ///
    /// Declaring a case and scheduling it are separate decisions. A resume
    /// position is persisted user data: if traversal were `allCases`, adding
    /// any case would silently move every later step's index and could land a
    /// half-onboarded user on a different screen than the one they left. An
    /// explicit list means a new case is inert until someone puts it in the
    /// sequence on purpose — which is the onboarding owner's call, not the
    /// schema's.
    static let flowOrder: [OnboardingStep] = [
        .none, .welcome, .goals, .accounts, .debts,
        .income, .obligations, .notifications, .review, .finished
    ]

    var sortIndex: Int {
        OnboardingStep.flowOrder.firstIndex(of: self) ?? OnboardingStep.flowOrder.count
    }

    /// The step to resume at when this is the last completed step.
    var next: OnboardingStep {
        let all = OnboardingStep.flowOrder
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
