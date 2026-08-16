import Foundation
import SwiftData
import XCTest
@testable import PaydayPlaybook

enum TestSupport {
    static let allModels: [any PersistentModel.Type] = [
        PlanVersion.self, IncomeRule.self, DebtAccount.self,
        PaydayPlanItem.self, PlannedCardBalance.self,
        PaydayCheckIn.self, CheckInCardPayment.self,
        LedgerEntry.self, BalanceSnapshot.self, ForecastSnapshot.self,
        NotificationPreference.self, Milestone.self, AppSettings.self,
        CashAccount.self, RecurringObligation.self, UserGoalProfile.self,
        OnboardingProgress.self, IncomeSchedule.self, IncomeChange.self,
        PlannedObligationReserve.self
    ]

    static func makeContainer() throws -> ModelContainer {
        let schema = Schema(allModels)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func money(_ raw: String) -> Decimal {
        Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX"))!
    }

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        DateMath.localDate(year: year, month: month, day: day)
    }

    /// Fixed "today", ten days before the fixture's first payday, so tests
    /// stay deterministic regardless of the wall clock.
    static var fixedToday: FixedDateProvider {
        FixedDateProvider(fixed: date(2054, 8, 10))
    }

    /// Inserts the fictional baseline plan (`DebugBaselineFixture`).
    ///
    /// This used to load the bundled template, which meant every test in the
    /// suite ran against one real person's finances. The fixture's numbers
    /// are invented and its schedule is derived by the shipped calc-v1
    /// engine, so it is internally consistent without describing anyone.
    @discardableResult
    static func seed(
        _ context: ModelContext,
        applySchemaUpgrade: Bool = true
    ) throws -> PlanVersion {
        try DebugBaselineFixture.insertIfNeeded(
            context: context, applySchemaUpgrade: applySchemaUpgrade
        ).planVersion
    }

    /// Number of paydays the fixture's derived schedule contains. Tests that
    /// need "how many checks does this plan have" ask the plan, never a
    /// hard-coded count.
    static func paydayCount(_ context: ModelContext, plan: PlanVersion) throws -> Int {
        try planItems(context, plan: plan).count
    }

    static func planItems(_ context: ModelContext, plan: PlanVersion) throws -> [PaydayPlanItem] {
        let planID = plan.id
        return try context.fetch(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
        ).sorted { $0.sequenceNumber < $1.sequenceNumber }
    }
}
