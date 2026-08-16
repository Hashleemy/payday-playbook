import Foundation
import SwiftData
@testable import PaydayPlaybook

/// Fictional stores for the portability and report suites (V3-12 fixture
/// policy).
///
/// Every value here is invented: round numbers, a first payday far in the
/// future, and names that read as placeholders. Nothing describes a real
/// person's finances, and nothing is derived from anything that did.
enum PortabilityFixtures {

    static let today = TestSupport.date(2054, 3, 2)
    static var dateProvider: FixedDateProvider { FixedDateProvider(fixed: today) }

    /// A complete modern (schema-3) setup: two accounts, a biweekly income
    /// schedule, two bills, three debts, and a goal profile with every
    /// scenario constraint stated so all three scenarios are computable.
    @discardableResult
    static func modernSetup(
        _ context: ModelContext,
        statingScenarioConstraints: Bool = true
    ) throws -> Setup {
        let spending = CashAccount(
            name: "Everyday checking",
            currentBalance: TestSupport.money("2400.00"),
            roles: [.income, .spending],
            isDefaultIncome: true,
            sortOrder: 0,
            protectedAmount: TestSupport.money("500.00"),
            balanceAsOf: today,
            createdAt: today,
            updatedAt: today
        )
        let reserves = CashAccount(
            name: "Bills and reserves",
            currentBalance: TestSupport.money("1200.00"),
            roles: [.reserves],
            sortOrder: 1,
            createdAt: today,
            updatedAt: today
        )
        context.insert(spending)
        context.insert(reserves)

        let schedule = IncomeSchedule(
            cadence: .biweekly,
            anchorPayday: TestSupport.date(2054, 3, 6),
            destinationAccountID: spending.id,
            baseTakeHome: TestSupport.money("2000.00"),
            createdAt: today,
            updatedAt: today
        )
        context.insert(schedule)

        let rent = RecurringObligation(
            name: "Housing",
            amount: TestSupport.money("1100.00"),
            cadence: .monthly,
            dueDay: 1,
            accountID: reserves.id,
            createdAt: today,
            updatedAt: today
        )
        let transit = RecurringObligation(
            name: "Transit pass",
            amount: TestSupport.money("90.00"),
            cadence: .monthly,
            dueDay: 15,
            accountID: reserves.id,
            createdAt: today,
            updatedAt: today
        )
        context.insert(rent)
        context.insert(transit)

        let debts = [
            debt(planID: "D1", name: "Blue card", balance: "3200.00", apr: "0.2199",
                 minimum: "80.00", dueDay: 12, priority: 1, type: .creditCard),
            debt(planID: "D2", name: "Green card", balance: "1450.00", apr: "0.1749",
                 minimum: "45.00", dueDay: 20, priority: 2, type: .creditCard),
            debt(planID: "D3", name: "Auto loan", balance: "6800.00", apr: "0.0625",
                 minimum: "230.00", dueDay: 5, priority: 3, type: .autoLoan)
        ]
        debts.forEach(context.insert)

        let profile = UserGoalProfile(
            goalText: "Clear the cards, then the car",
            targetDebtFreeDate: TestSupport.date(2057, 6, 1),
            posture: .steady,
            protectedFloor: TestSupport.money("500.00"),
            allowanceCap: TestSupport.money("150.00"),
            onboardingCompletedAt: today,
            createdAt: today,
            updatedAt: today
        )
        if statingScenarioConstraints {
            profile.minimumProtectedCash = TestSupport.money("300.00")
            profile.plannedSavingsPerPaycheck = TestSupport.money("100.00")
            profile.additionalCushionReserve = TestSupport.money("75.00")
            profile.extraPaymentCeiling = TestSupport.money("400.00")
            profile.zeroAllowanceConfirmedAt = today
        }
        context.insert(profile)

        context.insert(AppSettings(
            onboardingComplete: true,
            seedSchemaVersion: PlanContract.currentSchemaVersion,
            createdAt: today
        ))
        context.insert(NotificationPreference(
            type: .paydayMorning, enabled: true, hour: 8, minute: 0,
            leadDays: 0, detailedLockScreenContent: false
        ))
        context.insert(NotificationPreference(
            type: .obligationDueSoon, enabled: true, hour: 18, minute: 30,
            leadDays: 2, detailedLockScreenContent: false
        ))

        try context.save()
        return Setup(
            spending: spending, reserves: reserves, schedule: schedule,
            bills: [rent, transit], debts: debts, profile: profile
        )
    }

    struct Setup {
        let spending: CashAccount
        let reserves: CashAccount
        let schedule: IncomeSchedule
        let bills: [RecurringObligation]
        let debts: [DebtAccount]
        let profile: UserGoalProfile
    }

    static func debt(
        planID: String,
        name: String,
        balance: String,
        apr: String,
        minimum: String?,
        dueDay: Int?,
        priority: Int,
        type: DebtType
    ) -> DebtAccount {
        DebtAccount(
            planID: planID,
            displayName: name,
            startingBalance: TestSupport.money(balance),
            apr: TestSupport.money(apr),
            minimumAmount: minimum.map(TestSupport.money),
            dueDayOfMonth: dueDay,
            priority: priority,
            createdAt: today,
            updatedAt: today,
            debtType: type
        )
    }

    /// Adds recorded history so a backup has activity to round-trip and a
    /// template has something it must refuse to carry.
    static func addHistory(_ context: ModelContext, setup: Setup) throws {
        context.insert(LedgerEntry(
            effectiveDate: TestSupport.date(2054, 2, 20),
            type: .cardPayment,
            amount: TestSupport.money("120.00"),
            debtAccountID: setup.debts[0].id,
            debtPlanID: setup.debts[0].planID,
            note: "February payment",
            provenance: .user
        ))
        context.insert(BalanceSnapshot(
            debtAccountID: setup.debts[0].id,
            debtPlanID: setup.debts[0].planID,
            effectiveDate: TestSupport.date(2054, 2, 20),
            amount: TestSupport.money("3200.00"),
            sourceType: .currentOnlineBalance
        ))
        let cashSnapshot = BalanceSnapshot(
            effectiveDate: TestSupport.date(2054, 2, 20),
            amount: TestSupport.money("2400.00"),
            sourceType: .userEntry
        )
        cashSnapshot.cashAccountID = setup.spending.id
        context.insert(cashSnapshot)
        try context.save()
    }

    /// A store with a plan generated from `modernSetup`, so report sections
    /// that need a plan have one.
    @discardableResult
    static func setupWithPlan(_ context: ModelContext) throws -> Setup {
        let setup = try modernSetup(context)
        // Through the app's own activation path, so the fixture's plan graph
        // is shaped exactly like one a user would have.
        let service = GeneratedPlanService(context: context, dateProvider: dateProvider)
        try service.activate(service.previewFromCurrentInputs())
        try context.save()
        return setup
    }

    // MARK: - Documents

    /// Re-encodes a document with one payload mutation applied, for the
    /// corruption and tamper cases.
    static func mutatedBackupJSON(
        _ context: ModelContext,
        _ mutate: (inout [String: Any]) -> Void
    ) throws -> Data {
        let data = try ExportService.encodeBackup(try ExportService.buildBackup(context: context))
        var object = try XCTUnwrapDictionary(data)
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func XCTUnwrapDictionary(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "PortabilityFixtures", code: 1)
        }
        return object
    }
}
