# Agent 3 report — Financial Planning, Avalanche Optimization & Insights Engine (v0.2.0)

*(Edited 2026-08-13 under V3-12: personal financial values and the founding user's name redacted; all technical content, decisions, and results otherwise unchanged.)*

Branch: `feature/v0.2-avalanche-engine` · Date: 2026-08-10 · Based on Agent 1's contract
commit (`07bcf2f`). Pure engine code + tests — no SwiftUI screens, no persistence
migrations, no notification scheduling touched.

## What was built

Calculation-version-2 planning engine: a pure, deterministic, storage-independent
generator that turns onboarding inputs (`PlanningInput`) into an explainable
avalanche plan (`PlanningResult`). No Agent 2 contract existed on the branch or in
history, so this branch defines the DTO contract (documented below) for the data/UI
layers to adopt.

New code lives in `PaydayPlaybook/Services/Planning/`:

| File | Lines | Contents |
| --- | --- | --- |
| `PlanningContracts.swift` | 465 | All DTOs — inputs, results, events, reason codes. `Codable`, `Equatable`, `Sendable`. |
| `PayScheduleGenerator.swift` | 145 | Payday and due-date generation for all four cadences, with day clamping (R-11). |
| `AvalanchePlanEngine.swift` | ~950 | The calc-v2 engine: `generatePlan(_:)`, `reforecast(_:actuals:)`, `smoothedReserve(...)`. |

One existing file was modified: `PaydayPlaybook/Support/DateMath.swift` —
`days(from:to:)` now diffs noon-anchored dates so timezones whose DST
transition falls at midnight (e.g. America/Santiago) cannot drop an accrual
day. Behavior is identical in every timezone with a real midnight (verified by
the untouched v1 baseline suite passing unchanged).

Tests in `PaydayPlaybookTests/`: `PlanningFixtures.swift`, `AvalancheBaselineParityTests.swift` (renamed under V3-12),
`PayScheduleGeneratorTests.swift`, `AvalanchePlanEngineTests.swift`,
`AvalanchePropertyTests.swift`.

The frozen calc-v1 `DebtCalculationEngine` is **untouched**; `PlanCalculationVersion`
(`.v1LegacyBaseline` = 1, `.v2Avalanche` = 2) is the dispatch key. Original Plan v1
stays on calc v1 forever; new plans use calc v2.

## Formulas (implementing R-01…R-16)

All money is `Decimal`. `round2` = 2 decimal places, half-away-from-zero
(`MoneyMath.rounded2`, shared with calc v1). Internal projection math runs at **full
precision** (identical mechanics to calc v1 — this is what guarantees baseline parity);
rounding happens only at emission (see the rounding contract below).

- **Interest per paycheck (R-02):** `balance × effectiveAPR × days ÷ 365`, where
  `days` is the calendar-day gap from the previous payday (first check: from the
  previous cadence occurrence before the first payday; reforecast first check: from
  each debt's authoritative snapshot date). Accrued per debt at full precision.
- **Effective APR (promo, R-13):** `promo.apr` while `payday < promo.expirationDate`,
  else the standard `apr`. Promo rates are not prorated within an accrual period —
  the standard rate starts with the first payday on or after expiration (documented
  assumption).
- **Obligation smoothing (R-04):** per-paycheck reserve =
  `round2(amount × occurrencesPerYear ÷ paychecksPerYear)`. Occurrences per year:
  weekly 52, biweekly 26, monthly 12, quarterly 4, semiannual 2, annual 1. Paychecks
  per year: weekly 52, biweekly 26, semimonthly 24, monthly 12. Reproduces the
  baseline's smoothed per-paycheck reserves exactly for both of its obligations.
- **Card minimum estimate (R-06, when no minimum entered):**
  `max($17.50 × days ÷ 14, 0.005 × postInterestBalance)`, capped at the balance.
  Same constants as calc v1; flagged `.estimatedMinimum` in reason codes.
- **Allocation order per paycheck (R-05):** allowance → floor top-up
  (`max(protectedFloor − currentCeiling, 0)`, funded only up to available cash) →
  smoothed obligation reserves → minimums (by due date when a `dueDay` exists,
  otherwise per paycheck) → all remaining cash as extra principal to the
  highest-priority eligible debt, rolling to the next debt **within the same
  paycheck** when one is retired (R-07).
- **Priority order (R-08, extended):** effective APR descending → due day ascending
  (debts without a due day last) → current balance ascending → `createdOrder` →
  UUID string. The due-day key is an extension of R-08 introduced by this engine
  (proposed contract amendment — see "Deviations & proposed amendments").
- **Minimum scheduling by due date:** when a debt has a `dueDay`, its minimum is
  funded from the last payday in the half-open window `[payday_i, payday_{i+1})`
  containing the due occurrence; each occurrence in the window is funded once
  (a long gap containing two occurrences funds both). Without a `dueDay`, the
  entered minimum applies per paycheck (calc-v1-compatible).
- **Shortfall (R-09):** when `income + windfall − allowance < floorTopUp +
  obligations + minimums`: extra → $0, then the allowance is reduced toward $0,
  and any residual gap is emitted explicitly (`PaycheckShortfall.gap`), warned
  (`.shortfallOutsideFunds`), and evented (`.shortfallAlert`). Minimums and
  obligations are always modeled as paid; cash never goes silently negative.
  The gap is broken down into `floorGap + obligationGap + minimumsGap` so the
  UI can say exactly what the outside funds cover.
- **Prepayment eligibility (R-14):** debts with `.ineligible` or `.unknown`
  prepayment never receive extra principal; `.unknown` produces the
  `.prepaymentEligibilityUnknown` setup warning. If extra cash has no eligible
  target it stays in reserves (`unassignedCash`, `.noEligibleExtraTarget`).
- **Due-day clamping (R-11):** days 29–31 clamp to the last day of shorter months
  (Feb 28/29, 30-day months). Applies to paydays (monthly/semimonthly cadences)
  and due dates alike.
- **Horizon cap (A-05):** projection stops after 600 paychecks; unfinished plans
  set `notPayableAsConfigured` and warn `.horizonCapReached`.
- **Utilization (R-15):** per card, `balance ÷ creditLimit` rounded to 4 places;
  `.ok` < 30% ≤ `.elevated` < 90% ≤ `.critical`; `.unknown` when the limit is
  missing or zero (with `.creditLimitMissing` / `.creditLimitZero` warnings).
  Display-only — never changes allocation.
- **Minimum-only comparison (R-16):** a second projection with extra disabled.
  Only offered when every active non-card debt has an entered minimum (otherwise
  `nil` + `.minimumOnlyUnavailable` — never a guess). `interestSaved`/`daysSaved`
  are populated only when **both** tracks finish inside the horizon; if the
  minimum-only track never finishes, the comparison is returned with
  `unfinished = true` and `.minimumOnlyNeverFinishes`.

### Rounding contract (cent reconciliation)

Emitted rows are rounded with cascading penny allocation so every `PaycheckPlan`
reconciles **by construction**:

```
income + windfall                    == keepInSpending + transferToReserves
debtBudget + shortfall.minimumsGap   == minimumsTotal + extraTotal + unassignedCash
Σ (payment.minimum + extra)          == minimumsTotal + extraTotal
shortfall.gap                        == floorGap + obligationGap + minimumsGap
```

Only the minimums portion of a shortfall gap flows through the debt budget —
gap money earmarked for an underfunded floor top-up or obligation reserve can
never surface as "unassigned" cash.

`minimumsTotal = round2(Σ exact minimums)`; `extraTotal = round2(exact minimums +
exact extra) − minimumsTotal` (derived by subtraction, not independently rounded);
per-debt payments cascade with the last row absorbing the rounding remainder;
`unassignedCash` closes the row. Ending balances and interest are emitted as
`round2` of the full-precision values.

## DTO contract (for the data/UI layers)

Everything is `Codable & Equatable & Sendable`, defined in `PlanningContracts.swift`.

**Inputs** — `PlanningInput { calculationVersion, asOf, income, spending,
obligations, debts }`:
- `IncomeInput { cadence, firstPayday, amounts: [IncomeChange], windfalls: [Windfall] }`
  — `amounts` are step changes (raises) by effective date.
- `PayCadence`: `.weekly`, `.biweekly`, `.semimonthly(firstDay:secondDay:)`,
  `.monthly(day:)`; day 31 means "last day of month".
- `SpendingInput { startingBalance, protectedFloor, allowancePerPaycheck }`.
- `ObligationInput { id, name, amount, cadence, dueDay? }` with `ObligationCadence`
  (weekly/biweekly/monthly/quarterly/semiannual/annual).
- `DebtInput { id, name, debtType, balance, apr, promo?, minimumPayment?, dueDay?,
  creditLimit?, prepayment, createdOrder }`; `PromoAPR { apr, expirationDate }`;
  `PrepaymentEligibility` (.eligible/.ineligible/.unknown); six `DebtType`s
  (creditCard, personalLoan, autoLoan, studentLoan, medicalDebt, other — non-card
  types need an entered minimum; a missing one warns `.installmentMinimumMissing`
  and models $0).
- `ActualState { asOf, balances: [BalanceAuthority], spendingBalance? }` for
  reforecasts. Authoritative snapshots control the forecast from their effective
  date but **never rewrite the plan** — `reforecast` returns a new result with
  `kind == .reforecast`; the original `PlanningResult` value is immutable.

**Output** — `PlanningResult`: calculationVersion/kind/generatedAsOf; starting and
remaining principal; `payoffOrder` + `currentTargetDebtID`;
`recommendationReasons/-Explanations`; `paychecks: [PaycheckPlan]` (full
paycheck-by-paycheck deposits, keeps, transfers, obligation reserves, per-debt
minimum/extra payments with `ReasonCode`s, interest, ending balances, unassigned
cash, spending-ceiling path, shortfall, human-readable `movements`);
`forecastPayoffDate` + per-debt `debtSummaries` (payoff date, total paid, interest
paid); `estimatedTotalInterest` / `estimatedRemainingInterest`;
`minimumOnlyComparison?`; `utilization`; `cashBufferPath`; `hasUnassignedCash`;
calendar-ready `events: [PlanEvent]` with stable identifiers
(`payday-N`, `due-YYYY-MM-DD-<uuid>`, `payoff-<uuid>`, `obligation-…`,
`shortfall-N`, `plan-complete`); `warnings` + `assumptions` (`PlanningNote`);
`notPayableAsConfigured`.

Errors: `generatePlan`/`reforecast` throw `PlanningValidationError`
(negativeAmount / noIncome / invalidCadence / invalidDueDay) on malformed input
rather than producing a wrong plan.

## Baseline preservation

Two independent guarantees, both tested:

1. **Calc v1 frozen** — `DebtCalculationEngine` is untouched;
   `testLegacyBaselineRegressionIntact` still reproduces the documented full
   baseline schedule, including its modeled interest total, under
   `PlanContract.calculationVersion == 1`.
2. **Calc v2 parity** — fed baseline-equivalent onboarding inputs (raw values
   only; the baseline's first-check buffer *emerges* as the floor top-up from
   the starting balance to the protected floor), calc v2 reproduces the
   baseline **check by check** against the frozen v1 engine: every date,
   interest figure, budget, and per-debt balance
   (`testBaselineMatchesLegacyEngineCheckByCheck`, renamed under V3-12).

## Test results

`xcodebuild test` (iPhone 17 Pro simulator): **TEST SUCCEEDED — 97 tests, 0
failures** (baseline before this branch: 54; all pre-existing suites untouched and
green; 6 of the 43 new tests pin the adversarial-review fixes). The 18
mission-required behaviors map to:

| # | Required behavior | Test |
| --- | --- | --- |
| 1 | Highest effective-APR targeting | `testHighestAPRReceivesAllExtra` |
| 2 | Minimums scheduled by due date | `testMinimumsFundedByDueDates` |
| 3 | Shortfall explicit, never silent | `testShortfallExplicitNeverSilent` |
| 4 | Same-check rollover | `testBaselineFirstCheckAllocations` (renamed under V3-12) + `testRolloverWithinSamePaycheck` |
| 5 | Floor/allowance tradeoff | `testHigherFloorOrAllowanceDelaysPayoff` |
| 6 | Earlier extra ⇒ ≤ interest | `testEarlierWindfallNeverCostsMore` |
| 7 | Promo expiry priority flip | `testPromoExpirationChangesPriority` |
| 8 | Deterministic tie-break | `testEqualAPRTieBreakDeterministic` |
| 9 | Cadence dates (short months, leap, DST) | `PayScheduleGeneratorTests` (weekly/biweekly DST, semimonthly, monthly day 31, leap Feb 29) |
| 10 | Due-day 29/30/31 clamping | `testDueDayClampingWindows` |
| 11 | Zero-APR / already-paid debts | `testZeroAPRAndPaidOffDebts` |
| 12 | Utilization levels + warnings | `testCreditUtilizationSafety` |
| 13 | Prepayment-unknown warning, minimums only | `testPrepaymentUnknownBlocksExtraPrincipal` |
| 14 | Snapshots reforecast-only, plan immutable | `testAuthoritativeBalanceReforecastsOnly` |
| 15 | Min-only comparison withheld on insufficient inputs | `testMinimumOnlyComparisonRequiresSufficientInputs` |
| 16 | Cent reconciliation | `testDecimalTotalsReconcileToTheCent` + property suite |
| 17 | Legacy baseline regression | `testLegacyBaselineRegressionIntact` + check-by-check parity |
| 18 | Property/invariant tests | `AvalanchePropertyTests` (25 seeded-random inputs: determinism, reconciliation, non-negativity, eligibility, terminal coherence, unique event IDs, Codable round-trip) |

Performance: the full baseline plan (plus its minimum-only track) generates in
well under a test-suite timeout — the whole 91-test suite, which generates dozens
of plans including 600-check horizon runs, completes in seconds on a simulator.
No allocation-heavy paths; the engine is O(paychecks × debts).

## Adversarial review

A multi-agent adversarial review (four independent reviewers over the engine,
schedule, contracts, and test coverage; findings adversarially verified) ran
before commit. Seven distinct defects were confirmed and **all seven fixed**,
each with a pinned regression test:

1. Extra-payment emission order had no tie-break for equal amounts —
   Dictionary hash-seeded key order could leak into output across app
   launches, breaking determinism. Fixed with a stable (amount desc, input
   position) sort. → `testEqualExtraEmissionDeterministicOrder`
2. Shortfall paychecks could report phantom `unassignedCash` when the gap
   partly funded obligations or the floor. Fixed via the gap breakdown
   (`floorGap`/`obligationGap`/`minimumsGap`) and the corrected reconciliation
   identity. → `testShortfallGapBreakdownNoPhantomUnassigned`
3. A reforecast with `spendingBalance == nil` restarted the cash ceiling at
   plan-start balance, re-charging floor top-ups the plan already made. Fixed:
   the planned no-spend ceiling at the cutoff date is derived from the plan
   track. → `testReforecastNilSpendingBalanceKeepsPlannedCeiling`
4. Stale debts (no balance snapshot) silently dropped interest between plan
   start and the previous payday, contradicting the DTO contract. Fixed:
   stale debts accrue from the plan's accrual anchor.
   → `testReforecastStaleDebtAccruesFromPlanStart`
5. Duplicate `debtID` entries in `ActualState.balances` trapped
   (`Dictionary(uniqueKeysWithValues:)`). Fixed: latest-effective-date wins,
   documented on the DTO. → `testDuplicateBalanceAuthoritiesLatestWins`
6. A reforecast dated past the 600-paycheck horizon returned an empty result
   without `notPayableAsConfigured`. Fixed.
   → `testReforecastPastHorizonMarksNotPayable`
7. `DateMath.days` dropped a calendar day across midnight DST transitions
   (America/Santiago-class timezones), shorting one accrual period per year.
   Fixed with noon-anchored diffing (see changed-files note).

## Deviations & proposed amendments

- **R-08 tie-break extension (proposed amendment):** the contract's tie-break is
  effective APR → due date → principal → stable ID. This engine inserts the
  due-day key *between* APR and principal exactly as the mission text orders it,
  with "no due day" sorting last. Flagged for Agent 1 to ratify into R-08.
- **Doc float artifact:** the source plan document prints a final-payment amount
  a few cents different from the value both engines (v1 and v2) agree on. Per
  `ENGINEERING.md`, the doc's target column carries ±$0.01–$0.06 float noise;
  the clean-Decimal engine value is authoritative. The parity test pins the
  engine's value with a comment.

## Known estimation limits

- Simple interest, 365-day year (including leap years), accrued per accrual
  period at payday granularity — not daily compounding, not issuer statement
  cycles. Real card interest will differ.
- Payments are modeled as posting on the payday that funds them; real posting
  lags are not modeled.
- Card minimums without an entered amount use the R-06 estimator, which is a
  heuristic — statement minimums will differ.
- Promo APRs are not prorated inside an accrual period.
- `estimatedRemainingInterest` equals `estimatedTotalInterest` for a fresh plan;
  for reforecasts it is the interest from the authoritative snapshot forward.
- Due dates earlier than the first payday cannot be funded by any payday and are
  warned (`.dueDateBeforeFirstPayday`) rather than modeled.
- All of these are surfaced to the UI as `assumptions` notes on every result.

## Integration instructions

1. **Generating a plan** (onboarding flow, Agent 4+): map the SwiftData models to
   `PlanningInput` (stable `UUID`s for debts/obligations; `createdOrder` = insertion
   order), call `AvalanchePlanEngine.generatePlan(input)` on a background actor
   (it's pure and `Sendable`-friendly), persist the `PlanningResult` (it's
   `Codable` — store as a blob or map to schema-2 rows) together with
   `calculationVersion.rawValue == 2`.
2. **Reforecasting** (balance-update flow): build `ActualState` from entered
   snapshots and call `reforecast(input, actuals:)`. Store the result **alongside**
   the plan, never over it (`kind == .reforecast` — three-truths separation).
3. **Calendar/notifications** (out of my scope, per prohibition): consume
   `result.events` — identifiers are stable across regenerations of the same
   input, so diffing old/new event lists gives adds/removes for notification
   scheduling.
4. **Insights UI:** `movements` strings are ready-to-display per-paycheck
   explanations; `recommendationExplanations`, `warnings`, and `assumptions` are
   sentence-level copy with `ReasonCode`/`PlanningNoteCode` enums for iconography.
   `minimumOnlyComparison?.interestSaved` drives the "interest saved vs minimums"
   insight — show it only when non-nil (the engine already withholds unsupported
   claims).
5. **Version dispatch:** route Original Plan v1 rendering through the frozen
   calc-v1 path; only new/regenerated plans call calc v2. Never regenerate the
   migrated baseline.
