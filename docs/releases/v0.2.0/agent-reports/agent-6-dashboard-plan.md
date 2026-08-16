# Agent 6 report — Today Dashboard, Generated Plan, Debt Summary & Insights UX (v0.2.0)

*(Edited 2026-08-13 under V3-12: personal financial values and the founding user's name redacted; all technical content, decisions, and results otherwise unchanged.)*

Branch: `feature/v0.2-dashboard-plan` (Agent 3's `f0885d1` + merged Agent 2 `65a9236`) · Date: 2026-08-11
Scope: presentation layer only. No persistence migration, calculation algorithm, notification scheduler, or calendar code was rewritten.

## What shipped

The 0.1.x UI was still entirely hard-wired to the founding user's seeded plan: a fixed set of letter-keyed seeded credit cards, the `MoneyAccount.checking1/checking2` pair, fixed obligation reserve buckets, and `PlanContract` constants printed as if they were the user's numbers. Every v0.2 model (`CashAccount`, `RecurringObligation`, `IncomeSchedule`, `DebtType`, `creditLimit`, `originalPrincipal`, `isExtraPrincipalEligible`) and the whole calc-v2 engine were unreferenced by any view.

This branch makes Today, the new Plan screen, Debts, and Progress/Insights work for **any** generated plan and **all six** debt types, while the migrated Original Plan v1 keeps rendering value-for-value from its frozen calc-v1 rows.

## Screen inventory

| Screen | State | What it now shows |
| --- | --- | --- |
| **Today** (`Features/Today/`) | Rebuilt | Principal remaining + % eliminated (from live debts, not `PlanContract.startingDebtTotal`); plan status badge; current target with a one-sentence *why*; today's play with keep/move/reserve/pay and the check-in action; the finish line (forecast payoff, paychecks remaining, remaining interest, interest-saved when supported); named accounts by role with protected-cash status and available-not-spent; obligation reserve lines; upcoming payday / next due item / next payoff; one neutral insight; goal line; Phase II. |
| **Plan overview** (`Features/Plan/PlanOverviewView.swift`) | New | Inputs & assumptions, recommended avalanche order with per-debt detail, projected payoff / paychecks / interest, minimums-only comparison, per-debt payoff timeline, paycheck-by-paycheck playbook behind a **Plan / Actual / Reforecast** selector, principal totals + utilization, buffer & allowance what-if scenarios, warnings, and an explicit **Save & Activate New Plan Version** action. Reached from Today's "View Full Plan" and Settings → Plan versions. |
| **Plan activation** (`Features/Plan/PlanActivationView.swift`) | New | Previews the plan the current inputs would produce, states exactly what activation does and does not touch, then commits a new `PlanVersion` on an explicit tap. |
| **Debts list + detail + editor** (`Features/Debts/`) | Extended | Type icon and type-specific reference ("Card B" vs "Car note / auto loan"), utilization badge where a real limit exists, original vs current principal, APR / minimum / due day / priority / baseline + forecast payoff, minimums-only marker, payment and balance history, and a per-type editor validated through `ModelValidation`. Actions moved above the numbers (action-first). |
| **Progress + Insights** (`Features/Progress/`, `Features/Insights/`) | Extended | An insights card row at the top (V2-14's five cards), and chart summaries / payoff timeline computed from this install's own plan instead of hard-coded founding-user sentences. |

## Contract reconciliation (blocking, done first)

Agent 3 branched before Agent 2 landed, so both defined `PlanningInput`, `PlanningResult`, `PayCadence`, `ObligationCadence`, `DebtType`, and `IncomeChange`. The merge did not compile. Resolved as first consumer, keeping both agents' tested behavior byte-for-byte (commit `bafa07a`):

- Agent 3's engine contract keeps the canonical `PlanningInput` / `PlanningResult` names — the UI consumes it.
- Agent 2's stored-snapshot DTOs became `StoredPlanInput` / `StoredPlanResult`; `PlanningSnapshotCoder`, `PlanningInputBuilder`, and `PlanPersister` are otherwise untouched and the money-as-string wire format is preserved.
- The engine adopted the model-layer `DebtType` and `ObligationCadence` (its case-identical duplicates were deleted) and the shared `PlanningIncomeChange` (now `Sendable`).
- The engine's associated-value cadence enum is now `PlanningPayCadence`; the stored `String`-raw `PayCadence` in `Models/IncomeSchedule.swift` is unchanged.

**No behavior changed** — the 147 combined unit tests from Agents 2 and 3 passed unmodified on the first run after the rename.

## Changed files

| File | Change |
| --- | --- |
| `Services/GeneratedPlanService.swift` | **New.** The bridge: stored snapshot → engine input, engine result → stored rows, `previewFromCurrentInputs`, `baselineResult`, `reforecastResult`, `whatIfResult`, `nextPlanName`, `activate`. |
| `Services/ReforecastService.swift` | Dispatches on `PlanVersion.calculationVersion`: calc-v2 plans reforecast through `AvalanchePlanEngine`; Original Plan v1 keeps the frozen calc-v1 path unchanged. |
| `Services/AccountBalanceService.swift` | `namedAccountStates(plan:planItems:)` — per-`CashAccount` balances by role. Migrated Checking 1/2 keep their derived legacy-ledger values; v0.2 accounts derive from the entered balance + authoritative `cashAccountID` snapshots + account-linked ledger deltas. |
| `Components/DebtPresentation.swift` | **New.** Per-type icons/labels, `UtilizationBadge` (text carries the meaning, not colour alone), shared `DebtFormat.aprText`. |
| `Features/Today/TodayState.swift` · `TodayView.swift` | **New/rewritten.** State loader + card layout, all states below. |
| `Features/Plan/PlanViewData.swift` · `PlanViewDataLoader.swift` · `PlanOverviewView.swift` · `PlanActivationView.swift` | **New.** The generated-plan experience. |
| `Features/Insights/InsightsView.swift` | **New.** The five V2-14 insight cards + builder. |
| `Features/Debts/DebtsView.swift` | Type-aware list/detail/editor; per-install baseline payoff from milestones. |
| `Features/Progress/ProgressTabView.swift` | Insights row; plan-agnostic series, summaries, and payoff timeline. |
| `Features/Settings/SettingsView.swift` | Plan versions rows open the plan screen and show the calculation-version stamp. |
| `App/AppEnvironment.swift` | `init(dateProvider:)` so tests inject a fixed clock (default unchanged). |
| Tests | **New:** `DashboardFixtures` · `DashboardStateTests` (7) · `PlanPresentationTests` (12) · `DebtPresentationTests` (7) · `DashboardPlanUITests` (6). |

## Tests

```bash
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
# PaydayPlaybookTests   173 tests, 0 failures   (147 carried forward + 26 new)
# PaydayPlaybookUITests  15 tests, 0 failures   (9 carried forward + 6 new)
```

Fixtures build a **production-shaped** store — accounts through `CashAccountRepository`, a real `IncomeSchedule`, real obligations, a mixed-type debt portfolio — and run it through the real `AvalanchePlanEngine` and `PlanPersister`. No test hand-writes plan rows.

| Mission requirement | Test |
| --- | --- |
| Five-second dashboard content exists from production data | `testDashboardShowsEveryFiveSecondFactFromGeneratedData` |
| Baseline / actual / reforecast never mix | `testBaselineActualAndReforecastComeFromSeparateSources`, `testRecordingAnActualNeverChangesTheBaselineRows`, `testCompletedCheckInAppearsOnlyInTheActualTrack` |
| All debt types render correctly | `testEveryDebtTypeHasItsOwnLabelsAndIcon`, `testAllSixTypesSurviveGenerationAndRenderInThePlan`, `testInstallmentDebtsShowOriginalPrincipalAndCardsShowUtilization` |
| Utilization boundary / missing-limit states | `testUtilizationBoundariesMatchTheR12Thresholds`, `testUtilizationIsWithheldWithoutARealLimit`, `testUtilizationOverTheLimitStillRendersAsANumber` |
| Minimum-only comparison hidden / explained when insufficient | `testMinimumOnlyComparisonAppearsWhenEveryMinimumIsEntered`, `testMinimumOnlyComparisonIsExplainedNotGuessedWhenInputsAreInsufficient` |
| Plan activation creates a new version without history loss | `testActivationCreatesANewVersionAndLosesNoHistory`, `testActivationAlwaysPicksAFreeName` |
| Empty / error / recovery states | `testDashboardNeverInventsNumbersWhenNoPlanExists`, `testCorruptedPlanSnapshotDegradesWithAWarningNotFakeNumbers`, `testDebtFreeStateIsDerivedFromBalancesNotAnEmptyStore` |
| Accessibility at large text sizes | `testDashboardAndPlanAtAccessibilityTextSize` (AX-XL), `testProgressInsightsAndChartSummariesAtLargeText` (AX-L) |
| Legacy current-user plan remains viewable exactly | `testMigratedOriginalPlanV1RemainsViewableExactly`, `testLegacyPlanDashboardUsesLegacyReserveBucketsNotObligationRows`, `testLegacyPlanIsViewableExactlyWithoutCalcV2Claims` |
| Scenarios never mutate the active plan | `testScenariosArePreviewsThatNeverTouchTheActivePlan` |
| Neutral copy under a behind-plan status | `testBehindPlanIsStatedPlainlyWithoutBlame` |

Screenshots: not captured. The UI tests assert on accessibility identifiers and labels rather than images; there is no snapshot-testing dependency in the project and adding one is outside this mission's scope.

## Accessibility findings

- **The primary action falls below the fold at accessibility sizes.** At `AccessibilityXL` the "Start Check-In" button is off-screen on launch. It stays fully tappable after a scroll (pinned by `testDashboardAndPlanAtAccessibilityTextSize`, which scrolls *until hittable* rather than asserting on-screen), but if product wants the next action visible without scrolling at every text size, the status header needs to condense at `accessibilityLarge`+. Flagged, not silently designed around.
- Every chart keeps an `AccessibleChartSummary`; the three hard-coded founding-user summaries were replaced with computed ones, so the spoken text now matches what is actually plotted.
- Meaning is never colour-only: the utilization badge, plan status, and shortfall rows all carry the state in words.
- Composite rows (paycheck plays, debt rows, account rows, insight cards) are single a11y elements with hand-written labels including the amounts.
- All new controls are ≥ 44 pt; money uses `MoneyText` (`monospacedDigit`) throughout and every displayed figure is `Decimal`-derived.
- Reduce Motion: no new animation was added, so nothing new needs gating; the existing `DebtFreeTransitionView` check still stands.

## Integration needs

1. **Onboarding owner (Agent 4).** `GeneratedPlanService.previewFromCurrentInputs()` + `OnboardingProgressService.finish(planName:input:result:)` are the intended finish path; use `GeneratedPlanService.storedResult(from:input:)` to convert the engine result. The first plan of an install must be created with `isOriginalBaseline = true` — `activate` does that automatically only when no plan exists yet.
2. **Notification/calendar owner (Agent 5).** `DebtEditView` now edits due dates and fires a `.planEdit` reforecast, but it does **not** reschedule notifications — V2-11 is yours. Hook the reschedule into the save path (the edit already knows whether the due day changed). `PlanActivationView` does call `rescheduleAll` after activation, since paydays move.
3. **Due-day range.** The editor now accepts 1–31 (was 1–28) and relies on R-11 clamping. Calendar/notification code must clamp the same way.
4. **Plan naming.** `PlanPersister`'s duplicate guard is name-based; `GeneratedPlanService.nextPlanName` is the single place that picks "Plan v1", "Plan v2", … Any other creator of plan versions should use it.
5. **`AppEnvironment(dateProvider:)`** is the injection point if other suites need a fixed clock.

## Assumptions & deliberate decisions

1. **Scenario previews are calc-v2 only.** They require the stored input snapshot, which Original Plan v1 deliberately does not have. The screen says so rather than showing an empty card.
2. **Two scenarios, not four.** Each what-if is a full engine run on the main thread; the set was trimmed to one allowance and one floor variant to keep the screen responsive. The set is a one-line change if product wants more.
3. **The playbook renders 12 paychecks then offers "Show all N".** A 600-paycheck plan is a legal outcome of the horizon cap; rendering it eagerly is not.
4. **`totalOriginalPrincipal` is withheld unless every debt has one** — a partial sum would read as a whole-portfolio figure.
5. **Debt detail actions moved above the numbers.** Action-first per `soul.md` §8, and it restores reachability of "Update Balance" after the numbers section grew (the 0.1.x UI test that taps it passes unchanged).
6. **Reforecast for calc-v2 plans uses authoritative debt snapshots only** (`spendingBalance` left nil), so the engine keeps the planned cash-ceiling path rather than restarting it. Wiring actual spending-account balances in is a small follow-up.
7. **The dashboard's schedule source is the active plan when it owns payday rows, else the stored baseline.** This keeps 0.1.x settings-only plan versions rendering exactly as before.

## Risks / notes

- **Shared simulator contention.** Running `xcodebuild test` from several worktrees at once cross-contaminates results — this branch saw another worktree's `PaydayPlaybookUITests.swift` reported as failing inside this branch's run. Use a per-worktree `-derivedDataPath`; the totals above come from an isolated run.
- **Main-thread engine work.** `PlanViewDataLoader.load` runs a baseline generation, a reforecast, and two scenarios synchronously. It is fast at the scale of the baseline schedule; a very long plan would benefit from moving the analysis off the main actor. Not done here because `ModelContext` is not `Sendable` and the change belongs with a wider concurrency pass.
- `MVP_LAYOUT.md` §8.4's "Edit Card" is now "Edit Debt", and §8.5's insight row landed at the top of Progress as specified. No contract text needed changing; flagged for the doc owner only as vocabulary confirmation.

## Commit

`feat(v0.2.0): generalized dashboard, generated-plan screen, insights, all debt types` (`7a28219`), preceded by `refactor(v0.2.0): reconcile Agent 2/Agent 3 planning contracts on one type system` (`bafa07a`) and followed by the test/report commit — final hash in the agent's closing message.
