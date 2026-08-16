# Agent 4 — Checking Accounts and Bills & Debts Setup UX (v0.3.0)

Branch: `feature/v0.3-accounts-setup`, based on **Agent 2 ⊕ Agent 3** — a merge
of `feature/v0.3-privacy-data` (`6029107`) and `feature/v0.3-scenario-engine`
(`3aad53b`), both of which branch from Agent 1's contract at `4be5c57`. The
merge was necessary because this scope consumes Agent 2's repositories *and*
Agent 3's engine protocols; what it cost is recorded in §8.

Requirements delivered: **V3-02** (checking accounts workspace), **V3-03**
(dated balance adjustments), **V3-04** (extra-payment insight surface),
**V3-05** (three-plan calculator), **V3-06** (honest inputs), **V3-08**
(consolidated Bills & Debts), **V3-15** (plan separation, UI half).

No personal financial value, real date, or real person's name appears in any
file added or changed here. Every fixture and preview value is invented.

---

## 1. Screen inventory

### Accounts — the fifth tab (V3-02, §8.2)

| Screen | File | What it does |
| --- | --- | --- |
| Accounts workspace | `Features/Accounts/AccountsTabView.swift` | Summary header (total, protected, available), attention banner, one card per active account, reorder mode, add, archived-accounts link |
| Account card | same file, `AccountCardView` | Name, roles, balance + as-of stamp, protected, available, default-income marker, next planned movement, reconciliation state, last-updated |
| Account detail | `Features/Accounts/AccountDetailView.swift` | The card's figures in full, the four money actions, planned movement, recent activity, balance history, archive |
| Full activity list | same file, `AccountActivityListView` | Every movement, newest first, provenance-aware |
| Movement sheet | `Features/Accounts/AccountMovementSheet.swift` | Deposit, withdrawal, transfer, and balance adjustment — one sheet, four modes |
| Archive-blocked sheet | `AccountsTabView` / `AccountDetailView` | Names each thing still pointing at the account and where to change it |
| Archived accounts | `AccountsTabView`, `ArchivedAccountsView` | Restore an archived account |

Requirement by requirement:

- **Every contracted figure is on the card** — name, role, current balance with
  its as-of stamp, protected amount, available amount, default-income marker,
  last update, and next planned movement. `AccountsWorkspaceState.AccountCard`
  is the single struct carrying them, so the card, the detail header, and the
  VoiceOver label cannot disagree.
- **Add / edit / reorder / archive / set default income** — all present.
  Reorder is a drag list writing through `CashAccountRepository.reorder`.
- **Deposits, withdrawals, transfers, dated adjustments** — all four go through
  `CashLedgerService`; the UI performs no balance arithmetic of its own.
- **Paired transfer UX** — source, destination, amount, effective date, and the
  resulting balance on *both* sides, shown before commit. It commits as Agent
  2's single atomic row.
- **Balance adjustment** — requires a confirmation alert, and both the sheet
  and the alert state that it records a dated snapshot and does not rewrite
  history.
- **Activity and history** — activity resolves each row to the account's point
  of view (a transfer reads negative on its source and positive on its
  destination, from the same stored row); history lists every authoritative
  snapshot including corrections.
- **Archive blocked-or-explained** — see §3.3.

### Bills & Debts — one page (V3-08, §5.2)

| Screen | File | Used by |
| --- | --- | --- |
| The page | `Features/Setup/BillsAndDebtsView.swift` | Both surfaces below |
| Onboarding step 5 | `Features/Onboarding/BillsAndDebtsStepView.swift` | First-run setup |
| Settings destination | `SettingsBillsAndDebtsView` (same file as the page) | Settings → Bills & debts |
| Add chooser | `AddBillOrDebtChooser` (same file) | Bill-or-debt, then debt type |

The page carries the contracted structure: summary header (bill total,
per-paycheck reserve, debt minimum total, debt principal, incomplete count),
Bills section, Debts section, one **Add bill or debt** button, inline
missing-field warnings, empty states for each section, reorder and archive, and
a review block explaining how the totals reach available cash and the three
scenarios.

**Every v0.2 field survives** because the page *hosts* the existing
`ObligationEditorView` and `DebtEditorView` rather than reimplementing them.
That is the whole reason to reuse them: a reimplementation is where fields,
validation rules, and the extra-principal question quietly go missing.

### Scenarios (V3-04/V3-05/V3-06/V3-15, §8.6)

| Screen | File |
| --- | --- |
| Progress entry card | `Features/Scenarios/ScenariosEntryCard.swift` |
| Payoff calculator + three cards | `Features/Scenarios/PayoffScenariosView.swift` |
| Overrides panel | `ScenarioOverridesSheet`, same file |
| Missing-input panel | `ScenarioMissingInputsPanel`, same file |
| Detail comparison | `Features/Scenarios/ScenarioComparisonView.swift` |
| Apply confirmation | `ApplyScenarioView`, same file |
| Extra-payment sheet + insight | `Features/Scenarios/ExtraPaymentSheet.swift` |

Entry points for "What if I pay extra?": debt detail (`DebtDetailView`) and the
payment flow (`AddPaymentView`), both contracted.

---

## 2. Changed files

**New — mine:**

```
PaydayPlaybook/Features/Accounts/AccountsTabView.swift
PaydayPlaybook/Features/Accounts/AccountsWorkspaceState.swift
PaydayPlaybook/Features/Accounts/AccountDetailView.swift
PaydayPlaybook/Features/Accounts/AccountMovementSheet.swift
PaydayPlaybook/Features/Setup/BillsAndDebtsView.swift
PaydayPlaybook/Features/Setup/BillsAndDebtsState.swift
PaydayPlaybook/Features/Onboarding/BillsAndDebtsStepView.swift
PaydayPlaybook/Features/Scenarios/PayoffScenariosView.swift
PaydayPlaybook/Features/Scenarios/ScenarioWorkspaceState.swift
PaydayPlaybook/Features/Scenarios/ScenarioComparisonView.swift
PaydayPlaybook/Features/Scenarios/ExtraPaymentSheet.swift
PaydayPlaybook/Features/Scenarios/ScenariosEntryCard.swift
PaydayPlaybook/Services/AccountReconciliationService.swift
PaydayPlaybook/Services/ScenarioPlanActivationService.swift
PaydayPlaybook/Services/SetupOrderingRepositories.swift
PaydayPlaybookTests/AccountsWorkspaceTests.swift
PaydayPlaybookTests/ScenarioSurfaceTests.swift
PaydayPlaybookUITests/AccountsAndSetupUITests.swift
```

**Edited:**

| File | Change |
| --- | --- |
| `App/AppRouter.swift` | `AppTab.accounts` |
| `App/RootView.swift` | Fifth tab, between Calendar and Debts |
| `Features/Onboarding/OnboardingFlowView.swift` | Routes `.billsAndDebts`; `userFacing` is seven steps; retired cases route to the consolidated step |
| `Features/Onboarding/AccountsStepView.swift` | `AccountEditorView` gains `showsProtectedAmount` and `balanceEditable` |
| `Features/Onboarding/ObligationsStepView.swift` | Bill editor gains an archive action beside delete |
| `Features/Settings/SettingsView.swift` | "Essential bills" → "Bills & debts" |
| `Features/Settings/ReviewSetupView.swift` | Section renamed; link to the consolidated page |
| `Features/Progress/ProgressTabView.swift` | Scenario entry card |
| `Features/Debts/DebtsView.swift` | "What if I pay extra?" on debt detail |
| `Features/Ledger/QuickAddSheet.swift` | "What if I pay extra?" in the payment flow |
| `Models/OnboardingProgress.swift` | `flowOrder`, `retiredSteps`, `resumeEquivalent`, `sortIndex` (handed to me by Agent 2) |
| `Models/RecurringObligation.swift` | Defaulted `sortOrder` — see §8.2 |
| `Services/PlanningDTO.swift` | Removed duplicate DTOs — see §8.1 |
| `PaydayPlaybookTests/OnboardingSetupTests.swift`, `OnboardingProgressTests.swift` | Updated to the V3-08 sequence, plus retired-step coverage |
| `PaydayPlaybookUITests/PaydayPlaybookUITests.swift` | First-run walk updated to the new step order |

---

## 3. Key decisions

**3.1 Reconciliation is only claimed when it can be checked.**
`AccountReconciliation` has three states, not two: `notConfirmed`,
`reconciled`, `needsAttention`. Without an authoritative `BalanceSnapshot`
there is nothing to reconcile *against*, and reporting that as agreement would
be a claim the app cannot support. "Nobody has checked" and "checked and
correct" are different facts, so they read differently on the card.
`notConfirmed` deliberately does not count toward the attention banner — it is
information, not an alarm.

**3.2 A balance change in the workspace is a dated fact, not a text field.**
`AccountEditorView` previously wrote `currentBalance` directly. Once an account
has activity, that silently moves the number out from under the rows that
explain it — exactly the divergence the attention state detects. The workspace
therefore passes `balanceEditable: false` and routes balance changes through
the adjustment sheet, which writes a snapshot plus the explaining delta.
Onboarding keeps the free field: an opening balance has no history to
contradict.

**3.3 Archive says *why*, and names the fix.**
`AccountReconciliationService.archiveBlockers` returns a reason per blocker —
last active account, receives your paycheck, bills paid from it (named by
name), active plan routes income here — each with the screen that resolves it.
The button itself changes to "Why can't I archive this?" rather than being
disabled or failing on tap, so the route forward is visible before the user
commits to it.

**3.4 Reorder is presentation, and every reorder control says so.**
Debt order is `priority`; the payoff order the plan follows is recomputed from
APR and balance by the engine (R-08). A user who drags a debt to the top must
not come away believing they changed which one gets attacked, so the note above
the list states it.

**3.5 The consolidated step sits after income, and retired steps get a mapping.**
`.billsAndDebts` joins `flowOrder` after `.income` (Agent 1's §4 order), so the
per-paycheck reserve preview smooths against the real cadence instead of the
biweekly default. `.debts` and `.obligations` leave traversal but stay
*declared*, because their raw values are persisted in v0.2 stores.
`resumeEquivalent` maps a stored retired step onto the current step
representing the same amount of finished work. **Without it there is a real,
data-loss-shaped bug**: `sortIndex` falls off the end of `flowOrder`, `next`
returns `.finished`, and a user interrupted at the old debts step resumes past
income entirely. `sortIndex` resolves through the same mapping, or
`markStepCompleted`'s "position only advances" guard would treat a retired step
as later than `.finished` and refuse every subsequent step. Both are tested.

**3.6 Nothing is duplicated on resume, structurally.**
Each editor writes its own row on save; the step writes nothing on continue.
Resuming re-reads the store and finds the rows already there. A v0.2 user who
entered debts under the old flow sees them in the consolidated page —
`testDebtsEnteredUnderTheOldFlowAreNotReAskedOrDuplicated` pins it.

**3.7 Unstated is not zero.**
`UserGoalProfile`'s scenario columns default to `0`, which means "never
stated". `ScenarioWorkspaceLoader.definitions` maps a zero back to `nil` so the
calculator returns a named missing-input result rather than computing a card
from a number the user never gave (V3-06). The panel names the field and the
screen that answers it.

**3.8 Applying is the only write, and it is confirmed.**
`ScenarioPlanActivationService` is the sole path from a preview to a
`PlanVersion`. It is called from the confirmation step only, stamps
`scenarioKind = .scenario` and the scenario's `effectiveDate`, and stores the
*scenario's own* input — storing the baseline input would produce a plan that
regenerates into something the user never saw. The previous plan keeps every
row; only its `isActive` flag yields.

**3.9 The engine never runs in a view body.**
Agent 3 benchmarked three scenarios plus one insight at 1.25–1.35 s on an
eight-debt, 77-paycheck plan. Both surfaces compute in a `Task` with an
explicit loading state. The Progress entry card carries no figures for the same
reason: a headline number there would mean three projections on every
appearance of Progress.

---

## 4. Tests

**Unit: 422 tests, 0 failures.** Baseline after merging Agents 2 and 3: 391.
31 net new across three files; two v0.2 onboarding-order tests updated to the
V3-08 sequence.

| File | Covers |
| --- | --- |
| `AccountsWorkspaceTests` (19) | Card figures; available floors at zero; totals; the three reconciliation states; movements after a confirmed balance; a balance changed outside the ledger; correcting it without erasing history; a transfer reconciling both sides from one row; activity direction per account; balance-history ordering; archive blockers (last account, default income, named bills); archive/restore round trip; planned-movement selection and its absence; partial reorder; the card's VoiceOver label; no shame language |
| `ScenarioSurfaceTests` (19) | Preload; three cards in contract order; Balanced the only recommendation; unstated constraints becoming nil; the no-profile case; Fastest Safe without the zero-allowance confirmation; Balanced without planned savings; missing-input de-duplication; every missing input naming a destination; overrides never touching saved data; a raised income shortening payoff; the override summary's wording; scenarios and insights persisting nothing; the apply summary not applying; a future-effective calc-v3 scenario plan; the earlier plan and its payday rows surviving; refusing to apply a non-computable scenario; copy checks |
| `OnboardingSetupTests` (+3) | Resume at every V3-08 boundary; interrupted v0.2 setups resuming without skipping a step; retired steps sorting inside the sequence; old-flow debts and bills not re-asked or duplicated |

**UI: `AccountsAndSetupUITests`, 13 new tests.** Accounts tab exists and shows
protected/available; a deposit updates the balance and the activity list; the
balance update explains itself and requires confirmation; archive is blocked
with an explanation; Accounts at accessibility text size; Settings has one
Bills & Debts page with one add action; type-choice-first shows only relevant
fields; the debt editor still offers every type-specific field; Progress →
three cards with the Recommended badge; missing constraints named rather than
invented; the overrides panel's promise; the extra-payment preview from debt
detail; scenarios at accessibility text size. The existing first-run walk was
updated to the new step order.

Commands (derived data kept **outside** `~/Documents` — the file-provider
xattr / CodeSign trap):

```
xcodebuild build -scheme PaydayPlaybook -destination 'generic/platform=iOS Simulator'
  → ** BUILD SUCCEEDED **

xcodebuild test -only-testing:PaydayPlaybookTests
  -destination 'platform=iOS Simulator,id=<pp-v03-accounts>'
  → Executed 422 tests, with 0 failures (30.6 s)

xcodebuild test -only-testing:PaydayPlaybookUITests -parallel-testing-enabled NO
  -destination 'platform=iOS Simulator,id=<pp-v03-accounts-ui>'   # its own simulator
  → Executed 32 tests, with 0 failures (457.9 s)
  → ** TEST SUCCEEDED **
```

The UI suite's first run failed; what it caught, and what changed as a result,
is §9.1.

---

## 5. Accessibility findings

Applied throughout, and asserted in tests where it is assertable:

- **Dynamic Type** — no fixed font sizes; every wrapping string carries
  `fixedSize(horizontal:false, vertical:true)`; controls keep a 44-point
  minimum. Three UI tests run at `AccessibilityL`.
- **VoiceOver names, values, hints** — each account card is one element whose
  label reads the whole summary (name, roles, balance and its freshness,
  protected, available, paycheck marker, next movement, attention state), with
  a hint saying what opening it does. Comparison-table rows collapse into
  "*label*: *this scenario*, compared with *Balanced*", so a comparison is read
  as a comparison rather than as four loose numbers. Money fields keep their own
  label and value rather than being merged into a container VoiceOver cannot
  type into — the pattern `SetupPercentField` already documents.
- **Never colour alone** — the reconciliation badge, missing-field notes,
  warnings, and the Balanced "Recommended" badge all pair an icon *and* text
  with any tint. High contrast and colour-blind use lose nothing.
- **Reduce Motion** — no custom animation was added; the only transition in the
  app remains the pre-existing app-lock fade.
- **Focus and keyboard** — sheets keep the standard cancel/confirm toolbar
  placement, so focus order and the keyboard escape route are the system's.
  Money sheets use `scrollDismissesKeyboard(.interactively)`; the decimal pad
  has no return key, which is why the UI-test helper drops it before scrolling.
- **States** — loading (`ProgressView` with a spoken label on both engine-backed
  screens), empty (every list), error (`accounts.loadFailure` with retry, plus
  inline sheet errors), warning (attention banner, missing-field notes, engine
  warnings), success (`scenarios.applySuccess`).
- **No shame language** — pinned by two tests. A negative or below-floor result
  is stated as a fact with its consequence ("the plan will simply work with
  what's actually there"), never as a judgement. A blocked archive explains and
  offers a route; it never scolds.

**Findings worth carrying forward:**

1. Two reorder lists embed a `List` inside a `ScrollView` with a computed
   `minHeight`. It works and stays reachable, but nested scroll containers are
   fragile at the largest accessibility sizes if rows wrap to three lines. A
   dedicated reorder screen would be more robust; deferred as presentation
   polish, not a correctness gap.
2. The account card is deliberately one combined element. It reads well, but it
   means VoiceOver users reach the four money actions via the detail screen or
   the context menu rather than from the card itself. The detail screen is one
   activation away, so nothing is unreachable.

---

## 6. Screenshots

**Not captured, deliberately.** Any screenshot of these screens shows account
names, balances, and payoff dates. On a simulator that is the invented
`DebugBaselineFixture` and therefore safe — but the same capture step run
against a device or a populated store would put real financial data into a
tracked artifact, which is exactly what V3-12 withdraws. The UI tests assert on
accessibility labels and identifiers instead, which is stronger evidence than an
image and carries no such risk. If the integrator wants screenshots for release
notes, capture them from a fresh simulator seeded with the fixture and review
each image before committing it.

---

## 7. Integration needs (Agent 7)

**Needs an owner decision:**

1. **`PlanContract.currentCalculationVersion` is still `2`.** Agent 2 left it at
   2 deliberately and handed the bump to Agent 3; Agent 3's branch does not
   raise it. Nothing in my scope requires it — I call
   `ScenarioCalculationService` directly, and applied scenario plans are
   stamped calc 3 by the engine regardless. But `VERSIONING.md` mandates calc 3
   for the release, and `GeneratedPlanService.reforecastResult` /
   `ReforecastService.reforecast` gate on `>=` this constant, so raising it
   while ordinary plans still emit v2 would silently disable reforecasts.
   Whoever owns the versioning gate should decide. **I did not touch it.**

2. **The Agent 2 ⊕ Agent 3 merge is not clean, and I resolved it to unblock
   myself.** Details in §8.1. Review that resolution rather than assuming it.

**Coordination:**

3. **Agent 5 (calendar/reminders).** I own the Accounts feature folder,
   `BillsAndDebtsView`, and `BillsAndDebtsStepView`. I edited
   `ObligationsStepView.swift` only to add an archive action to the bill editor,
   and did not touch due-rule editing. Due-date editing from the combined page
   goes through the existing `SetupDayField` inside those two editors — if you
   change due-rule editing, those are the files, and you should own them.

   **Reminders are not rescheduled when a scenario is applied.**
   `ApplyScenarioView` tells the user their reminders are rebuilt to match the
   new schedule, which is only true once a reschedule runs on plan activation.
   Either wire `NotificationScheduler.rescheduleAll` into scenario activation or
   the sentence must be removed. Flagged, not fixed — the scheduler is your
   scope, and guessing at its contract from here is how duplicate requests get
   created.

4. **Agent 6 (portability/reports).** `SettingsView`'s Setup section now reads
   "Bills & debts"; the Data section is untouched, so the Back Up & Restore /
   Reports split lands without conflict. `CashAccountSnapshot.availableBalance`
   is what the Accounts UI shows as "available" — use the same for report
   parity.

5. **Model addition in Agent 2's area.** `RecurringObligation.sortOrder` — §8.2.
   Additive and defaulted; no migration written, and none needed by the same
   reasoning Agent 2 used for every other schema-3 column.

---

## 8. Deviations, and things I changed outside my lane

### 8.1 The duplicate-DTO collision (resolved)

Agents 2 and 3 **both** defined `StoredScenarioDefinition` and
`StoredExtraPayment` in `Services/PlanningDTO.swift`, with **different fields**,
and both wrote `Codable` conformances for them. Their branches merge textually
without conflict, so the collision only surfaces at compile time — precisely the
"duplicated bridges silently disagree" hazard the v0.2.0 retrospective pinned.

| Type | Agent 2's shape | Agent 3's shape |
| --- | --- | --- |
| `StoredExtraPayment` | `id, debtID, amount, startingSequence, occurrences` | `id, kind, amount, effectiveDate, targetDebtID, sourceAccountID` |
| `StoredScenarioDefinition` | `id, name, baselinePlanVersionID, createdAt, input, extraPayments, note` | `kind, incomeOverride, constraints…, zeroAllowanceConfirmedAt, effectiveDate` |

**Resolution: Agent 3's shapes kept, Agent 2's removed** — including their
orphaned `Codable` extensions. Every consumer in the tree (the engine, both new
services, `PlanGenerationService.scenarioInput`, `ScenarioFixtures`, and all of
Agent 3's tests) uses Agent 3's shape; Agent 2's had **zero** call sites.
Agent 3's is also the one the engine's `ScenarioInput` mirrors field for field.

Agent 2's `StoredScenarioDefinition` carried saved-scenario metadata (`name`,
`note`, `baselinePlanVersionID`) that Agent 3's does not. Nothing in v0.3.0
needs it: the calculator builds definitions per session, and applying stamps
provenance on the `PlanVersion` itself. If saved, named scenarios are wanted
later, that metadata belongs on a new type rather than on the engine's input
DTO.

A one-line doc-comment conflict in `AvalanchePlanEngine.swift` was resolved in
Agent 3's favour (its file; both phrasings were equivalent, neither carried
personal data).

**This was Agent 7's call and I made it, because I could not compile without
it.** Reviewing it is the first thing the integrator should do.

### 8.2 `RecurringObligation.sortOrder`

§5.2 item 7 requires reorder for both sections. Debts have `priority`; bills had
no ordering column, so persistent reorder was impossible without one. I added
`var sortOrder: Int = 0` — additive, defaulted, the same shape as every other
schema-3 column Agent 2 added, and a default of `0` means every existing row
keeps its precise creation order until the user drags something. No migration
step is required, for the same reason Agent 2's other additive columns need
none. The alternative — offering only a sort control — was rejected as quietly
dropping half of a stated requirement.

### 8.3 `OnboardingProgress.swift`

Edited on Agent 2's explicit handoff ("Add it to `flowOrder` when you build the
step"). I went further than the handoff: `retiredSteps`, `resumeEquivalent`, and
routing `sortIndex` through it. The handoff's instruction alone would have
shipped the resume bug described in §3.5.

### 8.4 Repository extensions rather than edits

`DebtRepository.reorder`, `ObligationRepository.reorder`, and
`ObligationRepository.restore` live in
`Services/SetupOrderingRepositories.swift`, a file I own, rather than in Agent
2's `SetupRepositories.swift`. Views get a repository API and no shared file is
touched.

### 8.5 A defect the tests caught

The first draft of `AccountReconciliationService` selected ledger rows with
`entry.createdAt > anchor.createdAt`, meaning to exclude the adjustment row a
snapshot is written with. Under any clock that does not advance between saves —
every test using `FixedDateProvider`, and a same-millisecond race in production
— that dropped **every** subsequent movement and reported a spurious attention
state. Same-instant rows now count as *after* the snapshot, except the
snapshot's own explaining row, identified by account, instant, and effective
date. Residual limitation, documented in the code: a movement recorded in the
same clock tick *before* a snapshot cannot be distinguished from one recorded
after it. Resolving that properly needs a monotonic sequence column on
`LedgerEntry` — a schema change, and Agent 2's call.

---

## 9. Limitations and open items

1. **UI-suite result** — see §9.1 below.
2. **Reminders are not rescheduled on scenario activation** — §7.3. The
   confirmation copy promises it; either wire it or change the copy.
3. **No screenshots committed** — §6, deliberate.
4. **Device pass outstanding**, as for every release: the account sheets and the
   scenario screens have not been exercised on hardware.
5. **`currentCalculationVersion`** — §7.1, not mine to bump.
6. **The main-thread cost is managed, not removed.** Scenarios run in a `Task`
   with a loading state, but the engine is still synchronous and still on the
   main actor; on a very large plan the calculator's spinner will sit for over a
   second. Moving the engine off the main actor stays out of scope per Agent 1's
   risk register.
7. **`SettingsObligationsView` is now unreferenced** from the Settings list —
   the consolidated page replaced its entry. I left the type in place rather
   than deleting a screen in a file I do not own; Agent 6 or Agent 7 can remove
   it once the consolidation is ratified.
8. **Bills reorder is new storage, debts reorder reuses `priority`.** Both are
   presentation-only, and both say so on screen; neither affects the engine.

### 9.1 UI suite — first run, and what it caught

**32 tests (19 existing + 13 new). First run: 6 failures, all six in the new
file.** Every pre-existing UI test passed, including
`testFirstRunSetupGeneratesAPlanAndLandsOnToday`, which I had rewritten for the
V3-08 step order — the strongest available evidence that the consolidated step
and the reordered flow work end to end.

Five failures were wrong assumptions in my tests, not app defects:

| Failure | Cause | Fix |
| --- | --- | --- |
| 3 × Settings navigation | I invented `today.settingsButton`; the suite reaches Settings via `app.buttons["Settings"]` and rows by their label — a `NavigationLink` in a `List` does not expose a custom identifier as a button | Shared `openSettings` / `openBillsAndDebts` helpers |
| Debt-detail entry | Rows addressed by an identifier that does not exist; the existing tests open a debt by its text | Shared `openFirstDebt` helper, matching the existing pattern |
| Scenario apply | The fixture install has no planned-savings constraint, so **Balanced correctly renders a missing-input card with no apply button** — the app doing exactly what V3-06 requires | Rewrote the test to pin the missing-input state, which is the state that install genuinely reaches. Apply-and-confirm stays covered end to end in `ScenarioSurfaceTests`, against a setup that has the constraints |

The sixth was a **real defect in my UI**, and worth recording: I had written
*two different* archive-explanation sheets — one in `AccountsTabView`, one
inline in `AccountDetailView` — with different copy. The test asserted the
workspace's wording and hit the detail screen's. The same refusal explained in
two sets of words is worse than either wording alone, so the inline copy is
gone and both screens now present the shared `ArchiveBlockedSheet`.

The test also assumed a single-account install; the upgraded fixture carries
two migrated accounts, so the blocker is "it receives your paycheck" rather
than the last-account rule. It now pins the *shape* of the explanation — a
titled sheet naming what still holds the account and what to do next — which is
what the contract actually requires.

**After the fixes, the full suite is green: 32 tests, 0 failures** (457.9 s,
run alone on a dedicated simulator with `-parallel-testing-enabled NO`).

The suite must be run alone, with `-parallel-testing-enabled NO`, on its own
simulator — the pinned v0.2.0 cross-contamination hazard, which Agent 3 also
hit first-hand.

---

## 10. Commits

On `feature/v0.3-accounts-setup`:

- `a414eb3` — merge of `feature/v0.3-scenario-engine` into the Agent 2 base
  (doc-comment conflict resolved; see §8.1)
- `04a1fc8` — Checking Accounts workspace (V3-02/V3-03), plus the duplicate-DTO
  removal
- `10bea22` — consolidated Bills & Debts setup page (V3-08)
- `f6c62c4` — payoff scenario and extra-payment surfaces
  (V3-04/V3-05/V3-06/V3-15)
- `c2dda92` — UI coverage for all three surfaces, the archive-sheet
  consolidation the suite exposed, and this report
- (+ one follow-up commit recording these hashes, as Agents 1 and 3 did.)

**Validation at `c2dda92`:** unit suite **422/422 green**; UI suite **32/32
green**, run alone on a dedicated simulator; Debug build succeeds. Derived data
was kept outside `~/Documents` throughout.

The branch is **local only** — no v0.3 branch has been pushed to `origin` by any
agent, and this one follows that convention rather than publishing itself.
