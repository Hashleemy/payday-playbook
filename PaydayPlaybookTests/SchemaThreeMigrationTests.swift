import XCTest
import SwiftData
@testable import PaydayPlaybook

/// T-1 (MVP_LAYOUT §7): the schema 2 → 3 upgrade preserves every existing
/// record, is idempotent across repeated launches, and adds only defaults.
final class SchemaThreeMigrationTests: XCTestCase {

    /// A store as v0.2.0 left it: fully migrated to schema 2, with the user's
    /// own accounts, obligations, profile, and activity.
    private func makeSchemaTwoStore() throws -> (ModelContainer, ModelContext) {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context, applySchemaUpgrade: false)

        // Run only the 1 → 2 step, then stamp as v0.2.0 would have.
        try MigrationService.applyLogicalUpgrade(context: context, dateProvider: TestSupport.fixedToday)
        let settings = try XCTUnwrap(context.fetch(FetchDescriptor<AppSettings>()).first)
        settings.seedSchemaVersion = 2
        settings.onboardingComplete = true
        try context.save()
        return (container, context)
    }

    // MARK: - Routing

    func testSchemaTwoStoreIsDetectedAndUpgradedToThree() throws {
        let (_, context) = try makeSchemaTwoStore()
        XCTAssertEqual(try MigrationService.detectInstallState(context: context), .needsMigration(from: 2))

        let summary = try MigrationService.migrateIfNeeded(
            context: context, dateProvider: TestSupport.fixedToday
        )
        XCTAssertTrue(summary.didMigrate)
        // The 1 → 2 work was already done; this run only does the 2 → 3 step.
        XCTAssertEqual(summary.accountsCreated, 0)
        XCTAssertEqual(summary.obligationsCreated, 0)

        XCTAssertEqual(try MigrationService.detectInstallState(context: context), .upToDate)
        let settings = try XCTUnwrap(context.fetch(FetchDescriptor<AppSettings>()).first)
        XCTAssertEqual(settings.seedSchemaVersion, 3)
        XCTAssertNotNil(settings.migratedAt)
        XCTAssertNotNil(settings.migrationAuditNote)
    }

    // MARK: - Preservation

    func testEveryExistingRecordSurvivesUnchanged() throws {
        let (_, context) = try makeSchemaTwoStore()

        func fingerprint() throws -> [String] {
            var out: [String] = []
            let plan = try XCTUnwrap(PlanRepository.legacyBaseline(context: context))
            for item in try PlanRepository.planItems(context: context, plan: plan) {
                out.append("payday:\(item.sequenceNumber):\(item.plannedIncome):"
                    + "\(item.plannedCardBudget):\(item.plannedDebtAfter)")
            }
            for debt in try context.fetch(FetchDescriptor<DebtAccount>()).sorted(by: { $0.priority < $1.priority }) {
                out.append("debt:\(debt.planID):\(debt.startingBalance):\(debt.apr)")
            }
            for account in try context.fetch(FetchDescriptor<CashAccount>()).sorted(by: { $0.sortOrder < $1.sortOrder }) {
                out.append("account:\(account.name):\(account.currentBalance):\(account.rolesRaw)")
            }
            for obligation in try context.fetch(FetchDescriptor<RecurringObligation>()).sorted(by: { $0.name < $1.name }) {
                out.append("obligation:\(obligation.name):\(obligation.amount)")
            }
            for entry in try context.fetch(FetchDescriptor<LedgerEntry>()).sorted(by: { $0.amount < $1.amount }) {
                out.append("ledger:\(entry.typeRaw):\(entry.amount)")
            }
            for snapshot in try context.fetch(FetchDescriptor<BalanceSnapshot>()).sorted(by: { $0.amount < $1.amount }) {
                out.append("snapshot:\(snapshot.amount)")
            }
            for checkIn in try context.fetch(FetchDescriptor<PaydayCheckIn>()) {
                out.append("checkIn:\(checkIn.statusRaw)")
            }
            for preference in try context.fetch(FetchDescriptor<NotificationPreference>()).sorted(by: { $0.typeRaw < $1.typeRaw }) {
                out.append("pref:\(preference.typeRaw):\(preference.enabled):\(preference.leadDays)")
            }
            return out
        }

        let before = try fingerprint()
        XCTAssertFalse(before.isEmpty)

        try MigrationService.migrateIfNeeded(context: context, dateProvider: TestSupport.fixedToday)

        XCTAssertEqual(before, try fingerprint(), "schema 3 must not alter a single stored value")
    }

    func testTheUserIsNeverReonboarded() throws {
        let (_, context) = try makeSchemaTwoStore()
        try MigrationService.migrateIfNeeded(context: context, dateProvider: TestSupport.fixedToday)

        let settings = try XCTUnwrap(context.fetch(FetchDescriptor<AppSettings>()).first)
        XCTAssertTrue(settings.onboardingComplete)
        let progress = try XCTUnwrap(context.fetch(FetchDescriptor<OnboardingProgress>()).first)
        XCTAssertNotNil(progress.completedAt)
        XCTAssertEqual(progress.resumeStep, .finished)
    }

    // MARK: - The one real decision: the protected amount

    /// The profile's single floor becomes the spending account's protected
    /// amount. Every other account stays at zero — inventing a second
    /// protected balance would silently shrink the money the plan may use.
    func testProtectedFloorMovesOntoTheSpendingAccountOnly() throws {
        let (_, context) = try makeSchemaTwoStore()
        let profile = try XCTUnwrap(context.fetch(FetchDescriptor<UserGoalProfile>()).first)
        let floor = profile.protectedFloor
        XCTAssertGreaterThan(floor, 0, "the fixture carries a floor to migrate")

        let summary = try MigrationService.migrateIfNeeded(
            context: context, dateProvider: TestSupport.fixedToday
        )
        XCTAssertEqual(summary.protectedAmountsSet, 1)

        let repository = CashAccountRepository(context: context)
        let spending = try XCTUnwrap(repository.spendingAccount())
        XCTAssertEqual(spending.protectedAmount, floor)

        for other in try repository.activeAccounts() where other.id != spending.id {
            XCTAssertEqual(other.protectedAmount, .zero, "\(other.name) must not gain a protected amount")
        }
    }

    /// New optional fields stay nil/zero rather than being backfilled with a
    /// guess: "written before this existed" is a fact worth keeping.
    func testNewFieldsAreDefaultedNeverInvented() throws {
        let (_, context) = try makeSchemaTwoStore()
        try MigrationService.migrateIfNeeded(context: context, dateProvider: TestSupport.fixedToday)

        let plan = try XCTUnwrap(PlanRepository.legacyBaseline(context: context))
        XCTAssertNil(plan.scenarioKindRaw, "an existing plan is not retroactively labelled a scenario")
        XCTAssertNil(plan.effectiveDate)

        for entry in try context.fetch(FetchDescriptor<LedgerEntry>()) {
            XCTAssertNil(entry.provenanceRaw, "provenance is never backfilled")
        }

        let profile = try XCTUnwrap(context.fetch(FetchDescriptor<UserGoalProfile>()).first)
        XCTAssertEqual(profile.minimumProtectedCash, .zero)
        XCTAssertEqual(profile.plannedSavingsPerPaycheck, .zero)
        XCTAssertEqual(profile.additionalCushionReserve, .zero)
        XCTAssertEqual(profile.extraPaymentCeiling, .zero)
        XCTAssertNil(profile.zeroAllowanceConfirmedAt,
                     "a zero allowance is not treated as confirmed by silence")
    }

    // MARK: - Idempotency

    func testRepeatedLaunchesChangeNothing() throws {
        let (_, context) = try makeSchemaTwoStore()
        try MigrationService.migrateIfNeeded(context: context, dateProvider: TestSupport.fixedToday)

        let repository = CashAccountRepository(context: context)
        let spending = try XCTUnwrap(repository.spendingAccount())
        let protectedAfterFirst = spending.protectedAmount
        let counts = [
            try context.fetchCount(FetchDescriptor<CashAccount>()),
            try context.fetchCount(FetchDescriptor<RecurringObligation>()),
            try context.fetchCount(FetchDescriptor<LedgerEntry>()),
            try context.fetchCount(FetchDescriptor<PlannedObligationReserve>()),
            try context.fetchCount(FetchDescriptor<UserGoalProfile>())
        ]

        for _ in 0..<3 {
            let again = try MigrationService.migrateIfNeeded(
                context: context, dateProvider: TestSupport.fixedToday
            )
            XCTAssertFalse(again.didMigrate, "an up-to-date store is left alone")
        }

        XCTAssertEqual(spending.protectedAmount, protectedAfterFirst)
        XCTAssertEqual(counts, [
            try context.fetchCount(FetchDescriptor<CashAccount>()),
            try context.fetchCount(FetchDescriptor<RecurringObligation>()),
            try context.fetchCount(FetchDescriptor<LedgerEntry>()),
            try context.fetchCount(FetchDescriptor<PlannedObligationReserve>()),
            try context.fetchCount(FetchDescriptor<UserGoalProfile>())
        ], "a repeated launch must not duplicate a single row")
    }

    /// A user who has since edited their protected amount is not overwritten
    /// if the step somehow runs again.
    func testAUserEditedProtectedAmountIsNeverOverwritten() throws {
        let (_, context) = try makeSchemaTwoStore()
        try MigrationService.migrateIfNeeded(context: context, dateProvider: TestSupport.fixedToday)

        let repository = CashAccountRepository(context: context)
        let spending = try XCTUnwrap(repository.spendingAccount())
        let edited = TestSupport.money("2222.00")
        try repository.update(spending, protectedAmount: edited)

        try MigrationService.applySchema3Upgrade(context: context, dateProvider: TestSupport.fixedToday)
        XCTAssertEqual(spending.protectedAmount, edited)
    }
}
