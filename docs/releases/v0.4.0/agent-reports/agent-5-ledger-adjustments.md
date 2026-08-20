# Agent 5 — Checking-Account Adjustment & Ledger UX report (v0.4.0)

- **Role:** V4-06 — replace the founding-user-specific "Checking 1 / 2 adjustment"
  quick-add path with a generic checking-account adjustment flow that works for any
  user's account structure.
- **Branch:** `feature/v0.4-ledger-adjustments`, based on the v0.4.0 contract commit
  `b71e193`. (The plan's prompt names the branch `feature/v0.4-account-adjustment` and the
  report `agent-5-account-adjustment.md`; this thread was launched with the
  `-ledger-adjustments` names — same scope, same contract. Recorded here so Agent 7's
  merge script finds both.)
- **Date:** 2026-08-20.
- **Commit:** `68908a3` (code + tests + this report; hash recorded by this follow-up
  docs commit per the release precedent).

This report contains no personal financial values (V3-12/V3-13, permanent).

## 1. Old workflow (retired)

The global `+` sheet offered **"Checking 1 / 2 adjustment"**, opening `CashAdjustmentView`
with seven hard-coded founding-vocabulary kinds — Checking 1 spending / buffer addition /
balance adjustment, car reserve use / contribution, train reserve use / contribution. Each
wrote a legacy-shaped `LedgerEntry` (raw `MoneyAccount` references, no account UUID, no
provenance) directly from the view, bypassing `CashLedgerService`. It was the last
user-facing **writer** of founding-vocabulary rows. The Windfall form's destination labels
("Apply to debt (Checking 2)" / "Keep in Checking 1") and the refund/correction target
rows ("Checking 1" / "Checking 2") carried the same vocabulary.

## 2. New workflow

**Add Entry → "Checking account adjustment"** (exact menu copy, pinned by test) opens one
form (`CheckingAccountAdjustmentView`):

1. **Account** — all active checking accounts by user-defined name, loaded through
   `CashAccountRepository.activeAccounts()` (canonical display order). With exactly one
   active account it is preselected; with several, choosing is the form's first step — the
   remaining fields appear once an account is chosen. The selected account's name and
   recorded balance are always visible, and the selection can be changed at any time.
2. **Adjustment type** — exactly the two contract types (plan §5.1 / MVP_LAYOUT §8.10):
   - **"Set balance to…"** — the user states the true balance; the computed difference is
     appended as a dated entry (increase and decrease are the sign of that difference).
   - **"Adjust by amount"** — a signed correction; positive adds, negative subtracts.
3. **Amount**, **effective date** (backdating and future-dating allowed), **optional
   note**, then **Record** behind a calm V3-03-tone confirmation that states the before →
   after figures and that nothing already recorded changes.

Both types converge on `CashLedgerService.adjustBalance`: an authoritative
`BalanceSnapshot` plus a signed `accountAdjustment` delta row written together in **one
save**, provenance `user`. "Adjust by amount" routes through a new **additive** overload:

```swift
CashLedgerService.adjustBalance(of:by:effectiveDate:note:auditNote:provenance:)
// guard delta != 0, then adjustBalance(of:to: current + delta, …)
```

so the two types are indistinguishable in the store and to reconciliation. A zero-delta
"Set balance to…" writes the snapshot only (confirming a balance is a fact; no money
moved); a zero "Adjust by amount" is refused with a new `LedgerError.adjustmentAmountZero`.

Also in this scope (contracted by V4-06 / Prompt 5):

- **Windfall labels** now derive from account roles/names via the new pure helper
  `LegacyCheckingLabels`: "Apply to debt (\<reserves-role account\>)" / "Keep in
  \<spending-role account\>", collapsing the parenthetical when one account holds every
  role, and falling back to the exact legacy wording when no account can supply a name.
  The founding install's migrated accounts are literally named "Checking 1"/"Checking 2",
  so the derived labels reproduce the legacy wording there with no special case.
- **Refund/correction target labels** are swept the same way (`targetLabels`), kept
  distinguishable when both slots resolve to one account ("Solo" / "Solo (reserves)").
  The persisted raws underneath are unchanged in both flows (see §4).
- **`.primaryAction` adoption (V4-05):** the submit buttons of every form I own —
  Card payment, Card balance update, Windfall, the new adjustment form, Note,
  Refund/correction, and the ledger edit sheet's Save Changes. Secondary actions
  ("What if I pay extra?") keep system styles. The style itself is Agent 4's file;
  adopt-only, per the ownership map.
- **The zero-amount Note entry is untouched** (soul amendment 6): it still writes a
  zero-amount `c1BalanceAdjustment` row and still renders as "Note".

## 3. Ledger invariants (held, and now pinned for the generic flow)

- **History is append-only.** No operation edits or deletes an earlier `LedgerEntry` or
  `BalanceSnapshot`; a wrong balance is reconciled by appending the signed difference.
  "Set balance to…" never rewrites — it records `stated − current` as its own dated row.
- **Every adjustment belongs to the selected account**: `destinationAccountID =
  account.id` regardless of sign, `sourceAccountID = nil` — the exact shape
  `AccountReconciliationService.isCompanionRow` matches on.
- **Companion-row invariant:** snapshot and delta row share `createdAt` and
  `effectiveDate`, written in one save. Pinned for both adjustment types, and pinned that
  reconciliation reports `.reconciled` after single adjustments and mixed
  deposit/adjust-by/set-balance sequences.
- **Effective date is respected** (backdated and future-dated rows carry their date;
  derivations remain day-granular and `createdAt`-anchored per the documented V3-03
  convention). The delta is computed against the account's recorded running balance —
  deliberately, because the reconciliation design defines a stated balance as superseding
  everything recorded before it was stated (`AccountReconciliationService` anchors by
  `createdAt`); computing the delta against a replayed as-of-date ledger balance would
  break `.reconciled` for every backdated statement with later movements.
- **Note stays optional**; audit note is auto-supplied by the flow.
- **Archived accounts are explicit:** not offered by the picker (repository-filtered), and
  refused by the service (`accountArchived`) for both types — pinned.
- **Transfers stay one atomic dual-account row.** Untouched; no transfer semantics were
  converted to paired adjustments.
- **No double counting:** new `accountAdjustment` rows carry no legacy raws (invisible to
  the raw-based `checking1State`/`checking2State` derivations) and legacy rows carry no
  account UUIDs (invisible to the account-scoped derivations) — pinned in both directions.
- **Historical rows remain readable and derived:** every legacy raw still decodes to its
  case and renders a display name; the raw-based derivations produce identical figures
  before and after generic adjustments run.

## 4. Persistence compatibility

**Nothing persisted changed shape.** Schema stays **3**; no new model field, no new
`LedgerEntryType` case, no new enum raw value, no export/backup DTO change, no CSV column
change. The generic flow reuses the existing schema-3 `accountAdjustment` case and `user`
provenance — display terminology is fully separated from storage vocabulary:

- Legacy raws (`c1*`, `c2Transfer`, `carReserve*`, `trainReserve*`, `MoneyAccount`
  `checking1`/`checking2`, `CashAccountKind`, `legacyKindRaw`) are untouched and still
  decode; the retired sheet was a **writer**, and only the writer is gone.
- The Windfall and refund/correction flows still persist the legacy `MoneyAccount` raws
  under their swept labels — those raws are schema vocabulary (MVP_LAYOUT §7) and the
  label/raw separation is deliberate. Note for the registry: on a non-migrated install
  those raws affect no named account's derived balance (pre-existing behavior); routing
  these flows onto account UUIDs is future work that must move the derivations in the
  same change (see §8).
- `provenanceRaw` is never backfilled; the byte-for-byte fixture test asserts legacy rows
  keep `nil`.
- Backup/restore and templates are unaffected; `BackupPortingTests`,
  `ExportCompatibilityTests`, `SchemaThreeMigrationTests`, `MigrationServiceTests` all
  green, unmodified.

## 5. Migrations

**None** — none needed, and none permitted by the contract (schema stays 3, no stored
field added, migration must never alter an existing stored value). The
byte-for-byte non-mutation test is the guard that the new flow performs no silent
"cleanup" of legacy rows either.

## 6. Tests

New suite **`LedgerAdjustmentFlowTests`** (T-23, 27 tests) — all on synthetic account
names ("Everyday", "Household", "Reserve", "Account N"); no test depends on
"Checking 1"/"Checking 2" except where those literals are themselves the fixture under
test (legacy raws, fallback labels):

- Menu copy is exactly "Checking account adjustment"; the type picker offers exactly the
  two contract types.
- Preselection across 1–10 fictional accounts (single account preselected, several force
  a choice, display order preserved); archived accounts never offered.
- Adjust-by: positive and negative signed deltas, snapshot = current + delta, zero
  refused, archived refused (both types), rounding via `.rounded2`.
- Set-balance: zero-delta writes snapshot only (generic named account); note optional on
  both types and preserved verbatim.
- Convergence: both types write the identical companion-row shape (`createdAt` shared with
  the snapshot, `effectiveDate` shared, `destinationAccountID` set, `sourceAccountID`
  nil, provenance `user`), and reconciliation reports `.reconciled` after each and after a
  mixed sequence with advancing clocks.
- Backdated and future-dated corrections carry their effective date; the dashboard
  derivation (`namedAccountStates`) agrees with the stored balance after backdating.
- Genericity: an adjustment touches only the selected account among three.
- Legacy: all 16 `LedgerEntryType` raws pinned case-by-case; a 12-row legacy fixture is
  **byte-identical** (every persisted property fingerprinted) after generic adjustments
  run; legacy derivations (`checking2State` totals and reserve buckets) unchanged; the
  new rows carry no legacy raws.
- Labels: role/name derivation, exact legacy fallback, single-account collapse, archived
  exclusion, migrated-founding-install reproduction, distinguishable refund targets.
- Note path: zero-amount `c1BalanceAdjustment` shape unchanged, not a cash-account
  movement, no signed effect on any account.

**Runs** (own simulator `PaydayPlaybook-Agent5` created via `simctl`, derived data outside
`~/Documents`, per TESTING.md):

- Full unit suite: **553/553 green** (526 at the contract commit + 27 new).
- `LedgerAdjustmentFlowTests` alone: 27/27 green.
- `CashLedgerServiceTests`, `AccountsWorkspaceTests`, `ReviewRegressionTests`,
  `ReconciliationServiceTests`, migration/porting/export suites: green within the full
  run, unmodified.
- UI suite not run: no UI test touches the quick-add adjustment path (verified by grep;
  the two `movement.save.adjustment` UI tests target Agent 4's Accounts workspace sheet,
  which is untouched). Agent 7's integration pass runs the UI suite serially per policy.

## 7. Files changed

- `PaydayPlaybook/Features/Ledger/QuickAddSheet.swift` — menu item; new
  `CheckingAccountAdjustmentView`; `LegacyCheckingLabels`; legacy `CashAdjustmentView`
  deleted; Windfall + refund/correction label sweep; `.primaryAction` adoption.
- `PaydayPlaybook/Services/CashLedgerService.swift` — additive only:
  `adjustBalance(of:by:)` overload + `LedgerError.adjustmentAmountZero`.
- `PaydayPlaybook/Features/Ledger/LedgerListView.swift` — `.primaryAction` on the edit
  form's submit button (no behavior change).
- `PaydayPlaybookTests/LedgerAdjustmentFlowTests.swift` — new (T-23).
- `docs/releases/v0.4.0/agent-reports/agent-5-ledger-adjustments.md` — this report.

No other file touched. Engine, scenario UI, Calendar (`CalendarTabView.swift` and its Add
Entry presentation line), onboarding, `PrimaryActionButton.swift`, `project.pbxproj`, and
all version constants untouched.

## 8. Interface Agent 6 should consume

Agent 6's `DebtAllocationService` can rely on these `LedgerEntry` semantics, all held and
test-pinned by this change:

- **Qualifying debt payments are `.cardPayment` rows only** (with
  `debtAccountID`/`debtPlanID`; check-in payments are already `.cardPayment` rows carrying
  `paydayCheckInID` — never also read `PaydayCheckIn`). Subtract `refundReversal` /
  `correction` rows carrying a `debtAccountID`, per R-28.
- **Every row the generic adjustment flow writes is typed `accountAdjustment`** with
  `destinationAccountID` set and no `debtAccountID` — structurally invisible to payment
  sums. Increase, decrease, and set-balance are all the same case with a signed amount;
  there is no adjustment row Agent 6 needs to special-case.
- **Transfers (`accountTransfer`, legacy `c2Transfer`) are never payments** and remain
  single atomic rows.
- `effectiveDate` is the cycle-attribution date (start-of-day from the quick-add flows);
  `createdAt` is the recording date. Use `effectiveDate` for cycle windows, per R-28.
- `LedgerEntryType.isCashAccountMovement` marks exactly the four generic movement cases
  if a structural filter is wanted.

## 9. Residual founding-vocabulary sites (for the registry — deliberately not touched)

Per the contract, out of this cycle's scope, listed for a future registry entry:

1. `Features/CheckIn/CheckInFlowView.swift` — "Keep in Checking 1", "Actual transfer to
   C2", "Actual car/train reserve" copy, and `PaydayCheckIn.actualC2Transfer/-CarReserve/
   -TrainReserve` fields (check-in is out of scope this cycle).
2. `Services/ReconciliationService.swift` — the check-in reconciler still **writes**
   legacy-shaped rows (`c2Transfer`, `carReserveContribution`, `trainReserveContribution`,
   `c1BufferAddition`, `c1Spending`); it is now the only remaining writer of
   founding-vocabulary rows.
3. `Features/Ledger/QuickAddSheet.swift` `AddPaymentView` — new `.cardPayment` rows still
   stamp `sourceAccount: .checking2` (invisible in UI; keeps legacy C2 derivation correct
   on migrated installs; generalizing it must move the derivation in the same change).
4. `WindfallView` / `RefundCorrectionView` — persisted `MoneyAccount` raws under the swept
   labels (see §4).
5. `NoteEntryView` — zero-amount `c1BalanceAdjustment` storage (contracted untouched).
6. `Features/Today/TodayView.swift` (Agent 4's file), `Features/Insights/InsightsView.swift`
   (`c1Spending` read), `Features/Settings/SettingsView.swift`
   (car/train reserve per-check plan fields), `AccountBalanceService`
   `Checking1State`/`Checking2State`, plan-model fields
   (`PlanVersion.carReservePerCheck` etc.) — reads and plan-shape internals.
7. `LedgerListView` type filter — legacy display names remain listed so historical rows
   stay filterable (reading history is contract-required).
8. UI test copy "Step 2 of 5 — Checking 1" in `PaydayPlaybookUITests` (check-in flow).

## 10. Assumptions, risks, handoff notes

- **Assumption:** the two-type picker ("Set balance to…" / "Adjust by amount") is the
  contract's exact shape; the mission's "increase / decrease" semantics are the sign of
  "Adjust by amount". Chosen per plan §5.1 / MVP_LAYOUT §8.10 / Prompt 5, which are
  explicit.
- **Assumption:** set-balance's delta is against the recorded running balance (the V3-03
  `adjustBalance` semantic), not a replayed as-of-date ledger balance — required by the
  `createdAt`-anchored reconciliation design (rationale in §3). The known same-tick
  ordering ambiguity (v0.3 §9.8) is unchanged; its sanctioned fix (a monotonic sequence
  column) remains a future schema change.
- **Risk (accepted, contracted):** on non-migrated installs the Windfall and
  refund/correction checking flows write legacy raws that no named account derives from —
  pre-existing behavior, now flagged in §9 for the registry.
- **Handoff to Agent 6:** §8 is the consumption contract; nothing this change writes can
  enter a payment sum.
- **Handoff to Agent 7:** merge position 5 of 1→2→3→4→5→6; expect a trivial adjacency to
  Agent 4's `.primaryAction` visual refinements (adopt-only here); the UI suite has no
  quick-add-adjustment coverage — if one is added at integration, the new form's
  accessibility identifiers are `adjustment.account/.type/.statedBalance/.amount/.date/
  .note/.record`.
- Simulator `PaydayPlaybook-Agent5` (`E6AC616D-114F-41DE-97DA-AB7ACD35C780`) was created
  for this thread and can be deleted after integration.

## 11. Commits

On `feature/v0.4-ledger-adjustments` (base `b71e193`):

- `68908a3` — feat(ledger): generalize checking account adjustment flow (QuickAddSheet
  rework, additive `CashLedgerService.adjustBalance(of:by:)`, label sweep,
  `.primaryAction` adoption, T-23 suite, this report; full unit suite 553/553 green at
  this commit).
- (+ this follow-up commit recording the hash, per the release precedent.)
