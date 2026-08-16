import Foundation
import SwiftData
@testable import PaydayPlaybook

/// Production-shaped v0.2 stores for the dashboard/plan/debt suites: a real
/// onboarding-style setup (accounts, income, obligations, debts) run through
/// the real generator and the real persister — never hand-built plan rows.
@MainActor
enum DashboardFixtures {

    /// "Today" for these fixtures: after setup, before the first payday.
    static var today: FixedDateProvider { FixedDateProvider(fixed: TestSupport.date(2054, 8, 10)) }

    static func environment() -> AppEnvironment {
        AppEnvironment(dateProvider: today)
    }

    struct Generated {
        let container: ModelContainer
        let context: ModelContext
        let plan: PlanVersion
        let debts: [DebtAccount]
        let spending: CashAccount
        let reserves: CashAccount
    }

    /// A plan generated through the real service — so it carries whatever
    /// calculation version the release stamps — built from a mixed-type
    /// debt portfolio:
    /// a credit card with a limit, a card without one, an auto loan, a
    /// student loan, a medical debt (0% APR, minimums only), and an "other".
    static func generatedPlan(
        debtSpecs: [DebtSpec] = DebtSpec.mixedPortfolio,
        allowanceCap: Decimal = TestSupport.money("300.00"),
        protectedFloor: Decimal = TestSupport.money("1500.00"),
        takeHome: Decimal = TestSupport.money("2400.00")
    ) throws -> Generated {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let now = today.now

        let accounts = CashAccountRepository(context: context)
        let spending = try accounts.create(
            name: "Everyday Checking",
            currentBalance: TestSupport.money("1500.00"),
            roles: [.income, .spending],
            now: now
        )
        let reserves = try accounts.create(
            name: "Bills & Debt",
            currentBalance: .zero,
            roles: [.reserves],
            now: now
        )

        let profile = UserGoalProfile(
            goalText: "Debt-free before the move",
            posture: .steady,
            protectedFloor: protectedFloor,
            allowanceCap: allowanceCap,
            createdAt: now,
            updatedAt: now
        )
        context.insert(profile)

        let schedule = IncomeSchedule(
            cadence: .biweekly,
            anchorPayday: TestSupport.date(2054, 8, 20),
            destinationAccountID: spending.id,
            baseTakeHome: takeHome,
            createdAt: now,
            updatedAt: now
        )
        context.insert(schedule)

        let rent = RecurringObligation(
            name: "Rent",
            amount: TestSupport.money("700.00"),
            cadence: .monthly,
            dueDay: 1,
            accountID: reserves.id,
            createdAt: now,
            updatedAt: now
        )
        context.insert(rent)
        let transit = RecurringObligation(
            name: "Transit pass",
            amount: TestSupport.money("150.00"),
            cadence: .monthly,
            dueDay: 5,
            accountID: reserves.id,
            createdAt: now,
            updatedAt: now
        )
        context.insert(transit)

        var debts: [DebtAccount] = []
        for (index, spec) in debtSpecs.enumerated() {
            let debt = DebtAccount(
                planID: spec.planID,
                displayName: spec.name,
                startingBalance: spec.balance,
                apr: spec.apr,
                minimumAmount: spec.minimum,
                dueDayOfMonth: spec.dueDay,
                priority: index + 1,
                createdAt: now.addingTimeInterval(Double(index)),
                updatedAt: now,
                debtType: spec.type,
                originalPrincipal: spec.originalPrincipal,
                creditLimit: spec.creditLimit,
                isExtraPrincipalEligible: spec.extraEligible
            )
            context.insert(debt)
            debts.append(debt)
        }
        try context.save()

        let service = GeneratedPlanService(context: context, dateProvider: today)
        let preview = try service.previewFromCurrentInputs()
        let plan = try service.activate(preview)

        return Generated(
            container: container,
            context: context,
            plan: plan,
            debts: debts,
            spending: spending,
            reserves: reserves
        )
    }

    struct DebtSpec {
        var planID: String
        var name: String
        var type: DebtType
        var balance: Decimal
        var apr: Decimal
        var minimum: Decimal?
        var dueDay: Int?
        var creditLimit: Decimal?
        var originalPrincipal: Decimal?
        var extraEligible: Bool = true

        /// One of every supported type, including the display edge cases:
        /// a card with a limit, a card without, and a 0% minimums-only debt.
        static let mixedPortfolio: [DebtSpec] = [
            DebtSpec(planID: "A", name: "Blue Card", type: .creditCard,
                     balance: TestSupport.money("1100.00"), apr: TestSupport.money("0.2600"),
                     minimum: nil, dueDay: 12, creditLimit: TestSupport.money("2000.00"),
                     originalPrincipal: nil),
            DebtSpec(planID: "B", name: "Store Card", type: .creditCard,
                     balance: TestSupport.money("800.00"), apr: TestSupport.money("0.2200"),
                     minimum: nil, dueDay: 20, creditLimit: nil, originalPrincipal: nil),
            DebtSpec(planID: "C", name: "Car Note", type: .autoLoan,
                     balance: TestSupport.money("8500.00"), apr: TestSupport.money("0.0649"),
                     minimum: TestSupport.money("320.00"), dueDay: 8, creditLimit: nil,
                     originalPrincipal: TestSupport.money("14000.00")),
            DebtSpec(planID: "D", name: "Student Loan", type: .studentLoan,
                     balance: TestSupport.money("6200.00"), apr: TestSupport.money("0.0499"),
                     minimum: TestSupport.money("145.00"), dueDay: 21, creditLimit: nil,
                     originalPrincipal: TestSupport.money("9000.00")),
            DebtSpec(planID: "E", name: "Clinic Bill", type: .medicalDebt,
                     balance: TestSupport.money("1700.00"), apr: .zero,
                     minimum: TestSupport.money("50.00"), dueDay: nil, creditLimit: nil,
                     originalPrincipal: nil, extraEligible: false),
            DebtSpec(planID: "F", name: "Family Loan", type: .other,
                     balance: TestSupport.money("2000.00"), apr: TestSupport.money("0.0300"),
                     minimum: TestSupport.money("100.00"), dueDay: 15, creditLimit: nil,
                     originalPrincipal: TestSupport.money("2500.00"))
        ]

        /// Cards only, with every minimum entered — supports the minimums-only
        /// comparison the engine withholds for incomplete installment input.
        static let cardsOnly: [DebtSpec] = [
            DebtSpec(planID: "A", name: "Blue Card", type: .creditCard,
                     balance: TestSupport.money("1100.00"), apr: TestSupport.money("0.2600"),
                     minimum: TestSupport.money("35.00"), dueDay: 12,
                     creditLimit: TestSupport.money("2000.00"), originalPrincipal: nil),
            DebtSpec(planID: "B", name: "Store Card", type: .creditCard,
                     balance: TestSupport.money("2400.00"), apr: TestSupport.money("0.2200"),
                     minimum: TestSupport.money("60.00"), dueDay: 20,
                     creditLimit: TestSupport.money("3000.00"), originalPrincipal: nil)
        ]
    }

    /// A migrated 0.1.x store: Original Plan v1 exactly as the seeder writes
    /// it, upgraded through the real migration path.
    static func legacyMigrated() throws -> (container: ModelContainer, context: ModelContext, plan: PlanVersion) {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let plan = try TestSupport.seed(context, applySchemaUpgrade: false)
        let settings = try context.fetch(FetchDescriptor<AppSettings>()).first
        settings?.seedSchemaVersion = 1
        try context.save()
        _ = try MigrationService.migrateIfNeeded(context: context, dateProvider: today)
        return (container, context, plan)
    }
}
