# Agent 2 — Privacy, Migration, and Cash Data (v0.3.0)

Branch: `feature/v0.3-privacy-data` (from `feature/v0.3-contract` @ `4be5c57`)
Scope: V3-12 (personal-data removal), V3-13 (privacy-safe diagnostics),
V3-04 (cash accounts and ledger), MVP_LAYOUT §6/§7 (schema 3 and its
migration), and the storage-independent DTO boundary shared with Agent 3.

**No value detected during the audit appears anywhere in this report.** Where a
figure is quoted it belongs to the invented development fixture that replaced
the withdrawn data.

---

## 1. Outcome

The project no longer carries any real person's financial information in a
tracked artifact. The bundled plan template and every constant, fixture, golden
value, comment, and pinned date derived from it are gone, replaced by an
invented fixture whose schedule is *computed* by the shipped calc-v1 engine
rather than transcribed. Existing installs are unaffected: the 1 → 2 migration
now derives what it used to hard-code, and a new 2 → 3 step adds only defaults.

Required work, item by item:

| # | Requirement | Status |
|---|---|---|
| 1 | Audit tracked artifacts for real-person financial data | Done — 27 files found, reported by path/category/count below |
| 2 | Replace personal seed/preview/test data with fictional data | Done — `DebugBaselineFixture`; fresh installs receive nothing at all |
| 3 | Idempotent migration retaining pre-existing installed data | Done — §7 below; nothing reseeded, duplicated, or erased |
| 4 | CashAccount / LedgerEntry / BalanceSnapshot + repositories | Done — `CashLedgerService`, extended `CashAccountRepository` |
| 5 | Preserve all v0.2 data; additive fields only | Done — every schema-3 field is optional or defaulted |
| 6 | Privacy-safe logging | Done — the app has **zero** logging call sites; verified and kept that way |
| 7 | Comment cleanup in owned code | Done — persona references and stale narration removed |
| 8 | Read-only Git-history audit | Done — findings and the owner decision in §9 |

---

## 2. Audit findings (paths, categories, and counts only)

Method: a ground-truth marker set was built from the two files known to carry
the founding user's plan, then matched against every tracked file with
count-only output, so no matched value entered a transcript, log, or report.
The marker set is 124 distinct amounts, 6 APRs, and 23 dates, after excluding
round figures that are plausibly generic.

**Before (at `4be5c57`) — 27 files carried at least one marker:**

| Category | Files | Notes |
|---|---|---|
| Bundled resource | 1 | The whole plan: balances, APRs, income, per-check schedule, payoff dates |
| Source constants | 1 | `PlanContract` — 22 personal constants |
| Seed/template stack | 3 | Loader, validator, seeder, catalog |
| Migration constants | 1 | Two hard-coded obligation amounts |
| App views | 8 | Fallback values used when a plan could not be read |
| Test fixtures and goldens | 24 | Fixtures, parity goldens, migration fixtures, pinned dates |
| Build machinery | 1 | `EXCLUDED_SOURCE_FILE_NAMES` + a guard phase whose script text described the data |
| Historical release doc | 1 | One APR in a v0.2.0 agent report |

Other audit axes:

- **Persona name** — 12 files, including one test file whose *name* carried it.
  All removed; zero remain in code.
- **Logging** — **zero** logging call sites of any kind in app source (no
  `print`, `NSLog`, `os_log`, `Logger`, or custom wrapper). V3-13's "do not log
  balances, labels, payloads, reports, or notes" is satisfied by construction,
  and `PrivacyScrubTests` pins the notification-identifier half of it.
- **Notification identifiers** — built from entity UUIDs and family prefixes;
  no amounts. Notification *bodies* do contain amounts, but only under the
  user's own `detailedLockScreenContent` preference, on their own device. That
  is product behaviour (V2-11), not a diagnostics leak, and is unchanged.

**After — zero markers in any tracked file**, verified by re-running the same
scan with the ground-truth set recovered read-only from history (so the scanner
still knows what to look for after the source files are gone).

One methodology note worth recording: the first verification pass reported
three false positives because the marker alternation lacked numeric boundaries,
so a longer invented total that merely *contained* a shorter real amount as a
substring matched. The scanner now requires numeric boundaries. Two genuine
collisions were also found — invented round balances that happened to equal
values in the withdrawn data — and the fixture was retuned to avoid them, so
the final result needs no "explained away" exceptions.

---

## 3. What was removed

- `PaydayPlaybook/Resources/OriginalPlanV1.json`
- `PaydayPlaybook/Services/SeedPlan.swift` (loader, validator, error type)
- `PaydayPlaybook/Services/PlanSeeder.swift`
- `PaydayPlaybook/Services/TemplateCatalog.swift`
- `PaydayPlaybookTests/PlanSeederTests.swift`
- `PaydayPlaybookTests/TemplatePrivacyTests.swift`
- `EXCLUDED_SOURCE_FILE_NAMES` and the Release "verify no template" build phase
  in `project.pbxproj` — both existed only to keep the resource out of
  distribution builds, and the guard script's own text described what the
  resource contained
- The Welcome screen's "Load a template instead" affordance and its warning
  alert, plus the `loadTemplate` / `completeWithoutGenerating` path

`PlanContract` keeps only version stamps, the plan-name lookup keys, the R-06
minimum-payment estimator constants, and the pay-frequency constant.

### `PlanRepository` — a deliberate deviation worth flagging

`PlanSeeder` was contracted as removed, but two of its methods —
`currentPlan(context:)` and `existingBaseline(context:)` — were generic plan
lookups with nothing to do with seeding, used by 12 app files and 11 test
files. They moved to a new `PlanRepository` (`currentPlan`, `legacyBaseline`,
`planItems`, `isStructurallyComplete`) rather than leaving a type named for a
job the app no longer does.

**This mechanically touched view files owned by Agent 4** (`TodayState`,
`ProgressTabView`, `CheckInFlowView`, `DebtsView`, `SettingsView`,
`InsightsView`, `CalendarTabView`, `DebtFreeTransitionView`, `TodayView`,
`DebtFreeTransitionView`). Every edit is either a call-site rename or the
removal of a personal-constant fallback — no behaviour change beyond §5.

---

## 4. Fallbacks that were showing one user's numbers to everyone

Eight view-layer call sites used the personal constants as *fallbacks* when a
plan could not be read. On any install without a readable plan, these displayed
the founding user's figures as if they were the current user's. Each now
degrades honestly instead:

| Site | Was | Now |
|---|---|---|
| `TodayView.releasedPerPaycheck` | Hard-coded budget/income | Zero when there is no plan or income on record |
| `DebtFreeTransitionView.releasedPerPaycheck` | Hard-coded budget/income | Same |
| `DebtFreeTransitionView` celebration copy | Fixed "debt eliminated" total | Summed from the user's own debt rows |
| `SettingsView.previewImpact` | Hard-coded income | Asks the user to add their income |
| `ProgressTabView.startingDebtTotal` | Fell back to a fixed total | Summed from the user's debts |
| `ProgressTabView.timelineOrder` | Fell back to a fixed avalanche order | The install's own order |
| `ProgressTabView.baselinePayoffText` | Fell back to a fixed date table | "—" when this store has no such date |
| `DebtsView.reload` | Fell back to a fixed date table | Nil when this store has no such date |
| `CalendarTabView.jumpToDebtFree` | Fell back to a fixed payoff date | Stays put when there is nothing to jump to |
| `CheckInFlowView` protected floor | Fixed constant | The user's profile floor, else their plan's |
| `SettingsView` §3 verification screen | Projected from constants | Re-projects the store's own plan |

`DebtCalculationEngine.baselineProjection()` was deleted outright: it assembled
an entire projection from the personal constants.

---

## 5. The development fixture

`PaydayPlaybook/Services/DebugBaselineFixture.swift`, compiled `#if DEBUG`
only. It replaces the bundled template for the UI-test hook and the whole unit
suite.

- Six invented cards in avalanche order, round balances, total $36,400.00
- Biweekly $2,400.00 take-home rising to $2,500.00 at check 9
- Spending balance and floor both $1,500.00 (so no top-up), allowance $300.00
- Two monthly obligations whose per-check reserves are **derived by R-04**
  rather than stated, so the fixture cannot disagree with the rule
- First payday 2054-08-20 — plainly in the future, so it can never be mistaken
  for a record of something that happened

The schedule is produced by running the shipped calc-v1 engine over these
inputs, so per-card balances, payoff dates, interest, and totals agree with the
engine by construction rather than by transcription. It retires in exactly 23
checks, the same *shape* the suite always exercised, so structural assertions
still mean what they meant.

Test dates moved by exactly **28 years**. A whole-Gregorian-cycle shift
preserves both weekday and leap-year status, so month-end clamping, February,
weekend-shift, and DST tests keep their meaning — a 5-year shift, tried first,
silently broke several of them.

Verified absent from distribution builds: a Release build produces a bundle
containing no JSON at all, and the Release binary contains zero occurrences of
`DebugBaselineFixture`, `OriginalPlanV1`, `PlanSeeder`, or `TemplateCatalog`.

---

## 6. Schema 3 — model changes (all additive)

| Model | Added | Default |
|---|---|---|
| `CashAccount` | `protectedAmount: Decimal` | `0` |
| `CashAccount` | `balanceAsOf: Date?` | `nil` — never stated |
| `LedgerEntry` | `.accountDeposit`, `.accountWithdrawal`, `.accountTransfer`, `.accountAdjustment` | additive cases; every existing raw value still decodes |
| `LedgerEntry` | `provenanceRaw: String?` (`LedgerProvenance`) | `nil`, **never backfilled** |
| `PlanVersion` | `scenarioKindRaw: String?` (`PlanScenarioKind`) | `nil` — not retroactively labelled `.baseline` |
| `PlanVersion` | `effectiveDate: Date?` | `nil` |
| `UserGoalProfile` | `minimumProtectedCash`, `plannedSavingsPerPaycheck`, `additionalCushionReserve`, `extraPaymentCeiling` | `0` |
| `UserGoalProfile` | `zeroAllowanceConfirmedAt: Date?` | `nil` — silence is not consent |
| `OnboardingProgress` | `.billsAndDebts` case | declared, **not yet in the flow** — see below |
| `BalanceSnapshot` | *unchanged*, as contracted | — |

`OnboardingStep` traversal now runs off an explicit `flowOrder` list instead of
`allCases`. A resume position is persisted user data: with `allCases`, adding
any case shifts every later step's index and can land a half-onboarded user on
a different screen than the one they left. `.billsAndDebts` is therefore inert
until the onboarding owner puts it in the sequence deliberately (V3-01).

---

## 7. Migration mapping

### Schema 1 → 2 (existing step, two changes)

**Obligation amounts are now derived, not hard-coded.** A 0.1.x store recorded
only the smoothed per-check reserve, never the billed amount, so the migration
carried two constants — one real user's bills, which it would have written into
*anybody's* store. They are replaced by inverse R-04
(`ObligationMath.amount(fromPerPaycheckReserve:cadence:paychecksPerYear:)`)
applied to the store's own numbers, with the existing guard kept and tightened:
the recovered amount must re-smooth to the stored reserve **exactly** or
migration aborts. No stored value is ever rewritten to make the math agree.

> **Finding.** The abort branch is *unreachable* on the migration path. For
> monthly obligations against 26 paychecks a year the round-trip closes for
> every reserve from $0.01 to $2,000.00 — verified exhaustively in
> `MigrationServiceTests`. The guard stays because other cadences do not share
> that property (a weekly obligation can fail it) and because a silently wrong
> amount is far worse than a refused migration. A pre-existing test that
> induced the mismatch by hand no longer can, and was rewritten to induce a
> *reachable* failure (a gap in the payday sequence) instead.

**The integrity pre-check is now structural.** It compared payday and debt
counts against fixed numbers taken from one user's plan, which rejected valid
stores of a different size *and* accepted that user's own partial graph. It now
checks self-consistency: contiguous payday sequence 1…n, every debt in the
avalanche order still present, per-card balances on every payday, at least one
income rule, and a final balance of zero.

**The crashed-partial-seed repair path is retired.** 0.1.x rebuilt a partial
seed by re-reading the bundled template; there is nothing to rebuild from now.
Such a store aborts cleanly and the user's own rows are untouched — inventing a
plan graph for a store whose real one is incomplete would be worse than
declining.

### Schema 2 → 3 (new)

| Step | Action |
|---|---|
| Detect | `AppSettings.seedSchemaVersion == 2` |
| Protected amount | Copy `UserGoalProfile.protectedFloor` onto the **spending-role** account's `protectedAmount` (same precedence `CashAccountRepository.spendingAccount()` uses); every other account stays at `0` |
| Everything else | Left at its default — the defaults are already correct for an upgraded store |
| Stamp | `seedSchemaVersion = 3`, `migratedAt`, and an audit note |

Only the spending account receives the floor: the user protected one balance,
and inventing a second protected balance on their reserves account would
silently shrink the money their plan is allowed to use. The step is idempotent
(a re-run finds the amount already set) and never overwrites a user who has
since edited it. Each step stamps only its own version, so a store that
completes 1 → 2 and then fails is honestly recorded as being at 2.

**Backup restore fixed along the way.** `ExportService.restore` ran only the
1 → 2 upgrade, so a restored v1 document landed at schema 2 — indistinguishable
from a legacy install, and migrated again next launch. It now runs every step
the backup predates and stamps to current, inside the same save.

---

## 8. Cash accounts and ledger (V3-04)

`CashLedgerService` — deposits, withdrawals, transfers, dated adjustments,
activity queries. Two rules shape it:

**History is append-only.** No operation edits or deletes an earlier row. A
balance the user says is wrong is reconciled by writing the *difference* as its
own dated row plus an authoritative `BalanceSnapshot` recording the stated
figure. The ledger stays a record of what was believed and when. A confirming
adjustment that changes nothing still writes a snapshot (the confirmation is
itself a fact) but no ledger row, because no money moved.

**A transfer is one row, not two.** It carries both endpoints and reads as
negative on its source and positive on its destination via
`CashLedgerService.signedAmount(of:for:)`. Two linked rows can half-exist after
an interrupted save and every reader then has to detect and repair that; with a
single row the movement either happened or it did not, so reconciliation has no
partial state to reason about. Both balances move in one save.

`CashAccountRepository` gains `reorder` (accounts the caller did not name keep
their relative order), `canArchive` / `archiveIfAllowed` (the last active
account cannot be archived — something must be able to receive income),
`restore`, and a validated `protectedAmount` on `update`.

## DTO contract (Agent 3 boundary)

`PlanningDTO.swift` stays Foundation-only; no SwiftData type crosses it.

- `StoredExtraPayment` — `id`, `debtID: UUID`, `amount`, `startingSequence`,
  `occurrences: Int?`. A UUID names the debt, so the engine never has to know
  `DebtAccount` exists.
- `StoredScenarioDefinition` — `id`, `name`, `baselinePlanVersionID: UUID?`,
  `createdAt`, a complete `StoredPlanInput`, `extraPayments`, `note`. The
  scenario stores its **own** full input, not a patch against the live plan: a
  patch changes meaning whenever the baseline moves underneath it, and a
  comparison against a baseline the scenario was never computed against is not
  a comparison.
- Both are `Codable` with money encoded as strings, matching the existing
  convention.
- `CashAccountManaging` + `CashAccountSnapshot` — plain-value account state with
  `availableBalance` (balance net of protected amount, floored at zero).
  `CashAccountRepository` conforms.
- `ObligationMath` gains `amount(fromPerPaycheckReserve:…)` and
  `roundTripReproduces(reserve:…)`.

---

## 9. Read-only Git-history audit

No history was rewritten, no branch force-pushed, no tag or release touched.

| Finding | Detail |
|---|---|
| Commits touching the withdrawn resource | 3, all in the project's earliest commits |
| Refs carrying it at their tip (at audit time) | **28 of 28** — every local branch, both tags, and 10 remote-tracking refs |
| Remote | `github.com/Hashleemy/payday-playbook` — **private**, but pushed |
| Local worktree | `.claude/worktrees/pp-0.1.0-device` is a 0.1.0 checkout and still contains the resource on disk |

**This is an owner decision, not mine to make.** MVP_LAYOUT §3 says that if
history contains personal financial information *and* the repository has been
shared, pushed, or made public, the owner must be asked whether to coordinate a
history rewrite. The repository has been pushed; it is private, which limits
exposure but does not remove the data from history. Removing it from history
would require a rewrite across every branch and both tags plus a coordinated
force-push — explicitly outside my instructions.

Recommended sequencing if the owner chooses to proceed: complete the v0.3.0
release first (this branch removes the data going forward), then decide on
history separately, since a rewrite invalidates every open branch.

---

## 10. Tests

New:

| File | Covers |
|---|---|
| `SchemaThreeMigrationTests` | **T-1** — routing, value-for-value preservation (a fingerprint of every stored row compared before/after), no re-onboarding, protected-floor mapping, defaults never invented, idempotency across repeated launches, user edits never overwritten |
| `CashLedgerServiceTests` | **T-3/T-4** — deposits, withdrawals, atomic single-row transfers, totals reconciling across many movements, adjustments writing signed deltas plus snapshot evidence without touching history, append-only snapshots, archive/restore safeguards, protected cash, reorder |
| `PrivacyScrubTests` | **T-2/T-15** — fresh install stores nothing; no bundled plan resource in any bundle; `PlanContract` carries only generic constants; the fixture is self-evidently synthetic; notification identifiers carry no amounts |

Renamed: `AvalancheLemParityTests` → `AvalancheBaselineParityTests`, rewritten
so the parity expectations are **derived from the calc-v1 run** rather than
transcribed from a document — privacy-safe and a stronger check, since a
transcription can drift from what either engine computes.

Reworked: `DebtCalculationEngineTests` (fictional golden projection),
`MigrationServiceTests`, `DashboardStateTests` and `PlanPresentationTests` (now
compare the view against the store's **own rows**, which tests "the screen
shows what was saved" directly), `ReconciliationServiceTests` (drafts derived
from each payday's planned figures, so they stay balanced whatever the
fixture's numbers are), and every file carrying a pinned date or golden.

---

## 11. Commands run and results

```
xcodebuild build -scheme PaydayPlaybook -configuration Debug
  -destination 'platform=iOS Simulator,id=E2EF0489…' -derivedDataPath <outside ~/Documents>
  → ** BUILD SUCCEEDED **

xcodebuild build-for-testing … (clean derived data)
  → ** TEST BUILD SUCCEEDED **

xcodebuild test-without-building … -only-testing:PaydayPlaybookTests
  → Executed 311 tests, with 0 failures (0 unexpected) in 24.956s
  → ** TEST EXECUTE SUCCEEDED **

xcodebuild build -configuration Release …
  → ** BUILD SUCCEEDED **
  → Release bundle contains no .json resource
  → Release binary: 0 occurrences of DebugBaselineFixture / OriginalPlanV1 /
    PlanSeeder / TemplateCatalog

privacy scan (markers recovered read-only from history)
  → 0 markers in any tracked file
```

Unit suite: **311 tests, 0 failures** (282 pre-existing after rework, plus 29
new). Derived data was kept outside `~/Documents` throughout, per the known
iCloud-xattr/CodeSign hazard.

---

## 12. Accessibility and privacy validation

- Accessibility: the only UI changes are the removal of the template button and
  its alert, plus copy that now reads from the user's own data. No layout,
  focus order, label, or Dynamic Type behaviour changed. The existing
  accessibility UI tests are unmodified and still describe the same screens.
- Privacy: zero markers tree-wide; zero persona references in code; zero
  logging call sites; notification identifiers verified amount-free by test;
  Release bundle and binary verified clean.

---

## 13. Limitations and device-only checks

1. **UI tests were not executed.** They need a dedicated simulator and serial
   execution (a pinned v0.2.0 hazard). They were *updated* — the template test
   is replaced by one asserting the affordance is absent, and the
   `--uitest-skip-onboarding` hook now lands the invented fixture — but only
   the unit suite was run. Someone should run the UI suite on a dedicated
   simulator before the build is cut.
2. **Device pass outstanding** for the notification and app-lock paths, as with
   every release.
3. **`currentCalculationVersion` deliberately left at 2.** I raised it to 3
   early on and it silently disabled every reforecast, because
   `GeneratedPlanService.reforecastResult` returns nil below the current
   version and the shipped engine still emits calc v2. Raising a version stamp
   ahead of the code implementing it breaks the consumers that gate on it. The
   bump belongs with the v3 engine — see the handoff.
4. **Git history still contains the withdrawn data** (§9) — owner decision.
5. **`.claude/worktrees/pp-0.1.0-device/`** is an untracked local 0.1.0
   checkout that still holds the resource on disk. Not a tracked artifact, but
   it should be deleted locally.

---

## 14. Handoff

**Agent 3 (engine / calculation):**
- `StoredScenarioDefinition` and `StoredExtraPayment` are in place and Codable;
  `ObligationMath` has the inverse-R-04 helpers. Confirm the names match your
  `ScenarioCalculating` / `ExtraPaymentInsightCalculating` contracts before
  Wave 3.
- **`PlanContract.currentCalculationVersion` is still 2.** Raise it to 3 in the
  same change that ships the v3 engine, and check the gates that compare
  against it (`GeneratedPlanService.reforecastResult`,
  `ReforecastService.reforecast`) — they use `>=`, so a premature bump disables
  them silently.
- `CashAccountManaging` / `CashAccountSnapshot` give you account state without
  SwiftData, including `availableBalance` net of the new protected amount.

**Agent 4 (onboarding / accounts UI):**
- `PlanSeeder.currentPlan` → `PlanRepository.currentPlan`,
  `PlanSeeder.existingBaseline` → `PlanRepository.legacyBaseline`. I applied
  this rename across your view files; they are call-site changes only.
- `OnboardingStep.billsAndDebts` exists but is **not** in
  `OnboardingStep.flowOrder`. Add it there when you build the step;
  `OnboardingFlowView` has a placeholder branch that currently falls back to
  the debts step.
- `CashAccountRepository` has `reorder`, `canArchive`/`archiveIfAllowed`,
  `restore`, and `protectedAmount` on `update` for the Accounts tab.
- `WelcomeStepView` now takes only `onContinue`.

**Agent 7 (integration):**
- Run the UI suite serially on a dedicated simulator.
- The Git-history question in §9 needs an owner decision before release.
- Migration ordering: `applyLogicalUpgrade` (1→2) → `applySchema3Upgrade` →
  `stamp`. `ExportService.restore` follows the same sequence.
