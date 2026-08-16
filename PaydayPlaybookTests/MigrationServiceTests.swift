import XCTest
import SwiftData
@testable import PaydayPlaybook

/// V2-16 / MVP_LAYOUT §7: schema 1→2 migration — routing, value-for-value
/// preservation, account conversion, idempotency, and clean aborts.
final class MigrationServiceTests: XCTestCase {

    /// A faithful 0.1.x store: seeded plan graph, schema stamp 1, no schema-2
    /// rows — plus the user activity a real upgrade carries.
    private func makeLegacyStore(
        withActivity: Bool = true,
        onboardingComplete: Bool = true
    ) throws -> (ModelContainer, ModelContext) {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context, applySchemaUpgrade: false)
        let settings = try XCTUnwrap(context.fetch(FetchDescriptor<AppSettings>()).first)
        settings.onboardingComplete = onboardingComplete

        if withActivity {
            let debts = try context.fetch(FetchDescriptor<DebtAccount>())
            let cardB = try XCTUnwrap(debts.first { $0.planID == "B" })
            context.insert(LedgerEntry(
                effectiveDate: TestSupport.date(2054, 8, 20),
                type: .c2Transfer,
                amount: TestSupport.money("1705.00"),
                sourceAccount: .checking1,
                destinationAccount: .checking2,
                note: "First transfer"
            ))
            context.insert(LedgerEntry(
                effectiveDate: TestSupport.date(2054, 8, 20),
                type: .cardPayment,
                amount: TestSupport.money("1061.07"),
                sourceAccount: .checking2,
                destinationAccount: .card,
                debtAccountID: cardB.id,
                debtPlanID: "B"
            ))
            context.insert(BalanceSnapshot(
                cashAccount: .checking1,
                effectiveDate: TestSupport.date(2054, 8, 20),
                amount: TestSupport.money("1250.00"),
                sourceType: .userEntry
            ))
            let plan = try XCTUnwrap(PlanRepository.legacyBaseline(context: context))
            let firstItem = try XCTUnwrap(TestSupport.planItems(context, plan: plan).first)
            let checkIn = PaydayCheckIn(paydayPlanItemID: firstItem.id, status: .completed)
            checkIn.actualIncome = TestSupport.money("2400.00")
            checkIn.completedAt = TestSupport.date(2054, 8, 20)
            context.insert(checkIn)
        }
        try context.save()
        XCTAssertEqual(try MigrationService.detectInstallState(context: context), .needsMigration(from: 1))
        return (container, context)
    }

    private struct ItemValues: Equatable {
        let seq: Int, date: Date
        let income: Decimal, keep: Decimal, buffer: Decimal, allowance: Decimal
        let transfer: Decimal, car: Decimal, train: Decimal, budget: Decimal
        let target: String, after: Decimal, ceiling: Decimal

        init(_ item: PaydayPlanItem) {
            seq = item.sequenceNumber; date = item.date
            income = item.plannedIncome; keep = item.plannedC1Keep
            buffer = item.plannedBufferAdd; allowance = item.plannedAllowance
            transfer = item.plannedC2Transfer; car = item.plannedCarReserve
            train = item.plannedTrainReserve; budget = item.plannedCardBudget
            target = item.plannedTargetDebtID; after = item.plannedDebtAfter
            ceiling = item.plannedC1NoSpendCeiling
        }
    }

    // MARK: - Routing (§13: clean install vs upgrade)

    func testFreshInstallRoutingLeavesStoreEmpty() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        XCTAssertEqual(try MigrationService.detectInstallState(context: context), .freshInstall)

        let summary = try MigrationService.migrateIfNeeded(context: context, dateProvider: TestSupport.fixedToday)
        XCTAssertFalse(summary.didMigrate)
        // A fresh install receives no plan data at all (V2-16).
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CashAccount>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecurringObligation>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DebtAccount>()), 0)
    }

    func testLegacyStoreRoutesThroughMigrationToUpToDate() throws {
        let (_, context) = try makeLegacyStore()
        let summary = try MigrationService.migrateIfNeeded(context: context, dateProvider: TestSupport.fixedToday)
        XCTAssertTrue(summary.didMigrate)
        XCTAssertEqual(summary.accountsCreated, 2)
        XCTAssertEqual(summary.obligationsCreated, 2)
        XCTAssertEqual(summary.reserveRowsCreated, 46)
        XCTAssertEqual(try MigrationService.detectInstallState(context: context), .upToDate)

        let settings = try XCTUnwrap(context.fetch(FetchDescriptor<AppSettings>()).first)
        XCTAssertEqual(settings.seedSchemaVersion, PlanContract.currentSchemaVersion)
        XCTAssertNotNil(settings.migratedAt)
        XCTAssertNotNil(settings.migrationAuditNote)
        XCTAssertTrue(settings.onboardingComplete)
    }

    // MARK: - Value-for-value preservation (V2-16)

    func testMigrationPreservesEveryBaselineValue() throws {
        let (_, context) = try makeLegacyStore()
        let plan = try XCTUnwrap(PlanRepository.legacyBaseline(context: context))
        let before = try TestSupport.planItems(context, plan: plan).map(ItemValues.init)
        let debtsBefore = try context.fetch(FetchDescriptor<DebtAccount>())
            .sorted { $0.priority < $1.priority }
            .map { ($0.planID, $0.startingBalance, $0.apr, $0.priority) }
        let ledgerBefore = try context.fetch(FetchDescriptor<LedgerEntry>())
            .sorted { $0.amount < $1.amount }
            .map { ($0.typeRaw, $0.amount, $0.sourceAccountRaw, $0.destinationAccountRaw) }
        let checkInBefore = try context.fetch(FetchDescriptor<PaydayCheckIn>())
            .map { ($0.statusRaw, $0.actualIncome) }
        let snapshotBefore = try context.fetch(FetchDescriptor<BalanceSnapshot>())
            .map { ($0.cashAccountRaw, $0.amount) }
        let milestoneCount = try context.fetchCount(FetchDescriptor<Milestone>())

        try MigrationService.migrateIfNeeded(context: context, dateProvider: TestSupport.fixedToday)

        // All 23 paydays intact, every field value unchanged.
        let after = try TestSupport.planItems(context, plan: plan).map(ItemValues.init)
        XCTAssertEqual(after.count, 23)
        XCTAssertEqual(before, after)

        // Plan identity untouched: calc v1 forever, name, headline values.
        XCTAssertEqual(plan.calculationVersion, 1)
        XCTAssertEqual(plan.name, "Original Plan v1")
        XCTAssertEqual(plan.baselineModeledInterest, TestSupport.money("2617.18"))
        XCTAssertEqual(plan.baselinePayoffDate, TestSupport.date(2055, 6, 24))
        XCTAssertEqual(plan.baselineNoSpendCeiling, TestSupport.money("8400.00"))
        XCTAssertEqual(plan.carReservePerCheck, TestSupport.money("323.08"))
        XCTAssertEqual(plan.trainReservePerCheck, TestSupport.money("69.23"))
        XCTAssertNil(plan.inputSnapshotData)
        XCTAssertFalse(plan.generatedFromProfile)
        XCTAssertEqual(plan.payCadence, .biweekly)

        // History untouched.
        let debtsAfter = try context.fetch(FetchDescriptor<DebtAccount>())
            .sorted { $0.priority < $1.priority }
            .map { ($0.planID, $0.startingBalance, $0.apr, $0.priority) }
        XCTAssertEqual(debtsBefore.map(\.0), debtsAfter.map(\.0))
        XCTAssertEqual(debtsBefore.map(\.1), debtsAfter.map(\.1))
        XCTAssertEqual(debtsBefore.map(\.2), debtsAfter.map(\.2))
        XCTAssertEqual(debtsBefore.map(\.3), debtsAfter.map(\.3))
        let ledgerAfter = try context.fetch(FetchDescriptor<LedgerEntry>())
            .sorted { $0.amount < $1.amount }
            .map { ($0.typeRaw, $0.amount, $0.sourceAccountRaw, $0.destinationAccountRaw) }
        XCTAssertEqual(ledgerBefore.map(\.1), ledgerAfter.map(\.1))
        XCTAssertEqual(ledgerBefore.map(\.2), ledgerAfter.map(\.2))
        XCTAssertEqual(checkInBefore.map(\.1), try context.fetch(FetchDescriptor<PaydayCheckIn>()).map { ($0.statusRaw, $0.actualIncome) }.map(\.1))
        XCTAssertEqual(snapshotBefore.map(\.1), try context.fetch(FetchDescriptor<BalanceSnapshot>()).map { ($0.cashAccountRaw, $0.amount) }.map(\.1))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Milestone>()), milestoneCount)
    }

    // MARK: - Checking 1/2 conversion (§7.2)

    func testCheckingAccountsConvertWithRolesAndDerivedBalances() throws {
        let (_, context) = try makeLegacyStore()
        try MigrationService.migrateIfNeeded(context: context, dateProvider: TestSupport.fixedToday)

        let accounts = try context.fetch(FetchDescriptor<CashAccount>())
            .sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(accounts.count, 2)

        let c1 = accounts[0]
        XCTAssertEqual(c1.name, "Checking 1")
        XCTAssertEqual(c1.roles, [.income, .spending])
        XCTAssertTrue(c1.isDefaultIncome)
        XCTAssertEqual(c1.legacyKind, .checking1)
        // Migrating on Aug 10, before any fixture activity takes effect, the
        // balance derives from the plan's starting $900 — nothing invented.
        XCTAssertEqual(c1.currentBalance, TestSupport.money("1500.00"))

        let c2 = accounts[1]
        XCTAssertEqual(c2.name, "Checking 2")
        XCTAssertEqual(c2.roles, [.reserves])
        XCTAssertFalse(c2.isDefaultIncome)
        XCTAssertEqual(c2.legacyKind, .checking2)

        // Legacy references now also carry CashAccount ids; raws untouched.
        let transfer = try XCTUnwrap(context.fetch(FetchDescriptor<LedgerEntry>())
            .first { $0.type == .c2Transfer })
        XCTAssertEqual(transfer.sourceAccountRaw, "checking1")
        XCTAssertEqual(transfer.destinationAccountRaw, "checking2")
        XCTAssertEqual(transfer.sourceAccountID, c1.id)
        XCTAssertEqual(transfer.destinationAccountID, c2.id)
        let snapshot = try XCTUnwrap(context.fetch(FetchDescriptor<BalanceSnapshot>())
            .first { $0.cashAccount == .checking1 })
        XCTAssertEqual(snapshot.cashAccountID, c1.id)

        // Plan points at its income account.
        let plan = try XCTUnwrap(PlanRepository.legacyBaseline(context: context))
        XCTAssertEqual(plan.incomeAccountID, c1.id)
    }

    func testCheckingBalancesReflectActivityOnOrBeforeToday() throws {
        let (_, context) = try makeLegacyStore()
        // Migrate "later", after the first payday's activity took effect.
        let later = FixedDateProvider(fixed: TestSupport.date(2054, 8, 21))
        try MigrationService.migrateIfNeeded(context: context, dateProvider: later)

        let accounts = try context.fetch(FetchDescriptor<CashAccount>())
        let c1 = try XCTUnwrap(accounts.first { $0.legacyKind == .checking1 })
        let c2 = try XCTUnwrap(accounts.first { $0.legacyKind == .checking2 })
        // C1: the $1,250 authoritative snapshot governs; the same-day
        // transfer was recorded before the confirmation, so it is already
        // reflected in the confirmed balance (0.1.x same-day rule).
        XCTAssertEqual(c1.currentBalance, TestSupport.money("1250.00"))
        // C2: $1,694 in, $1,061.07 card payment out.
        XCTAssertEqual(c2.currentBalance, TestSupport.money("643.93"))
    }

    // MARK: - Obligations (§7.3, R-04 reduction)

    func testCarAndTrainBecomeObligationsWithVerifiedSmoothing() throws {
        let (_, context) = try makeLegacyStore()
        try MigrationService.migrateIfNeeded(context: context, dateProvider: TestSupport.fixedToday)

        let obligations = try context.fetch(FetchDescriptor<RecurringObligation>())
        XCTAssertEqual(obligations.count, 2)
        let car = try XCTUnwrap(obligations.first { $0.legacyKey == "car" })
        XCTAssertEqual(car.name, "Car")
        XCTAssertEqual(car.amount, TestSupport.money("700.01"))
        XCTAssertEqual(car.cadence, .monthly)
        let train = try XCTUnwrap(obligations.first { $0.legacyKey == "train" })
        XCTAssertEqual(train.amount, TestSupport.money("150.00"))

        // The R-04 reduction that §7.3 verifies before committing.
        XCTAssertEqual(
            ObligationMath.perPaycheckReserve(amount: car.amount, cadence: .monthly, paychecksPerYear: 26),
            TestSupport.money("323.08")
        )
        XCTAssertEqual(
            ObligationMath.perPaycheckReserve(amount: train.amount, cadence: .monthly, paychecksPerYear: 26),
            TestSupport.money("69.23")
        )

        // Reserve rows mirror the stored per-item values, copied verbatim.
        let plan = try XCTUnwrap(PlanRepository.legacyBaseline(context: context))
        let items = try TestSupport.planItems(context, plan: plan)
        let reserves = try context.fetch(FetchDescriptor<PlannedObligationReserve>())
        XCTAssertEqual(reserves.count, items.count * 2)
        let byItem = Dictionary(grouping: reserves, by: \.paydayPlanItemID)
        for item in items {
            let rows = try XCTUnwrap(byItem[item.id])
            XCTAssertEqual(rows.first { $0.obligationID == car.id }?.amount, item.plannedCarReserve)
            XCTAssertEqual(rows.first { $0.obligationID == train.id }?.amount, item.plannedTrainReserve)
        }
    }

    // MARK: - No fabrication (migration rule 5)

    func testUnknownDebtFieldsStayUnknown() throws {
        let (_, context) = try makeLegacyStore()
        try MigrationService.migrateIfNeeded(context: context, dateProvider: TestSupport.fixedToday)

        for debt in try context.fetch(FetchDescriptor<DebtAccount>()) {
            XCTAssertEqual(debt.debtType, .creditCard)
            XCTAssertTrue(debt.isExtraPrincipalEligible)
            XCTAssertNil(debt.originalPrincipal, "\(debt.planID): original principal must stay unknown")
            XCTAssertNil(debt.creditLimit, "\(debt.planID): credit limit must stay unknown")
            XCTAssertNil(debt.dueDayOfMonth, "\(debt.planID): due date must stay unknown")
            // Percent-paid display falls back to the starting balance.
            XCTAssertEqual(debt.principalBasis, debt.startingBalance)
        }
    }

    // MARK: - No re-onboarding (§7.7)

    func testMigratedUserNeverReonboards() throws {
        let (_, context) = try makeLegacyStore()
        try MigrationService.migrateIfNeeded(context: context, dateProvider: TestSupport.fixedToday)

        let progress = try XCTUnwrap(context.fetch(FetchDescriptor<OnboardingProgress>()).first)
        XCTAssertNotNil(progress.completedAt)
        XCTAssertEqual(progress.resumeStep, .finished)

        let profile = try XCTUnwrap(context.fetch(FetchDescriptor<UserGoalProfile>()).first)
        XCTAssertEqual(profile.posture, .steady)
        XCTAssertNil(profile.goalText)
        XCTAssertEqual(profile.protectedFloor, TestSupport.money("1500.00"))
        XCTAssertEqual(profile.allowanceCap, TestSupport.money("300.00"))
        XCTAssertNotNil(profile.onboardingCompletedAt)

        // Schema-2 notification kinds gained default rows; the six existing
        // rows were not duplicated.
        let prefs = try context.fetch(FetchDescriptor<NotificationPreference>())
        XCTAssertEqual(prefs.count, NotificationKind.allCases.count)
        XCTAssertEqual(Set(prefs.map(\.typeRaw)).count, prefs.count)
    }

    // MARK: - Idempotency (§7 / rule 6)

    func testMigrationIsIdempotentAcrossRepeatedLaunches() throws {
        let (container, context) = try makeLegacyStore()
        try MigrationService.migrateIfNeeded(context: context, dateProvider: TestSupport.fixedToday)

        func counts(_ context: ModelContext) throws -> [Int] {
            [
                try context.fetchCount(FetchDescriptor<CashAccount>()),
                try context.fetchCount(FetchDescriptor<RecurringObligation>()),
                try context.fetchCount(FetchDescriptor<PlannedObligationReserve>()),
                try context.fetchCount(FetchDescriptor<UserGoalProfile>()),
                try context.fetchCount(FetchDescriptor<OnboardingProgress>()),
                try context.fetchCount(FetchDescriptor<IncomeSchedule>()),
                try context.fetchCount(FetchDescriptor<IncomeChange>()),
                try context.fetchCount(FetchDescriptor<NotificationPreference>()),
                try context.fetchCount(FetchDescriptor<PaydayPlanItem>()),
                try context.fetchCount(FetchDescriptor<PlanVersion>())
            ]
        }
        let first = try counts(context)

        // A second launch is a no-op…
        let second = try MigrationService.migrateIfNeeded(context: context, dateProvider: TestSupport.fixedToday)
        XCTAssertFalse(second.didMigrate)
        XCTAssertEqual(try counts(context), first)

        // …and even a forced re-run of the upgrade inserts nothing new.
        let summary = try MigrationService.applyLogicalUpgrade(context: context, dateProvider: TestSupport.fixedToday)
        try context.save()
        XCTAssertEqual(summary.accountsCreated, 0)
        XCTAssertEqual(summary.obligationsCreated, 0)
        XCTAssertEqual(summary.reserveRowsCreated, 0)
        XCTAssertEqual(try counts(context), first)

        // A different context (fresh launch) agrees.
        XCTAssertEqual(try counts(ModelContext(container)), first)
    }

    /// §7 step 7 for a store whose 0.1.x flow was quit before the final step:
    /// the plan is complete, so migration also completes onboarding — both
    /// persisted signals agree and the user is never re-onboarded.
    func testMidOnboardingLegacyStoreNeverReonboards() throws {
        let (_, context) = try makeLegacyStore(onboardingComplete: false)
        try MigrationService.migrateIfNeeded(context: context, dateProvider: TestSupport.fixedToday)

        let settings = try XCTUnwrap(context.fetch(FetchDescriptor<AppSettings>()).first)
        XCTAssertTrue(settings.onboardingComplete)
        XCTAssertEqual(settings.seedSchemaVersion, PlanContract.currentSchemaVersion)
        let progress = try XCTUnwrap(context.fetch(FetchDescriptor<OnboardingProgress>()).first)
        XCTAssertNotNil(progress.completedAt)
    }

    // MARK: - Template identity (baseline lookup keys on the contract name)

    /// A user-generated plan graph on a v0.2 store: build directly, the way
    /// `PlanPersister` shapes it (isOriginalBaseline true per §4.9/A-04, a
    /// non-template name, a variable horizon).
    private func insertGeneratedGraph(context: ModelContext) throws -> (PlanVersion, DebtAccount) {
        let plan = PlanVersion(
            name: "Plan v1",
            isOriginalBaseline: true,
            isActive: true,
            firstPayday: TestSupport.date(2054, 9, 4),
            payFrequencyDays: 14,
            startingChecking1: TestSupport.money("500.00"),
            protectedBuffer: TestSupport.money("800.00"),
            allowanceCap: TestSupport.money("200.00"),
            firstCheckBufferAdd: .zero,
            carReservePerCheck: .zero,
            trainReservePerCheck: .zero,
            calculationVersion: 2,
            avalancheOrderRaw: "UserLoan",
            baselinePayoffDate: TestSupport.date(2055, 1, 1),
            baselineModeledInterest: TestSupport.money("42.00"),
            baselineNoSpendCeiling: TestSupport.money("8400.00")
        )
        plan.generatedFromProfile = true
        context.insert(plan)
        context.insert(PaydayPlanItem(
            planVersionID: plan.id, sequenceNumber: 1,
            date: TestSupport.date(2054, 9, 4),
            plannedIncome: TestSupport.money("1500.00"),
            plannedC1Keep: .zero, plannedBufferAdd: .zero, plannedAllowance: .zero,
            plannedC2Transfer: .zero, plannedCarReserve: .zero, plannedTrainReserve: .zero,
            plannedCardBudget: .zero, plannedTargetDebtID: "UserLoan",
            plannedDebtAfter: .zero, plannedC1NoSpendCeiling: .zero
        ))
        let debt = DebtAccount(
            planID: "UserLoan", displayName: "Auto loan",
            startingBalance: TestSupport.money("9000.00"),
            apr: TestSupport.money("0.0599"),
            minimumAmount: TestSupport.money("310.00"),
            priority: 1,
            debtType: .autoLoan,
            isExtraPrincipalEligible: false
        )
        context.insert(debt)
        context.insert(Milestone(
            type: .debtFree, title: "Debt-free",
            baselineDate: TestSupport.date(2055, 1, 1)
        ))
        return (plan, debt)
    }

    /// Regression for the review's HIGH finding: a store holding a generated
    /// plan (isOriginalBaseline, non-template shape) must never be mistaken
    /// for a broken template seed — a template load must add the template
    /// alongside without deleting or rewriting any of the user's rows.
    func testTemplateSeedDoesNotTouchAGeneratedPlanGraph() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let (userPlan, userDebt) = try insertGeneratedGraph(context: context)
        context.insert(CashAccount(
            name: "Main", currentBalance: TestSupport.money("500.00"),
            roles: [.income, .spending], isDefaultIncome: true
        ))
        context.insert(AppSettings(onboardingComplete: true, seedSchemaVersion: 2))
        try context.save()

        // The generated plan is not the template.
        XCTAssertNil(try PlanRepository.legacyBaseline(context: context))

        // Template load: seeds Original Plan v1 next to the user's graph.
        let inserted = try TestSupport.seed(context)
        XCTAssertEqual(inserted.name, PlanContract.planName)

        // The user's plan graph survives untouched.
        let userPlanID = userPlan.id
        let plans = try context.fetch(FetchDescriptor<PlanVersion>())
        XCTAssertEqual(plans.count, 2)
        XCTAssertNotNil(plans.first { $0.id == userPlanID })
        XCTAssertEqual(try context.fetchCount(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == userPlanID })
        ), 1)

        // The user's debt keeps its entered type and eligibility (§7.4 is
        // scoped to the template's own debts).
        XCTAssertEqual(userDebt.debtType, .autoLoan)
        XCTAssertFalse(userDebt.isExtraPrincipalEligible)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DebtAccount>()), 7)

        // Exactly one default income account — the user's, not Checking 1.
        let defaults = try context.fetch(FetchDescriptor<CashAccount>())
            .filter { $0.isDefaultIncome && !$0.isArchived }
        XCTAssertEqual(defaults.map(\.name), ["Main"])
    }

    /// A partially-written legacy plan graph is refused, not repaired.
    ///
    /// 0.1.x could rebuild a crashed partial seed by re-reading the bundled
    /// template. That template is gone (V3-12), so there is nothing to rebuild
    /// from — and inventing a plan graph for a store whose real one is
    /// incomplete would be worse than declining. Migration aborts and the
    /// user's own rows are left exactly as they were.
    func testPartialLegacyGraphIsRefusedAndUserRowsSurvive() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let (_, userDebt) = try insertGeneratedGraph(context: context)
        // An interrupted 0.1.x seed: the plan row exists, its graph does not.
        context.insert(PlanVersion(
            name: PlanContract.planName,
            isOriginalBaseline: true,
            isActive: false,
            firstPayday: TestSupport.date(2054, 8, 20),
            payFrequencyDays: 14,
            startingChecking1: TestSupport.money("1500.00"),
            protectedBuffer: TestSupport.money("1500.00"),
            allowanceCap: TestSupport.money("300.00"),
            firstCheckBufferAdd: .zero,
            carReservePerCheck: TestSupport.money("323.08"),
            trainReservePerCheck: TestSupport.money("69.23"),
            calculationVersion: 1,
            avalancheOrderRaw: "A,B,C,D,E,F",
            baselinePayoffDate: TestSupport.date(2055, 6, 24),
            baselineModeledInterest: TestSupport.money("2617.18"),
            baselineNoSpendCeiling: TestSupport.money("8400.00")
        ))
        let settings = try context.fetch(FetchDescriptor<AppSettings>()).first
            ?? {
                let fresh = AppSettings(seedSchemaVersion: 1)
                context.insert(fresh)
                return fresh
            }()
        settings.seedSchemaVersion = 1
        try context.save()

        XCTAssertThrowsError(
            try MigrationService.migrateIfNeeded(context: context, dateProvider: TestSupport.fixedToday)
        ) { error in
            guard case MigrationService.MigrationError.baselineIncomplete = error else {
                return XCTFail("Expected baselineIncomplete, got \(error)")
            }
        }

        // No second baseline was fabricated, and the user's rows are intact.
        let baselines = try context.fetch(FetchDescriptor<PlanVersion>())
            .filter { $0.name == PlanContract.planName }
        XCTAssertEqual(baselines.count, 1, "migration must not invent a replacement plan")
        XCTAssertFalse(userDebt.isDeleted)
        XCTAssertEqual(userDebt.debtType, .autoLoan)
    }

    // MARK: - Clean abort (§7 preamble)

    /// Migration must roll back completely when the store it is handed is not
    /// internally consistent.
    ///
    /// The trigger is a broken plan graph — a gap in the payday sequence —
    /// rather than an unreproducible reserve. Since obligation amounts are now
    /// *derived* from the stored reserve by inverse R-04, the smoothing check
    /// cannot disagree with itself on the monthly/biweekly pair migration
    /// uses; see `testInverseSmoothingAlwaysRoundTripsForMonthlyReserves`.
    func testFailedMigrationLeavesStoreUntouched() throws {
        let (_, context) = try makeLegacyStore()
        let plan = try XCTUnwrap(PlanRepository.legacyBaseline(context: context))
        let items = try PlanRepository.planItems(context: context, plan: plan)
        // Punch a hole in the middle of the payday sequence.
        context.delete(items[3])
        try context.save()

        XCTAssertThrowsError(
            try MigrationService.migrateIfNeeded(context: context, dateProvider: TestSupport.fixedToday)
        ) { error in
            guard case MigrationService.MigrationError.baselineIncomplete = error else {
                return XCTFail("Expected baselineIncomplete, got \(error)")
            }
        }

        // Nothing was written; the store retries next launch.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CashAccount>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecurringObligation>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlannedObligationReserve>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserGoalProfile>()), 0)
        let settings = try XCTUnwrap(context.fetch(FetchDescriptor<AppSettings>()).first)
        XCTAssertEqual(settings.seedSchemaVersion, 1)
        XCTAssertEqual(try MigrationService.detectInstallState(context: context), .needsMigration(from: 1))
    }

    /// Why the obligation-mismatch abort cannot fire on the migration path.
    ///
    /// Migration recovers a monthly bill from a stored per-paycheck reserve by
    /// inverse R-04 and then requires the forward rule to reproduce that
    /// reserve exactly. For monthly obligations against 26 paychecks a year
    /// the round-trip always closes, so the recovered amount is always safe to
    /// write. The guard stays in the code because other cadences do not share
    /// that property — a weekly obligation can fail it — and because a silent
    /// wrong amount is far worse than a refused migration.
    func testInverseSmoothingAlwaysRoundTripsForMonthlyReserves() {
        var checked = 0
        for cents in stride(from: 1, through: 200_000, by: 7) {
            let reserve = Decimal(cents) / 100
            XCTAssertTrue(
                ObligationMath.roundTripReproduces(
                    reserve: reserve, cadence: .monthly, paychecksPerYear: 26
                ),
                "monthly/biweekly round-trip must close for every reserve"
            )
            checked += 1
        }
        XCTAssertGreaterThan(checked, 25_000)
    }

    /// The same guard is genuinely reachable on other cadences, which is why
    /// it is not dead code.
    func testInverseSmoothingCanFailOnOtherCadences() {
        XCTAssertFalse(
            ObligationMath.roundTripReproduces(
                reserve: TestSupport.money("0.01"), cadence: .weekly, paychecksPerYear: 26
            ),
            "a weekly obligation can round-trip to a different reserve"
        )
    }
}
