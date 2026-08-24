# Agent 7 — Integration, QA, and Release report (v0.4.0-alpha.1)

- **Role:** Integration, regression, privacy, versioning, and release QA owner.
- **Branch:** `release/v0.4.0-alpha.1`, created from the Agent 1 contract tip.
- **Date:** 2026-08-20.

This report contains no personal financial values (V3-12/V3-13, permanent). All
figures quoted from tests are fictional fixtures.

## 0. The history rewrite (read this before comparing hashes)

Mid-integration, the owner directed that every `Co-Authored-By: Claude …` and
`Claude-Session: …` trailer be removed from the entire repository, including
pushed history. This was done with `git filter-branch --msg-filter` over **all
refs**; every tree is byte-identical (verified: pre/post tree hashes equal at
`main` and the release tip) but **every commit SHA changed**, and all twelve
origin branches plus the `v0.2.0-alpha.1` tag were force-pushed. Zero Claude
trailers remain on any live ref.

Consequences:

- Hashes recorded in v0.2.0/v0.3.0 documents are pre-rewrite identifiers of the
  same content; they no longer resolve in the live history. The v0.4.0
  documents (this directory) were updated to post-rewrite hashes.
- Key remaps: `main` `124d56b`→`3b20669`; contract commit `9071553`→`80b2ee4`
  (branch tip `b71e193`→`06e8c36`); the 0.1.0 root `b0e7443` is unchanged (its
  message carried no trailer, and it has no rewritten ancestor).
- GitHub retains the pre-rewrite objects server-side for some time (and PR
  pages still cite old SHAs); purging those requires GitHub support, same as
  it would for the (still open) withdrawn-data history decision.
- This rewrite **did not** address the withdrawn-data history question (§8) —
  the two are independent, and that decision remains the owner's.

## 1. Starting state and contract verification

- Contract: `feature/v0.4-contract` tip `06e8c36` (contract commit `80b2ee4`),
  based on `main` = the merged v0.3.0-alpha.1 (`3b20669`). Verified before any
  merge: `MARKETING_VERSION 0.3.0`, `CURRENT_PROJECT_VERSION 4`,
  `PlanContract` schema 3 / calc 3 / boundary 2, `ExportService` 3 / 1…3.
- Baseline suite at the contract tip: **526/526 unit tests green** (run in this
  environment before any merge — matching Agent 1's recorded count).
- Every feature branch based exactly on the contract tip (merge-bases
  verified). Branch names differ from the plan's table
  (`-onboarding-correctness`, `-planning-strategy`, `-ledger-adjustments`,
  `-debt-allocation-calendar`, `-debt-ui`); same scopes, recorded as
  administrative deviations.
- **Agent 4's work was complete but uncommitted** in the `v0.4-debt-ui`
  worktree (implementation, 16 tests, drafted report; no commit). After a full
  read-only audit of the uncommitted diff (ownership, canon, privacy), I
  committed it verbatim on `feature/v0.4-debt-ui` as `2badd77`, filled the
  report's two placeholders honestly, and verified its standalone claim by
  running its suite in its own worktree: **542/542 green**.

## 2. Merge order, commits, and conflicts

Order executed: **2 → 3 → 5 → 6 → 4** (the mission's order; it differs from
plan §7's 2→3→4→5→6 for a compelling repository reason — Agent 4's branch had
no commits when integration began, and its uncommitted diff was based on the
contract commit, not on Wave 2). Normal merge commits preserve provenance.
After **every** merge: build + full unit suite, plus diff inspection.

| # | Branch (feature tip) | Merge commit | Unit suite after |
| --- | --- | --- | ---: |
| 1 | `feature/v0.4-onboarding-correctness` (`8bf335c`, docs `e6351ec`) | `d36cd6a` | 548/548 |
| 2 | `feature/v0.4-planning-strategy` (`64a19d0`, docs `1a56666`) | `f87f513` | 587/587 |
| 3 | `feature/v0.4-ledger-adjustments` (`d0cb448`, docs `fc0c133`) | `5423f78` | 614/614 |
| 4 | `feature/v0.4-debt-allocation-calendar` (`af6b81c`, docs `51ae5b4`) | `9b64e02` | 661/661 |
| 5 | `feature/v0.4-debt-ui` (`2badd77`, docs `9c9354b`) | `cfdac57` | 677/677 |

Every count reconciles exactly with the owning agent's claimed additions
(526 + 22 + 39 + 27 + 47 + 16 = 677). No test was weakened or skipped.

**Textual conflicts (3 files, all in merge 5), and their resolutions:**

1. `Services/Planning/AvalanchePlanEngine.swift` — Agents 3 and 4 had
   independently made the *same* mechanical edit (routing the engine's
   `CreditUtilization` assembly through `UtilizationMath`); the contract's
   exception for Agent 4 applied only if Agent 3 had not already done it, and
   Agent 3 had. Resolution: **Agent 3's side wholesale** — Agent 4's hunk was
   semantically identical and contributed nothing unique.
2. `Features/Onboarding/DebtsStepView.swift` and
3. `Features/Onboarding/ReviewStepView.swift` — a genuine **display-convention
   divergence**, not just a textual collision: Agent 2's branch kept two-decimal
   `rounded2` percent strings at the three onboarding utilization call sites,
   Agent 4 standardized on `UtilizationMath.wholePercentString`. Resolution:
   **whole-percent wins** — §3.4 mandates one standardized display rounding
   ("nearest whole percent", "<1%"), and Agent 2's own report deferred the
   display-rounding half of R-12 to Agent 4 at exactly these call sites. Agent
   2's validation logic and canonical-routing structure were kept; only the
   formatting line took Agent 4's side.

`Features/Plan/PlanActivationView.swift` auto-merged cleanly (Agent 3's
exhaustiveness-forced `promotionsRequireCalcV4` case + Agent 4's
`.primaryAction` adoptions were disjoint hunks) — verified both survive.

## 3. Merged-tree defect hunt (what only the merged tree could show)

1. **V4-08 dashboard card vs. the Calendar month layout — real defect, fixed.**
   The serial UI suite failed `testCalendarDayOpensCheckIn`: with the
   dashboard card and the month grid in a fixed VStack, the selected-day panel
   List was squeezed to a **43.7-point sliver** partially under the floating
   tab bar (its first row is 98 points tall) — effectively unusable for any
   user in month mode whenever the card shows, which is whenever a plan is
   active. Fix (integrator, in Agent 6's file): month mode is now **one
   scrollable List** — dashboard card section first (still the topmost content,
   per §5.2), month grid section (borderless buttons keep each day cell
   individually tappable), then the selected-day sections. Week and agenda
   modes are unchanged (they had room). The UI test now scrolls to materialize
   the lazy day rows — the pattern ENGINEERING.md documents. Full unit suite
   re-run green after the change; UI suite re-run in §5.
2. **The engine duplicate edit** (§2.1) — the class of failure this project
   merges cleanly and breaks on; caught by pre-merge audit, resolved to one
   implementation.
3. **The display-convention divergence** (§2.2/2.3) — two branches that were
   each internally consistent and mutually contradictory; arbitrated by
   contract text.
4. **Checked, no defect found:** Agent 5's `accountAdjustment` rows vs Agent
   6's cycle sums (adjustments carry `destinationAccountID` and no
   `debtAccountID`, so the R-28 qualifying filter excludes them — pinned by
   both suites); Agent 2's `SetupInputFingerprint` vs Agent 6's
   `DebtAllocationFingerprint` (different stores, no interaction); Agent 4's
   `.primaryAction` refinement vs Agent 5's adopt-only call sites (style API
   unchanged); the Balanced rationale DTO vs the scenario surface (field-for-
   field match with the contract).

## 4. Duplicate / divergence audit (merged tree)

Verified single declarations (grep + read, post-merge): `PlanningInput` /
`PlanningResult` / `StoredPlanInput` / `StoredPlanResult` (the only extra match
is the pre-existing `PlanningInputBuilder`), `UtilizationMath` (one enum; the
only 0.3/0.9 threshold literals anywhere are its own definitions;
`DebtAccount.utilization` forwards), `PrimaryActionButtonStyle`,
`BalancedSelectionRationale`, `BalancedStrategySelector`,
`DebtAllocationCalculating` / `DebtAllocationService` / `PayCycleAllocation` /
`MonthlyDebtProgress` / `ClearedDebt`, `ScenarioDefinitionBuilder` (one
mapping; consumed, never reimplemented), `SetupInputFingerprint`,
`DebtAllocationFingerprint`. Payment-qualification logic exists once
(`DebtAllocationService`); `AccountBalanceService` replays balances for a
different purpose, as before.

**Ratified as amended §4 canon** (disclosed deviations, accepted):

- `UpcomingDebtAllocation` + `DebtAllocationCalculating.upcomingAllocation(asOf:)`
  (Agent 6 — required for the contracted before-first-payday state).
- `DebtAllocationFingerprint` (Agent 6) and `SetupInputFingerprint` (Agent 2) —
  the two content-invalidation keys; new observers should follow them.
- `UtilizationMath.wholePercentString` (Agent 4) — the one display-rounding
  implementation, additive on Agent 1's file.
- `PlanViewData.balanceUnavailableReason` (Agent 4) — view-layer only.
- `CalendarDebtDashboardCard.swift` as a new file in Agent 6's Calendar area;
  `AppEnvironment.debtAllocationService(context:)` factory (4 lines, matches
  the service-factory pattern).
- Agent 3's three disclosed out-of-grant edits, each necessary and test-pinned:
  `PlanPersister.orderedDisplayIDs` promotion ordering (plan surfaces must
  agree with the engine's promoted order), the `ExportService.restore`
  migration condition re-keyed to `PlanContract.currentSchemaVersion` (a
  constants-only bump would have re-run the schema-3 upgrade on schema-3
  restores — a value mutation), and the forced switch case in
  `PlanActivationView`.
- Agent 2's observation-only `@Query` additions in two Settings files and the
  service-boundary staleness guard in `OnboardingProgressService`.

**Documented drift hazards (no action this cycle, watch on future changes):**
the promotion-eligibility predicate exists in three agreeing forms (engine,
`PlanPersister`, selector pre-filter); `DebtAllocationService.zeroReachingDate`
mirrors the balance-replay ordering of `AccountBalanceService.debtBalances()`;
`LegacyCheckingLabels` re-derives the spending/reserves pair-selection
convention; `DebtAllocationFingerprint` covers ledger + active-plan rows but
not `BalanceSnapshot`/`DebtAccount` content (cleared-debts staleness from
another tab is mitigated by on-appear reloads).

## 5. Test matrix (final, this machine)

Environment per TESTING.md: derived data outside `~/Documents`
(`/private/tmp/...`), dedicated `simctl`-created simulators — `PP-v040-unit`
for unit runs, `PP-v040-ui` for the UI suite alone with
`-parallel-testing-enabled NO`; unit and UI never shared a simulator.

```bash
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,id=<PP-v040-unit>' \
  -derivedDataPath "$TMPDD/dd-unit" -only-testing:PaydayPlaybookTests test

xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,id=<PP-v040-ui>' \
  -derivedDataPath "$TMPDD/dd-ui" -parallel-testing-enabled NO \
  -only-testing:PaydayPlaybookUITests test
```

| Run | Result |
| --- | --- |
| Baseline at contract tip | 526/526 unit, 0 failures |
| After each of the five merges | 548, 587, 614, 661, 677 — all 0 failures |
| Agent 4 branch standalone (its worktree, its simulator) | 542/542, 0 failures |
| **Final unit suite (release tip)** | **677/677, 0 failures** |
| First full serial UI run (merged tree) | 35 tests, **1 failure** — the §3.1 Calendar defect |
| **Final full serial UI run (after the fix)** | **35/35, 0 failures** |

The one UI failure was a genuine merged-tree defect (not flake): deterministic
across three runs, root-caused to layout, fixed in the app, and the suite
re-run in full.

## 6. End-to-end acceptance evidence (mission scenarios A–H)

| Scenario | Evidence (all green on the merged tree) |
| --- | --- |
| A — card, no original principal | `DebtTypeValidationMatrixTests`: `testCreditCardWithNoOriginalPrincipalPassesSetupValidation`, `testNoSurfaceAsksACardForOriginalPrincipal`, `testInstallmentTypesKeepTheOptionalOriginalPrincipalGap` |
| B — back-navigation reactivity | `ReactiveSetupTests`: `testRegeneratedPreviewDerivesFromTheEditedBalance`, `testAPRChangeRetargetsTheAttackOrder`, `testDueDayEditReachesTheRegeneratedPlanInput`, `testIncomeEditMovesTheFuturePaydays`, `testCommitRefusesAPreviewWhoseInputsChanged` |
| C — strategy honesty | `BalancedStrategySelectorTests`: `testBadTradeoffKeepsTheAvalancheTarget` (avalanche-superior → no promotion), `testAdmissibleQuickWinIsSelected`, `testRationaleFiguresMatchIndependentEngineRuns` (tradeoff = full forecasts), `testSelectionIsDeterministicAcrossRepeatedRuns`; Fastest Safe untouched (`ScenarioCalculationTests` 34/34) |
| D — utilization | `UtilizationDisplayTests`: `testNearLimitNonTerminatingRatioNeverRendersZeroPercent` (the reported defect, root-caused to `Int(truncating:)` garbling full-width Decimal mantissas), `testNilLimitIsUnknown`/`testZeroLimitIsUnknown` (missing limit ≠ 0%), `testOverLimitExceedsOne` |
| E — CTA contrast | `PrimaryActionContrastTests`: measured WCAG ≥ 4.5:1 from the actual asset catalog in light and dark, dark-variant existence, label/fill pairing; disabled/pressed distinct by construction in `PrimaryActionButtonStyle` |
| F — checking adjustment | `LedgerAdjustmentFlowTests`: exact menu copy, both contract types, picker across 1–10 fictional user-named accounts (no "Checking 1/2" assumption), preselection rules, delta+snapshot appended in one save, legacy rows byte-for-byte unmutated |
| G — allocation arithmetic | `DebtAllocationServiceTests`: `testCarryoverAccumulatesAcrossConsecutiveCycles`, `testPartialPaymentLowersTheRemainderImmediately`, `testOverpaymentShowsZeroRemainingAndTheHonestOverage`, `testTransfersNeverCountAsDebtPayments`, `testDebtLinkedRefundRestoresTheAllocation` — the mission's carryover/available/remaining walk is this arithmetic |
| H — Calendar dashboard | `CalendarDebtDashboardTests`: exact wording (`testPaidTowardDebtsLabelIsExact`), monthly vs cycle separation, upcoming allocation labeled with its date, content-fingerprint refresh on same-count edits; plus the §3.1 layout fix and its passing UI test |

## 7. Calculation-version and export regression

- `PlanContract.currentCalculationVersion = 4`;
  **`minimumModernCalculationVersion = 2`, untouched** — now pinned directly by
  `ReleaseIntegrationTests.testTheModernBoundaryIsStillTwo` in addition to the
  behavioral guards: `testAnUpgradedCalcV2PlanStillReachesTheModernEngine`,
  `testAnUpgradedCalcV3PlanStillReachesTheModernEngine`,
  `testTheFrozenCalcV1BaselineStaysOffTheModernPath`,
  `testANewlyGeneratedPlanIsStampedCalcFour`.
- Both calc-version representations moved together
  (`PlanCalculationVersion.v4BalancedQuickWin = 4` + the constant; equality
  test-pinned). `CalcV4ReductionTests` (15): calc v4 with no promotions is
  byte-identical to calc v3, chain to v2/v1 intact — no stored plan changes
  value; stamps 1/2/3 frozen.
- Export: `backupSchemaVersion = 4`, `importableSchemaVersions = 1...4`, both
  stamping sites; `ExportCompatibilityTests`/`BackupPortingTests` green
  (schema-4 round-trip; 1/2/3 files still import).
- **Ratified:** `TemplateImportExportService` stays at template schema 3 —
  templates carry setup structure only and can never contain a calc-4 plan, so
  there is nothing a schema-3 template reader could mis-dispatch; bumping it
  would break older readers for no semantic reason. (VERSIONING.md §5's
  "templates share the axis" is satisfied by the shared axis *name*;
  `documentKind` distinguishes the envelopes.)
- Persistence schema stays 3; no migration-step lists changed;
  `SchemaThreeMigrationTests`/`MigrationServiceTests` green.

## 8. Privacy audit

Method per the v0.3.0 report: the marker set was harvested **read-only** from
the withdrawn resource at the (unrewritten) 0.1.0 root; scans print counts
only; no personal value entered any transcript, log, or this document.

- Identifying markers: 99 cents-precise money figures (≥ $100, non-round), 22
  founding-baseline dates, 1 name phrase. Calibration against the 0.1.0 tree:
  **352 hits across 20 files** — the scanner is proven non-vacuous.
- **Final tracked tree (217 files): 0 hits** on all 121 identifying money/date
  markers. The name phrase resolved to "Original Plan v1" — the app's own
  documented plan-version vocabulary (VERSIONING.md §1), not personal data; its
  occurrences are ordinary doc/code references. Residual collisions in the
  broader sweep were exclusively round-multiple-of-50 whole-cent amounts —
  generic fictional-fixture values.
- Per-branch diff audits (five branches, full diffs read): no real creditor
  names, personal balances, personal dates, or founding-user vocabulary added
  to any generic flow. "Checking 1/2" literals appear only in the contract-
  sanctioned legacy fallback (`LegacyCheckingLabels`) and as fixture pins for
  legacy schema vocabulary.
- `PrivacyScrubTests` (fresh install stores nothing; no bundled plan resource;
  no amounts in notification identifiers) green in every run.
- **Still open, owner-only:** the withdrawn resource remains reachable in git
  history (the 0.1.0 root and most refs) and the repository has been pushed.
  The trailer rewrite (§0) did not and could not resolve this — deciding
  whether and how to purge that history remains the owner's call, and
  **external distribution remains blocked until they make it** (v0.3.0 report
  §8, restated, not resolved).

## 9. Versions (final)

| Axis | Value |
| --- | --- |
| App / release | 0.4.0 / 0.4.0-alpha.1 (`MARKETING_VERSION` verified 0.3.0 → set 0.4.0, all 6 build configs) |
| Build | 5 (`CURRENT_PROJECT_VERSION` verified 4 → set 5, all 6 build configs) |
| Persistence schema | 3 (unchanged) |
| Calculation | 4 new/previewed/applied; boundary 2; stamps 1/2/3 frozen |
| Export schema | 4 (writes 4; reads 1–4); templates 3 (ratified, §7) |
| Tags | none created; `v0.4.0-alpha.1` is tagged only at an actual owner-authorized cut |

## 10. Release build

Release-configuration build succeeds; the compiled binary names none of the
withdrawn machinery (TESTING.md distribution check: marker count 0), and no
`.json` plan resource ships in any configuration.

## 11. Known limitations (truthful list)

1. **Nothing has run on hardware for build 5.** Device checklist items 1–23
   remain outstanding from earlier cycles, plus new items 24–28 (dark-mode CTAs
   on OLED, Balanced rationale under VoiceOver, generic adjustment with
   VoiceOver, dashboard at accessibility sizes, on-device utilization sweep).
2. The engine still emits `creditLimitMissing` for cards whose limit was
   explicitly marked unknown (`DebtInput` lacks the flag) — setup and editors
   respect the mark; only the plan's advisory list can nag. Registry item for
   the next engine cycle (Agent 2 hand-off, out of every v0.4 agent's scope).
3. Scenario-apply paths (`GeneratedPlanService.activate`,
   `ScenarioPlanActivationService.apply`) have no input-recency guard — the
   Review step's fingerprint guard closes onboarding's instance of the hole;
   `SetupInputFingerprint` is reusable there. Registry item.
4. Count-keyed refresh observers remain on Debts, Progress, Plan overview, and
   Accounts (dashboard-class screens); setup and Calendar are fingerprint-
   keyed. Same-count edits refresh those screens on reappear, not instantly.
5. Balanced preview cost grows with candidates (~0.05 s selector overhead on
   the 8-debt benchmark fixture; the engine remains main-thread — the known
   perf debt, out of scope).
6. `AddPaymentView` still stamps `sourceAccount = .checking2` on new
   card-payment rows (legacy-shaped writer; harmless to allocation sums —
   Agent 5 residual, registry item).
7. Founding vocabulary persists outside the generic flows (check-in, Today,
   Settings copy) — deliberately out of v0.4.0 scope; inventoried in Agent 5's
   report §9.
8. The month-mode Calendar now scrolls as one list; on standard phones the
   selected day sits one swipe below the grid when the dashboard card is tall.
   Judged acceptable (and far better than the 44-pt sliver it replaces); on
   the largest accessibility sizes the device pass (item 27) validates it.

## 12. Conclusion

Every §11 v0.4.0 acceptance criterion has green merged-tree evidence; the full
V2/V3 regression is green; calc stamps 1/2/3 are untouched and the boundary is
mutation-pinned at 2; export 4 round-trips and 1–3 import; the tracked tree
passes the calibrated privacy scan with zero identifying hits; versions are
stamped 0.4.0 / build 5; the changelog claims exactly what shipped.

**Status: READY FOR ALPHA DEVICE TESTING.**

Not a public release: the hardware checklist (items 1–28, upgrade rehearsal
first) has never run for this build, no tag is created until an owner-
authorized cut, and external distribution remains blocked on the owner's
git-history decision (§8).

## 13. Commits (this branch, post-rewrite hashes)

- `d36cd6a` merge(v0.4.0): integrate Agent 2 debt-type validation and reactive setup
- `f87f513` merge(v0.4.0): integrate Agent 3 Balanced quick-win strategy, calc 4, export 4
- `5423f78` merge(v0.4.0): integrate Agent 5 generic checking-account adjustment flow
- `9b64e02` merge(v0.4.0): integrate Agent 6 pay-cycle debt allocation and Calendar dashboard
- `cfdac57` merge(v0.4.0): integrate Agent 4 utilization display and primary-action design
- `e73634c` release: prepare v0.4.0-alpha.1 integration (versions, Calendar
  layout fix, display-convention resolution, docs, this report)
- (+ one follow-up commit recording this hash, per precedent)
