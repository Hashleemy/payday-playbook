# Agent 1 — Release Contract / Architecture report (v0.4.0)

- **Role:** Release Contract & Architecture owner (registry, versioning, shared
  interfaces, agent boundaries). No feature implementation — only the three contract-level
  leaf types the plan §4 lands deliberately.
- **Branch:** `feature/v0.4-contract`, based on `main` at `124d56b` (the merged
  v0.3.0-alpha.1 integration; working tree verified clean before work began).
- **Date:** 2026-08-17. Current state verified as **0.3.0 / build 4 / schema 3 / calc 3 /
  export 3** (`project.pbxproj`, `PlanContract`, `ExportService` constants read directly;
  0.3.0-alpha.1 prepared, untagged, undistributed; 515 unit + 35 UI tests documented
  green) → targets confirmed as **0.4.0** and **v0.4.0-alpha.1**, build **5** at the next
  distributed cut. No version derivation was needed.

This report contains no personal financial values (V3-12/V3-13, permanent).

## Outcome

The v0.4.0 contract is authoritative and implementation-ready:

1. **Registry:** V4-01…V4-08 are canonical in `ALPHA_V0.4.0_MULTI_AGENT_PLAN.md`, carried
   at soul level in `soul.md` (new v0.4.0 contract table + amendments 6 and 7), and
   specified in `MVP_LAYOUT.md` (§4.6/§4.7 validation and reactivity, §5 R-12 amendment +
   R-25…R-29, §6 v0.4.0 DTO block, §8.4/§8.6/§8.10/§8.11 screens, §11 acceptance
   criteria, §12 V4 parity matrix, §13 T-18…T-25, §15 wave sequence).
2. **Versioning:** `docs/releases/v0.4.0/VERSIONING.md` — app 0.4.0; build 5; persistence
   schema **stays 3**; calculation version **4** with the reduction chain and the
   two-constant rule preserved (`minimumModernCalculationVersion` stays 2); export schema
   **4** (writes 4, reads 1–4) as a semantic forward-refusal bump.
3. **The Balanced policy is fully determined** (V4-03, R-25…R-27): candidate enumeration
   with an interest-ignoring optimistic pre-filter, guardrails G1–G3 on four named
   `PlanContract` constants, lexicographic selection with a complete tie-break chain,
   engine-side `quickWinPromotions` mechanics that leave the R-16 identities untouched, a
   rationale DTO for honest explanation, and snapshot-pinned reproducibility on apply.
   Agent 3 implements without inventing product policy.
4. **Shared interfaces landed or bound by name** (plan §4): no agent can mint a competing
   DTO, bridge, or service for any v0.4.0 concept.
5. **Ownership boundaries** pre-assign every known hot spot (onboarding utilization call
   sites → Agent 2; `QuickAddSheet.swift` incl. style adoption → Agent 5;
   `TodayView.swift` → Agent 4; `CalendarTabView.swift` → Agent 6), with copy-paste
   prompts for Agents 2–7.

## Changed files

Documentation:

- `ALPHA_V0.4.0_MULTI_AGENT_PLAN.md` — new; authoritative registry, behavior contracts,
  DTO/interface contract, ownership map, wave plan, prompts 2–7, dashboard, DoD.
- `docs/releases/v0.4.0/VERSIONING.md` — new; six-axis contract.
- `soul.md` — v0.4.0 feature contract table (V4-01…V4-08); amendments 6 (legacy
  quick-entry adjustment supersession) and 7 (Balanced strategy enrichment); V3-05 and
  F-05 row annotations; registry-scope line extended to V4.
- `MVP_LAYOUT.md` — retitled v0.4.0; §1 brief, §2 versioning summary, §4.6 debt-type
  field-relevance matrix, §4.7 setup-reactivity rules, §5 R-12 amended + calc-v4 block
  (R-25…R-27) + derived-service rules (R-28/R-29), §6 v0.4.0 DTO additions, §8 intro +
  §8.4/§8.6 amendments + new §8.10/§8.11, §10 service-map rows, §11 v0.4.0 criteria,
  §12 V4 parity matrix, §13 T-18…T-25, §15 v0.4.0 wave sequence, §17 addendum.
- `docs/releases/v0.4.0/agent-reports/agent-1-contract.md` — this report.
- `CHANGELOG.md` — deliberately untouched (Agent 7 owns release notes; repository policy
  does not require an Unreleased entry at contract time).

Code (contract-level leaf types only, plan §4):

- `PaydayPlaybook/Support/UtilizationMath.swift` — new; the single R-12 implementation +
  the 0.30/0.90 thresholds.
- `PaydayPlaybook/Models/DebtAccount.swift` — `DebtType.usesOriginalPrincipal` (the V4-01
  semantic predicate); `DebtAccount.utilization(currentBalance:)` now forwards to
  `UtilizationMath` (behavior identical).
- `PaydayPlaybook/Components/DebtPresentation.swift` — `showsOriginalPrincipal` forwards
  to the semantic predicate (values unchanged for all six types, pinned by test).
- `PaydayPlaybook/Components/PrimaryActionButton.swift` — new; `PrimaryActionButtonStyle`
  + `.primaryAction` (semantic API; visual refinement and ownership pass to Agent 4).
- `PaydayPlaybookTests/UtilizationMathTests.swift` — new; T-21 contract pins (unknown
  limits, exact ratios, over-limit, thresholds, model forwarding, per-type
  original-principal relevance).

## Key decisions (with rationale)

1. **Calc version 4, boundary constant untouched.** V4-03's promotion input changes
   calculation semantics for new plans, so `currentCalculationVersion` → 4 and
   `PlanCalculationVersion` gains `.v4BalancedQuickWin = 4` — both representations
   together (the v0.3.0 survey showed `ScenarioCalculationService` stamps the enum
   directly; splitting them silently splits stamps). `minimumModernCalculationVersion`
   stays 2: v0.4.0 retires no calculation family, and the v0.3.0 mutation-checked
   blank-on-upgrade regression is re-pinned, not re-litigated. Reduction chain: v4 (no
   promotions) ≡ v3 ≡ v2 (no scenario/extras) ≡ v1 (biweekly), all tested — so V2-10's
   generated baseline and every stored plan keep their exact values.
2. **Balanced selection is lexicographic guardrails, not scoring.** The release mandate
   forbade `APR × w1 + balance × w2`; the policy compares complete engine simulations and
   admits a quick win only when it strictly advances the first payoff (G3) without
   materially delaying debt-freedom (G1: ≤ 1 pay period) or costing material interest
   (G2: ≤ min(1% of baseline interest, $50)). The four thresholds are named, tunable
   `PlanContract` product constants (A-12) — transparent numbers a user could be told,
   not hidden weights. Single promotion per candidate (A-14) keeps the search
   deterministic and affordable; the pre-filter bound is provably over-inclusive (it
   ignores interest), so no true candidate is lost. Selection runs at preview; **apply
   pins the promotion into the snapshot**, so applied plans regenerate through the
   engine alone, forever, without re-running the selector.
3. **Export schema 4 is a semantic bump; persistence schema stays 3.** No stored field is
   added anywhere (promotions ride `inputSnapshotData` as an additive optional key;
   V4-07/V4-08 are derived services by mandate). But a 0.4.0 backup can carry calc-4
   plans that a schema-3 reader would restore and then fail to dispatch
   (`PlanCalculationVersion(rawValue: 4)` is nil there) — the envelope exists precisely
   to refuse newer documents by name, so the export axis says no. Writers emit 4, readers
   accept 1–4, envelope shape unchanged, both stamping sites move together.
4. **Pay-cycle allocation is derived, anchored, and single-sourced.** Cycle boundaries
   come from the active plan's `PaydayPlanItem` dates (the calendar's own schedule
   source) extended by the live `IncomeSchedule` cadence — the survey showed no cycle API
   exists and two near-miss derivations (TodayState, AccountBalanceService) disagree at
   the edges, so R-28 mandates exactly one implementation in `DebtAllocationService`.
   Qualifying payments are `.cardPayment` ledger rows only (check-in payments already are
   ledger rows — the double-count hazard is pinned in R-28 and T-24). The carry-in fold
   is `max(0, …)` per cycle: overspending surfaces as overage, never as negative
   spendable money or borrowed carry-in.
5. **V4-01 is a one-predicate fix with a three-surface contract.** The defect is an
   asymmetry: `SetupCompletenessService` and the Bills & Debts warnings demand original
   principal for every debt while both editors hide the field for cards — an unresolvable
   chip. The predicate (`DebtType.usesOriginalPrincipal`) lands now so all three surfaces
   consume one rule; the §4.6 matrix also settles credit-limit relevance and preserves
   the non-blocking philosophy exactly (installment minimums remain the only per-debt
   blocker, A-06).
6. **V4-02 is contracted as an invalidation rule, not a rewrite.** The survey showed
   back-navigation currently resets derived state only by SwiftUI view-identity accident,
   count-keyed observers miss same-count edits, and the Review step can persist a cached
   plan preview after upstream edits (the commit-staleness hole). The contract pins
   content-fingerprint invalidation, the Generate/Commit fingerprint guard, and makes the
   back-edit-forward matrix a tested behavior rather than a structural coincidence.
7. **V4-04 lands its canonical function now.** Three utilization reimplementations and
   two divergent balance sources exist; `UtilizationMath` + threshold constants are in the
   tree from day one so Agents 2/3/4 route to it instead of negotiating mid-wave. The
   survey found no literal `0%`-at-high-balance code path; the contract therefore names
   the three candidate divergences (plan-screen `startingBalance` fallback, engine
   snapshot-lag, truncating percent formatting) and obligates Agent 4 to reproduce and
   pin the reported case rather than declare it fixed by assertion.
8. **V4-06 retires the legacy sheet, not the legacy data.** The generic flow converges on
   `CashLedgerService.adjustBalance` (snapshot + delta row in one save — the
   reconciliation companion-row invariant depends on their shared `createdAt`). The
   seven-kind legacy sheet was the last user-facing writer of founding-vocabulary rows;
   its retirement is recorded as soul amendment 6 with an explicit
   historical-rows-forever guarantee and a byte-for-byte non-mutation test. The windfall
   form's "Checking 1/2" labels are swept in the same scope; remaining founding
   vocabulary elsewhere (check-in, Today, Settings) is deliberately out of scope and must
   be listed in Agent 5's report for a future registry.
9. **`PrimaryActionButtonStyle` ships as a working baseline.** Both Agent 4 (visuals) and
   Agent 5 (adoption in parallel Wave 3) need the API; landing the semantic name with a
   conservative white-on-accent implementation (≈10:1 against the current navy in both
   appearances) avoids a cross-wave dependency. Agent 4 owns the file from here,
   including the `AccentColor` dark-appearance variant.
10. **Wave shape:** Agents 2 and 3 are disjoint by file and run in parallel; Agent 4
    consumes both (rationale DTO for the Balanced card; validation semantics for chips)
    and so sits in Wave 3 with Agents 5 (depends only on Wave 1) and 6. Merge order
    1→2→3→4→5→6 with a build+unit run after every merge — the v0.3.0 lesson (textually
    clean merges failing at compile or only in the merged tree) is written into
    Agent 7's prompt.

## New shared interfaces

Landed (code): `UtilizationMath` (+ thresholds), `DebtType.usesOriginalPrincipal`,
`PrimaryActionButtonStyle`/`.primaryAction`.

Bound by name (docs, plan §4 / layout §6): `PlanCalculationVersion.v4BalancedQuickWin`;
`ScenarioInput.quickWinPromotions` / `StoredScenarioDefinition.quickWinPromotions`;
`BalancedSelectionRationale` (+ `ScenarioResult.balancedRationale`);
`ReasonCode.quickWinPromotion`; `PlanningNoteCode.quickWinSelected` /
`.quickWinCostsMoreInterest` / `.quickWinPromotionIneligible`; `BalancedStrategySelector`;
`PlanContract.balancedQuickWin*` (four constants); `DebtAllocationCalculating` /
`DebtAllocationService`; `PayCycleAllocation`; `MonthlyDebtProgress` / `ClearedDebt`.

## Version decisions (summary)

| Axis | Decision |
| --- | --- |
| App | 0.4.0, tag `v0.4.0-alpha.1` only at the cut; distribution stays blocked on the owner's history decision |
| Build | 5 at the next distributed build (Agent 7 only) |
| Persistence schema | stays 3; conditional-bump path documented (both duplicated migration step lists) |
| Calculation | 4 for new/previewed/applied plans; stamps 1/2/3 frozen; `minimumModernCalculationVersion` stays 2; both calc-version representations move together |
| Export schema | 4 (writes 4, reads 1–4); envelope shape unchanged |
| User plan versions | data, not software — unchanged |

## Checks run

- **Branch/versions verified** before any change: `feature/v0.4-contract` at `124d56b`
  == `main`, clean tree; `MARKETING_VERSION 0.3.0` / `CURRENT_PROJECT_VERSION 4`;
  `PlanContract` 3/3/2/1/1; `ExportService` 3 / 1...3 — all read from source.
- **Survey evidence:** every V4 contract statement is grounded in file:line findings from
  a seven-reader parallel survey plus direct reads of the engine, DTO, scenario,
  validation, and versioning layers (no personal values encountered — the tree is
  post-V3-12 fictional).
- **Registry coverage:** V4-01…V4-08 present in `soul.md`, `ALPHA_V0.4.0_MULTI_AGENT_PLAN.md`,
  and `MVP_LAYOUT.md` (§11 criteria + §12 matrix), verified by grep (8/8 each).
- **Coupling check:** every v0.4.0 DTO/protocol contract references Foundation-only
  types; no SwiftUI/SwiftData type appears in any engine-side contract; `UtilizationMath`
  imports Foundation only.
- **Unit suite:** full `PaydayPlaybookTests` run on this branch with the new contract
  types and tests — **526/526 green** (515 existing + 11 new `UtilizationMathTests`;
  command and environment per `TESTING.md`: dedicated `-derivedDataPath` outside
  `~/Documents`, iPhone 17 Pro simulator).
- UI suite not run (docs + leaf types; no UI behavior change — the style exists but no
  call site adopts it yet, by design).

## Risks and open items

1. **Guardrail constants are product judgment.** The four `balancedQuickWin*` values
   (3 paychecks / 1 paycheck / 1% / $50) are my determination of "strategically useful
   without material harm" — transparent, named, and tunable (A-12), but the owner may
   want different numbers; changing them is a constant edit, not a contract change.
2. **Balanced cost grows with candidates.** Worst case ≈ debts−1 extra engine runs per
   Balanced preview on top of the known ~0.2 s/projection simulator figure. The
   pre-filter and the skip-minimum-only option bound it; Agent 3's benchmark gates
   whether further mitigation (e.g., a candidate cap) is needed — do not add one
   speculatively.
3. **The 0%-utilization report is not yet reproduced.** The survey found no code path
   that literally renders 0% near the limit; the three named divergences are candidate
   causes. If Agent 4's root-cause lands elsewhere (e.g., a data-entry path), the fix may
   move owners — the contract requires the finding either way.
4. **Legacy-row derivations after the V4-06 retirement** are guaranteed by contract and
   test, but the legacy `Checking2State` reserve buckets lose their only user-facing
   "use" writer; the founding install records such movements through the generic
   account flow going forward. Recorded as soul amendment 6; flag for the owner's alpha
   pass on the migrated device.
5. **Carried-forward, unchanged:** Git-history remediation remains an owner decision
   blocking external distribution; the TESTING.md device checklist (upgrade rehearsal
   first) has still never run on hardware for build 4 and now gates build 5; repository
   visibility must be re-checked against the hosting account, not assumed private;
   main-thread engine work remains the known perf debt (out of scope).
6. **Docs briefly lead code** (by design): until Waves 2–3 land, the tree still contains
   the card original-principal gap, the count-keyed observers, the legacy adjustment
   sheet, and calc/export constants at 3 — `MVP_LAYOUT.md` describes the contracted
   state.

## Handoff contracts

- **Agent 2:** §4.6 matrix + §4.7 reactivity; consume `DebtType.usesOriginalPrincipal`;
  onboarding utilization call sites route to `UtilizationMath` (your files); keep the
  non-blocking philosophy and V2-01 matrix green; `SetupCompletenessService` stays the
  single gap source.
- **Agent 3:** R-25…R-27 exactly; both calc-version representations + every stamping
  site; export 4; dispatch guards extended and mutation-checked; rationale DTO as named;
  benchmark; nothing outside your file list.
- **Agent 4:** `UtilizationMath` adoption + thresholds; the three named divergences +
  0% root-cause with regression pin; `PrimaryActionButton.swift` ownership, AccentColor
  dark variant, contrast evidence; Balanced rationale card UI.
- **Agent 5:** §8.10 exactly; both adjustment types through `CashLedgerService.adjustBalance`;
  legacy non-mutation fixture test; windfall label sweep; `.primaryAction` adoption in
  your forms; report residual founding-vocabulary sites.
- **Agent 6:** R-28/R-29 exactly; `DebtAllocationCalculating` shapes as named; the only
  cycle-boundary implementation; content-fingerprint refresh; honest labels.
- **Agent 7:** merge 1→2→3→4→5→6 with build+suite per merge; §11 v0.4.0 gates + full
  regression; versions 0.4.0/5; truthful changelog; TESTING.md/README refresh; one
  status.

## Commits

On `feature/v0.4-contract` (base `124d56b`):

- `9071553` — docs(v0.4): establish release contract and agent boundaries (10 files:
  the four governing docs, the versioning contract, this report, the three contract
  leaf types, and their tests; unit suite 526/526 green at this commit).
- (+ one follow-up commit recording this hash in this report, per the v0.3.0 precedent.)
