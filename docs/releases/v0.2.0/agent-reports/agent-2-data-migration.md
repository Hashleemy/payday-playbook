# Agent 2 report — Data Model, Persistence & Migration (v0.2.0)

*(Edited 2026-08-13 under V3-12: personal financial values and the founding user's name redacted; all technical content, decisions, and results otherwise unchanged.)*

Branch: `feature/v0.2-data-migration` (based on Agent 1's `07bcf2f`) · Date: 2026-08-10
Scope: schema 2 models, schema 1→2 migration, planning DTOs, repositories, backup schema 2, tests. No feature screens, no optimizer math, no notification scheduling.

## Schema 2 at a glance

New models are additive; every schema-1 model keeps its shape (new columns are
optional or property-defaulted, so SwiftData migrates the store lightweight —
the logical upgrade is code, §Migration below).

```text
UserGoalProfile (spec: UserProfile)          CashAccount (spec: CheckingAccount)
  goalText?, targetDebtFreeDate?,              name, currentBalance, roles{income,
  posture, protectedFloor, allowanceCap,       spending,reserves}, isDefaultIncome
  onboardingCompletedAt?                       (exactly 1 active), sortOrder,
                                               isArchived, legacyKindRaw?
OnboardingProgress (spec: OnboardingState)
  lastCompletedStep, startedAt,              RecurringObligation (spec: Obligation)
  completedAt?  — steps write real rows;       name, amount, cadence(weekly…annual),
  this row only tracks position                dueDay?, accountID?, isArchived,
                                               legacyKey? ("car"/"train")
IncomeSchedule ── IncomeChange (1:N)
  cadence(weekly/biweekly/semimonthly/       PlannedObligationReserve
  monthly), anchorPayday, monthly/              paydayPlanItemID → obligationID,
  semimonthly days, destinationAccountID?,     amount (frozen at generation /
  baseTakeHome                                 copied verbatim by migration)

PlanVersion (extended)                       DebtAccount (extended)
  + payCadence, monthly/semimonthly days,      + debtType (6 kinds), original-
  + incomeAccountID?, generatedFromProfile,      Principal?, creditLimit?,
  + inputSnapshotData? (encoded                  isExtraPrincipalEligible
    PlanningInput → reproducible plans)          (status derived, never stored)

PaydayPlanItem  + shortfallAmount? (R-09)    AppSettings + migratedAt?, auditNote
LedgerEntry     + source/destinationAccountID? (legacy raws untouched beside them)
BalanceSnapshot + cashAccountID?             NotificationKind + obligationDueSoon/Today
```

Spec-name compatibility: `typealias CheckingAccount = CashAccount`,
`UserProfile = UserGoalProfile`, `Obligation = RecurringObligation`,
`OnboardingState = OnboardingProgress` — downstream agents may use either name.

## Migration path (schema 1 → 2, V2-16)

`MigrationService.migrateIfNeeded` runs in `PaydayPlaybookApp.init`, before any
UI, on `AppSettings.seedSchemaVersion < 2`:

1. **Routing** — `detectInstallState`: no settings & no plan → `.freshInstall`
   (nothing written; onboarding is the only path to a plan); stamp ≥ 2 →
   `.upToDate`; otherwise `.legacyNeedsMigration`. A crashed 0.1.x partial
   seed is repaired by the 0.1.x seeder first, exactly as a 0.1.x launch would.
2. **Integrity pre-check** — baseline plan present with its full expected
   complement of plan items and debts, else abort (store untouched, retry
   next launch).
3. **Checking 1/2 → CashAccount** — roles income+spending (default income) /
   reserves; balances **derived** from the existing snapshot+ledger state via
   `AccountBalanceService` (nothing invented); `legacyKindRaw` keeps the
   mapping stable. Ledger and snapshot rows gain `…AccountID` references;
   their legacy raw fields are not modified.
4. **Car/train → RecurringObligation** (the two baseline monthly obligation
   amounts) — the R-04 smoothing is verified to reproduce the stored
   per-paycheck reserve amounts **before** committing; a mismatch aborts the
   whole migration.
5. **Plan metadata** — `payCadence=.biweekly`, `incomeAccountID`,
   `generatedFromProfile=false`. **No `PaydayPlanItem`/check-in/ledger/
   snapshot/forecast/milestone value is touched**; Original Plan v1 keeps
   `calculationVersion = 1` and `inputSnapshotData = nil`.
6. **Reserve rows** — two `PlannedObligationReserve` rows per plan item,
   values copied from the stored car/train columns, never recomputed.
7. **Profile & onboarding** — default `UserGoalProfile` (steady, floor/
   allowance copied from the plan) and a completed `OnboardingProgress`: the
   migrated user never re-onboards. Missing notification-kind rows are added;
   existing rows untouched.
8. **Stamp** — `seedSchemaVersion = 2`, `migratedAt`, audit note. Everything
   above happens in **one save**; any throw rolls the context back.

Idempotency: every step guards on existence (`legacyKindRaw`, `legacyKey`,
per-item reserve presence, fetch counts), so repeated launches — and even a
forced re-run of the upgrade — insert nothing.

Template loads (`PlanSeeder`) apply the same logical upgrade in the same save,
so a deliberate Original-Plan-v1 load on a fresh v2 store lands complete.

## Shared DTO contract (Agent 2 ↔ Agent 3)

`PaydayPlaybook/Services/PlanningDTO.swift` — Foundation-only, no SwiftData:

- **`PlanningInput`** — calculationVersion, cadence + day-of-month fields
  (R-11: stored 31 ≡ "last day"), nextPayday anchor, baseTakeHome +
  `[PlanningIncomeChange]`, spendingStartingBalance, protectedFloor,
  allowanceCap, firstCheckBufferAdd, `[PlanningObligation]`, `[PlanningDebt]`
  (array order = creation order, the final R-08 tie-break), paycheckCap
  (default 600, A-05), timeZoneID.
- **`PlanningResult`** — `[PlanningPayday]` (income, keepInSpending,
  transferToReserves, allowance, floorTopUp, obligationReserves, debtBudget,
  targetDebtID?, perDebtBalancesAfter, totalDebtAfter, noSpendCeiling,
  shortfallAmount? for R-09), payoffDate?, totalEstimatedInterest,
  paycheckCount, debtPayoffs, cappedAtPaycheckLimit.
- **Money is `Decimal` in memory and a JSON *string* on the wire** (custom
  Codable; never a binary-float JSON number). `PlanningSnapshotCoder` gives
  deterministic bytes (sorted keys, ISO-8601) for
  `PlanVersion.inputSnapshotData`.
- **`ObligationMath.perPaycheckReserve`** is the one shared R-04
  implementation (`round2(amount × occurrencesPerYear ÷ paychecksPerYear)`);
  generator, migration check, and onboarding previews must all use it.
- Flow: `PlanningInputBuilder.build()` (store → input) → engine (Agent 3,
  pure) → `OnboardingProgressService.finish(planName:input:result:)` →
  `PlanPersister.insertPlanGraph` (atomic, duplicate-proof, snapshot stored).
  The engine never sees a `ModelContext`.
- Note for Agent 3: the enums `DebtType`, `PayCadence`, `ObligationCadence`
  are declared in model files but are plain Swift enums with no SwiftData
  dependency — safe to use from pure engine code.

## Changed files

| File | Change |
| --- | --- |
| `Models/CashAccount.swift` · `RecurringObligation.swift` · `UserGoalProfile.swift` · `OnboardingProgress.swift` · `IncomeSchedule.swift` · `PlannedObligationReserve.swift` | New models + role/cadence/posture/step enums + spec-name typealiases |
| `Models/DebtAccount.swift` | `DebtType` (6 kinds) + type metadata, utilization, principal basis, derived status |
| `Models/PlanVersion.swift`, `PaydayPlanItem.swift`, `LedgerEntry.swift`, `BalanceSnapshot.swift`, `AppSettings.swift`, `NotificationPreference.swift` | Additive schema-2 columns (all defaulted/optional), new notification kinds + `missingDefaults` |
| `Models/ModelValidation.swift` | New: per-type debt rules, account/obligation/income validation, day-of-month bounds, last-four privacy rule |
| `Services/PlanningDTO.swift` | New: `PlanningInput`/`PlanningResult`, money-string Codable, `ObligationMath`, `PlanningSnapshotCoder` |
| `Services/MigrationService.swift` | New: routing, §7 logical upgrade, single-transaction + rollback |
| `Services/CashAccountRepository.swift` | New: account CRUD + exactly-one-default-income invariant |
| `Services/OnboardingProgressService.swift` | New: step persist/resume + atomic duplicate-proof finish |
| `Services/PlanPersister.swift` | New: input builder + result persister (R-08 order, milestones, snapshot) |
| `Services/PlanContract.swift` | `currentSchemaVersion = 2`, `currentCalculationVersion = 2` beside frozen v1 constants |
| `Services/PlanSeeder.swift` | Template loads apply the logical upgrade in-save; reserve-row cleanup in repair; test-only `applySchemaUpgrade` flag |
| `Services/ExportService.swift` | Backup schema 2 (writes 2, imports 1–2); v1 import runs the logical migration; restore is now a true single transaction; append-only debts CSV columns |
| `App/PaydayPlaybookApp.swift`, `PaydayPlaybookTests/TestSupport.swift` | Schema lists + launch migration hook |
| Tests | New: `MigrationServiceTests` (13) · `CashAccountRepositoryTests` (8) · `DebtTypeTests` (10) · `OnboardingProgressTests` (5) · `PlanningContractTests` (7) · `ExportCompatibilityTests` (7) |

## Test commands & results

```bash
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:PaydayPlaybookTests test    # 104 tests, 0 failures
# UI suite (unchanged 0.1.x behavior):
  … -only-testing:PaydayPlaybookUITests test  # 9 tests
```

Unit: **104/104 green** (54 carried-forward 0.1.x + 50 new). One review-pass
test caught a real data-loss defect before it shipped: SwiftData's batch
`context.delete(model:)` operates at the store level, so a failed v1-import
migration after deletion could not be rolled back and left the store empty.
`deleteAllWithoutSaving` now deletes rows through the context, and
`testV1ImportMigrationFailureRollsBackTheWholeRestore` pins the guarantee
(mission rule 7: no partial write, ever). Mission coverage:
clean-vs-upgrade routing · every baseline payday value-for-value (every field
of every item compared before/after) · derived C1/C2 balances incl. the
same-day snapshot rule · R-04 reduction of both baseline monthly obligations
to their stored per-paycheck reserves + five more cadences to the cent · all six debt types + per-type validation · unknowns
stay nil (no fabrication) · due-date edits persist prospectively with the
baseline untouched · interrupted/resumed onboarding, no regression, no
duplicate rows on double-finish · migration idempotent across launches and
forced re-runs · induced failure aborts with a clean, untouched store · v1
backup imports through migration · v2 round-trip · future-schema files fail
with a clear message and no partial write · CSV columns append-only ·
DTO money-exactness (0.2999, 0.10) and deterministic snapshots · R-08
ordering (ties, 0% APR) · exactly-one-default-income under add/edit/archive.

### Adversarial review outcome

A 5-lens multi-agent review (migration correctness, SwiftData pitfalls,
contract compliance, export compatibility, boundary/tests) produced 26 raw
findings; 3 were confirmed on verification and all 3 are resolved:

- **HIGH — template lookup ambiguity (fixed).** `PlanSeeder.existingBaseline`
  matched *any* `isOriginalBaseline == true` plan, but onboarding-generated
  plans carry that flag too (§4.9/A-04) — so a future template load onto a
  store holding a generated plan would have judged it "incomplete" and
  `removePlanGraph` would have deleted the user's plan, all debts, and all
  milestones. The lookup is now keyed on `PlanContract.planName`
  ("Original Plan v1"), `removePlanGraph` deletes only template-owned debts
  (keyed by the plan's avalanche order) and milestones, the §7.4 debt stamp
  is scoped the same way, and migration's Checking 1 conversion no longer
  claims default-income when the store already has a default. Regression
  tests: `testTemplateSeedDoesNotTouchAGeneratedPlanGraph`,
  `testSeedRepairRemovesOnlyTemplateRows`.
- **MEDIUM — `originalPrincipal` deviation (kept, documented).** See
  assumption 1 below; the spec text needs amending to match.
- **LOW — mid-onboarding legacy store flags (fixed).** A 0.1.x store whose
  onboarding was quit before the last step migrated with a finished
  `OnboardingProgress` but `AppSettings.onboardingComplete` still false —
  contradictory signals that would re-onboard a fully migrated user. The
  launch migration and the v1-backup restore now set
  `onboardingComplete = true` after a successful upgrade (deliberately *not*
  inside `applyLogicalUpgrade`, which the live onboarding flow runs mid-flow
  and which must not complete onboarding out from under it). Regression
  test: `testMidOnboardingLegacyStoreNeverReonboards`.

## Assumptions & deliberate decisions

1. **`originalPrincipal` stays `nil` on migrated debts** — deviation from
   MVP_LAYOUT §7 step 4 ("originalPrincipal = startingBalance"), required by
   this mission's rule 5 (never fabricate a principal). Display behavior is
   identical: `principalBasis` falls back to `startingBalance`, which is
   exactly how 0.1.x computed percent-paid. Upgrade onboarding may ask later.
   If product prefers the spec's stamping, it is a two-line change.
   **Review-confirmed contract deviation**: schema-2 backups and the debts
   CSV export an empty `originalPrincipal` where §7.4 as written expects the
   starting balance. Decision stands (mission rule 5 outranks), but
   MVP_LAYOUT §7 step 4 should be amended to say the field stays unknown —
   flagged for the doc owner.
2. Mission model names are canonical (`CashAccount`, `UserGoalProfile`,
   `RecurringObligation`, `OnboardingProgress`); spec §6 names are typealiases.
3. Semimonthly/monthly "last day" is stored as day 31 — R-11 clamping makes
   31 ≡ last-day in every month, so no sentinel is needed (documented on the
   fields).
4. Account cap (A-02, 10 accounts) is a UI concern; the model layer is
   uncapped per this mission ("unlimited user-created accounts").
5. The store-level schema change is purely additive, so SwiftData lightweight
   migration handles the container and no `VersionedSchema`/
   `SchemaMigrationPlan` is needed; the logical §7 upgrade is explicit,
   transactional code (`MigrationService`) with the version stamp in
   `AppSettings.seedSchemaVersion`. This is also what makes in-memory
   migration tests possible.
6. Generated plans put obligation reserves only in `PlannedObligationReserve`
   rows; the legacy `plannedCarReserve`/`plannedTrainReserve` columns are 0
   for them (kept verbatim on migrated items). Readers should prefer the
   reserve rows and fall back to the legacy columns for Original Plan v1
   (both are populated there).
7. Amount-eliminated milestones are seeded only for the template/migrated
   plan; generated plans get per-debt payoff + debt-free milestones. Adding
   amount milestones for generated plans belongs to the milestone/progress
   owner if wanted.
8. Migrated installs also get a live `IncomeSchedule` (+`IncomeChange` for the
   plan's scheduled raise) copied from the plan's income rules so Settings can
   edit income forward; the plan's own `IncomeRule` rows remain the frozen
   truth.

## Risks / notes for downstream agents

- **Engine dispatch**: reforecast/generation must dispatch on
  `PlanVersion.calculationVersion` (1 = frozen §3 rules, 2 = §5). The data
  layer guarantees the stamp; Agent 3 owns the dispatch.
- **UI reads**: dashboards should now resolve accounts via
  `CashAccountRepository` (roles), not the `MoneyAccount` raws; the raws
  remain valid for ledger history rendering.
- **`PlanPersister` duplicate guard is name-based** ("Plan v1"): callers
  creating *new* plan versions (F-13 edits) must choose fresh names ("Plan
  v2", …) — the plan-versions owner should enforce naming.
- **Backup import of v1 files uses wall-clock "now"** for the derived account
  balances (same as an app upgrade at that moment). Deterministic tests pin
  the date via `FixedDateProvider`.
- The `--uitest-skip-onboarding` path still seeds via `PlanSeeder`, which now
  lands schema-2-complete; UI agents can rely on accounts/obligations existing
  in that fixture.

## Commit

`feat(v0.2.0): schema-2 data layer — models, 1→2 migration, planning DTOs, backup v2` — hash in the final agent message.
