# Agent 3 report — Planning Strategy & Optimization (v0.4.0)

- **Role:** Balanced Strategy and Calculation Version owner — V4-03 (R-25…R-27),
  the calc-4 bump at every stamping site, and the export-4 bump.
- **Branch:** `feature/v0.4-planning-strategy`, based on the Agent 1 contract
  commit `b71e193` (verified before any edit; clean tree).
- **Commit:** recorded in the follow-up commit, per the v0.2/v0.3 precedent.
- **Date:** 2026-08-20.

This report contains no real person's financial values (V3-12/V3-13,
permanent). Every number below is from invented fixtures.

## Outcome

Balanced (Recommended) is now a genuine multi-objective strategy. It compares
complete engine simulations of the pure-avalanche baseline and every
deterministic quick-win promotion, admits candidates through the contract's
three guardrails, selects lexicographically — never by weighted scoring — and
explains its choice with engine-proven figures. Fastest Safe and More Cushion
are untouched: pure R-08 avalanche under their own constraints. No stored plan
changes value; calc v4 with no promotions reproduces calc v3 byte-identically,
and the chain to v2 (and the frozen v1) stands.

## 1. Old behavior

Before this branch, every scenario kind — including Balanced — ran one
projection whose extra principal always attacked the highest effective APR
(R-08). A small, nearly-cleared account never received attention before the
strict avalanche target, even when clearing it would cost cents and free its
minimum payment within a couple of paychecks. The only Balanced/Fastest-Safe
difference was the constraint set (floor, allowance, planned savings).

## 2. New strategy algorithm (V4-03, R-25…R-27 — implemented exactly)

### Engine mechanics (R-25)

`ScenarioInput` and `StoredScenarioDefinition` gained
`quickWinPromotions: [UUID]` (optional key, default empty; tolerant decoders;
the key is omitted when empty, so calc-v2/v3 snapshot bytes are unchanged —
tested). In `AvalanchePlanEngine`:

- Promotions are validated once per run: only debts that are **active and
  `.eligible` at plan start** promote. Anything else — retired, ineligible,
  unknown-terms, or not in the plan — is a no-op with warning
  `.quickWinPromotionIneligible`, byte-identical output otherwise (tested).
- Validated promotions sort ahead of the R-08 extra-principal attack order
  **and** the assembled payoff order, in list order, until retired; the pure
  R-08 order resumes behind them (`attackSorted`, which *is*
  `prioritySorted` when the promotion list is empty — the reduction depends on
  that, and `CalcV4ReductionTests` pins it byte-for-byte).
- Minimums funding, obligation reserves, floor top-up, allowance, scenario
  cash retention, and shortfall math are untouched — only the *destination* of
  extra principal moves — so all four R-16 reconciliation identities hold on
  every promoted run (asserted by the shared `ScenarioFixtures.assertReconciles`
  on every new projection the suites produce).
- Promoted extra payments carry `ReasonCode.quickWinPromotion` instead of
  `.avalancheHighestEffectiveAPR` (calling the promotion "highest APR" would
  lie), and the paycheck movement line and recommendation explanation adjust
  the same way. With no promotions, every reason, movement, and explanation is
  unchanged.
- A promotion on an input stamped below calc v4 is a **validation error**
  (`PlanningValidationError.promotionsRequireCalcV4`) — never a silent ignore,
  never a silent upgrade (tested at both the engine and snapshot levels).

### Candidate enumeration (R-25)

`BalancedStrategySelector.select(snapshot:definition:)`:

1. **B0** — Balanced constraints, no promotions — is run once (a full run,
   minimums-only comparison included) and reused for the pre-filter, every
   guardrail, and the fallback result.
2. Every debt that is active, `.eligible`, and not B0's first extra target is
   a *pre-candidate* iff `balance ≤ Σ over B0's first
   balancedQuickWinHorizonPaychecks paychecks of (extraTotal + that debt's
   minimums)`. The bound ignores interest, so it can only over-include; the
   suite proves the over-inclusion direction by force-simulating an excluded
   debt and showing it genuinely cannot retire in time.
3. Each pre-candidate is simulated as a complete engine run with
   `quickWinPromotions = [debt]` (single promotion — A-14). It is a
   *candidate* iff the simulation retires it within the horizon.

### Guardrails and selection (R-26)

Admissibility against B0, each side a complete engine forecast:

- **G1** `candidate.paycheckCount ≤ B0.paycheckCount +
  balancedQuickWinMaxDelayPaychecks`, and the candidate is not "not payable as
  configured".
- **G2** `candidate.interest − B0.interest ≤
  min(balancedQuickWinMaxExtraInterestRate × B0.interest,
  balancedQuickWinMaxExtraInterestCap)`. A zero-interest baseline admits only
  zero-delta candidates — the guardrail never manufactures headroom.
- **G3** the candidate's first account payoff is *strictly* earlier than B0's
  (or B0 clears nothing within its projection and the candidate does).

Selection among admissible candidates is the exact lexicographic chain:
earliest first-payoff date → lowest estimated total interest → earliest
debt-free date → promoted debt earliest in R-08 order at plan start → promoted
debt UUID string. The guardrail predicates and the comparator are internal
statics tested at exact boundaries (`50.00` passes, `50.01` fails; a tie at
each level falls through to the next; the final UUID key makes the order
total). No admissible candidate → **B0 is Balanced**, byte-identically the
pre-v0.4.0 behavior (tested).

The four policy constants live in `PlanContract` exactly as contracted:
`balancedQuickWinHorizonPaychecks = 3`, `balancedQuickWinMaxDelayPaychecks = 1`,
`balancedQuickWinMaxExtraInterestRate = 0.01`,
`balancedQuickWinMaxExtraInterestCap = 50`.

### Deterministic decision rules

Identical inputs always produce the identical selection (R-22 extended):
candidates are enumerated and simulated in R-08 order at plan start
(`AvalanchePlanEngine.attackOrder`, a public helper sharing the projection's
own comparator so the two can never drift), every comparison figure comes from
a deterministic engine run, and the tie chain ends at a UUID string. Repeated
`select` calls and repeated full `scenarios` calls are byte-identical (tested).

### Where the selector runs — and where it never does

- `ScenarioCalculationService` invokes the selector **only** for `.balanced`
  definitions whose `quickWinPromotions` is empty. Fastest Safe and More
  Cushion never see it.
- **Applying pins the selection** (`ScenarioPlanActivationService.apply`): a
  previewed quick win writes its concrete promotion into the persisted
  snapshot's definition, so `PlanGenerationService.regenerate` re-runs the
  engine with the pinned promotion and **never the selector**. The applied
  plan reproduces the previewed projection byte-for-byte (tested), forever.
- Previews remain write-free (R-15/V3-15): the selector and the scenario
  service are pure value-type code; the store-count test pins it.
- Applying keeps the existing future-effective plan-version model:
  `scenarioKind = .scenario`, `effectiveDate` from the definition, a brand-new
  `PlanVersion` graph, prior versions untouched beyond `isActive`.

### Selector walkthrough on the fictional T-20 fixture

Biweekly take-home $2,400; floor $1,000; allowance $250; planned savings $100;
one $900/month bill (smoothed reserve $415.38). Debts (all entered minimums,
no due days): Aurora Card $8,000 @ 24.00% (min $160), Comet Auto $9,000 @
7.00% (min $200), Frost Loan $900 @ 23.00% (min $45). Extra per paycheck ≈
$1,229.62.

1. **B0:** R-08 order Aurora → Frost → Comet; every extra dollar attacks
   Aurora; the first account payoff (Aurora) lands around paycheck 7.
2. **Pre-filter (H = 3):** Frost qualifies ($900 ≤ ≈3 × $1,229 + its
   minimums). Comet does not ($9,000 far above the optimistic bound) — and the
   suite force-simulates Comet's promotion to prove the exclusion honest.
   Aurora is B0's first target and is excluded by definition.
3. **Candidate run C(Frost):** promoted Frost absorbs ≈ $863 of paycheck 1's
   extra and clears immediately — within the horizon, so it is a candidate.
4. **Guardrails:** G1 — the debt-free date is unchanged (the redirected
   dollars return to Aurora with Frost's freed $45 on top). G2 — the extra
   interest is ≈ $2 (a ~1% APR differential on ≈ $863 for a few weeks),
   inside min(1% × baseline interest, $50). G3 — the first account payoff
   moves from paycheck 7 to paycheck 1.
5. **Selection:** one admissible candidate → Frost wins; the full re-run
   becomes the Balanced card; the rationale reports the engine-proven deltas;
   applying pins `quickWinPromotions = [Frost]` into the snapshot.

Lower Frost's APR to 15.00% and step 4 fails at G2 (≈ $19 of extra interest
against a ≈ $5.50 allowance): Balanced stays the strict avalanche,
byte-identically — the suite pins both outcomes.

## 3. Explainability model (R-27)

`BalancedSelectionRationale` (Foundation-only, Codable/Equatable/Sendable, in
`PlanningContracts.swift`) is attached as `ScenarioResult.balancedRationale` —
nil for the other two kinds, for non-computable cards, and for pinned
regenerations. Fields exactly as contracted: `selection`
(`.avalanche`/`.quickWin`), `promotedDebtID`, `promotedDebtName`,
`candidatesConsidered` (R-25 candidates — debts whose full simulation retired
them within the horizon), `interestDeltaVsAvalanche`, `payoffDelayPaychecks`,
`firstPayoffAdvanceDays` (nil when B0 clears nothing), and
`releasedMinimumPerPaycheck` — defined as the minimum B0 still funds for the
promoted debt in its first paycheck after the quick win clears it (nil when B0
funds none after that date, which honestly means nothing is released).
`explanations` carries calm sentences whose every number restates a field.

Honesty rules carried through: a costlier quick win is disclosed with its
amount (`PlanningNoteCode.quickWinCostsMoreInterest` in warnings;
`.quickWinSelected` in assumptions); no finish-line or savings claim is made
unless both compared projections finished (the R-16 precedent — the
`bothFinished` branch states the horizon caveat instead); the scenario
surface's cross-scenario `deltaVsBalanced` figures stay measured against the
*selected* Balanced, so the Fastest Safe comparison stays honest; utilization
is never a selection input and never appears in an explanation (pinned by a
test that strips credit limits and gets an identical rationale).

**One canonical mapping path.** Both scenario consumers — the Payoff Scenarios
workspace and the PDF report builder — call the same
`ScenarioCalculationService.scenarios`, so they get the same rationale from
the same run. For applied plans, the Plan screen, Today, and Insights all read
the one stored graph / regenerated result: `payoffOrder`,
`currentTargetDebtID`, `recommendationReasons` (now carrying
`.quickWinPromotion`), the `PaydayPlanItem.plannedTargetDebtID` rows, and
`PlanVersion.avalancheOrder` all lead with the promoted debt (tested
end-to-end from preview through apply to regeneration). No surface invents its
own comparison.

## 4. Calculation-version handling (VERSIONING.md §5 — both representations, every site)

- `PlanCalculationVersion.v4BalancedQuickWin = 4` and
  `PlanContract.currentCalculationVersion = 4` move together; a test pins
  their equality so the stamps can never split again.
- **`PlanContract.minimumModernCalculationVersion` stays 2**, untouched. The
  dispatch guards are extended, not weakened: an upgraded calc-2 *and* an
  upgraded calc-3 plan still reach the modern engine under their own stamps;
  the frozen calc-v1 baseline stays off it; a newly generated plan stamps 4; a
  new mutation-style test asserts the boundary is still 2 and strictly below
  the current version.
- Stamping sites updated together: `PlanningInputBuilder` (via the constant),
  `ScenarioCalculationService` (scenario snapshots now stamp v4),
  `ScenarioPlanActivationService.apply` (stamps the *projection's* version
  into the snapshot — always matching the persisted rows) and its summary
  fallback, `ExtraPaymentInsightService`, and
  `PlanGenerationService.engineInput`'s inference (`≥ 4` → v4; `3`/scenario/
  extras → v3, unchanged; `1` → frozen). The engine's result stamp switch
  covers v4.
- **Value preservation:** calc v4 with no promotions ≡ calc v3 byte-identical
  apart from the stamp; calc v4 with no scenario and no extras ≡ calc v2
  (V2-10's generated-baseline contract holds to the cent); stamps 1/2/3 are
  never rewritten and reproduce under their own semantics. Onboarding
  generation is unchanged in value — only its stamp becomes 4.
- Exports/restores preserve the calculation version: the calc-4 stamp and the
  pinned promotion ride `inputSnapshotData` through backup and restore
  (tested round-trip).

## 5. Export schema 4 (semantic bump)

`ExportService.backupSchemaVersion` 3→4, `importableSchemaVersions`
`1...3`→`1...4`. The envelope derives its version from the payload and
`readBackup` already enforces their equality, so both stamping sites move with
the one constant. Schema 1/2/3 files still import; a 4 file round-trips; a
future schema still fails safely by name.

**One necessary fix beyond the constants**, in `ExportService.restore`: the
migration-steps condition was `backup.schemaVersion < backupSchemaVersion`,
which conflated the export-envelope axis with the persistence axis. With the
constant at 4 it would have re-run the schema-3 logical upgrade on every
schema-3 restore — re-copying the profile floor onto an account whose
protected amount the user had since zeroed, and forcing
`onboardingComplete = true` — both value mutations on restore. The condition
now keys on `PlanContract.currentSchemaVersion` (the axis the migrations are
actually about; export 3 and export 4 both carry schema-3 rows). Behavior for
schema-1/2 files is unchanged; a new test pins the schema-3 no-side-effects
restore. `TemplateImportExportService` deliberately stays at template schema 3:
templates carry setup structure only and can never contain a calc-4 plan, so
there is nothing for an older reader to mis-dispatch (flagged for Agent 7 to
ratify).

## 6. Performance

Design choices, per the contract: B0 is computed once and reused everywhere
(memoization within a single evaluation; no global caches); candidate runs
skip the minimums-only comparison projection via a new internal engine option
`generatePlan(_:includeMinimumOnlyComparison:)` — tested to change nothing but
the omitted comparison — halving candidate cost; the winner is re-run once in
full so the returned/persisted result is a complete ordinary engine run.
Balanced preview cost is therefore `2 + N + 2` projections (B0 full + N
candidates + winner full) when a quick win is selected, `2 + N` otherwise.

Measured on the iPhone 17 Pro simulator (fictional fixtures, invented values —
`testEightDebtBalancedSelectionBenchmark`, which prints the figures and
asserts only an order-of-magnitude backstop, not simulator jitter):

| Work | Wall clock |
| --- | ---: |
| 8-debt fixture, Balanced selector end-to-end (4 candidates simulated; a quick win selected) | **0.045 s** |
| 8-debt fixture, all three scenario cards including the selector | **0.078 s** |

That fixture's plan is short (~17 biweekly paychecks — a large surplus against
$33,450 of debt), so per-projection cost is small. The v0.3.0 report's
0.2 s/projection figure came from a 77-paycheck fixture; the engine is
O(paychecks × debts) and the selector adds `2 + N + 2` projections, so a
long-horizon 8-debt plan extrapolates to roughly 1.5–2 s for the Balanced
card — the same order as the existing three-card screen, and the reason the
skip-minimum-only option exists. The scenario screen's cache-and-loading-state
posture (v0.3.0 agent-3/agent-4 handoff) still applies; no engine call happens
in a view body. No candidate cap was added — the contract says not to add one
speculatively, and these measurements do not justify one.

## 7. Tests

Full unit suite: **565 tests, 0 failures** (baseline at the contract commit:
526; 39 new). UI suite: **35 tests, 0 failures**, run alone with
`-parallel-testing-enabled NO` on the dedicated simulator — no view behavior
changes in this scope (the Balanced card UI is Agent 4's Wave-3 work), but the
scenario surface's data changed, so the suite was confirmed rather than
assumed.

New suites:

- `CalcV4ReductionTests` (15): v4 ≡ v3 byte-identical without promotions; v4 ≡
  v2 without scenario/extras; stamp inference for 3- and 4-stamped snapshots;
  the promotion gate (engine- and snapshot-level); promotion mechanics (leads
  attack + payoff order, `quickWinPromotion` reason, funding lanes untouched,
  R-16 identities); ineligible/unknown promotions as warned no-ops; the
  skip-minimum-only option's exact scope; snapshot byte-stability (no key when
  empty; pinned key round-trips; engine payloads without the key decode);
  promoted-run determinism.
- `BalancedStrategySelectorTests` (T-20, 20): admissible quick win selected
  with full-run result; guardrails re-verified against an independent
  baseline run; bad-tradeoff fixture keeps avalanche byte-identically;
  no-candidate fixture; Fastest Safe / More Cushion untouched; freed minimum
  flows into extra to the cent on the rows after the quick win clears; G1/G2/
  G3 at exact boundaries including the zero-interest baseline; the full
  lexicographic tie chain on synthetic stats; pre-filter over-inclusion proof
  by forced simulation; rationale figures reconciling to independent engine
  runs; determinism across repeats; unknown credit limits changing nothing;
  the scenario surface carrying rationale and notes; preview-writes-nothing +
  apply-pins-promotion + regeneration reproducing the preview; every surface
  resolving the same target from the stored graph; the 8-debt benchmark.

Extended/updated:

- `ReleaseIntegrationTests`: calc-2 guard reworded; **new** calc-3-plan
  dispatch guard; new-plan stamp is 4 with both representations agreeing;
  **new** boundary-still-2 mutation check.
- `ExportCompatibilityTests`: writer emits 4; **new** schema-3 import with no
  migration side effects (pins the restore fix); **new** calc-4 snapshot
  (with pinned promotion) backup/restore round trip.
- `BackupPortingTests`: envelope writes 4; probe classifies 4; the
  newer-schema rejection's "highest importable" is 4.
- `ScenarioSurfaceTests`: applied scenario stamps calc v4 (row and snapshot).
- `PrivacyScrubTests`: the `PlanContract` constant pin covers calc 4 and the
  four quick-win policy constants (generic product policy, no personal data).

## 8. Files changed

Owned code:

- `Services/Planning/PlanningContracts.swift` — `.v4BalancedQuickWin`;
  `ScenarioInput.quickWinPromotions` + tolerant Codable;
  `ReasonCode.quickWinPromotion`; `PlanningNoteCode.quickWinSelected` /
  `.quickWinCostsMoreInterest` / `.quickWinPromotionIneligible`;
  `BalancedSelectionRationale`; `ScenarioResult.balancedRationale`.
- `Services/Planning/AvalanchePlanEngine.swift` — promotion validation +
  ordering (`attackSorted`), the shared `PriorityKey` comparator + public
  `attackOrder`, the calc-v4 gate and stamp, promoted reason/movement/
  explanation lines, the `includeMinimumOnlyComparison` option, and the
  `CreditUtilization` assembly routed through `UtilizationMath` (values
  identical; R-12/V4-04 coordination point Agent 4 verifies).
- `Services/BalancedStrategySelector.swift` — **new**; R-25/R-26/R-27.
- `Services/PlanningDTO.swift` — `StoredScenarioDefinition.quickWinPromotions`
  (optional key; omitted when empty).
- `Services/PlanContract.swift` — `currentCalculationVersion = 4`; the four
  `balancedQuickWin*` constants.
- `Services/PlanGenerationService.swift` — v4 inference in `engineInput`;
  promotion pass-through in `scenarioInput`.
- `Services/ScenarioCalculationService.swift` — selector integration for
  `.balanced` (pinned definitions bypass); v4 stamping; rationale/notes
  attachment.
- `Services/ScenarioPlanActivationService.swift` — apply-time pinning; stamps
  follow the projection; summary fallback v4.
- `Services/ExtraPaymentInsightService.swift` — v4 stamp.
- `Services/ExportService.swift` — the two version constants; the
  restore-condition fix (§5 above).

Adjacent, forced or contract-implied (kept mechanical, flagged for Agent 7):

- `Services/PlanPersister.swift` — `orderedDisplayIDs` lifts validated
  promotions to the front so `PlanVersion.avalancheOrder` (which the Plan
  screen sorts by) agrees with the engine's promoted payoff order; byte-
  identical with no promotions. Without this, an applied quick-win plan's Plan
  screen would list the old order while Today targeted the promoted debt —
  exactly the "surfaces disagree" failure V4-03 forbids.
- `Features/Plan/PlanActivationView.swift` — one added `switch` case for the
  new validation error (exhaustiveness; unreachable from that screen; noted
  because SwiftUI files are otherwise out of my scope).

Tests: `CalcV4ReductionTests.swift` (new), `BalancedStrategySelectorTests.swift`
(new), `ReleaseIntegrationTests.swift`, `ExportCompatibilityTests.swift`,
`BackupPortingTests.swift`, `ScenarioSurfaceTests.swift`,
`PrivacyScrubTests.swift`.

Docs: this report.

## 9. Integration risks and handoff notes

1. **Agent 4 (Balanced card UI):** render `ScenarioResult.balancedRationale`
   — one calm line on the card, the full rationale in the comparison detail.
   `explanations` is ready-made copy; every figure in it restates a rationale
   field, so the card may also format its own from the numeric fields — but do
   not invent comparisons the rationale doesn't carry. `deltaVsBalanced` on
   the other cards already measures against the selected Balanced. The engine
   `CreditUtilization` assembly now routes through `UtilizationMath` — your
   "verify, don't re-edit" case.
2. **Balanced preview cost grew** (§6): unchanged advice — cache per input,
   loading state, never in a view body. If Agent 7 sees unacceptable
   wall-clock on device, the contract's next lever is a candidate cap; do not
   add one speculatively.
3. **`BackupPortingService`'s upgrade preview line** ("This backup uses format
   3. It will be upgraded to format 4…") now shows for schema-3 files. The
   restore itself is a no-op upgrade (by design, §5); the copy reads as
   envelope-format language, but Agent 7 may want to soften it. Not my file;
   not changed.
4. **Templates stay at schema 3** (§5). If Agent 7 reads VERSIONING's
   "templates share the axis" as requiring template schema 4, it is a
   two-constant change in `TemplateImportExportService` with no payload
   implications; I recommend ratifying 3.
5. **`GeneratedPlanService.whatIfResult`** (plan screen floor/allowance
   what-ifs) edits `protectedFloor`/`allowanceCap` on a copy of a snapshot; on
   a scenario-born plan the scenario's own preferred floor/allowance override
   those columns, so the what-if rows understate the change for such plans.
   Pre-existing v0.3.0 behavior, unchanged by this branch; recorded so it
   isn't attributed to calc v4.
6. **Merge order:** Agent 2's branch and this one are disjoint by file, per
   the ownership map; the two adjacent edits above are in files no other
   Wave-2/3 agent lists as owned (`PlanPersister.swift`,
   `PlanActivationView.swift` — the latter is in Agent 4's `Features/Plan/*`
   sweep; the one-case diff is trivial to carry).

## 10. Commands run

```bash
# Build (derived data outside ~/Documents — the iCloud-xattr CodeSign trap)
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$JOB_TMP/dd-agent3" build
# ** BUILD SUCCEEDED **

# Unit suite, on a simulator created for this worktree
xcrun simctl create pp-v04-agent3 …iPhone-17-Pro …iOS-26-5
xcodebuild … -destination 'platform=iOS Simulator,id=<pp-v04-agent3>' \
  -derivedDataPath "$JOB_TMP/dd-agent3" -only-testing:PaydayPlaybookTests test
# ** TEST SUCCEEDED ** — Executed 565 tests, with 0 failures
# [benchmark] 8 debts — Balanced selector alone: 0.045s (candidates simulated:
#   4, selection: quickWin); all three scenario cards incl. selector: 0.078s

# UI suite, alone, serially, same dedicated simulator
xcodebuild … -parallel-testing-enabled NO -only-testing:PaydayPlaybookUITests test
# ** TEST SUCCEEDED ** — Executed 35 tests, with 0 failures (501 s)
```
