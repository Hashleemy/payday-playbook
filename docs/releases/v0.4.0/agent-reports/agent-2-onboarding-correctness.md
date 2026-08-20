# Agent 2 — Onboarding & Debt Correctness report (v0.4.0)

- **Role:** Onboarding Validation and Reactive Setup owner — V4-01 (debt-type-specific
  validation) and V4-02 (reactive onboarding/setup state).
- **Branch:** `feature/v0.4-onboarding-correctness`, branched from the Agent 1 contract
  commit `b71e193` (verified: `git log` ancestry and clean tree before work began).
  *Naming note:* the plan document (§6) names this branch
  `feature/v0.4-validation-reactivity` and this report
  `agent-2-validation-reactivity.md`; the launch prompt for this agent named
  `feature/v0.4-onboarding-correctness` and `agent-2-onboarding-correctness.md`, and the
  branch had been created under that name. The prompt's names are used; the scope is
  identical. Recorded here so Agent 7's merge script keys on the right ref.
- **Date:** 2026-08-20.

This report contains no real person's financial values (V3-12/V3-13, permanent). All
fixtures are fictional ("Card Alpha", "Card Beta", "Auto Loan", far-future 2054 dates).

## Outcome

1. **V4-01:** No surface asks a credit card for an original amount any more. The three
   validation surfaces — editor rules, Bills & Debts row chips, and the completeness
   gap list that feeds the onboarding Review step and the Settings upgrade checklist —
   now all consult the one semantic source (`DebtType.usesOriginalPrincipal`, landed by
   Agent 1) and agree field-by-field per the MVP_LAYOUT §4.6 matrix, pinned by the new
   T-18 suite on identical fixtures. The blocking set is unchanged: only missing
   installment minimums (A-06) and the structural blockers block generation.
2. **V4-02:** Derived setup state is keyed to a canonical content fingerprint
   (`SetupInputFingerprint`: row IDs + `updatedAt` across every input family), never to
   row counts or view identity. The Review step's Generate captures the fingerprint,
   Commit re-verifies it inside `OnboardingProgressService.finish` and throws before
   writing anything on mismatch — persisting a stale preview is impossible at the
   service boundary, pinned by the new T-19 suite. Previews remain write-free end to
   end (a body-side store write in the Review step was found and removed).

## Root cause — the "Still needs the original amount" bug (V4-01)

The three surfaces disagreed because two of them never consulted the type:

- `SetupCompletenessService.debtGaps()` emitted the `.originalPrincipal` gap for **every**
  debt with `originalPrincipal == nil` — no type guard (`SetupCompletenessService.swift`,
  formerly line 207).
- `BillsAndDebtsLoader.warnings(for:)` appended **"the original amount"** for every such
  debt — no type guard (`BillsAndDebtsState.swift`, formerly line 212). This is the
  literal "Still needs the original amount." chip on the setup review row.
- The editors, meanwhile, already hid the field for cards — so a card user was told a
  field was missing that no editor would ever show them: an unresolvable chip.

A second asymmetry: `DebtFormRules` (the onboarding editor's field rules) kept its own
per-type table beside the model predicates, and its visibility gate
(`rules.originalPrincipal != .optional || originalPrincipal != nil || type != .creditCard`)
would even re-show the field for a card carrying a stray stored value. Chip labels also
contradicted the §4.6 matrix: due day claimed "Required" on four types and credit limit
claimed "Required" on cards, though neither ever blocks anything anywhere.

## Root cause — stale downstream setup state (V4-02)

- **Count-keyed invalidation.** `BillsAndDebtsView` reloaded its derived
  `BillsAndDebtsState` (summary totals, per-paycheck reserve preview, warnings) only on
  `onChange(of: obligations.count)` / `onChange(of: debts.count)`. A value-only edit —
  amount, APR, cadence, due day — changes no count and refreshed nothing. Worse, the
  income schedule (whose cadence the reserve preview smooths against) was not observed
  at all.
- **View-identity-accident freshness.** The onboarding flow's step `switch` destroys and
  recreates step views on navigation, which *incidentally* reset the Review step's
  cached `@State generated` preview and `gaps` list. Nothing else ever invalidated them:
  `gaps` was loaded once per view identity (`.task`), and no code path cleared
  `generated` when inputs changed. The contract's warning was accurate — a refactor that
  kept view identity across steps would silently ship stale state.
- **No commit re-verification.** `commit()` persisted the cached preview verbatim.
  Any store mutation between Generate and Commit produced an immutable baseline plan
  built from inputs the user had already replaced — and `PlanPersister.insertPlanGraph`'s
  name-keyed idempotency would then silently pin the stale plan forever.
- **A write inside `body`.** The Review step's guardrails card called
  `GoalProfileRepository.profile()`, which *creates and saves* a `UserGoalProfile` row if
  none exists — a store write from view rendering, on what must be a write-free preview
  screen.
- **Smaller instances of the same disease:** the Settings gap list and the Settings
  badge did not observe the income schedule; the reminders step derived its payday
  preview from an unobserved imperative fetch; the goal step's posture suggestions
  armed their "user touched this" flags from `onChange`, which also fires for
  programmatic writes — so after the first suggestion, posture switches never updated
  untouched fields again (a stale derived recommendation).

## Architectural fix

**One rule, stated once.** *Inputs persist; derivations are recomputed or invalidated
whenever any dependency changes, keyed by content.*

1. **`SetupInputFingerprint`** (new, `Services/SetupInputFingerprint.swift`): the
   canonical content fingerprint over every setup input family — `UserGoalProfile`,
   `CashAccount`, `IncomeSchedule`, `IncomeChange`, `RecurringObligation`,
   `DebtAccount` — as sorted `family:id:updatedAt:archived` lines. Row edits bump
   `updatedAt` in every repository (verified: `SetupRepositories`,
   `CashAccountRepository`, and the Debts-tab editor), inserts/deletes change the line
   set, so any content change — same-count edits included — changes the value.
2. **Invalidation keys on the fingerprint.** `BillsAndDebtsView` now observes all four
   input families (`@Query`) and reloads on `onChange(of: inputFingerprint)`; the two
   count-keyed observers are gone. `ReviewStepView` observes all six families and, on
   fingerprint change, recomputes the gap list and **drops** a cached preview whose
   fingerprint no longer matches (with a calm notice — the preview is cleared rather
   than silently rebuilt, so the user only ever confirms numbers they have seen; the
   button reverts to "Generate My Plan").
3. **The commit-staleness guard is service-level, not view-level.**
   `OnboardingProgressService.finish(planName:input:result:verifying:)` recomputes the
   fingerprint and throws `FinishError.staleInputs` *before any write* when it differs
   from the one captured at Generate. `ReviewStepView.generate()` captures the
   fingerprint **before** building the input (so a mutation racing the engine run reads
   as a mismatch, never as freshness), and `commit()` always passes it — a preview with
   no fingerprint provenance is treated as stale. The only production caller of
   `finish` is the Review step, and it always verifies.
4. **Previews stay write-free.** The Review step renders the guardrails card from a
   `@Query` (`profiles.first`) instead of the row-creating repository accessor; T-19
   asserts that repeated previews leave the store fingerprint byte-identical and persist
   zero plan rows.
5. **The remaining derived surfaces observe their actual inputs.** Settings' "Review
   setup" gap list and badge observe income (and, for the badge, all checklist inputs);
   the reminders step's payday preview derives from an observed `@Query` schedule
   through a new testable `RemindersStepView.upcomingPaydays(for:)`; the goal step's
   suggestion logic distinguishes programmatic suggestion writes from user edits (and
   the R-14 table is now the testable `GoalStepView.suggestedDefaults(for:)`).
6. **V4-01 is the predicate, applied.** `SetupCompletenessService` and
   `BillsAndDebtsLoader.warnings` gate the original-principal gap/warning on
   `debt.debtType.usesOriginalPrincipal`; `DebtFormRules` gained
   `showsOriginalPrincipal` forwarding to the same predicate and the editor shows the
   field iff it is true (never for cards, even with a stray stored value — stored data
   is never silently mutated, only the ask is gated). Chip labels now match §4.6: due
   day "Optional" for all six types, credit limit "Optional" unless marked unknown; the
   loans' "Required" original-principal chip stays, presentation-only, per the contract.
7. **Onboarding utilization call sites route through `UtilizationMath`** (Agent 1's
   canonical R-12 implementation): the debt editor's inline `balance/creditLimit`
   preview, the setup row's threshold colors, and the Review step's aggregate "Card
   usage" ratio. No threshold literal remains in my files.
8. **`ObligationsStepView` retired** (optional scope, taken): the unrouted v0.2.0
   standalone obligations step and its private row view are deleted; the shared
   `ObligationEditorView`/`ObligationEditorTarget` remain (used by Bills & Debts and
   the Settings checklist). The `.obligations` raw value and resume mapping are
   untouched and still tested — stored progress is data; the unreachable screen was not.

## Files changed

App (11 modified, 1 new):

- `PaydayPlaybook/Services/SetupCompletenessService.swift` — type-gate the
  original-principal gap (V4-01).
- `PaydayPlaybook/Features/Setup/BillsAndDebtsState.swift` — type-gate the "the
  original amount" chip warning (V4-01).
- `PaydayPlaybook/Features/Onboarding/DebtsStepView.swift` — `DebtFormRules` unified
  with §4.6 (`showsOriginalPrincipal` forwards to the predicate; due-day and
  credit-limit chips per matrix); editor visibility gate simplified; utilization
  preview and row colors through `UtilizationMath` (V4-01, V4-04 call sites).
- `PaydayPlaybook/Services/SetupInputFingerprint.swift` — **new**; the canonical
  content fingerprint (V4-02).
- `PaydayPlaybook/Services/OnboardingProgressService.swift` — `finish(verifying:)` +
  `FinishError.staleInputs` (V4-02 commit guard).
- `PaydayPlaybook/Features/Onboarding/ReviewStepView.swift` — full input observation;
  fingerprint-keyed gap refresh and preview invalidation with stale notice; commit
  guard wiring; body-side write removed; aggregate utilization through
  `UtilizationMath`.
- `PaydayPlaybook/Features/Setup/BillsAndDebtsView.swift` — content-fingerprint reload
  replacing the two count-keyed observers; income/account observation.
- `PaydayPlaybook/Features/Onboarding/GoalStepView.swift` — posture-suggestion
  staleness fix; testable R-14 table.
- `PaydayPlaybook/Features/Onboarding/RemindersStepView.swift` — observed schedule;
  testable `upcomingPaydays(for:)` extraction.
- `PaydayPlaybook/Features/Onboarding/ObligationsStepView.swift` — retired step view;
  shared editor kept.
- `PaydayPlaybook/Features/Settings/ReviewSetupView.swift` — income observation for the
  gap list. *(Outside my single-owner list; unowned by any other agent; smallest change
  meeting V4-02 — flagged for Agent 7's per-diff review.)*
- `PaydayPlaybook/Features/Settings/SettingsView.swift` — the "Review setup" badge
  observes the checklist inputs. *(Same note as above.)*

Tests (2 new suites, 1 re-anchored):

- `PaydayPlaybookTests/DebtTypeValidationMatrixTests.swift` — **new (T-18, 9 tests)**.
- `PaydayPlaybookTests/ReactiveSetupTests.swift` — **new (T-19, 12 tests)**.
- `PaydayPlaybookTests/UpgradeChecklistTests.swift` — re-anchored to V4-01: a migrated
  all-card store emits **no** original-principal gap (the old expectation pinned the
  defect); the checklist story no longer "answers" a question cards are never asked;
  new test proves the ask *appears* when the user confirms a defaulted card is really a
  loan — the concept survives for the types that have it.

## Tests added

**T-18 `DebtTypeValidationMatrixTests` (9):** card with no original principal passes
setup validation end-to-end (zero gaps, zero warnings, plan generates) — prompt case 1;
no surface asks a card (editor rules, chips, gap list, presentation predicate);
installment types keep the optional never-blocking gap on all three surfaces with
blank-save accepted — case 2; credit limit never interpreted as, satisfied by, or
confused with original principal (distinct gap kinds; utilization reads the limit,
never the principal; a card with only an original principal has *unknown* utilization)
— case 3; credit limit never asked of non-cards (chips, gaps, editor, and model-layer
rejection); `creditLimitMarkedUnknown` stops every ask; the blocking set is exactly
installment minimums among per-debt fields (direct-inserted minimum-less rows per
type); chips and gap list agree field-by-field on identical fixtures for all six types;
due day is an optional gap for every type.

**T-19 `ReactiveSetupTests` (12):** fingerprint stability (no-op, and across fresh
contexts on one store); every input family's edit changes it (profile, account balance,
income, income change, bill, debt, archive, delete, insert); same-count edits
invalidate and the reloaded Bills & Debts state shows the new totals; a cadence edit
reaches the reserve-smoothing preview ($1300 monthly: $600.00 biweekly ↔ $1300.00
monthly, R-04); **commit refuses a stale preview** (edit a card balance between
Generate and Commit → `staleInputs`, zero plan rows persisted, onboarding not
completed) — cases 4–7; commit succeeds when unchanged; the regenerated preview derives
from the edited balance (new input value, different projected interest, fresh
fingerprint commits cleanly, persisted snapshot decodes to the new input) — case 8; an
APR edit retargets the avalanche attack and changes the payoff order — case 9; an
income/payday edit moves both the reminders-step payday preview and the regenerated
plan's pay rows — case 10; a due-day edit lands in the regenerated plan input's
downstream metadata — case 11; preview navigation persists no plan version and touches
no input (byte-identical fingerprint) — cases 12–13; many previews + one commit = one
plan version.

The V2-01 kill/resume matrix (`OnboardingSetupTests`, `OnboardingProgressTests`) runs
unmodified and green — resumability is untouched.

## Test commands and results

Per `TESTING.md`: dedicated simulator (`xcrun simctl create "PP-Agent2-Unit"
"iPhone 17 Pro" iOS 26.5), dedicated `-derivedDataPath` outside `~/Documents`
(`/private/tmp/claude-501/pp-agent2-dd`). UI suite not run against this simulator or
in parallel (no UI-test changes; the one UI assertion touching my surfaces —
auto-loan editor shows `debt.originalPrincipal` — is preserved by design and left to
Agent 7's serial run on its own simulator).

```bash
# Focused (V4-01/V4-02 + neighbors): all passed
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,name=PP-Agent2-Unit' \
  -derivedDataPath /private/tmp/claude-501/pp-agent2-dd \
  -only-testing:PaydayPlaybookTests/DebtTypeValidationMatrixTests \
  -only-testing:PaydayPlaybookTests/ReactiveSetupTests \
  -only-testing:PaydayPlaybookTests/UpgradeChecklistTests \
  -only-testing:PaydayPlaybookTests/OnboardingSetupTests \
  -only-testing:PaydayPlaybookTests/OnboardingProgressTests \
  -only-testing:PaydayPlaybookTests/DebtTypeTests \
  -only-testing:PaydayPlaybookTests/DebtPresentationTests \
  -only-testing:PaydayPlaybookTests/UtilizationMathTests \
  test

# Full unit suite: 548/548 passed (526 at the contract commit + 21 new + 1 added
# to UpgradeChecklistTests)
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,name=PP-Agent2-Unit' \
  -derivedDataPath /private/tmp/claude-501/pp-agent2-dd \
  -only-testing:PaydayPlaybookTests test
```

## Decisions worth review

1. **Stored original principal on a card is kept, silently, forever.** The matrix
   gates the *ask/warn/gap*, not storage. A card that carries a value (a former loan
   retyped, a restored backup) keeps it; no editor shows it for cards, no validation
   strips it. Silent data deletion would be worse than an invisible dormant field.
   `principalBasis` still falls back to `startingBalance` when nil (unchanged).
2. **Stale preview → cleared, not auto-regenerated.** The contract allowed either;
   clearing plus a notice means the user never confirms numbers they haven't seen.
3. **Chip-label changes** (due day and credit limit now "Optional" per §4.6) are
   user-visible copy changes on the debt editor — no behavior change, since neither
   ever blocked.
4. **`finish(verifying:)` defaults to `nil`** for source compatibility with existing
   tests; the Review step always passes it, and it is the only production caller.
5. **The fingerprint reads the whole store per body evaluation** (six fetches). At this
   app's scale that matches the existing "fetch whole tables, filter in memory" posture
   documented in TESTING.md; revisit only if that posture is revisited.

## Remaining integration concerns (adapted, not fixed — per boundaries)

1. **Engine still warns about marked-unknown card limits.** `DebtInput` carries no
   `creditLimitMarkedUnknown`, so `AvalanchePlanEngine` emits `creditLimitMissing` for
   a card the user explicitly marked unknown — the plan's "Worth knowing" list can
   nag where setup no longer does. Engine contracts are Agent 3's; the §4.6 marked-
   unknown rule holds on all three of my surfaces. Registry item for Agent 3/7.
2. **Scenario-apply has no input-recency guard.** `GeneratedPlanService.activate` and
   `ScenarioPlanActivationService.apply` persist a preview's captured input with no
   fingerprint verification — the same class of hole the Review step just closed,
   on Agent 3's files. `SetupInputFingerprint` is reusable there as-is.
3. **Count-keyed observers outside setup remain** (my sweep found: `DebtsView`
   ledger/snapshot counts, `CalendarTabView` check-in/ledger counts, `ProgressTabView`
   three counts, `PlanOverviewView` two, `AccountsTabView` one). They key *dashboard*
   derived state, owned by Agents 4/5/6; V4-02's contract text names setup state only,
   but the same fingerprint technique applies. Flagged for the owners and Agent 7's
   merged-tree defect hunt (Agent 6's dashboard-refresh contract already covers the
   Calendar instance).
4. **Percent display formatting is not yet standardized** ("nearest whole percent",
   "<1%") in the onboarding call sites — deliberately left to Agent 4, who owns the
   display-rounding half of R-12. My sites consume the canonical ratio and thresholds;
   the strings still use `rounded2` two-decimal formatting. Call sites for Agent 4's
   sweep: `DebtsStepView` row + editor preview, `ReviewStepView` aggregate.
5. **Two Settings files edited outside my single-owner list** (`ReviewSetupView.swift`,
   `SettingsView.swift`, observation-only changes; no other agent owns them). Agent 7
   should confirm no collision at merge — Agent 4's CTA sweep and Agent 5's vocabulary
   sweep both stay out of these files per their prompts.
6. **`PlanPersister.insertPlanGraph` idempotency is name-keyed.** With the commit
   guard, the Review flow can no longer reach it twice with different inputs, but the
   underlying return-existing-row-untouched behavior is unchanged and remains the
   §4.0 double-finish bar (still tested).
7. **UI-level onChange firing is pinned indirectly.** T-19 proves the invalidation
   *key* changes and the commit guard refuses staleness at the service boundary; the
   SwiftUI `onChange(of: fingerprint)` plumbing itself is exercised only by the
   existing UI suite. If Agent 7 wants a direct UI regression for back-edit-forward,
   the hooks (`review.staleNotice` accessibility identifier) are in place.

## Commits

On `feature/v0.4-onboarding-correctness` (base `b71e193`):

- `PENDING_SHA` — fix(onboarding): make debt validation type-aware and previews
  reactive (14 files: the V4-01 trio, the fingerprint service and commit guard, the
  reactive step views, the retired obligations step, two Settings observation fixes,
  T-18 + T-19, and the re-anchored upgrade-checklist suite).
- (+ one follow-up commit recording this hash here, per the Agent 1/v0.3.0 precedent.)
