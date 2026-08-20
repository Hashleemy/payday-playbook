# Agent 6 — Debt Allocation & Calendar Progress report (v0.4.0)

- **Role:** V4-07 (canonical derived pay-cycle debt-allocation service) and V4-08
  (Calendar debt dashboard), per R-28/R-29 exactly.
- **Branch:** `feature/v0.4-debt-allocation-calendar`, based on Agent 1's contract commit
  `b71e193` (verified before work began; clean tree).
- **Date:** 2026-08-20.

This report contains no personal financial values (V3-12/V3-13, permanent). Every number
below is a synthetic fixture value.

## Outcome

`DebtAllocationService` is the single implementation of the pay-cycle boundary rule and
the carry-in fold; the Calendar tab renders a debt dashboard card that consumes it and
nothing else, refreshing on a content fingerprint (row IDs + `updatedAt`), not row
counts. No new persisted state anywhere — schema stays 3, no calc/export constant was
touched, and the arithmetic is deliberately outside calculation versioning (R-28/R-29
preamble in `MVP_LAYOUT.md` §5).

## Allocation formulas (exact)

All money is `Decimal`; `.rounded2` is applied only when a value crosses into a DTO the
view renders. Internally the fold carries full precision.

**Qualifying payment sum** (one rule, used by both the cycle fold and the month
aggregate — `DebtAllocationService.qualifyingAmount(of:)`):

```
qualifying(entry) =
  +entry.amount                    when entry.type == .cardPayment
  −entry.amount                    when entry.type ∈ {.refundReversal, .correction}
                                   AND entry.debtAccountID != nil
  (not counted)                    otherwise
used(window) = Σ qualifying(entry) for entries with startOfDay(effectiveDate) ∈ window
```

Check-in payments are already `.cardPayment` ledger rows (carrying `paydayCheckInID`),
so the service never also reads `PaydayCheckIn`/`CheckInCardPayment` — the double-count
hazard is pinned by test. Transfers (`.accountTransfer`, `.c2Transfer`), balance
adjustments (`.accountAdjustment`, `.c1BalanceAdjustment`), deposits, withdrawals,
spending, and reserve rows never count. A `.refundReversal`/`.correction` row without a
`debtAccountID` is a cash-side event, not a debt event, and never counts.

**Carry-in fold** (anchored at the active plan's first payday):

```
carryIn(0)   = 0
available(N) = carryIn(N) + allocation(N)
carryIn(N+1) = max(0, available(N) − used(N))
```

**Current-cycle display values:**

```
remaining = max(0, available − used)
overage   = max(0, used − available)
```

`allocation(N)` = the opening payday's `PaydayPlanItem.plannedCardBudget` — the plan
track's *planned allocation*, never engine `debtBudget` and never account cash. Cycles
opened by an extended boundary past the plan's last item have `allocation = 0` (the plan
promises nothing there); carry still flows through them.

**Monthly aggregate (R-29):** `paidTowardDebts` = the same qualifying sum over
`[monthStart, nextMonthStart)` by `effectiveDate`. Pay-cycle remaining and calendar-month
paid are computed from different windows and never merged.

## Cycle-boundary semantics

- Boundaries come from the active plan's `PaydayPlanItem` dates, resolved through
  `CalendarEventService.schedulePlan(context:)` — the calendar's own schedule source, so
  the dashboard and the calendar can never disagree about paydays.
- The current cycle is `[most recent plan payday ≤ asOf, next plan payday)`. Half-open:
  a payment on payday N belongs to cycle N, a payment on payday N+1 to cycle N+1.
- Past the last plan item, boundaries extend by the live `IncomeSchedule` cadence (the
  `ReforecastService` continue-the-cadence precedent, generalized to all four cadences
  through `PayScheduleGenerator` with R-11 month-end clamping). Fallbacks, in order: the
  plan row's own cadence columns, then the plan's fixed `payFrequencyDays` interval.
- Before the plan's first payday there is no current cycle: `currentCycle(asOf:)`
  returns nil and the dashboard shows the upcoming allocation instead.
- `DebtAllocationService` is the only implementation of this rule. The pre-existing
  near-miss derivations Agent 1's survey flagged (the allowance windows in
  `TodayState`/`AccountBalanceService.checking1State` and the Insights allowance
  aggregate) are *allowance* windows, not debt-allocation cycles; they are untouched and
  out of scope.

## Carryover semantics

Positive unused remainder rolls into the next cycle's `carryIn`; the fold is
deterministic (same rows → same result, pinned by test) and runs from the anchor forward,
so editing or deleting any historical payment recomputes every subsequent carry.
Payments dated before the plan's first payday never enter the fold (they still count in
the month aggregate — actuals are never hidden). Activating a different plan re-anchors
the fold at the new plan's first payday with `carryIn = 0`; no historical ledger row is
rewritten, re-dated, or re-attributed.

## Overpayment semantics

Overspending a cycle never produces negative spendable money and never borrows from the
next cycle: `remaining` clamps at 0, the excess surfaces as `overage`, and
`carryIn(N+1)` is `max(0, …)` so the next cycle opens with its own allocation intact.
The dashboard renders the R-28 string verbatim: **"$0 remaining · +$X over planned
allocation"**. The actual overpayment still reduces the debt through the normal
ledger/reforecast path — the allocation view just refuses to pretend it created
negative cash.

## Qualifying ledger-entry rules (audit summary)

Audited writers of `.cardPayment` rows: `QuickAddSheet.AddPaymentView` (quick-add) and
`ReconciliationService.completeCheckIn` (check-in completion, rows carry
`paydayCheckInID`). Both are plain ledger rows, so summing the ledger once covers both;
summing check-in drafts too would double-count — pinned by
`testCheckInPaymentRowsAreCountedExactlyOnce`. Refund/correction rows created by the
refund flow carry `debtAccountID` and subtract. `CashLedgerService` movements
(deposit/withdraw/transfer/adjustBalance) never qualify, including a transfer that
funds a debt-payment account. Multiple checking accounts change nothing: qualification
is by entry type + debt linkage, never by source account, so a payment counts once no
matter which account funded it.

## Cleared-debt attribution (R-29)

"Debts cleared this month" = debts whose derived balance
(`AccountBalanceService.debtBalances()`) is zero **now**, attributed to the earliest
dated event — authoritative snapshot or debt-linked payment — after which the derived
balance reaches zero *and stays there*. The replay
(`DebtAllocationService.zeroReachingDate`) mirrors `debtBalances()` event selection
exactly (latest authoritative snapshot ≤ today as base, then debt-linked
`.cardPayment`/`.refundReversal`/`.correction` rows after it, ordered by effective day
then `createdAt`), so the attribution can never disagree with the balance it explains.
A refund that reopens a debt moves the cleared date to the payment that finally closed
it. A debt that was never positive (zero starting balance, no dated events) has no
cleared date and is never listed.

## Calendar UI (V4-08)

`CalendarDebtDashboardCard` sits at the top of the Calendar tab, above the mode
controls, visible in month, week, and agenda modes. It renders only
`DebtAllocationService` outputs — the view does no arithmetic (`CalendarDebtDashboardState.load`
calls the service; every figure passes through untouched, verified by test).

Content, in order:

- **"Paid toward debts this month"** — the exact R-29 label; dollars are never
  "paid off". "Debts cleared this month" rows appear only when any exist ("cleared" is
  reserved for debts).
- **Current pay cycle** (header names both boundary dates): Planned allocation,
  Carry-in (shown when non-zero), Used, and Remaining — or the verbatim overage line.
- **Upcoming**: the next payday's planned allocation labeled with its availability date
  ("$X becomes available <date>") — never presented as spendable today. Before the
  first payday the card explains no cycle has started and names the first allocation
  and its date.
- Honest-cash footnote: "Planned allocation comes from your debt plan — it isn't your
  account cash."

The card hides on an install with no plan and no payment activity (no fabricated debt
story); payment activity alone (no plan) still shows the honest month section.

**Refresh:** the view observes `DebtAllocationFingerprint.fingerprint` — an
order-independent hash of every ledger row's `(id, updatedAt)` plus the active plan
IDs — via `.onChange`, so inserts, deletes, **same-count amount edits**, and plan
activations all recompute immediately, with `onDismiss` refreshes on the check-in and
quick-add sheets as belt-and-suspenders. The pre-existing count-based ledger `onChange`
was replaced by the fingerprint (a strict superset); the `checkIns.count` trigger
remains for event statuses.

**Accessibility:** every money row is a combined accessibility element with an explicit
"label: amount" description; status meaning is carried by text (the overage line is a
sentence, not a color); the card uses Dynamic-Type-friendly single-column rows, `MoneyText`
tabular numerals, and the standard `DashboardCard` container.

## Tests

New suites (all synthetic fixtures, in-memory containers, pinned dates via
`FixedDateProvider`):

- **`DebtAllocationServiceTests` (T-24, 33 tests):** first cycle/no payments; partial,
  multiple, and exact-use payments; the contract's carryover example (1000 → 750 paid →
  250 carry → 1250 available → 400 paid → 850 remaining); multi-cycle carry
  accumulation; fold determinism; overpayment (zero remaining, honest overage, zero
  carry borrowed); debt-linked refund restoring allocation; non-debt-linked correction
  ignored; delete and same-count edit recompute; check-in + quick-add same-day
  double-count guard; transfers (`.accountTransfer`, `.c2Transfer`) never count;
  balance adjustments never count; payments from any checking account count once;
  no-cycle-before-first-payday (with upcoming allocation); pre-anchor payments outside
  the fold but inside the month aggregate; future payday never available today;
  boundaries for weekly, biweekly, semimonthly (15/31 with clamping), and monthly
  cadences; day-31 clamping to Feb 28 (non-leap) and Feb 29 (leap 2056); weekly
  boundaries across the US DST transition; extension past the plan's last item (zero
  allocation, carry preserved, live-schedule cadence honored even when it differs from
  the plan's); plan-activation re-anchor; month-boundary-inside-a-cycle keeping both
  truths separate; cross-cycle month aggregate; refund-adjusted month aggregate;
  cleared-this-month attribution (cleared vs. still-open, last-month exclusion,
  refund-reopened debt attributed to the final payment).
- **`CalendarDebtDashboardTests` (T-25, 14 tests):** exact "Paid toward debts this
  month" label; no copy string ever says "paid off" for dollars; verbatim
  "$0 remaining · +$X over planned allocation" (leading "$0 remaining", no negative
  rendering); upcoming allocation labeled with its availability date and never
  "spendable"; planned-allocation-is-not-cash footnote; "cleared" reserved for debts;
  fingerprint changes on same-count edits, inserts, deletes, and plan activation, and
  ignores fetch order; dashboard state reconciling to the service to the cent (199.99 +
  0.01 = 200.00) and carrying service DTOs untouched; before-first-payday upcoming
  state; card hidden with no plan and no activity; card shown on activity alone.

Suite runs (dedicated simulator `PP-Agent6`, derived data outside `~/Documents` per
TESTING.md): **full unit suite `PaydayPlaybookTests` — 573/573 green** (526 existing +
47 new; includes `CalendarEventServiceTests` and `ReconciliationServiceTests` unchanged
and green). UI suite not run: no UI-test-visible flow changed (the card is additive;
existing UI tests do not assert on the calendar tab's top area) — flagged for Agent 7's
integration pass, where the accessibility-size device checklist item covers the new
card.

## Performance

No engine run anywhere on this path: the service reads stored `PaydayPlanItem` rows and
the ledger, folds once (O(cycles + entries·log-free scan), both small), and returns
value types. The dashboard never computes in a view body — state loads in
`onAppear`/`onChange` and only when the content fingerprint actually changed, so
SwiftUI body re-evaluations are free and a multi-year payoff simulation is never
triggered by rendering the Calendar tab.

## Files changed

- `PaydayPlaybook/Services/DebtAllocationService.swift` — new: `PayCycleAllocation`,
  `MonthlyDebtProgress`, `ClearedDebt`, `UpcomingDebtAllocation`,
  `DebtAllocationCalculating`, `DebtAllocationService`, `DebtAllocationFingerprint`.
- `PaydayPlaybook/Features/Calendar/CalendarDebtDashboardCard.swift` — new:
  `DebtDashboardCopy` (exact wording), `CalendarDebtDashboardState` (loader),
  `CalendarDebtDashboardCard` (view).
- `PaydayPlaybook/Features/Calendar/CalendarTabView.swift` — dashboard card at the top
  of the tab; content-fingerprint observation replacing the count-based ledger trigger;
  `reloadDashboard()`/`refreshAfterSheet()`.
- `PaydayPlaybook/App/AppEnvironment.swift` — `debtAllocationService(context:)` factory.
- `PaydayPlaybookTests/DebtAllocationServiceTests.swift` — new (T-24).
- `PaydayPlaybookTests/CalendarDebtDashboardTests.swift` — new (T-25).
- `docs/releases/v0.4.0/agent-reports/agent-6-debt-allocation-calendar.md` — this report.

Nothing else was touched: no engine, no Balanced strategy, no Add Entry/adjustment flow,
no utilization logic, no version constant, no schema change, no new persisted field.

## Contract deviations (deliberate, for Agent 7)

1. **One additive interface beyond the named shapes:** the contract binds
   `DebtAllocationCalculating` to `currentCycle(asOf:)` and `monthlyProgress(month:)`,
   and R-28 requires that before the first payday "the dashboard shows the upcoming
   allocation instead" — but neither named DTO can carry that state. I added a third
   protocol method `upcomingAllocation(asOf:) -> UpcomingDebtAllocation?`
   (`availableOn: Date`, `amount: Decimal`) rather than overloading nil-ness or minting
   a competing cycle DTO. The two contracted methods match the contracted signatures
   exactly; `PayCycleAllocation`, `MonthlyDebtProgress`, and `ClearedDebt` match
   field-for-field.
2. **Report filename:** this file is `agent-6-debt-allocation-calendar.md` (the launch
   prompt's name; the plan's Prompt 6 says `agent-6-allocation-calendar.md` — same
   document, one name).

## Integration expectations with Agent 5

- Agent 5 owns `QuickAddSheet.swift` (V4-06 generic adjustment + `.primaryAction`
  adoption). I did not touch that file; the calendar's Add Entry presentation line in
  `CalendarTabView` is untouched per the plan's ownership note.
- Agent 5's generic adjustments write `.accountAdjustment` rows through
  `CashLedgerService.adjustBalance`. Those rows never qualify as debt payments here
  (pinned by `testBalanceAdjustmentsNeverCountAsDebtPayments`), so the two features
  compose without coordination: an adjustment refreshes the dashboard (fingerprint) but
  never changes `used`.
- If Agent 5 renames or re-routes the legacy seven-kind sheet, nothing here cares: the
  service reads entry types, not forms. The one shared surface is `LedgerEntry` itself,
  which neither of us reshapes.
- Merge order is 1→2→3→4→5→6; this branch merges last. The likely (textual, harmless)
  collision points are `AppEnvironment.swift` (Agent 4/5 may add factories) and
  `CalendarTabView.swift` sheet wiring if Agent 5's sheet API changes — both resolve
  mechanically; re-run the unit suite after merge per the v0.3.0 lesson.

## Commits

On `feature/v0.4-debt-allocation-calendar` (base `b71e193`):

- `f3838d5` — feat(calendar): track pay-cycle debt allocation and carryover
  (V4-07/V4-08, R-28/R-29; unit suite 573/573 green at this commit).
- (+ one follow-up commit recording this hash in this report, per the v0.3.0 precedent.)
