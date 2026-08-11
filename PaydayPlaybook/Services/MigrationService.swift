import Foundation
import SwiftData

/// Schema 1 → 2 migration (MVP_LAYOUT §7, V2-16).
///
/// The store-level schema change is purely additive (new models, new optional
/// or defaulted properties), so SwiftData migrates the container lightweight.
/// This service performs the *logical* upgrade: converting Checking 1/2 into
/// `CashAccount` rows, creating the car/train `RecurringObligation`s, filling
/// new references, and stamping the store — all in a single save, idempotent
/// across repeated launches, and never altering an existing stored value.
/// On any failure the context is rolled back so the store stays untouched and
/// the app retries next launch.
struct MigrationService {

    /// Routing between clean install and upgrade (§7, §13).
    enum InstallState: Equatable {
        /// Nothing stored yet — v0.2.0 onboarding is the only path to a plan.
        case freshInstall
        /// A 0.1.x store that still needs the logical upgrade.
        case legacyNeedsMigration
        /// Already stamped schema 2.
        case upToDate
    }

    enum MigrationError: LocalizedError, Equatable {
        case baselineIncomplete(String)
        case obligationMathMismatch(String)

        var errorDescription: String? {
            switch self {
            case .baselineIncomplete(let detail):
                return "The existing plan data is incomplete; migration was not applied: \(detail)"
            case .obligationMathMismatch(let detail):
                return "Obligation smoothing failed to reproduce the stored reserves: \(detail)"
            }
        }
    }

    struct MigrationSummary: Equatable {
        var didMigrate: Bool
        var accountsCreated: Int
        var obligationsCreated: Int
        var reserveRowsCreated: Int
    }

    static let legacyChecking1Name = "Checking 1"
    static let legacyChecking2Name = "Checking 2"
    static let legacyCarAmount = Decimal(string: "726.00")!
    static let legacyTrainAmount = Decimal(string: "111.00")!

    // MARK: - Routing

    static func detectInstallState(context: ModelContext) throws -> InstallState {
        let settings = try context.fetch(FetchDescriptor<AppSettings>()).first
        if let settings {
            return settings.seedSchemaVersion >= PlanContract.currentSchemaVersion
                ? .upToDate
                : .legacyNeedsMigration
        }
        // No settings row: a 0.1.x store always wrote one in the same save as
        // its seed, so any plan data present means a legacy store mid-crash.
        let planCount = try context.fetchCount(FetchDescriptor<PlanVersion>())
        return planCount == 0 ? .freshInstall : .legacyNeedsMigration
    }

    // MARK: - Entry point

    /// Runs once before any UI. Fresh installs are stamped current and skip
    /// everything; legacy stores get the §7 upgrade in one transaction.
    @discardableResult
    static func migrateIfNeeded(
        context: ModelContext,
        dateProvider: DateProviding = SystemDateProvider(),
        bundle: Bundle = .main
    ) throws -> MigrationSummary {
        switch try detectInstallState(context: context) {
        case .upToDate:
            return MigrationSummary(didMigrate: false, accountsCreated: 0, obligationsCreated: 0, reserveRowsCreated: 0)
        case .freshInstall:
            // Nothing to convert and nothing to invent. Onboarding creates
            // the settings row (stamped schema 2) when it starts.
            return MigrationSummary(didMigrate: false, accountsCreated: 0, obligationsCreated: 0, reserveRowsCreated: 0)
        case .legacyNeedsMigration:
            do {
                // A crashed 0.1.x partial seed is repaired exactly as a 0.1.x
                // launch would have repaired it, before upgrading.
                if let baseline = try PlanSeeder.existingBaseline(context: context),
                   try !PlanSeeder.isComplete(baseline, context: context) {
                    try PlanSeeder.seedIfNeeded(context: context, bundle: bundle)
                }
                let summary = try applyLogicalUpgrade(context: context, dateProvider: dateProvider)
                // §7 step 7: the migrated user never re-onboards. A 0.1.x
                // store whose flow was quit before its final step set this
                // flag still holds a complete plan, so completion stands.
                // (Set here, not in applyLogicalUpgrade — the live onboarding
                // flow runs the upgrade mid-flow and owns its own flag.)
                if let settings = try context.fetch(FetchDescriptor<AppSettings>()).first {
                    settings.onboardingComplete = true
                }
                try context.save()
                return summary
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    // MARK: - Logical upgrade (steps 2–8 of §7)

    /// Applies the logical schema-2 upgrade without saving; callers own the
    /// transaction boundary. Also used by v1 backup imports and template
    /// loads onto a v2 store. Idempotent: every step guards on existence.
    @discardableResult
    static func applyLogicalUpgrade(
        context: ModelContext,
        dateProvider: DateProviding = SystemDateProvider()
    ) throws -> MigrationSummary {
        let now = dateProvider.now

        // §7.1 — integrity pre-check: the baseline graph must be whole.
        guard let plan = try PlanSeeder.existingBaseline(context: context) else {
            throw MigrationError.baselineIncomplete("no baseline plan version")
        }
        let planID = plan.id
        let items = try context.fetch(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
        ).sorted { $0.sequenceNumber < $1.sequenceNumber }
        guard items.count == PlanContract.paydayCount else {
            throw MigrationError.baselineIncomplete("expected \(PlanContract.paydayCount) paydays, found \(items.count)")
        }
        let debts = try context.fetch(FetchDescriptor<DebtAccount>())
        guard debts.count >= PlanContract.debtCount else {
            throw MigrationError.baselineIncomplete("expected \(PlanContract.debtCount) debts, found \(debts.count)")
        }

        var accountsCreated = 0
        var obligationsCreated = 0
        var reserveRowsCreated = 0

        // §7.2 — Checking 1 / Checking 2 become CashAccount rows. Balances
        // derive from the existing bucket state; nothing is invented.
        let existingAccounts = try context.fetch(FetchDescriptor<CashAccount>())
        let balances = AccountBalanceService(context: context, dateProvider: dateProvider)

        let checking1: CashAccount
        if let existing = existingAccounts.first(where: { $0.legacyKind == .checking1 }) {
            checking1 = existing
        } else {
            let c1State = try balances.checking1State(plan: plan, planItems: items)
            // Checking 1 becomes the default income account only when the
            // store doesn't already have one (a template load onto an
            // onboarded store must not create a second default).
            let hasDefaultIncome = existingAccounts.contains { $0.isDefaultIncome && !$0.isArchived }
            checking1 = CashAccount(
                name: legacyChecking1Name,
                currentBalance: c1State.actualBalance,
                roles: [.income, .spending],
                isDefaultIncome: !hasDefaultIncome,
                sortOrder: 0,
                legacyKind: .checking1,
                createdAt: now,
                updatedAt: now
            )
            context.insert(checking1)
            accountsCreated += 1
        }

        let checking2: CashAccount
        if let existing = existingAccounts.first(where: { $0.legacyKind == .checking2 }) {
            checking2 = existing
        } else {
            let c2State = try balances.checking2State()
            checking2 = CashAccount(
                name: legacyChecking2Name,
                currentBalance: c2State.totalBalance,
                roles: [.reserves],
                isDefaultIncome: false,
                sortOrder: 1,
                legacyKind: .checking2,
                createdAt: now,
                updatedAt: now
            )
            context.insert(checking2)
            accountsCreated += 1
        }

        // §7.3 — car and train obligations, verified against the stored
        // per-check reserves. A mismatch aborts (values are never rewritten).
        let existingObligations = try context.fetch(FetchDescriptor<RecurringObligation>())
        let cadence = plan.payCadence

        let car: RecurringObligation
        if let existing = existingObligations.first(where: { $0.legacyKey == "car" }) {
            car = existing
        } else {
            car = RecurringObligation(
                name: "Car", amount: legacyCarAmount, cadence: .monthly,
                accountID: checking2.id, legacyKey: "car", createdAt: now, updatedAt: now
            )
            let smoothed = ObligationMath.perPaycheckReserve(
                amount: car.amount, cadence: car.cadence, paychecksPerYear: cadence.paychecksPerYear
            )
            guard smoothed == plan.carReservePerCheck else {
                throw MigrationError.obligationMathMismatch(
                    "car: smoothing gives \(smoothed), plan stores \(plan.carReservePerCheck)"
                )
            }
            context.insert(car)
            obligationsCreated += 1
        }

        let train: RecurringObligation
        if let existing = existingObligations.first(where: { $0.legacyKey == "train" }) {
            train = existing
        } else {
            train = RecurringObligation(
                name: "Train pass", amount: legacyTrainAmount, cadence: .monthly,
                accountID: checking2.id, legacyKey: "train", createdAt: now, updatedAt: now
            )
            let smoothed = ObligationMath.perPaycheckReserve(
                amount: train.amount, cadence: train.cadence, paychecksPerYear: cadence.paychecksPerYear
            )
            guard smoothed == plan.trainReservePerCheck else {
                throw MigrationError.obligationMathMismatch(
                    "train: smoothing gives \(smoothed), plan stores \(plan.trainReservePerCheck)"
                )
            }
            context.insert(train)
            obligationsCreated += 1
        }

        // §7.4 — stamp the baseline's own debts (keyed by the plan's
        // avalanche order) with type metadata; debts created outside the
        // template graph are never rewritten. Genuinely unknown facts
        // (credit limit, original principal, due date) stay nil — asked
        // later in upgrade onboarding, never fabricated.
        let baselineDebtIDs = Set(plan.avalancheOrder)
        for debt in debts where baselineDebtIDs.contains(debt.planID) {
            debt.debtTypeRaw = DebtType.creditCard.rawValue
            debt.isExtraPrincipalEligible = true
        }

        // §7.5 — plan-version metadata. No PaydayPlanItem/check-in/ledger/
        // snapshot/forecast/milestone/preference *value* is touched.
        plan.payCadenceRaw = PayCadence.biweekly.rawValue
        plan.incomeAccountID = checking1.id
        plan.generatedFromProfile = false

        // §7.6 — obligation-reserve rows mirroring the stored car/train
        // amounts, values copied, never recomputed.
        let existingReserves = try context.fetch(FetchDescriptor<PlannedObligationReserve>())
        let itemsWithReserves = Set(existingReserves.map(\.paydayPlanItemID))
        for item in items where !itemsWithReserves.contains(item.id) {
            context.insert(PlannedObligationReserve(
                paydayPlanItemID: item.id, obligationID: car.id, amount: item.plannedCarReserve
            ))
            context.insert(PlannedObligationReserve(
                paydayPlanItemID: item.id, obligationID: train.id, amount: item.plannedTrainReserve
            ))
            reserveRowsCreated += 2
        }

        // Fill schema-2 account references on ledger entries and snapshots.
        // The legacy checking1/checking2 raws stay in place beside them.
        func accountID(forLegacyRaw raw: String?) -> UUID? {
            switch raw {
            case MoneyAccount.checking1.rawValue: return checking1.id
            case MoneyAccount.checking2.rawValue: return checking2.id
            default: return nil
            }
        }
        for entry in try context.fetch(FetchDescriptor<LedgerEntry>()) {
            if entry.sourceAccountID == nil {
                entry.sourceAccountID = accountID(forLegacyRaw: entry.sourceAccountRaw)
            }
            if entry.destinationAccountID == nil {
                entry.destinationAccountID = accountID(forLegacyRaw: entry.destinationAccountRaw)
            }
        }
        for snapshot in try context.fetch(FetchDescriptor<BalanceSnapshot>()) where snapshot.cashAccountID == nil {
            snapshot.cashAccountID = accountID(forLegacyRaw: snapshot.cashAccountRaw)
        }

        // A live income schedule mirroring the plan's stored income rules
        // (copied values), so Settings can edit income going forward.
        if try context.fetchCount(FetchDescriptor<IncomeSchedule>()) == 0 {
            let rules = try context.fetch(
                FetchDescriptor<IncomeRule>(predicate: #Predicate { $0.planVersionID == planID })
            ).sorted { $0.effectiveDate < $1.effectiveDate }
            if let first = rules.first {
                let schedule = IncomeSchedule(
                    cadence: .biweekly,
                    anchorPayday: plan.firstPayday,
                    destinationAccountID: checking1.id,
                    baseTakeHome: first.netPaycheckAmount,
                    createdAt: now,
                    updatedAt: now
                )
                context.insert(schedule)
                for rule in rules.dropFirst() {
                    context.insert(IncomeChange(
                        scheduleID: schedule.id,
                        effectiveDate: rule.effectiveDate,
                        newTakeHome: rule.netPaycheckAmount,
                        createdAt: now
                    ))
                }
            }
        }

        // §7.7 — default profile and completed onboarding: the migrated user
        // never re-onboards. Floor and allowance are copied from the plan.
        if try context.fetchCount(FetchDescriptor<UserGoalProfile>()) == 0 {
            context.insert(UserGoalProfile(
                posture: .steady,
                protectedFloor: plan.protectedBuffer,
                allowanceCap: plan.allowanceCap,
                onboardingCompletedAt: now,
                createdAt: now,
                updatedAt: now
            ))
        }
        if try context.fetchCount(FetchDescriptor<OnboardingProgress>()) == 0 {
            context.insert(OnboardingProgress(
                lastCompletedStep: .finished,
                startedAt: now,
                updatedAt: now,
                completedAt: now
            ))
        }

        // Preference rows for kinds added in schema 2; existing rows untouched.
        let preferences = try context.fetch(FetchDescriptor<NotificationPreference>())
        for missing in NotificationPreference.missingDefaults(existing: preferences) {
            context.insert(missing)
        }

        // §7.8 — stamp and audit.
        if let settings = try context.fetch(FetchDescriptor<AppSettings>()).first {
            if settings.seedSchemaVersion < PlanContract.currentSchemaVersion {
                settings.seedSchemaVersion = PlanContract.currentSchemaVersion
                settings.migratedAt = now
                settings.migrationAuditNote =
                    "Upgraded schema 1→2: Checking 1/2 converted to cash accounts, "
                    + "car/train converted to obligations, plan values preserved verbatim."
            }
        } else {
            let settings = AppSettings(
                onboardingComplete: true,
                seedSchemaVersion: PlanContract.currentSchemaVersion,
                createdAt: now
            )
            settings.migratedAt = now
            settings.migrationAuditNote = "Upgraded schema 1→2 (settings row recreated during migration)."
            context.insert(settings)
        }

        return MigrationSummary(
            didMigrate: true,
            accountsCreated: accountsCreated,
            obligationsCreated: obligationsCreated,
            reserveRowsCreated: reserveRowsCreated
        )
    }
}
