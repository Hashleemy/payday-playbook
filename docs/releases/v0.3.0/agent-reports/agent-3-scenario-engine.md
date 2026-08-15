# Agent 3 report — Scenario and Extra-Payment Calculation (v0.3.0)

Branch: `feature/v0.3-scenario-engine`, based on Agent 1's contract branch
`feature/v0.3-contract` at `4be5c57`. Commit: **`3aad53b`** (this report's own
hash line follows in the next commit, as Agent 1's did). Pure calculation work:
engine, engine DTOs, the two new services, and their tests. No SwiftUI, no
SwiftData model or migration change, no import/export.

The branch is **local only** — no v0.3 branch has been pushed to `origin` by any
agent so far, so this one follows that convention and waits for the integration
owner rather than publishing itself.

Requirements delivered: **V3-04** (extra-payment insight), **V3-05** (three-plan
payoff calculator), **V3-06** (honest scenario inputs), **V3-15** (plan
separation, calculation half). Calculation rules **R-17…R-24**.

## Reading and starting state

`AGENTS.md` **does not exist** in this repository, at the root or nested
(`find . -iname "agents*.md"` returns nothing); the release plan's shared rule
reads it "if present", so that item is satisfied vacuously. `soul.md`,
`MVP_LAYOUT.md`, `ALPHA_V0.3.0_MULTI_AGENT_PLAN.md`, `TESTING.md`, Agent 1's
contract report, and the v0.2.0 avalanche-engine report were read in full before
any edit, together with the existing engine, DTO, and bridge sources.

Agent 2 had created `feature/v0.3-privacy-data` but had published nothing —
the branch was byte-identical to `feature/v0.3-contract` with a clean worktree.
This work therefore builds against the MVP_LAYOUT §6 names, which Agent 1
declared binding, and the reconciliation notes are in **Handoff** below.

## Calc v3 in one paragraph

Calc v3 is calc v2 plus R-17…R-24 running through the **same** projection.
There is no second payoff algorithm, no third store→engine bridge, and no
duplicated allocation loop. `AvalanchePlanEngine.runProjection` gained two
inputs — scenario constraints and an extra-payment schedule — at the points in
the existing R-05 order where they belong. With no scenario and no extra
payments, a v3 run is byte-identical to a v2 run apart from the version stamp.

## Formulas and rules

### R-17 — the three scenarios

Constraints come only from the user. The engine resolves a scenario kind into
concrete numbers during normalization, so there is exactly one interpretation
per kind and no caller can reinterpret them:

| Kind | Protected floor | Allowance | Retained per paycheck | Extra cap |
| --- | --- | --- | --- | --- |
| Fastest Safe | `minimumProtectedCash` | `0` | `0` | none |
| Balanced | `preferredFloor` | `preferredAllowance` | `plannedSavingsPerPaycheck` | none |
| More Cushion | `preferredFloor` | `preferredAllowance` | `plannedSavings + additionalReserve` | `extraPaymentCeiling` |

`preferredFloor` / `preferredAllowance` left nil mean "keep the saved floor and
allowance", per §6. Fastest Safe's $0 allowance is never assumed: it requires
`zeroAllowanceConfirmedAt`, and without it the card is a missing-input result.

**Where retained cash goes (the design decision that preserves R-16).** Planned
savings, the cushion reserve, and any extra principal held back by the ceiling
are **cash the user keeps**, so they join `keepInSpending` exactly as the floor
top-up does:

```
keepInSpending = allowanceReserved + floorTopUp + scenarioCashRetained
transferToReserves = income + windfall − keepInSpending
debtBudget = transferToReserves − obligationReserveTotal
```

Identity 1 is untouched and `debtBudget` shrinks by precisely the retained
amount, so identity 2 continues to close at zero unassigned cash. The retained
money also raises the R-23 cash path, which is exactly what "More Cushion"
means.

Retention is funded from the surplus **after** minimums:

```
surplus  = income + windfall − allowance − floorTopUp − bills − minimums
retained = floorToCents(min(retentionTarget, max(surplus, 0)))     // 0 on a shortfall paycheck
extra    = max(surplus − retained, 0)
```

`floorToCents` truncates rather than rounds. Money the plan *holds back* must
never exceed the money that was actually there — rounding up by half a cent
would leave the emitted row owing a fraction it does not have, and identity 2
would miss. Truncation keeps every emitted amount whole cents, which is what
makes the reconciliation exact rather than approximate.

The ceiling then caps extra principal, with the difference moved into retained
cash (never left unassigned) and a warning stating the tradeoff:

```
heldBack = floorToCents(extra − ceiling); extra −= heldBack; retained += heldBack
```

### R-18 — income override

Applied to a **copy** during normalization; the caller's `PlanningInput` and the
saved `StoredPlanInput` are never mutated (pinned by
`testIncomeOverrideNeverMutatesTheSavedInput`).

- **Same cadence:** the override is a take-home step that supersedes every saved
  income change from its effective date forward; earlier steps survive.
- **Different cadence:** a new pay frequency has no meaning against the old
  anchor, so the payday timeline is **rebased** on the override's effective date
  and the override amount applies throughout. Surfaced as
  `.incomeOverrideRebasesTimeline` so the user is told, not surprised.

Both cases also emit `.incomeOverrideApplied`.

### R-19 — scenario outputs

`ScenarioResult` wraps the full `PlanningResult` (so the calendar, paycheck
table, and warnings all come from one projection) and adds the card summary:
payoff date; `ScenarioDuration` (days / paychecks / whole months); total
starting and current principal; `periodicDebtContribution` = mean of
`minimumsTotal + extraTotal`; `cashRetainedPerPaycheck` = mean of
`keepInSpending`; estimated total interest; `totalPaid` = Σ per-debt
`totalPaid`; `minimumEndingCash` = `min(cashBufferPath)`; `deltaVsBalanced`;
assumptions; `missingInputs`; warnings. Calendar-ready actions are
`result.events`, unchanged in shape and identifier scheme.

`deltaVsBalanced` is withheld unless **both** scenarios reached a payoff date —
an unfinished projection has no comparable total. This follows the R-16
minimum-only precedent rather than inventing a comparison.

### R-20 — extra payments

**Modeled as money arriving in the single spending pool on its payday**, which
then flows through the normal allocation order. This is the only placement that
lets `extraTotal` grow while `income + windfall == keep + transfer` stays true;
bolting the amount onto `debtBudget` would have required amending identity 1,
which the release plan forbids. `PaycheckPlan.extraPaymentInflow` names the
portion of `windfall` that came from extra payments, so the two are never
conflated in reporting.

Occurrence scheduling reuses the engine's existing windfall rule — *first payday
on or after the date*:

| Kind | Occurrences |
| --- | --- |
| `oneTime` | the effective date |
| `recurringPerPaycheck` | every payday on/after the effective date |
| `recurringMonthly` | the effective date's day-of-month, monthly, clamped per R-11 (`PayScheduleGenerator.dueDates`) |

Targeting: a named debt is paid first, subject to R-07 eligibility; whatever it
cannot absorb rolls into the normal avalanche order rather than sitting idle.
An automatic target is the ordinary R-08 pick. Per-payday injection order is
sorted by payment identifier, so a caller's collection order can never leak into
the plan (pinned by `testExtraPaymentOrderInTheInputDoesNotChangeTheResult`).

`ExtraPaymentInsight` is computed as the difference between two full engine
runs, so every figure reconciles to the engine to the cent by construction
rather than by an independent formula. `projectedPrincipalReduction` is the
projected total debt on the landing payday, before minus after — the principal
effect *after* that period's modeled interest has accrued.

### R-21 — prepayment semantics and warnings

- **Revolving debt never claims a principal-only instruction.** When an extra
  payment touches a card, the result carries `.revolvingNoPrincipalOnly`:
  the payment reduces the balance after interest and posted charges, and card
  issuers have no principal-only designation to give.
- **Installment debt** gets `.installmentPrincipalOnlyEligible` guidance only
  when eligibility is actually known (`.eligible`).
- Warning taxonomy: `.aprMissingOrZero`, `.extraPaymentTargetUnknownBehavior`,
  `.extraPaymentTargetIneligible` / `.prepaymentProhibited`,
  `.insufficientAvailableCash`, `.sourceAccountNotVerified`,
  `.protectedFloorAtRisk`, `.extraPaymentAfterPayoff`,
  `.extraPaymentPartiallyPlaced`, `.extraPaymentCeilingHeldBackCash`,
  `.noBillsConfigured`.

A named source account only drives warnings — the engine keeps its single-pool
model. It says so (`.sourceAccountNotVerified`) and additionally compares the
amount against the cash the plan projects above the protected floor rather than
staying silent.

### R-22 — determinism and versioning

`.v3Scenario = 3` added to `PlanCalculationVersion`. `assemble` stamps v3 only
when the input asked for it; a v1 input never reaches this allocator.
`PlanGenerationService.engineInput` stamps v3 when the snapshot's version column
says 3 **or** the snapshot carries a scenario or extra payments — so v3 inputs
can never be silently modeled as a v2 result. Ties resolve per R-08 unchanged;
`PlanEvent` identifiers are unchanged.

### R-23 — cash path

Unchanged mechanism (`cashBufferPath`, one point per paycheck); retained
scenario cash now raises it, and `ScenarioResult.minimumEndingCash` exposes its
low point. The engine keeps its single-spending-pool model; per-account detail
stays outside it.

### R-24 — honest inputs

Missing inputs surface **in the result**, never as a thrown error, unless the
snapshot cannot be used to call the engine at all (a missing pay day is still an
actionable `GenerationError`, because there is no card to render).

| Detected | Field | Behavior |
| --- | --- | --- |
| No debt with a balance | `.debts` | card not computed |
| Installment debt with no entered payment | `.debtMinimum` | card not computed, debt named |
| No take-home | `.income` | card not computed |
| Fastest Safe without minimum protected cash | `.minimumProtectedCash` | card not computed |
| Fastest Safe without the $0-allowance confirmation | `.zeroAllowanceConfirmation` | card not computed |
| Balanced / More Cushion without planned savings | `.plannedSavings` | card not computed |
| More Cushion with neither reserve nor ceiling | `.cushionConstraint` | card not computed |
| Extra payment of $0 | `.extraPaymentAmount` | insight not computed |
| Extra payment aimed at a deleted debt | `.extraPaymentTarget` | insight not computed |

Two R-24 inputs are deliberately **not** blocking, because at this boundary they
cannot be distinguished from a real user answer:

- **No bills** is indistinguishable from "I have no bills" → `.noBillsConfigured`
  warning, and the estimate proceeds reserving nothing.
- **A 0% APR** is indistinguishable from a genuine 0% promotional card →
  `.aprMissingOrZero` warning naming the debt, and the estimate proceeds.

Both are named in the result so the user can correct them; neither is silently
assumed and neither is fabricated. The data layer *can* tell the difference, so
`ScenarioInputField` declares `.debtBalance`, `.debtAPR`, `.payCadence`,
`.nextPayday`, `.protectedCash`, and `.preferredAllowance` for its use, with the
gap documented on the enum.

### R-15 / V3-15 — previews

Both services take value types and return value types. There is no
`ModelContext` in scope, nothing is written, and nothing activates itself.
`testScenariosProduceNoPersistableSideEffects` and
`testInsightNeverMutatesTheSnapshot` pin the shape so a later change cannot
quietly introduce persistence.

## DTOs

All §6 names are used verbatim; none were minted as alternatives.

**Engine layer (`Services/Planning/PlanningContracts.swift`, Foundation only):**

- `PlanCalculationVersion.v3Scenario = 3`
- `PlanningInput` + `scenario: ScenarioInput?`, `extraPayments: [ExtraPaymentInput]`
  (with a tolerant `init(from:)` so payloads written before these keys still decode)
- `ScenarioKind`, `IncomeOverrideInput`, `ScenarioInput`, `ExtraPaymentKind`,
  `ExtraPaymentInput`
- `ScenarioResult`, `ScenarioDuration`, `ScenarioComparisonDelta`,
  `ScenarioMissingInput`, `ScenarioInputField`
- `ExtraPaymentInsight`, `ExtraPaymentDownstreamChange`
- `PaycheckPlan` + `scenarioCashRetained`, `extraPaymentInflow` (both default 0,
  so calc-v2 rows are unchanged)
- New `ReasonCode` and `PlanningNoteCode` cases, all of them reachable

**Snapshot layer (`Services/PlanningDTO.swift`, money-as-strings):**

- `StoredPlanInput` + `scenario: StoredScenarioDefinition?`,
  `extraPayments: [StoredExtraPayment]`
- `StoredScenarioDefinition`, `StoredIncomeOverride`, `StoredExtraPayment`, all
  hand-written `Codable` following the file's existing money-as-string pattern

**Backward compatibility.** Both new keys are optional on decode, and on encode
`scenario` is omitted when nil and `extraPayments` when empty — so a calc-v2
snapshot's bytes are **unchanged**, byte-stability of
`PlanningSnapshotCoder` is preserved, and existing `PlanVersion.inputSnapshotData`
still decodes. Pinned by `testCalcV2SnapshotBytesAreUnchangedByTheNewKeys`.

**Protocols:** `ScenarioCalculating` and `ExtraPaymentInsightCalculating`, with
the §6 signatures exactly.

## Services

| File | Contents |
| --- | --- |
| `Services/ScenarioCalculationService.swift` | `ScenarioCalculating`; three scenarios via `PlanGenerationService.engineInput`; `ScenarioInputAudit` (the shared R-24 honest-input audit) |
| `Services/ExtraPaymentInsightService.swift` | `ExtraPaymentInsightCalculating`; before/after projections, deltas, downstream changes, R-21 warnings |

Both expose a static entry point and an instance conformance; tests pin that the
two agree.

## Tests

**362 unit tests, 0 failures** (baseline before this branch: 292; 70 new).
**19 UI tests, 0 failures**, run alone on their own simulator — unchanged by this
work, confirmed rather than assumed.

| Suite | Tests | Covers |
| --- | ---: | --- |
| `CalcV3ReductionTests` | 12 | T-5: v3 ≡ v2 byte-identical without scenario/extras; version stamping; determinism; R-16 identities on every scenario and insight result, including under shortfall; snapshot byte-stability and round trips |
| `ScenarioCalculationTests` | 34 | T-7 + T-8: ordering and deltas, retention, ceiling, cash path, determinism, edge cases, every missing-input case, income override |
| `ExtraPaymentInsightTests` | 24 | T-6: one-time and recurring extras, targeting, R-21 semantics and warnings, downstream changes, preview separation, promo APR, benchmark |
| `ScenarioFixtures` | — | Fictional builders and the shared R-16 reconciliation assertion |

Required edge-case coverage:

| Case | Test |
| --- | --- |
| Zero APR | `testZeroAPRDebtSortsLastAndAccruesNoInterest` |
| Very high APR | `testVeryHighAPRStillProducesAFiniteEstimate` |
| Zero balance | `testAlreadyPaidDebtIsIgnoredWithoutAPayoffEvent` |
| Payment larger than balance | `testMinimumLargerThanBalanceNeverOverpays`, `testTargetLargerThanItsBalanceRollsToTheNextDebt` |
| Same-APR ties | `testEqualAPRTiesResolveDeterministically` |
| Insufficient income / negative available cash | `testInsufficientIncomeReportsTheGapInsteadOfNegativeCash`, `testIdentitiesHoldUnderShortfallWithScenarioConstraints` |
| Semimonthly and biweekly dates | `testSemimonthlyMonthEndAndLeapYearPaydaysClampCorrectly`, `testBiweeklyAccrualDaysAreAlwaysFourteen` |
| Leap year and month end | same, plus `testMonthlyDay31ClampsAcrossShortMonths`, `testRecurringMonthlyOnDay31ClampsInShortMonths` |
| Recurring extras | `testRecurringPerPaycheckAppliesOnEveryPaydayFromItsDate`, `testRecurringMonthlyAppliesOncePerMonthOnItsDayOfMonth` |
| Promotional APR | `testPromoAPRStillDrivesPriorityUnderCalcV3` |
| Loan prepayment restrictions | `testPrepaymentRestrictedLoanReceivesMinimumsOnly`, `testUnknownPrepaymentWarnsAndWithholdsExtra`, `testIneligibleTargetIsWarnedAndRedirected` |
| Exact cent reconciliation | `ScenarioFixtures.assertReconciles`, asserted on every projection every suite produces |
| Deterministic repeated runs | `testRepeatedRunsAreByteIdentical`, `testDeterminismAcrossRepeatedRuns`, `testExtraPaymentOrderInTheInputDoesNotChangeTheResult` |

Every fixture value is invented (V3-12). The existing `PlanningFixtures.lemInput()`
is deliberately **not** used by any new test.

## Benchmark

8 debts, tight surplus, 77-paycheck horizon, on the iPhone 17 Pro simulator:

| Work | Projections | Wall clock |
| --- | ---: | ---: |
| 3 scenarios + 1 extra-payment insight | 6 (each scenario also runs its minimum-only track; the insight runs before and after) | **1.25 – 1.35 s** |

That is roughly **0.2 s per projection** at 77 paychecks × 8 debts. The engine is
O(paychecks × debts) with no allocation-heavy paths, so cost scales linearly;
the 600-paycheck cap is the practical ceiling.

**This is a main-thread cost Agent 4 must plan around.** Opening the Payoff
Scenarios screen is over a second of synchronous work at this size, and the
existing v0.2.0 limitation (plan analysis runs on the main thread) now has a
larger multiplier. Recommendations: build scenarios once and cache them per
input; never call either service from a SwiftUI view body; and prefer a task
with a loading state. Moving the engine off the main actor remains out of scope
for this release, per Agent 1's risk register.

`testMultiDebtHorizonBenchmark` asserts a deliberately generous 10-second bound —
it exists to catch an order-of-magnitude regression, not to police simulator
jitter — and prints the measured figure.

## Estimation limitations

Everything the v0.2.0 engine documented still holds (simple interest, 365-day
year, payday-granularity accrual, payments modeled as posting on the funding
payday, heuristic card minimums, promo APRs not prorated within an accrual
period). Calc v3 adds:

1. **Extra payments are modeled as new money** entering the pool on their date.
   The engine cannot verify that a named source account holds it; it warns
   instead of pretending to check.
2. **A cadence-changing income override rebases the payday timeline** on its
   effective date. Paydays before that date are not part of the estimate. A
   genuine mid-plan cadence switch that preserves prior paydays is not modeled.
3. **Retained scenario cash is a per-paycheck set-aside**, not a modeled savings
   account. It raises the cash path; it earns no interest and is not tracked as
   a separate balance.
4. **The extra-payment ceiling truncates to whole cents**, so an emitted
   `extraTotal` may exceed the ceiling by at most the sub-cent remainder.
5. **A monthly extra payment lands on the first payday on or after each
   occurrence**, so on a biweekly cadence its cash-flow timing is approximate to
   within one pay period.
6. **`missingInputs` cannot see a never-entered balance or APR** — see R-24
   above. Those are warnings, not blocks.
7. **`StoredPlanInput` carries no promotional-APR column**, so a promo rate can
   only reach the engine through a directly-built `PlanningInput`. The engine
   honours it under calc v3 (tested); the data layer cannot yet supply one.

All of these are surfaced to the UI as `assumptions` or `warnings` on every
result rather than living only in this document.

## Privacy and accessibility

- **Privacy (V3-12/V3-13).** No real person's balances, income, account labels,
  dates, schedules, or name appears in any file added or changed here. Every
  fixture is invented. No financial payload is logged: the only `print` is the
  benchmark's timing line. Diffed lines were grep-scanned for the founding
  user's known values and name; clean.
- One **incidental removal**: the `PlanCalculationVersion` doc comment I was
  rewriting for v3 previously named a real plan's date range. It is gone. The
  remaining personal-data comments in `PlanningDTO.swift` (`ObligationMath`'s
  smoothing example and `PlanningDebt.displayID`'s letter note) are **left
  untouched on purpose** — they are Agent 2's contracted scrub, and rewriting
  the same lines concurrently would create a conflict on exactly the lines
  Agent 2 is editing. Flagged below.
- **Accessibility.** Not applicable to this scope: no view, string catalog, or
  user-facing layout was touched. Every message this layer produces is a plain
  sentence with no color- or icon-only meaning, and each carries a machine-
  readable `PlanningNoteCode` / `ScenarioInputField` so Agent 4 can attach
  iconography and VoiceOver labels without parsing prose.

## Proposed contract amendments

1. **`StoredScenarioDefinition` needs `zeroAllowanceConfirmedAt: Date?`** — added
   here. §6 puts the confirmation on `UserGoalProfile`, but
   `scenarios(from:definitions:)` takes no profile, so Fastest Safe would be
   uncomputable without it. The data layer copies the profile value onto the
   definition. Optional key; calc-v2 snapshots are unaffected.
2. **`StoredIncomeOverride` carries `PayCadence` plus day-of-month columns**
   rather than a bare cadence, mirroring `StoredPlanInput` so both go through
   the one `planningCadence` conversion. §6 said only "cadence".
3. **`PaycheckPlan` gained two fields** (`scenarioCashRetained`,
   `extraPaymentInflow`), both defaulting to 0. §6 said `PlanningResult` is
   "unchanged in shape"; the rows needed these to stay auditable. `StoredPlanResult`
   is genuinely unchanged.
4. **`ExtraPaymentInsight` gained `totalPaidBefore`** alongside the contracted
   `totalPaid`, so the UI can render a before/after pair without a second engine
   run.

## Handoff

**To Agent 2 (privacy and data):**

- Add the §6 `UserGoalProfile` fields (`minimumProtectedCash`,
  `plannedSavingsPerPaycheck`, `additionalCushionReserve`, `extraPaymentCeiling`,
  `zeroAllowanceConfirmedAt`) and copy them onto `StoredScenarioDefinition` when
  building one — including `zeroAllowanceConfirmedAt` (amendment 1).
- Add `PlanVersion.scenarioKindRaw` / `effectiveDate`; the engine already stamps
  calc v3 correctly for applied scenarios.
- **`PlanningDTO.swift` still contains two personal-data comments** I left for
  your scrub: `ObligationMath`'s doc comment naming the founding user's smoothing
  amounts, and `PlanningDebt.displayID`'s letter note. I extended that file but
  did not touch those lines.
- Consider adding a promotional-APR column to `PlanningDebt` — the engine
  supports promo rates under calc v3 but the snapshot cannot carry one
  (limitation 7).
- Merge order note: my `StoredPlanInput` change adds two optional properties and
  two `CodingKeys` cases. If you re-anchor `PlanningFixtures` in the same file
  region, expect a small textual conflict there and nowhere else.

**To Agent 4 (scenario UI):**

- Call `ScenarioCalculationService.scenarios(from:definitions:)` once per input
  and cache; **never from a view body** (see Benchmark — over a second at 8
  debts).
- Render `missingInputs` as the missing-input state; each carries actionable
  copy and an optional `debtID`. `isComputable == false` means `plan` is nil.
- Balanced is the visual recommendation and is never auto-applied. Applying is
  yours: create a new future-effective `PlanVersion` stamped calc v3 with the
  `StoredScenarioDefinition` inside `inputSnapshotData`. Nothing in this layer
  persists or activates.
- Warnings and assumptions are sentence-level copy with machine-readable codes
  for iconography; `ScenarioResult.events` supplies calendar-ready actions.
- `deltaVsBalanced` is nil when a comparison would be dishonest — show nothing
  rather than a zero.

**To Agent 5 / integration:** run the UI suite alone with
`-parallel-testing-enabled NO` on its own simulator. I hit the documented
cross-contamination first-hand by running the unit and UI suites against one
simulator; the AX errors it produced were entirely the collision.

## Commands run

```bash
# Build (derived data OUTSIDE ~/Documents — the file-provider xattr / CodeSign trap)
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$JOB_TMP/dd-scenario" build
# ** BUILD SUCCEEDED **

# Unit suite, on a simulator created for this worktree
xcrun simctl create pp-v03-scenario com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,id=<pp-v03-scenario>' \
  -derivedDataPath "$JOB_TMP/dd-scenario" \
  -only-testing:PaydayPlaybookTests test
# ** TEST SUCCEEDED ** — Executed 362 tests, with 0 failures
# [benchmark] 8 debts, 77 paychecks, 3 scenarios + 1 insight (6 projections): 1.253s

# UI suite, alone, on its own simulator
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,id=<pp-v03-scenario-ui>' \
  -derivedDataPath "$JOB_TMP/dd-ui" -parallel-testing-enabled NO \
  -only-testing:PaydayPlaybookUITests test
# ** TEST SUCCEEDED ** — Executed 19 tests, with 0 failures (290 s)
```

## Self-review finding, fixed before commit

Reviewing the diff caught a warning that was firing on the wrong condition:
`.extraPaymentPartiallyPlaced` only fired when a named target received
*nothing*, so the common case — aiming $2,000 at a $900 balance — redirected the
overflow silently. It now compares the amount actually placed against the amount
requested. Pinned by an assertion in
`testTargetLargerThanItsBalanceRollsToTheNextDebt`.
