# Agent 4 report — Onboarding, Goals, Accounts, Debts & Income Setup (v0.2.0)

Branch: `feature/v0.2-onboarding` (Agent 2's `65a9236` + Agent 3's `f0885d1`, merged here) · Date: 2026-08-11
Scope: `Features/Onboarding`, onboarding-facing Settings, the setup repositories, and the store↔engine bridge. No optimizer math, no migration internals, no calendar scheduling, no dashboard files.

## What shipped

A resumable eight-screen setup flow that turns a fresh install into a real generated plan, plus the upgrade checklist that existing installs get **instead** of re-onboarding.

| Screen | Mission items | File |
| --- | --- | --- |
| Welcome & privacy (+ template path) | 1 | `WelcomeStepView.swift` |
| Goal, posture, target date, floor, allowance | 2 | `GoalStepView.swift` |
| Checking accounts (CRUD, roles, default income) | 3 | `AccountsStepView.swift` |
| Debt type picker → type-specific details | 4, 5 | `DebtsStepView.swift` |
| Income (4 cadences, destination, future change) | 6 | `IncomeStepView.swift` |
| Essential obligations (live reserve preview) | 7 | `ObligationsStepView.swift` |
| Dates & reminders preview, contextual permission | 8 | `RemindersStepView.swift` |
| Review → generate → commit | 9, 10 | `ReviewStepView.swift` |

Supporting code: `SetupRepositories.swift` (debt/obligation/income/goal CRUD with validation),
`SetupCompletenessService.swift` (one rule set behind both the review list and the upgrade
checklist), `PlanGenerationService.swift` (the store↔engine bridge),
`Components/SetupComponents.swift` (shared form controls),
`Features/Settings/ReviewSetupView.swift` (upgrade checklist + post-onboarding editors).

## The merge: two independently-authored planning contracts

Agents 2 and 3 worked on sibling branches off Agent 1's contract commit and **each defined its
own DTO layer**. Merging produced six colliding type names in one module: `PlanningInput`,
`PlanningResult`, `PayCadence`, `ObligationCadence`, `DebtType`, `IncomeChange`. The module did
not compile at the merge commit. Resolution (commit `4006e3f`), chosen to keep the *tested*
engine contract canonical and the persistence layer intact:

- **Engine keeps `PlanningInput` / `PlanningResult`** — that is what `AvalanchePlanEngine` and
  its 43 tests actually implement.
- **Agent 2's snapshot DTOs became `PlanInputSnapshot` / `PlanResultSnapshot`** — they are the
  deterministic money-as-strings coding format stored on `PlanVersion.inputSnapshotData`, not
  the engine call contract. `ObligationMath`, `PlanningSnapshotCoder`, and every persister
  behavior are unchanged.
- **The engine's duplicate `DebtType` and `ObligationCadence` were deleted** in favor of the
  model-layer declarations (identical cases, plus display metadata) — exactly as Agent 2's
  report invited, since those enums carry no SwiftData dependency.
- **Engine `PayCadence` → `PlanningPayCadence`** (associated-value form) and **engine
  `IncomeChange` → `IncomeStep`**, so the storage `PayCadence` enum and the `IncomeChange`
  `@Model` class keep their names.

`PlanGenerationService` is the seam: `PlanInputSnapshot → PlanningInput → engine →
PlanningResult → PlanResultSnapshot → PlanPersister`. Both agents' full suites pass together.

### One semantic mismatch worth naming

The persisted row's `debtBudget` (calc-v1 `plannedCardBudget`) means *the planned card
payment* — minimums + extra. The engine's `PaycheckPlan.debtBudget` means *cash available to
debts*, which on the final check exceeds what is actually sent (the last payment is capped at
the balance). The bridge maps `minimumsTotal + extraTotal`, which is what reproduces Lem's
documented final payment of $929.59. Anyone reading either field should know they differ only
on the terminal check.

## Deviation from MVP_LAYOUT §4: step order

The mission's required flow and §4's step table disagree. I implemented the **mission** order
and recorded it here rather than silently editing either document:

| | MVP_LAYOUT §4 | Shipped (mission) |
| --- | --- | --- |
| 3 | Checking accounts | Checking accounts |
| 4 | Income | **Debts** |
| 5 | Obligations | Debt details |
| 6 | Floor & allowance | Income |
| 7 | Debts | Obligations |
| 8 | Review | **Reminders preview** |
| 9 | Notifications | Review & generate |

Two substantive differences: **floor and allowance are folded into the goal step** (the mission
lists them under "Goal"), and **the reminders preview comes before review** (the mission has
dates/reminders at 8 and review at 9). Rationale for accepting the mission order: the goal step
is where posture is chosen, and R-14's posture suggestions *are* the floor and allowance — asking
them three screens apart would show a suggestion the user cannot see the effect of. Putting
debts right after accounts also front-loads the longest data-entry task while attention is
highest.

**No V2 or F requirement changes.** Every §4 question is still asked, with the same validation
and the same resumability contract. `OnboardingStep` was reordered accordingly (`floorAndAllowance`
removed as a separate case); the enum's doc comment records the deviation at the source.
Recommendation for the doc owner: amend §4's step table to match, or tell me to reorder.

## Schema additions (additive, defaulted)

Five columns the mission required and schema 2 didn't have. All optional or property-defaulted,
so SwiftData's lightweight migration still covers the container:

| Model | Field | Why |
| --- | --- | --- |
| `DebtAccount` | `setupNote: String?` | Mission item 5 ("optional note") |
| `DebtAccount` | `prepaymentRaw: String?` | Tri-state `PrepaymentEligibility`; the engine needs `.unknown` to withhold extra principal, which a Bool cannot express |
| `DebtAccount` | `debtTypeConfirmedAt: Date?` | Migrated rows defaulted to `.creditCard`; nil means "assumed, not confirmed", which is what the upgrade checklist offers to fix |
| `DebtAccount` | `creditLimitMarkedUnknown: Bool` | "Explicitly mark unknown" (mission item 5) — distinct from "not asked yet", so the app stops nagging |
| `RecurringObligation` | `isEssential: Bool` | Mission item 7 ("essential flag"); non-essential rows are recorded but never reserved |

All five round-trip through backup v2 and the debts CSV (append-only, two new trailing columns).
`ExportCompatibilityTests.testDebtsCSVColumnsAreSupersetOfV1` asserted *exact* header equality
despite its name and V2-18's append-only rule; I changed it to assert the prefix plus
no-duplicate-columns, which is what the contract actually says.

## Behavior notes

- **Resumability**: every step writes real rows (`UserGoalProfile`, `CashAccount`, `DebtAccount`,
  `IncomeSchedule`, `RecurringObligation`) as the user continues; `OnboardingProgress` tracks only
  position. So a mid-step force-quit keeps everything already saved, not just completed steps, and
  duplicates are structurally impossible.
- **Prepayment `.unknown`** never receives extra principal and raises
  `.prepaymentEligibilityUnknown` — the app would rather be slower than risk a penalty. Credit
  cards are always eligible regardless of the stored value.
- **Posture affects nothing after generation**: pinned by
  `testPostureDoesNotChangeGeneratedMath`, which generates under all three postures with
  identical numbers and asserts identical results.
- **Notification denial** is a first-class path: the reminders step shows a calm "that's fine"
  notice with a link to iOS Settings, and generation/commit never touch permission state.
- **Zero debts is valid** — the plan still reserves obligations, floor, and allowance.
- **Generation failures name the step that fixes them** (`GenerationError.missingIncome` →
  "Add your paycheck in the Income step").
- **Privacy**: no field anywhere asks for an account number, routing number, CVV, SSN, or
  credential. The only identifying field is the pre-existing optional last-four.

## Tests

**Unit: 183/183 green.** (Baseline entering this branch: 147 after the merge reconciliation.)

```bash
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:PaydayPlaybookTests test    # 183 tests, 0 failures
```

New suites:

- `PlanGenerationServiceTests` (8) — Lem-equivalence *through the whole store bridge* (23 checks,
  Jun 24 2027, $3,461.16 interest, $929.59 final, $7,900 ceiling, the $100 first-check buffer
  emerging from the floor top-up rather than being an input); snapshot-regeneration determinism;
  all four cadences incl. reversed semimonthly normalization; actionable missing-input failures;
  prepayment tri-state; shortfall and horizon-cap mapping.
- `OnboardingSetupTests` (18) — resume correctness at **every** step boundary; answers surviving a
  mid-step interruption; multiple accounts with the exactly-one-default-income invariant under
  add/edit/archive; every one of the six debt types through create→edit→remove; card limit rules,
  utilization, and the unknown-limit path; all four cadences; invalid and boundary values
  (zero/negative amounts, day 0/32/31, duplicate semimonthly days, blank names); obligation
  smoothing to the cent; non-essential obligations excluded from the generator; posture-neutrality
  of the math.
- `UpgradeChecklistTests` (5) — a migrated store never re-onboards; the checklist asks *only*
  about what migration could not know (goals, card limits, original principal, debt types) and
  never about what it established (roles, default income, income cadence, obligations); nothing
  blocks a migrated user; and answering the checklist leaves all 23 baseline paychecks, the plan
  version's own fields, the ledger, the check-in, and every debt balance/APR **unchanged**
  value-for-value.

**UI tests: partially verified — stated plainly.** I rewrote `PaydayPlaybookUITests` for the new
flow (full first-run through generation; force-quit-and-resume; template path with its warning;
setup at accessibility text size) and fixed `testBackupCreatesShareableFile`, which my new
Settings section pushed off-screen. Of these, **`testTemplateLoadShowsWarningAndSeedsOriginalPlan`
is confirmed passing**. The other three new tests failed only against a cold simulator boot
("wait for app to idle" timing out before the first assertion) and I did not re-verify them on a
warm simulator: this machine's simulator is shared with the other v0.2.0 agents' worktrees, and
re-running the suite cross-contaminates their results. The app itself was verified by hand — built,
installed, launched, and screenshotted on the welcome screen, which renders correctly. **Someone
should run the UI suite on an uncontended simulator before the alpha cut.**

## Assumptions

1. **A-04 naming**: a fresh install's generated baseline is `PlanContract.generatedPlanName` =
   "Plan v1" (`isOriginalBaseline = true`, `calculationVersion = 2`), per §4.9.
2. **Onboarding-created debts use plan IDs "D1", "D2", …**, deliberately disjoint from the
   template's letters "A"–"F", so a later deliberate template load cannot collide.
3. **A-02 account cap of 10** is enforced in the UI only; the model layer stays uncapped.
4. **Obligation reserve previews use the saved pay cadence**, defaulting to biweekly before the
   income step is reached (the common case, since obligations come after income in the flow).
5. **Posture suggestions re-arm**: switching posture re-applies its floor/allowance suggestion
   unless the user has typed in the field since the last suggestion.
6. **`firstCheckBufferAdd` is added to the engine's starting balance** rather than passed
   separately; it is 0 for every generated plan and non-zero only for the Lem template, where the
   engine's floor top-up reproduces it.

## Risks / notes for downstream agents

- **The dashboard, calendar, and insights owners** should read generated plans through
  `PlanGenerationService.regenerate(from:)` when they need the rich `PlanningResult` (events,
  warnings, per-paycheck movements). Only the row shape is persisted; the full result is
  reproducible from `inputSnapshotData` and deliberately not stored as a blob.
- **`SetupCompletenessService` is the single source** for "what's missing". If a new field is
  added that the user should be asked about, add a `SetupGap.Kind` there and both the review
  step and the upgrade checklist pick it up.
- **Original Plan v1 must never be regenerated** — `regenerate(from:)` returns nil for plans
  without a snapshot, which is exactly the migrated baseline.
- The account/debt/obligation editors are shared between onboarding and Settings via an
  `allowsDelete` flag: true during onboarding (nothing references the row yet), false afterwards,
  where rows are archived so history survives.

## Commits

```
c3236a3  merge: bring calc-v2 avalanche engine onto the schema-2 data layer
4006e3f  fix(v0.2.0): reconcile the two independently-authored planning contracts
<next>   feat(v0.2.0): plan generation bridge — store rows to engine to persisted plan
<next>   feat(v0.2.0): resumable onboarding flow, upgrade checklist, and setup tests
```
