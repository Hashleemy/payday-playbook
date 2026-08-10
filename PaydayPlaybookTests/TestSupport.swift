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
        NotificationPreference.self, Milestone.self, AppSettings.self
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

    /// Fixed "today" of Aug 10, 2026 — after the plan was written, before the
    /// first payday — so tests stay deterministic regardless of the wall clock.
    static var fixedToday: FixedDateProvider {
        FixedDateProvider(fixed: date(2026, 8, 10))
    }

    @discardableResult
    static func seed(_ context: ModelContext) throws -> PlanVersion {
        try PlanSeeder.seedIfNeeded(context: context).planVersion
    }

    static func planItems(_ context: ModelContext, plan: PlanVersion) throws -> [PaydayPlanItem] {
        let planID = plan.id
        return try context.fetch(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
        ).sorted { $0.sequenceNumber < $1.sequenceNumber }
    }
}
