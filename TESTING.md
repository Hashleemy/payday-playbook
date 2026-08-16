# Payday Playbook — Testing

Applies to **0.3.0-alpha.1** (app 0.3.0 · build 4 · schema 3 · calc 3 · export schema 3).

## Distribution check: no real person's data ships, in any configuration

The bundled Original Plan v1 template is **gone** (V3-12) — the resource, the seeder, the
template catalog, the Welcome affordance, and the Release build machinery that used to
exclude it. There is no longer a "developer builds keep it" carve-out, because there is
nothing to keep. The development fixture that replaced it is `#if DEBUG` only and invented.

Verify the artifact directly before distributing:

```bash
unzip -l YourApp.ipa | grep -i '\.json'      # must print nothing
# and, on a local Release build, the binary must not name the withdrawn machinery:
strings "$BUILT/PaydayPlaybook.app/PaydayPlaybook" \
  | grep -cE 'DebugBaselineFixture|OriginalPlanV1|PlanSeeder|TemplateCatalog|SeedPlan'
# must print 0
```

Removing the data from the working tree does **not** remove it from Git history, where it
remains reachable from most refs and both tags. That is an owner decision and is tracked in
`docs/releases/v0.3.0/agent-reports/agent-7-integration-qa.md` §8.

## Running the suites

```bash
# Unit suite — 515 tests
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath "$SOMEWHERE_OUTSIDE_DOCUMENTS/dd" \
  -only-testing:PaydayPlaybookTests test

# UI suite — 35 tests. Run it ALONE and serially (see below).
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath "$SOMEWHERE_OUTSIDE_DOCUMENTS/dd-ui" \
  -parallel-testing-enabled NO \
  -only-testing:PaydayPlaybookUITests test

# Render the six sample PDF reports and export them for inspection.
# Without the variable the export is skipped and only the assertions run,
# so CI never depends on a path.
TEST_RUNNER_PP_QA_PDF_DIR=/some/dir xcodebuild … \
  test -only-testing:PaydayPlaybookTests/FinancialReportVisualQATests
```

**Three rules that are not optional here, all learned the hard way:**

1. **Keep `-derivedDataPath` outside `~/Documents`.** The file-provider sync stamps
   FinderInfo xattrs onto build products inside a synced folder and CodeSign fails with
   "resource fork, Finder information, or similar detritus not allowed". Every agent on
   this release hit it.
2. **Give every concurrent checkout its own `-derivedDataPath` and its own
   simulator** (`xcrun simctl create`). Running `xcodebuild test` from several
   worktrees against the shared "iPhone 17 Pro" cross-contaminates results —
   runs have reported failures in test files that do not exist in the checkout
   under test, and have executed zero of their own tests.
3. **Run the UI suite alone, with `-parallel-testing-enabled NO`.** Under
   parallel execution with other simulators booted, `SimRenderServer` crashes
   and takes app launches with it. The symptom is a handful of tests reported
   as "failed" with no assertion failure and no app crash log, and a *different*
   set failing on each run. Serially, on a quiet machine, the suite is green.

## Unit tests — 515, all passing

| Suite | Tests | Covers |
| --- | ---: | --- |
| `ScenarioCalculationTests` | 34 | R-17…R-19: the three scenarios, ordering and deltas, retention, ceiling, cash path, determinism, every missing-input case, income override |
| `CalendarRemindersHardeningTests` | 28 | V3-07: prospective due-rule edits, future-vs-history rebuild, deep links, idempotent reconciliation, permission states, identifier privacy, month-end/leap/DST/time-zone cases |
| `OnboardingSetupTests` | 26 | Resume at every V3-08 boundary incl. retired steps, all six debt types, one-default-income invariant, all four cadences, old-flow rows never re-asked or duplicated |
| `NotificationSchedulerTests` | 24 | Diff-based reconcile, permission states, rolling window and 60-request cap, no double-fire on upgrade |
| `ExtraPaymentInsightTests` | 24 | R-20/R-21: one-time and recurring extras, targeting, prepayment semantics and warnings, downstream changes, preview separation |
| `FinancialReportTests` | 22 | V3-11: every section, engine agreement, scenarios and charts, masking, ranges, multi-page pagination, temp-file lifecycle |
| `AvalanchePlanEngineTests` | 22 | Allocation order, rollover, shortfall, promo APR, eligibility, utilization, minimum-only comparison |
| `CalendarEventServiceTests` | 21 | Event taxonomy, statuses, ordering, deep-link resolution, archived/deleted fallback |
| `BackupPortingTests` | 21 | V3-09: envelope and probe routing, v3 round trip, v1/v2 import, corruption and tampering, staging non-mutation, failed-commit rollback, safety backup |
| `ScenarioSurfaceTests` | 19 | V3-05/V3-06/V3-15: card order, unstated constraints becoming nil, overrides never touching saved data, apply creating a future calc-v3 version |
| `AccountsWorkspaceTests` | 19 | V3-02/V3-03: card figures, the three reconciliation states, corrections without erasing history, one-row transfers, archive blockers, VoiceOver label, tone |
| `TemplatePortingTests` | 18 | V3-10: field-by-field default exclusion, allow-list key set, opt-in categories, merge never overwriting, imported templates never enabling lock-screen detail |
| `CashLedgerServiceTests` | 17 | Deposits, withdrawals, atomic transfers, adjustments writing signed deltas plus snapshot evidence, append-only history, archive/restore, protected cash, reorder |
| `DueDateRuleTests` | 16 | Day 29–31 clamping, weekend shift rules, DST and time-zone stability, prospective edits |
| `MigrationServiceTests` | 15 | Clean-vs-upgrade routing, value-for-value preservation, derived obligation amounts and their round-trip guard, idempotency, reachable-failure rollback |
| `PlanPresentationTests` | 12 | Plan screen data, three-track separation, activation without history loss |
| `DebtCalculationEngineTests` | 12 | Frozen calc-v1 baseline: order, dates, payoffs, headline interest total |
| `CalcV3ReductionTests` | 12 | T-5: calc v3 is byte-identical to calc v2 without scenario or extras; stamping; R-16 identities on every scenario and insight result |
| `AvalancheBaselineParityTests` | 12 | Calc v2 reproduces the calc-v1 baseline check by check, derived from the engine rather than transcribed |
| `ReleaseIntegrationTests` | 10 | **Merge-only defects** — see below |
| `DebtTypeTests` | 10 | Per-type metadata, validation, utilization, principal basis |
| `ReviewRegressionTests` | 9 | 0.1.x review findings (unfunded payments, double-counting, CSV neutralisation) |
| `ReconciliationServiceTests` | 9 | Check-in reconciliation, snapshot-vs-baseline separation, invalid input |
| `PlanGenerationServiceTests` | 8 | Baseline equivalence through the store bridge, cadences, actionable failures |
| `PayScheduleGeneratorTests` | 8 | All four cadences, short months, leap years, DST |
| `CashAccountRepositoryTests` | 8 | Account CRUD and the exactly-one-default-income invariant |
| `AppRouterTests` | 8 | Notification routes, legacy `card` parsing, tab destinations |
| `SupportingServiceTests` | 7 | Money formatting/parsing, rounding, date math |
| `SchemaThreeMigrationTests` | 7 | T-1: 2 → 3 routing, every stored row fingerprinted before and after, no re-onboarding, defaults never invented, idempotency, user edits never overwritten |
| `PlanningContractTests` | 7 | DTO money exactness, deterministic snapshots, R-08 ordering at persistence |
| `ExportCompatibilityTests` | 7 | Backup round trip, older-schema import through migration, append-only CSV |
| `DebtPresentationTests` | 7 | Per-type labels/icons, utilization badge, non-colour meaning |
| `DashboardStateTests` | 7 | Five-second dashboard from the store's own rows, empty/error states |
| `NotificationDiagnosticsTests` | 6 | The duplicate detector behind the debug diagnostics screen: 0.1.x leftovers, same-copy-same-moment duplicates, no false alarms |
| `UpgradeChecklistTests` | 5 | Migrated users never re-onboard; a fresh install stores nothing and blocks until setup is done |
| `PrivacyScrubTests` | 5 | T-2/T-15: fresh install stores nothing, no bundled plan resource in any bundle, `PlanContract` carries only generic constants, notification identifiers carry no amounts |
| `OnboardingProgressTests` | 5 | Step persistence, resume, duplicate-proof finish |
| `ExportServiceTests` | 5 | JSON round trip, schema rejection, CSV escaping |
| `AvalanchePropertyTests` | 2 | Seeded-random invariants: determinism, cent reconciliation, non-negativity |
| `FinancialReportVisualQATests` | 1 | Renders six sample reports and asserts every glyph falls inside the printable area; exports them when `TEST_RUNNER_PP_QA_PDF_DIR` is set |

`ReleaseIntegrationTests` pins defects that existed **only in the merged tree**,
because each one's two halves arrived from different agent branches: the
presentation bridge ignoring the snapshot's `asOf`, reversed semimonthly days
normalising differently on the two bridges, missing pay days defaulting instead
of failing, the prepayment tri-state collapsing to a boolean, and the income
lookup reporting the bundled template's take-home on a generated-plan install.

v0.3.0 added three more, all guarding the calculation-version bump: an upgraded calc-2 plan
must still reach the modern engine, the frozen calc-v1 baseline must stay off it, and a
newly generated plan must be stamped 3. The first is the one that matters — gating engine
dispatch on `currentCalculationVersion` rather than on `minimumModernCalculationVersion`
would silently blank reforecast, insights, Today's projection and the plan screen for every
existing v0.2.0 user on upgrade. It was mutation-checked, not merely written.

## UI tests — 35, all passing

Run alone, serially, on a dedicated simulator.

A clean install opens on Welcome and **not** inside the app (the alpha.1 device-testing
regression); clean install through onboarding — now including the consolidated Bills &
Debts step — to a generated plan and Today; resume after force-quit mid-step; first payday
check-in end to end; draft save and resume; card payment and authoritative balance update;
calendar day panel opening the check-in; dashboard, plan, progress and setup at
accessibility text sizes; debt detail vocabulary and the type-aware editor; plan screen
tracks and activation; notification settings without permission.

New in v0.3.0: the Accounts tab showing protected and available; a deposit updating both
the balance and the activity list; a balance update explaining itself and requiring
confirmation; archive blocked with a named explanation; Settings offering exactly one
Bills & Debts page with one add action; type-choice-first showing only relevant fields;
Progress → three scenario cards with the Recommended badge; missing constraints named
rather than invented; the overrides panel's promise; the extra-payment preview from debt
detail; Accounts and scenarios at accessibility text sizes; the backup screen and its
warning; CSV export; report → PDF; and template export defaulting to structure-only.

The Welcome "Load a template" case is **gone**, replaced by a test asserting the affordance
is absent — the template it loaded was one real person's finances (V3-12).

## Device checklist (physical iPhone)

**Nothing below has been validated on hardware for this build.** The release is
not ready for general alpha distribution until items 1–7 pass on a real device;
everything else in this file is green in the simulator.

### Use the diagnostics screen

**Settings → Notification diagnostics (debug)** is how items 1, 2 and 5 are actually
judged. A lock screen cannot tell you whether an edit left a duplicate behind — a stale
trigger looks exactly like a correct one until it fires on the wrong day. The screen shows
the pending count against the 64-request system limit, `droppedByCap`, the last
reconciliation's added/removed/unchanged counts, every pending request with its identifier
and resolved fire time, and a **Findings** section that flags:

- any request still pending under a 0.1.x identifier (`due-soon-…`, `due-today-…`,
  bare `milestone-…`) — after an upgrade each one is a reminder that will fire twice;
- any two requests that would reach the user as the same notification at the same minute.

"No duplicates" means that section is empty. **Reconcile now** re-runs the reconcile without
backgrounding the app, so a change can be observed immediately.

### Run the phases in this order

One delete boundary, and the upgrade rehearsal first — it carries the most risk, and it
leaves behind the only store where legacy identifiers can collide, which is exactly where
item 1 has to be proven.

1. **Upgrade rehearsal** (item 13), 2. notification items 1–6 on the migrated store,
3. accessibility (item 7), 4. delete and do a fresh install, 5. one Release-configuration
install for the template and lock-screen checks — a Debug build is not the artifact you
would ship.

1. **Notification delivery.** Enable reminders, set a payday morning time a few
   minutes out, lock the device, confirm the banner arrives and the tap opens
   the right check-in. Confirm the evening nudge disappears once the check-in
   is completed.
2. **The 64-request limit in practice.** With many debts and obligations,
   confirm iOS accepts all 60 scheduled requests and fires them.
3. **Lock-screen copy.** With detailed previews off, confirm no amount and no
   debt nickname appears on the lock screen — including under notification
   grouping and the "Show Previews" system setting.
4. **Provisional authorization.** Cannot be entered in the simulator; verify
   quiet delivery on a device build.
5. **Time-zone travel and DST.** Change the device time zone and cross a real
   DST boundary; confirm a 9:00 reminder still fires at 9:00 local and that no
   duplicates appear.
6. **Cold-launch deep link.** Tap a delivered notification with the app
   terminated; confirm it lands on the right screen.
7. **VoiceOver and Dynamic Type on the new calendar modes.** Week strip and
   agenda list at accessibility sizes, and the spoken order of combined event
   rows.
8. **Notification-denied path.** Deny permission, confirm Settings → Reminders
   explains it, offers "Open iOS Settings", and the app stays fully usable.
9. **Face ID lock.** Enable in Settings → Security, background, reopen, confirm
   the overlay, Face ID unlock, and passcode fallback.
10. **Backup round trip.** Export JSON and CSVs to Files; re-import the JSON,
    review the restore summary, confirm the rollback backup lands in Documents,
    and spot-check that debts, ledger, and completed check-ins survive.
11. **Relaunch persistence and offline use.** Force-quit and relaunch in
    airplane mode; entries, drafts, and settings survive and nothing needs the
    network.
12. **Reduce Motion.** The debt-free celebration shows without the spring
    animation.
13. **Upgrade rehearsal — do this first, and do not skip it.** The only proof outside
    fixtures that the existing user loses nothing.
    - Delete the app. Build 0.1.x to the phone from its own worktree so the release branch
      is undisturbed: `git worktree add .claude/worktrees/pp-0.1.0-device b0e7443 --detach`
      (already created). It is build 1, same bundle id, and auto-seeds on first launch.
    - Use it: complete the first check-in, record a card payment, enter an authoritative
      balance update, and enable reminders so 0.1.x schedules its letter-keyed requests.
    - **Without deleting**, build this branch (build 3) over it.
    - Confirm: every payday and every value unchanged, ledger and check-in intact,
      onboarding does not reappear, the upgrade checklist asks only about what migration
      could not know, and the diagnostics screen reports **no** 0.1.x identifiers and no
      duplicates. Cross-check the numbers against item 14.
14. **Plan verification screen** (debug builds): Settings → About → Plan
    verification — confirm the debt count, payday count, starting total,
    payoff date, modeled interest, and ceiling against your own source plan
    records, which are kept outside the repository (V3-12).

### New in v0.3.0 — none of these has run on hardware

15. **Duplicate hunt after a due-date edit.** Edit a due date, then read the diagnostics
    screen's pending snapshot: exactly one request per family per occurrence, and no legacy
    identifier sitting beside its replacement. A stale trigger is indistinguishable from a
    correct one until it fires on the wrong day, which is why this is a diagnostics read
    rather than a wait.
16. **The upgrade's one round of reminder churn.** The debt reminder reference changed
    shape, so the first reconcile after upgrading re-adds every debt due reminder once.
    Confirm it happens once and that a second reconcile adds and removes nothing.
17. **Applying a scenario rebuilds reminders.** Apply a scenario, then confirm on the
    diagnostics screen that the pending set matches the *new* schedule — the confirmation
    copy promises this.
18. **Share sheet.** Export a JSON backup, a template, and a PDF report; confirm each
    reaches Files/Mail intact and that nothing is written outside the app's own storage.
19. **System file importer.** Import a backup and a template through the real Files
    provider, including from iCloud Drive, not just a local path.
20. **PDF rendering on device hardware.** Generate a full-detail report and a masked one on
    the phone; confirm pagination, that no glyph clips, and that the masked one really has
    no balances.
21. **Restore, cancelled and committed.** Stage a restore and back out — the store must be
    untouched. Then commit one and confirm the safety backup is written and is itself
    restorable.
22. **Lock-screen copy with detail deliberately on.** Turn detailed lock-screen content on
    for one reminder kind and confirm only that kind shows detail — and that importing a
    template never turns it on for you.
23. **Accounts and scenarios at accessibility sizes on device**, including the two nested
    reorder lists, which are the known-fragile layout at the largest sizes.

## Known behaviours and limitations

- Due days accept 1–31 and clamp to the last valid day of shorter months
  (Jan 31 → Feb 28, or Feb 29 in a leap year). **This replaces the 0.1.x
  1–28 clamp**, which is gone from every call site. Weekend shifting is opt-in;
  holidays are deliberately unsupported.
- Editing a due day is prospective. Markers for months before the edit are not
  drawn, because the app never recorded what the old due day was and will not
  invent one.
- Weekly and biweekly obligations get no due-date marker or reminder; a
  day-of-month cannot describe them. Their per-paycheck reserve is unaffected.
- Quarterly, semiannual, and annual obligations recur from their creation
  month; there is no first-due-date field yet.
- Migrated debts carry no `originalPrincipal`; percent-paid falls back to the
  starting balance, exactly as 0.1.x computed it.
- Interest is simple, 365-day, accrued per payday — not daily compounding and
  not issuer statement cycles. Card minimums without an entered amount use a
  heuristic. Every plan surfaces these as assumptions in the UI.
- The plan analysis, the three payoff scenarios, the extra-payment insight, and PDF report
  rendering all run synchronously on the main thread. Three scenarios plus one insight is
  roughly 1.3 s on an eight-debt, 77-paycheck plan — six full projections. The scenario and
  report screens compute in a task with a loading state rather than blocking silently, and
  no engine call is made from a view body. Moving the engine off-actor is still the real
  fix and is out of scope.
- Applying a scenario is the only path from a preview to a stored plan, and it is confirmed
  first. Previewing writes nothing at all: both calculation services take values and return
  values, with no `ModelContext` in scope.
- A structure-only template cannot create bills, installment debts, or a pay schedule,
  because the model requires amounts the template deliberately omits. Apply reports what
  each skipped row still needs rather than inventing a figure.
- Restore replaces the whole store. Duplicate identifiers in a file are refused outright
  rather than merged — two rows claiming one identity means the file is wrong, and picking
  a winner would silently discard the other.
- At the largest accessibility sizes, Today's primary action requires a scroll.
- Balance derivations fetch whole tables and filter in memory — fine at this
  scale, revisit if the app outlives Phase II.
- Calendar notes are stored as zero-amount Checking 1 adjustments (shown as
  "Note" in the ledger) and export under that type.
