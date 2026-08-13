# Payday Playbook — Testing

Applies to **0.2.0-alpha.2** (app 0.2.0 · build 3 · schema 2 · calc 2 · backup 2).

## Distribution check: the template must not ship

Original Plan v1 is a real person's finances and is excluded from Release builds. Its
**full removal from every build configuration is contracted under V3-12** (v0.3.0); until
that lands, the Release build phase fails the build if it reappears — but verify the
artifact directly before distributing:

```bash
unzip -l YourApp.ipa | grep OriginalPlanV1   # must print nothing
# or, for a local build:
ls "$(xcodebuild -showBuildSettings -configuration Release | awk -F'= ' '/ BUILT_PRODUCTS_DIR/{print $2}')/PaydayPlaybook.app/OriginalPlanV1.json"
```

Developer builds intentionally keep it — the crashed-partial-seed migration repair and the
seed suites need it, and the "Load a template" affordance on Welcome appears only when it
is present.

## Running the suites

```bash
# Unit suite — 292 tests
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/dd \
  -only-testing:PaydayPlaybookTests test

# UI suite — 19 tests. Run it ALONE and serially (see below).
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/dd-ui \
  -parallel-testing-enabled NO \
  -only-testing:PaydayPlaybookUITests test
```

**Two rules that are not optional here, both learned the hard way:**

1. **Give every concurrent checkout its own `-derivedDataPath` and its own
   simulator** (`xcrun simctl create`). Running `xcodebuild test` from several
   worktrees against the shared "iPhone 17 Pro" cross-contaminates results —
   runs have reported failures in test files that do not exist in the checkout
   under test, and have executed zero of their own tests.
2. **Run the UI suite alone, with `-parallel-testing-enabled NO`.** Under
   parallel execution with other simulators booted, `SimRenderServer` crashes
   and takes app launches with it. The symptom is a handful of tests reported
   as "failed" with no assertion failure and no app crash log, and a *different*
   set failing on each run. Serially, on a quiet machine, the suite is green.

## Unit tests — 292, all passing

> **V3-12 note.** Suites whose code names still carry the founding user's name appear
> below under their contracted replacement names (`AvalancheBaselineParityTests`;
> "baseline equivalence" in `PlanGenerationServiceTests`). The code rename lands with the
> v0.3.0 privacy agent; test counts and coverage are unchanged.

| Suite | Tests | Covers |
| --- | ---: | --- |
| `NotificationSchedulerTests` | 24 | Diff-based reconcile, permission states, rolling window and 60-request cap, no double-fire on upgrade |
| `OnboardingSetupTests` | 23 | Resume at every step boundary, all six debt types, one-default-income invariant, all four cadences, boundary values |
| `AvalanchePlanEngineTests` | 22 | Allocation order, rollover, shortfall, promo APR, eligibility, utilization, minimum-only comparison |
| `CalendarEventServiceTests` | 21 | Event taxonomy, statuses, ordering, deep-link resolution, archived/deleted fallback |
| `DueDateRuleTests` | 16 | Day 29–31 clamping, weekend shift rules, DST and time-zone stability, prospective edits |
| `MigrationServiceTests` | 13 | Clean-vs-upgrade routing, full baseline value-for-value, derived balances, idempotency, induced-failure rollback |
| `PlanPresentationTests` | 12 | Plan screen data, three-track separation, activation without history loss |
| `DebtCalculationEngineTests` | 11 | Frozen calc-v1 baseline: order, dates, payoffs, headline interest total |
| `AvalancheBaselineParityTests` | 11 | Calc v2 reproduces the calc-v1 baseline check by check |
| `PlanSeederTests` | 10 | Template load, allocations, no-spend ceiling construction |
| `DebtTypeTests` | 10 | Per-type metadata, validation, utilization, principal basis |
| `ReviewRegressionTests` | 9 | 0.1.x review findings (unfunded payments, double-counting, CSV neutralisation) |
| `ReconciliationServiceTests` | 8 | Check-in reconciliation, snapshot-vs-baseline separation, invalid input |
| `PlanGenerationServiceTests` | 8 | Baseline equivalence through the store bridge, cadences, actionable failures |
| `PayScheduleGeneratorTests` | 8 | All four cadences, short months, leap years, DST |
| `CashAccountRepositoryTests` | 8 | Account CRUD and the exactly-one-default-income invariant |
| `AppRouterTests` | 8 | Notification routes, legacy `card` parsing, tab destinations |
| `SupportingServiceTests` | 7 | Money formatting/parsing, rounding, date math |
| `ReleaseIntegrationTests` | 7 | **Merge-only defects** — see below |
| `PlanningContractTests` | 7 | DTO money exactness, deterministic snapshots, R-08 ordering at persistence |
| `ExportCompatibilityTests` | 7 | Backup v2 round trip, v1 import through migration, append-only CSV |
| `DebtPresentationTests` | 7 | Per-type labels/icons, utilization badge, non-colour meaning |
| `DashboardStateTests` | 7 | Five-second dashboard from production data, empty/error states |
| `NotificationDiagnosticsTests` | 6 | The duplicate detector behind the debug diagnostics screen: 0.1.x leftovers, same-copy-same-moment duplicates, no false alarms |
| `TemplatePrivacyTests` | 5 | Template absent from distribution builds; the resource-less state is safe and still reaches onboarding |
| `UpgradeChecklistTests` | 5 | Migrated users never re-onboard; answering changes no baseline value |
| `OnboardingProgressTests` | 5 | Step persistence, resume, duplicate-proof finish |
| `ExportServiceTests` | 5 | JSON round trip, schema rejection, CSV escaping |
| `AvalanchePropertyTests` | 2 | Seeded-random invariants: determinism, cent reconciliation, non-negativity |

`ReleaseIntegrationTests` pins defects that existed **only in the merged tree**,
because each one's two halves arrived from different agent branches: the
presentation bridge ignoring the snapshot's `asOf`, reversed semimonthly days
normalising differently on the two bridges, missing pay days defaulting instead
of failing, the prepayment tri-state collapsing to a boolean, and the income
lookup reporting the bundled template's take-home on a generated-plan install.

## UI tests — 19, all passing

A clean install opens on Welcome and **not** inside the app (the alpha.1 device-testing
regression); clean install through onboarding to a generated plan and Today; resume after
force-quit mid-step; template load with its warning; first payday check-in end
to end; draft save and resume; card payment and authoritative balance update;
calendar day panel opening the check-in; dashboard, plan, progress and setup at
accessibility text sizes; debt detail vocabulary and the type-aware editor;
plan screen tracks and activation; notification settings without permission;
backup producing shareable files.

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
- The plan analysis (baseline + reforecast + two scenarios) runs synchronously
  on the main thread; fine at typical plan lengths, worth moving off-actor for
  very long plans.
- At the largest accessibility sizes, Today's primary action requires a scroll.
- Balance derivations fetch whole tables and filter in memory — fine at this
  scale, revisit if the app outlives Phase II.
- Calendar notes are stored as zero-amount Checking 1 adjustments (shown as
  "Note" in the ledger) and export under that type.
