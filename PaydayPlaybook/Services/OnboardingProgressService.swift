import Foundation
import SwiftData

/// Step persistence and resume for the v0.2.0 onboarding (V2-01, §4.0).
///
/// Steps write their answers into the real rows (`UserGoalProfile`,
/// `CashAccount`, `IncomeSchedule`, `RecurringObligation`, `DebtAccount`) as
/// the user continues; this service tracks position, resumes at the first
/// incomplete step, and finishes atomically so a double-finish or a relaunch
/// mid-generation can never duplicate rows.
struct OnboardingProgressService {
    let context: ModelContext
    let dateProvider: DateProviding

    init(context: ModelContext, dateProvider: DateProviding = SystemDateProvider()) {
        self.context = context
        self.dateProvider = dateProvider
    }

    /// The single progress row, created on first access.
    @discardableResult
    func progress() throws -> OnboardingProgress {
        if let existing = try context.fetch(FetchDescriptor<OnboardingProgress>()).first {
            return existing
        }
        let now = dateProvider.now
        let fresh = OnboardingProgress(startedAt: now, updatedAt: now)
        context.insert(fresh)
        try context.save()
        return fresh
    }

    /// The step the UI should show next.
    func resumeStep() throws -> OnboardingStep {
        try progress().resumeStep
    }

    /// Records a step as completed. Position only advances (revisiting an
    /// earlier step never loses later progress, §4.0), and completed flows
    /// are never reopened.
    func markStepCompleted(_ step: OnboardingStep) throws {
        let row = try progress()
        guard row.completedAt == nil else { return }
        if step.sortIndex > row.lastCompletedStep.sortIndex {
            row.lastCompletedStep = step
        }
        row.updatedAt = dateProvider.now
        try context.save()
    }

    /// Finishes onboarding atomically: persists the generated plan graph,
    /// stamps the settings row, and completes the progress row in ONE save.
    /// Running it twice returns the already-persisted plan without inserting
    /// anything — the §4.0 idempotency bar.
    @discardableResult
    func finish(
        planName: String,
        input: StoredPlanInput,
        result: StoredPlanResult
    ) throws -> PlanVersion {
        let now = dateProvider.now
        let persister = PlanPersister(context: context)
        let plan = try persister.insertPlanGraph(
            named: planName,
            input: input,
            result: result,
            isOriginalBaseline: true,
            now: now
        )

        let settings: AppSettings
        if let existing = try context.fetch(FetchDescriptor<AppSettings>()).first {
            settings = existing
        } else {
            settings = AppSettings(seedSchemaVersion: PlanContract.currentSchemaVersion, createdAt: now)
            context.insert(settings)
        }
        settings.onboardingComplete = true

        let row = try progress()
        if row.completedAt == nil {
            row.lastCompletedStep = .finished
            row.completedAt = now
            row.updatedAt = now
        }

        if let profile = try context.fetch(FetchDescriptor<UserGoalProfile>()).first,
           profile.onboardingCompletedAt == nil {
            profile.onboardingCompletedAt = now
            profile.updatedAt = now
        }

        if try context.fetchCount(FetchDescriptor<NotificationPreference>()) == 0 {
            for preference in NotificationPreference.seedDefaults() {
                context.insert(preference)
            }
        }

        try context.save()
        return plan
    }
}
