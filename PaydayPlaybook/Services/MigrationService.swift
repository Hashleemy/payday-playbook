import Foundation
import SwiftData

/// Schema migrations (MVP_LAYOUT §7, V2-16, V3-12).
///
/// Every store-level schema change here is purely additive (new models, new
/// optional or defaulted properties), so SwiftData migrates the container
/// lightweight. This service performs the *logical* upgrades:
///
/// - **1 → 2**: Checking 1/2 become `CashAccount` rows, the recurring
///   obligations become `RecurringObligation` rows, new references are filled.
/// - **2 → 3**: per-account protected amounts, defaults for the schema-3
///   fields.
///
/// Both run in a single save, are idempotent across repeated launches, and
/// never alter an existing stored value. On any failure the context is rolled
/// back so the store stays untouched and the app retries next launch.
struct MigrationService {

    /// Routing between clean install and upgrade (§7, §13).
    enum InstallState: Equatable {
        /// Nothing stored yet — onboarding is the only path to a plan.
        case freshInstall
        /// A store stamped below the current schema, with the version it holds.
        case needsMigration(from: Int)
        /// Already stamped current.
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
        /// Accounts that received a protected amount in the 2 → 3 step.
        var protectedAmountsSet: Int = 0
    }

    static let legacyChecking1Name = "Checking 1"
    static let legacyChecking2Name = "Checking 2"
    /// Stable keys for the two obligations a 0.1.x store carried. These are
    /// app-assigned schema vocabulary, not user data — the *amounts* they
    /// used to be paired with were, and are now derived from the store.
    static let legacyCarKey = "car"
    static let legacyTransitKey = "train"

    // MARK: - Routing

    static func detectInstallState(context: ModelContext) throws -> InstallState {
        let settings = try context.fetch(FetchDescriptor<AppSettings>()).first
        if let settings {
            return settings.seedSchemaVersion >= PlanContract.currentSchemaVersion
                ? .upToDate
                : .needsMigration(from: settings.seedSchemaVersion)
        }
        // No settings row: a 0.1.x store always wrote one in the same save as
        // its plan graph, so any plan data present means a legacy store
        // caught mid-crash.
        let planCount = try context.fetchCount(FetchDescriptor<PlanVersion>())
        return planCount == 0 ? .freshInstall : .needsMigration(from: PlanContract.schemaVersion)
    }

    // MARK: - Entry point

    /// Runs once before any UI. Fresh installs skip everything; older stores
    /// get each upgrade step they are missing, in one transaction.
    @discardableResult
    static func migrateIfNeeded(
        context: ModelContext,
        dateProvider: DateProviding = SystemDateProvider()
    ) throws -> MigrationSummary {
        switch try detectInstallState(context: context) {
        case .upToDate, .freshInstall:
            // Nothing to convert and nothing to invent. Onboarding creates
            // the settings row (stamped current) when it starts.
            return MigrationSummary(
                didMigrate: false, accountsCreated: 0, obligationsCreated: 0, reserveRowsCreated: 0
            )
        case .needsMigration(let storedVersion):
            do {
                var summary = MigrationSummary(
                    didMigrate: true, accountsCreated: 0, obligationsCreated: 0, reserveRowsCreated: 0
                )
                if storedVersion < 2 {
                    let step = try applyLogicalUpgrade(context: context, dateProvider: dateProvider)
                    summary.accountsCreated += step.accountsCreated
                    summary.obligationsCreated += step.obligationsCreated
                    summary.reserveRowsCreated += step.reserveRowsCreated
                }
                let step3 = try applySchema3Upgrade(context: context, dateProvider: dateProvider)
                summary.protectedAmountsSet += step3.protectedAmountsSet

                // §7 step 7: the migrated user never re-onboards. A store
                // whose flow was quit before its final step still holds a
                // complete plan, so completion stands. (Set here, not in the
                // step functions — the live onboarding flow runs the upgrade
                // mid-flow and owns its own flag.)
                if let settings = try context.fetch(FetchDescriptor<AppSettings>()).first {
                    settings.onboardingComplete = true
                }
                try stamp(context: context, from: storedVersion, now: dateProvider.now)
                try context.save()
                return summary
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    // MARK: - Schema 2 → 3 (§7, V3-04 / V3-05)

    /// Applies the schema-3 logical upgrade without saving.
    ///
    /// Everything schema 3 added is optional or defaulted, so this step is
    /// almost entirely "leave it alone": the defaults are already correct for
    /// an upgraded store. The one real decision is the protected amount,
    /// which moves from a single plan-wide floor to a per-account figure.
    /// It is copied onto the spending-role account and left at zero
    /// everywhere else — the user protected one balance, and inventing a
    /// second protected balance on their reserves account would silently
    /// shrink the money their plan is allowed to use.
    @discardableResult
    static func applySchema3Upgrade(
        context: ModelContext,
        dateProvider: DateProviding = SystemDateProvider()
    ) throws -> MigrationSummary {
        let now = dateProvider.now
        var protectedAmountsSet = 0

        let profile = try context.fetch(FetchDescriptor<UserGoalProfile>()).first
        let floor = profile?.protectedFloor ?? .zero

        if floor > 0 {
            let accounts = try context.fetch(FetchDescriptor<CashAccount>())
                .filter { !$0.isArchived }
                .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
            // Same precedence CashAccountRepository.spendingAccount uses, so
            // the floor lands on the account the app already treats as the
            // spending one.
            let target = accounts.first(where: { $0.roles.contains(.spending) }) ?? accounts.first
            // Idempotent: a re-run finds the amount already set and does
            // nothing, and a user who has since edited it is never overwritten.
            if let target, target.protectedAmount == .zero {
                target.protectedAmount = floor
                target.updatedAt = now
                protectedAmountsSet += 1
            }
        }

        return MigrationSummary(
            didMigrate: true,
            accountsCreated: 0,
            obligationsCreated: 0,
            reserveRowsCreated: 0,
            protectedAmountsSet: protectedAmountsSet
        )
    }

    // MARK: - Stamp

    static func stamp(context: ModelContext, from storedVersion: Int, now: Date = Date()) throws {
        let note = "Upgraded schema \(storedVersion)→\(PlanContract.currentSchemaVersion). "
            + "Existing accounts, debts, bills, check-ins, plans, due dates, and "
            + "preferences preserved; new fields defaulted."
        if let settings = try context.fetch(FetchDescriptor<AppSettings>()).first {
            if settings.seedSchemaVersion < PlanContract.currentSchemaVersion {
                settings.seedSchemaVersion = PlanContract.currentSchemaVersion
                settings.migratedAt = now
                settings.migrationAuditNote = note
            }
        } else {
            let settings = AppSettings(
                onboardingComplete: true,
                seedSchemaVersion: PlanContract.currentSchemaVersion,
                createdAt: now
            )
            settings.migratedAt = now
            settings.migrationAuditNote = note + " (Settings row recreated during migration.)"
            context.insert(settings)
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
        //
        // This once compared payday and debt counts against fixed numbers
        // taken from one user's plan, which both rejected valid stores of a
        // different size and accepted that user's own partial graph. It now
        // checks that the graph is *self-consistent*, which is the property
        // migration actually depends on and holds for any user's plan.
        guard let plan = try PlanRepository.legacyBaseline(context: context) else {
            throw MigrationError.baselineIncomplete("no baseline plan version")
        }
        let planID = plan.id
        let items = try PlanRepository.planItems(context: context, plan: plan)
        guard try PlanRepository.isStructurallyComplete(plan, context: context) else {
            throw MigrationError.baselineIncomplete(
                "the stored plan graph is not internally consistent "
                + "(payday sequence, per-card balances, income rules, or final balance)"
            )
        }
        let debts = try context.fetch(FetchDescriptor<DebtAccount>())

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

        // §7.3 — the two 0.1.x obligations become `RecurringObligation` rows.
        //
        // A 0.1.x store recorded only the smoothed per-check reserve, so the
        // billed amount has to be recovered by inverse R-04 from the store's
        // own numbers. It used to be hard-coded, which meant the app carried
        // one real user's bills as constants and would have written those
        // amounts into *anybody's* store.
        //
        // The guard is unchanged in spirit and stricter in effect: the
        // recovered amount must smooth back to the stored per-check reserve
        // exactly, or migration aborts. No stored value is ever rewritten to
        // make the math agree.
        let existingObligations = try context.fetch(FetchDescriptor<RecurringObligation>())
        let cadence = plan.payCadence

        func makeObligation(
            name: String, legacyKey: String, storedReserve: Decimal
        ) throws -> (RecurringObligation, Bool) {
            if let existing = existingObligations.first(where: { $0.legacyKey == legacyKey }) {
                return (existing, false)
            }
            let recovered = ObligationMath.amount(
                fromPerPaycheckReserve: storedReserve,
                cadence: .monthly,
                paychecksPerYear: cadence.paychecksPerYear
            )
            let resmoothed = ObligationMath.perPaycheckReserve(
                amount: recovered, cadence: .monthly, paychecksPerYear: cadence.paychecksPerYear
            )
            guard resmoothed == storedReserve else {
                throw MigrationError.obligationMathMismatch(
                    "\(legacyKey): recovered amount does not reproduce the stored per-check reserve"
                )
            }
            let obligation = RecurringObligation(
                name: name, amount: recovered, cadence: .monthly,
                accountID: checking2.id, legacyKey: legacyKey, createdAt: now, updatedAt: now
            )
            context.insert(obligation)
            return (obligation, true)
        }

        let (car, carCreated) = try makeObligation(
            name: "Car", legacyKey: legacyCarKey, storedReserve: plan.carReservePerCheck
        )
        if carCreated { obligationsCreated += 1 }

        let (train, trainCreated) = try makeObligation(
            name: "Transit pass", legacyKey: legacyTransitKey, storedReserve: plan.trainReservePerCheck
        )
        if trainCreated { obligationsCreated += 1 }

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

        // §7.8 — stamp this step only. The 2 → 3 step stamps the rest, so a
        // store that completes 1 → 2 and then fails is honestly recorded as
        // being at 2 rather than claiming a version it never reached.
        if let settings = try context.fetch(FetchDescriptor<AppSettings>()).first {
            if settings.seedSchemaVersion < 2 {
                settings.seedSchemaVersion = 2
                settings.migratedAt = now
                settings.migrationAuditNote =
                    "Upgraded schema 1→2: Checking 1/2 converted to cash accounts, "
                    + "recurring obligations created from stored reserves, plan values preserved verbatim."
            }
        } else {
            let settings = AppSettings(
                onboardingComplete: true,
                seedSchemaVersion: 2,
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
