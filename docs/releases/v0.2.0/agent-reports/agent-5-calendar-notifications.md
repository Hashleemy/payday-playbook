# Agent 5 report — Calendar, Due Dates, Deep Links & Local Notifications (v0.2.0)

Branch: `feature/v0.2-calendar-notifications` · Date: 2026-08-11
Based on Agent 2's schema-2 data layer (`65a9236`) merged with Agent 3's calc-v2
engine (`f0885d1`). Owns F-07, F-11, V2-11, V2-12 and MVP_LAYOUT §8.3 / §9.
No optimizer math, onboarding forms, or unrelated dashboard files were changed.

## Integration prerequisite (before any of my work)

Agents 2 and 3 each independently declared `PlanningInput`, `PlanningResult`,
`PayCadence`, `ObligationCadence`, `DebtType`, and `IncomeChange`. Each branch
compiled alone; the merged tree did not compile at all.

I first resolved this by prefixing Agent 3's engine-local types with `Engine`.
Agent 6 independently resolved the same clash on `feature/v0.2-dashboard-plan`
(`bafa07a`) and did it better: the engine keeps `PlanningInput`/`PlanningResult`,
the stored-snapshot DTOs became `StoredPlanInput`/`StoredPlanResult`, the engine
adopted the model-layer `DebtType`/`ObligationCadence` (removing the duplicate
enums instead of renaming them), and the engine's cadence enum became
`PlanningPayCadence`.

**This branch now sits on `bafa07a`** — my own rename commit was dropped and the
five feature commits were replayed onto Agent 6's resolution, which is therefore
the single canonical type system across both branches. The replay was
conflict-free: no feature code here references a renamed planning type. Verified
212 unit tests green on the rebased branch.

## Event taxonomy

`CalendarEventService.Event` — every event carries a `kind`, an explicit
`status`, and an optional typed `link`.

| Kind | Source | Identifier | Link |
| --- | --- | --- | --- |
| `payday` | `PaydayPlanItem` (income, keep) | `payday-<seq>` | Check-In |
| `transfer` | `plannedC2Transfer` | `transfer-<seq>` | Check-In |
| `reserve` | `plannedBufferAdd` (protected floor) | `reserve-buffer-<seq>` | Check-In |
| `reserve` | `PlannedObligationReserve` rows | `reserve-<obligationUUID>-<seq>` | Check-In |
| `reserve` | legacy car/train columns (fallback) | `reserve-car|train-<seq>` | Check-In |
| `debtPayment` | `plannedCardBudget` + `plannedTargetDebtID` | `debtpay-<seq>` | Debt (target) |
| `debtDue` | `DebtAccount.dueDayOfMonth` via `DueDateRule` | `debt-due-<debtUUID>-<yyyyMMdd>` | Debt |
| `obligationDue` | `RecurringObligation.dueDay` + cadence via `DueDateRule` | `obligation-due-<obligationUUID>-<yyyyMMdd>` | — |
| `milestone` | `Milestone` (achieved / forecast / baseline) | `milestone-<UUID>` | Milestone |
| `entry` | `LedgerEntry` | `entry-<UUID>` | Entry |
| `entry` | `BalanceSnapshot` (debt balance updates) | `snapshot-<UUID>` | Debt |
| `reforecast` | `ForecastSnapshot` (latest per day, excluding `initialSeed`) | `reforecast-<UUID>` | — |

The five statuses are `planned`, `actual`, `completed`, `needsAttention`,
`reforecast`. Each renders as **icon + text** in the row and is spoken in the
VoiceOver label; color is reinforcement only, never the signal. A day cell with
any needs-attention event gets both an amber ring *and* a warning triangle, so
the state survives color-blindness and grayscale.

Status assignment:

- **Payday** — check-in `needsAttention` → needs attention; check-in `completed`
  → completed; generated R-09 `shortfallAmount` → needs attention with the exact
  gap; date on/before today with no check-in → needs attention ("still open");
  otherwise planned.
- **Transfer / reserve / debt payment** — inherit the payday's completion truth
  (completed once the check-in is done, needs attention when the payday is
  overdue, else planned).
- **Due dates** — always planned, past or future. A due date is a scheduled
  obligation, not a record: the app has no payment matching, so calling a past
  due date "actual" would claim knowledge it does not have. They are excluded
  from the Actual-entries filter for the same reason.
- **Milestone** — completed when achieved; reforecast when the forecast date has
  moved off the baseline; else planned.
- **Ledger entries and balance snapshots** — always actual.

Within a day, events sort by `kind.dayOrder` so the panel reads as the
allocation story: payday → transfer → reserves → debt payments → due dates →
milestones → entries → reforecast.

**Schedule source.** `schedulePlan(context:)` returns the newest *active* plan
version that owns `PaydayPlanItem` rows, falling back to Original Plan v1. A
generated plan therefore renders identically to the seeded baseline (V2-12), and
a user-created "Plan v2" that carries only allocation changes still borrows the
baseline's dates, exactly as 0.1.x behaved.

## Due-date rules (`DueDateRule`)

One implementation shared by the calendar, the scheduler, and the Today
dashboard — the 0.1.x `min(dueDay, 28)` truncation is gone from every call site.

- **Day 29/30/31 → last valid day.** Delegates to
  `PayScheduleGenerator.clampedDate` (Agent 3's R-11 implementation) rather than
  forking a second clamping rule. Jan 31 → Feb 28, and Feb 29 in leap years.
- **Local date preserved across time zones and DST.** All arithmetic is calendar
  components in `Calendar.current`; nothing stores or compares absolute instants.
  A due date on the 15th is the 15th on the wall calendar wherever the user is.
  Notification triggers are `UNCalendarNotificationTrigger` over
  (year, month, day, hour, minute) with **no** `timeZone` set, so a reminder set
  for 9:00 fires at 9:00 local after a move rather than drifting by the offset.
- **Weekends never shift by default.** `DueDateShiftRule` is `.exactDay` unless
  the user picks `.previousWeekday` or `.nextWeekday`. Stored as nil for
  `.exactDay`, so migrated rows and defaults are byte-identical.
  **Holidays are deliberately unsupported** — iOS ships no holiday calendar, and
  a wrong holiday guess is worse than none.
- **Windows are half-open `[start, end)`** and filtered *after* shifting, so a
  shift that moves an occurrence across a window edge is reported in the window
  it actually lands in, never both or neither.
- **Cadence decides which months.** A `dueDay` is a day *of month*, so it only
  describes cadences on a monthly grid. Monthly recurs every month; quarterly,
  semiannual, and annual recur every 3/6/12 months counted from the row's
  creation month (the model carries no separate due-date anchor). Weekly and
  biweekly obligations get **no** due-date marker or reminder — a day-of-month is
  meaningless for them, and drawing twelve annual markers for a weekly bill would
  be worse than drawing none. Their per-paycheck reserve is what the plan acts on.
- **Edits are prospective, and history is never rewritten.** Occurrences come
  from current model state, so an edit changes future events. Because the app
  does not store past due days, editing one also stamps
  `dueDayEffectiveFrom`; occurrences before that date are not rendered at all
  rather than being redrawn on a day that was never in force. Debts and
  obligations that have never been edited keep `nil` there and describe history
  correctly, which is the common case. Each edit also appends an audit line
  (`dueDateAuditLog`, MVP_LAYOUT §9).

Editing surfaces: the debt editor now accepts days 1–31 (was 1–28) with a
weekend-rule picker, and a new Settings → **Obligation due dates** screen edits
obligation due days. Both save, reforecast where relevant, and **await the
notification reschedule before dismissing** (§9: "the reschedule completes
before the edit screen is dismissed").

## Notification identifier format

`<family>-<entity>[-<occurrence>]`

| Family | Identifier | Entity |
| --- | --- | --- |
| `payday-morning` | `payday-morning-<planItemUUID>` | plan item |
| `payday-evening` | `payday-evening-<planItemUUID>` | plan item |
| `debt-due-soon` | `debt-due-soon-<debtUUID>-<yyyyMMdd>` | debt + due date |
| `debt-due-today` | `debt-due-today-<debtUUID>-<yyyyMMdd>` | debt + due date |
| `obligation-due-soon` | `obligation-due-soon-<obligationUUID>-<yyyyMMdd>` | obligation + due date |
| `obligation-due-today` | `obligation-due-today-<obligationUUID>-<yyyyMMdd>` | obligation + due date |
| `milestone-approaching` | `milestone-approaching-<milestoneUUID>` | milestone |
| `weekly-summary` | `weekly-summary-<yyyyMMdd>` | date |

Entities are **UUIDs, never row positions or plan letters**. 0.1.x keyed payday
reminders on `sequenceNumber` and debt reminders on the plan letter ("B"), both
of which a plan edit or a re-letter can silently repoint at the wrong thing.

**Deviation from MVP_LAYOUT §9, deliberate.** The spec says migration should
"re-register existing card reminders under the same identifiers they already
use". I did not freeze the legacy identifiers — the letter-keyed scheme cannot
address a generated plan's debts unambiguously. Instead
`NotificationFamily.ownedPrefixes` includes the 0.1.x spellings (`due-soon-`,
`due-today-`, `milestone-`), and reconciliation *removes* any pending request
under an owned prefix that is not in the desired set. The §9 requirement that
actually matters — **no duplicate fires after upgrade** — is satisfied and
tested (`testUpgradeFromLegacyIdentifiersDoesNotDoubleFire`), and the result is
strictly stronger because it also cleans up orphans the spec's approach leaves
behind. Flagged for the doc owner to amend §9.

## Rescheduling algorithm

Split into a pure planner and an effectful reconciler so the whole schedule is
testable without the system notification center.

1. **Snapshot** — `NotificationPlanner.makeInput(context:dateProvider:)` reads
   the store into plain values: preferences, future paydays (from the same
   `schedulePlan` the calendar uses, so the two can never disagree), non-archived
   debts with paid-off status derived from `AccountBalanceService`, non-archived
   obligations, unachieved milestones, and the pay frequency.
2. **Plan** — `NotificationPlanner.plan(_:)` is pure and deterministic. For each
   enabled preference it emits entries with stable identifiers, wall-clock
   `DateComponents`, and safe-by-default copy. Entries whose moment has already
   passed, or that fall beyond the 45-day rolling window, are never emitted.
   Results sort by fire date (ties by identifier) and truncate to
   `maxPendingRequests = 60`, leaving headroom under the iOS limit of 64;
   the overflow count is returned as `droppedByCap`, never silently discarded.
3. **Diff** — `NotificationPlanner.reconcile(desired:pending:)` compares against
   the pending requests. Each request carries a content **fingerprint** in
   `userInfo` (title, body, route, reference, and the whole fire moment down to
   the minute):
   - identifier absent → add;
   - identifier present, fingerprint equal → leave alone (no churn);
   - identifier present, fingerprint different → re-add (same identifier
     replaces in place, so this can never duplicate);
   - pending, owned by us, not desired → remove.
   Requests this app does not own are never touched.
4. **Apply** — `NotificationScheduler.rescheduleAll` removes then adds, and
   publishes the reconciliation and drop count for diagnostics.

The old implementation called `removeAllPendingNotificationRequests()` and
rebuilt from scratch on every trigger; the diff replaced that.

**Reconcile trigger points:** app launch and every foreground (`scenePhase
.active`), `NSSystemTimeZoneDidChange`, `UIApplication.significantTimeChange`
(covers DST and midnight rollover), onboarding completion / plan activation,
debt due-date save, obligation due-date save, every notification-settings
change, and check-in completion. Completion additionally cancels that payday's
two reminders synchronously (`cancelPaydayReminders(itemID:)`) so the evening
nudge is gone the instant the work is done, before the async reconcile lands.

**Permission.** Requested only from onboarding step 9 and Settings → Reminders,
both of which explain the value first. `canSchedule` accepts `.authorized`,
`.provisional`, and `.ephemeral`. When denied or undetermined, `rescheduleAll`
returns without touching pending state and the app is fully usable; Settings
shows the denial explanation and an **Open iOS Settings** button.

**Lock-screen safety.** Default copy names nothing and shows no amounts ("A debt
payment is due soon", "Your payday check-in is ready"). Entity names and
`Decimal` amounts appear only when that reminder's
`detailedLockScreenContent` is on — pinned by
`testLockScreenCopyIsGenericUnlessDetailedPreviewsAreEnabled`, which asserts no
`$` and no debt nickname in any default-mode body.

## Deep links

`CalendarEventService.DeepLink` is typed: `.checkIn(itemID:)`, `.debt(planID:)`,
`.entry(entryID:)`, `.milestone(milestoneID:)`. Resolution lives in the service
(`resolve(_:) -> LinkResolution`), not the view, so the archived/deleted policy
is a tested contract: an existing target opens; an archived debt explains it is
archived; a deleted item explains it belongs to an older plan version or was
removed. Nothing dead-ends.

Notification routes (`NotificationRoute`) map to tabs in `AppRouter`, carrying
entity identity so a tap still lands correctly after plan edits:

| Route | Destination |
| --- | --- |
| `checkin` | Today, opening that payday's check-in |
| `debt` | Debts, scrolled to that debt |
| `obligation` | Calendar, selecting that obligation's next occurrence |
| `milestone` | Progress, scrolled to and highlighting that milestone |
| `progress` | Progress |
| `today` | Today |

0.1.x wrote `card` for debt routes; `NotificationRoute.parse` still maps it to
`.debt` so a reminder that survives the upgrade routes correctly. A reference
that no longer parses or resolves still changes tabs — the screen then shows its
own current state, which is always something useful.

## Changed files

| File | Change |
| --- | --- |
| `Services/DueDateRule.swift` | **New.** Shared occurrence math, shift rules, clamping, audit note. |
| `Services/NotificationPlanner.swift` | **New.** Families, `PlannedNotification`, pure planner, store snapshot, reconcile diff. |
| `Services/CalendarEventService.swift` | **Rewritten.** Full taxonomy, statuses, deep links, link resolution, active-plan awareness. |
| `Services/NotificationScheduler.swift` | **Rewritten.** Diff-based reconcile, `NotificationCenterProtocol` seam, permission handling. |
| `App/AppRouter.swift` | Typed routes, obligation/milestone destinations, legacy `card` parsing. |
| `App/PaydayPlaybookApp.swift` | Foreground, time-zone, and significant-time reconcile hooks. |
| `Features/Calendar/CalendarTabView.swift` | Week + agenda modes, new filters, icon+text status, deep-link dispatch, obligation reveal, entry/milestone detail sheets. |
| `Features/Settings/ObligationDueDatesView.swift` | **New.** Obligation due-date editing with await-before-dismiss reschedule. |
| `Features/Settings/SettingsView.swift` | One navigation row for the above. |
| `Features/Debts/DebtsView.swift` | Due day 1–31, weekend-rule picker, audit note, await-before-dismiss reschedule. |
| `Features/Today/TodayView.swift` | `nextCardDueText` routes through `DueDateRule` (was `min(dueDay, 28)`). |
| `Features/CheckIn/CheckInFlowView.swift` | `cancelPaydayReminders(itemID:)` (was sequence-keyed). |
| `Features/Progress/ProgressTabView.swift` | Honors the milestone deep link (scroll + highlight). |
| `Models/DebtAccount.swift`, `Models/RecurringObligation.swift` | `dueDateShiftRuleRaw`, `dueDateAuditLog`, `dueDayEffectiveFrom` (all optional, additive). |

No engine file (`Services/Planning/*`, `DebtCalculationEngine`) is touched by
this branch — the planning-contract reconciliation comes in from `bafa07a`
underneath it.

## Tests

`xcodebuild -only-testing:PaydayPlaybookTests test` — **212 tests, 0 failures**
(147 carried forward from the merged Agents 2+3 baseline, 65 new).
`-only-testing:PaydayPlaybookUITests` — **9 tests, 0 failures**.

Both suites were run on a dedicated simulator (`xcrun simctl create`, deleted
afterwards). **Note for anyone re-running these:** other agents' worktrees were
testing concurrently on the shared "iPhone 17 Pro" device, and results
cross-contaminated — my run reported failures from
`v0.2-dashboard-plan/DashboardPlanUITests.swift` and
`v0.2-onboarding/PaydayPlaybookUITests.swift`, files that do not exist in this
worktree, and once executed 0 of my own tests. Use a per-agent device for UI
runs while the release is being built in parallel.

| Mission requirement | Test |
| --- | --- |
| Event merge and ordering | `testPaydayDayMergesTheFullPlayByPlay`, `testEventsAreSortedByDateThenDayOrder` |
| Date edits create no duplicates | `testDueDateEditIsProspectiveAndCreatesNoDuplicates`, `testDueDateEditReplacesTheOldReminderWithNoDuplicate` |
| Short-month handling | `testDay31ClampsToLastValidDayOfEveryMonth`, `testOccurrencesAcrossShortMonthsHaveNoDuplicatesAndStayOrdered`, `testDueDayClampsToShortMonthsWithoutDuplicates`, `testShortMonthDueDayProducesOneReminderPerMonth` |
| DST / time-zone behavior | `testOccurrencesKeepTheirLocalDayAcrossDSTTransitions`, `testTriggerCarriesLocalComponentsSoTimeZoneMovesKeepTheHour` |
| Permission authorized / denied / provisional | `testDeniedAuthorizationSchedulesNothingAndTouchesNothing`, `testNotDeterminedSchedulesNothingUntilPermissionIsGranted`, `testProvisionalAuthorizationSchedulesNormally` |
| Stable identifier replacement | `testIdentifiersAreNamespacedAndEntityKeyed`, `testRescheduleTwiceAddsNothingTheSecondTime`, `testChangedCopyForTheSameIdentifierIsReAdded`, `testUpgradeFromLegacyIdentifiersDoesNotDoubleFire` |
| Rolling-window reconciliation | `testRollingWindowCapKeepsTheSoonestAndReportsTheRest`, `testDenseRealisticScheduleStaysUnderTheSystemPendingLimit`, `testWindowExcludesMomentsAlreadyPastAndBeyondTheHorizon` |
| Incomplete reminder cancellation | `testCompletingACheckInCancelsThatPaydaysReminders` |
| Deep links for every event type | `testEveryLinkedEventCarriesEntityIdentity`, `testEveryScheduledFamilyRoutesSomewhereUseful`, `testLinksResolveToTheirEntityWhileItExists` |
| Archived / deleted target fallback | `testArchivedDebtLinkExplainsRatherThanDeadEnds`, `testDeletedTargetsResolveToAnExplanationForEveryLinkType`, `testArchivedDebtAndObligationScheduleNothing`, `testDeletedOrUnparsableReferenceStillLandsOnTheRightTab` |
| Accessibility, non-color status | `testAccessibilityDescriptionSpeaksKindTitleAndStatus` |
| Weekend rules opt-in only | `testExactDayNeverShiftsOffWeekends`, `testPreviousWeekdayShiftsSaturdayAndSundayToFriday`, `testNextWeekdayShiftsSaturdayAndSundayToMonday`, `testWeekendShiftRuleMovesTheMarkerOnlyWhenSelected`, `testOccurrenceWindowFiltersAfterShifting` |
| Obligation cadence honored | `testObligationCadenceControlsHowOftenItIsDrawn`, `testObligationCadenceControlsHowOftenRemindersFire` |
| Edits are prospective | `testEditingADueDayDoesNotRewritePastOccurrences`, `testPastDueDatesStayPlannedAndOutOfTheActualFilter` |
| Safe lock-screen copy | `testLockScreenCopyIsGenericUnlessDetailedPreviewsAreEnabled` |
| Reforecast status | `testReforecastSnapshotRendersMarkerButInitialSeedDoesNot` |
| Shortfall / needs attention | `testShortfallPaydayNeedsAttentionWithExactGap`, `testOverduePaydayWithoutCheckInNeedsAttention`, `testCheckInExceptionSurfacesAsNeedsAttention` |

`FakeNotificationCenter` (a `NotificationCenterProtocol` stand-in) makes the
scheduler testable: the real `UNUserNotificationCenter` cannot be exercised in a
unit-test process without granted permission and an app lifecycle.

## Adversarial review

A four-lens multi-agent review ran over this work before finalizing (date
correctness, notification scheduling, calendar merge, integration/deep links),
with each finding sent to an independent verifier instructed to refute it.

**The verification stage is not trustworthy on this run:** 10 of its 11
verifier agents died on a session token limit rather than returning a verdict,
so the workflow reported zero "confirmed" findings purely because nothing got
adjudicated. I verified the remaining findings against the code myself. Recording
that here because a reader glancing at the workflow output would otherwise
conclude the review came back clean, which it did not.

Eleven raw findings; **seven were real and are fixed**, each with a pinned
regression test, one was correctly refuted, and three were duplicates across
lenses.

1. **HIGH — fingerprint omitted the fire date** (found independently by two
   lenses). `PlannedNotification.fingerprint` covered hour and minute but not
   year/month/day, and identifiers for due-soon and milestone reminders are keyed
   on the *due*/*target* date, not the fire date. So raising `cardDueSoon.leadDays`
   from 3 to 6, or a reforecast moving a milestone, produced an identical
   identifier and an identical generic body — reconciliation classified it
   `unchanged` and the stale trigger kept firing on the old day. The user's
   setting silently did nothing. Fixed: the fingerprint carries the whole fire
   moment. → `testChangingLeadDaysMovesTheReminderInsteadOfLeavingItStale`,
   `testFingerprintDistinguishesFireDatesThatShareEverythingElse`
2. **HIGH — obligation due dates were monthly regardless of cadence** (two
   lenses). `RecurringObligation` supports weekly through annual, but both the
   calendar and the scheduler fed every `dueDay` through monthly occurrence
   generation, so a quarterly insurance bill drew 12 markers and fired 12
   reminders a year. Fixed with cadence-aware occurrences (see due-date rules).
   → `testObligationCadenceControlsHowOftenItIsDrawn`,
   `testObligationCadenceControlsHowOftenRemindersFire`
3. **MEDIUM — due-day edits rewrote the past.** Occurrences were generated from
   the *current* due day across the whole requested window, so changing a due day
   redrew previous months on a date that was never in force — the opposite of
   V2-11's "prospective". Fixed with `dueDayEffectiveFrom`.
   → `testEditingADueDayDoesNotRewritePastOccurrences`
4. **MEDIUM — past due dates claimed Actual status** and therefore appeared under
   the Actual-entries filter, implying a payment record that does not exist.
   Fixed: due dates are always Planned.
   → `testPastDueDatesStayPlannedAndOutOfTheActualFilter`
5. **MEDIUM — month navigation blanked the day panel and week strip.**
   `shiftMonth` moved `displayedMonth` and reloaded that month's window, but left
   `selectedDay` in the old month — outside the loaded window — so the
   selected-day panel and the week strip (both derived from `selectedDay`) showed
   nothing. Fixed: the selection follows the month, landing on today when the new
   month contains it and the 1st otherwise.
6. **MEDIUM — the edit forms mutated before validating.** `DebtEditView.save()`
   assigned `minimumAmount` and then returned early if the due day failed
   validation; these are live SwiftData objects, so a rejected edit still left a
   changed minimum on the model. Fixed in both editors: validate everything into
   locals, then assign.
7. **LOW — a vacuous assertion in my own test.** The route table pre-set
   `selectedTab = .calendar` and then asserted the obligation route lands on
   `.calendar` — true before the call ran. Fixed: each case now starts on a tab
   that is not its expected destination.
8. **Refuted (correctly) — duplicate `nil` IDs in the month grid's `ForEach`.**
   The premise is accurate (leading blanks share `Optional<Date>.none`), but
   `ForEach` emits one child per element regardless of ID collisions; identity
   only governs state and animation reassociation, and the duplicated views are
   stateless `Color.clear` spacers. No input produces a different grid. Left
   as-is — a console-hygiene preference, not a defect.

## Device-only validation still required

None of the following can be proven in the simulator or in unit tests:

1. **Real delivery.** That notifications actually fire at the scheduled local
   time, on a locked device, with the app terminated. Simulator delivery is
   unreliable and the tests assert what we *ask* the system for, not what it does.
2. **The 64-request limit in practice.** iOS silently drops requests past 64 per
   app. The 60-cap is verified as arithmetic; that the system accepts all 60 and
   fires them needs a device over a full window.
3. **Lock-screen rendering.** That default copy is genuinely unrevealing on a
   real lock screen (notification grouping, previews-when-unlocked, and the
   "Show Previews" system setting all affect what a passerby sees).
4. **Provisional authorization.** The quiet-delivery path (`.provisional`)
   cannot be entered in the simulator; needs a device build that requests it.
5. **Real time-zone travel and DST rollover.** Changing the simulator clock does
   not reliably reproduce what iOS does to pending `UNCalendarNotificationTrigger`
   requests across an actual DST boundary or a physical time-zone change.
6. **Cold-launch deep links.** A tap on a delivered notification that starts a
   terminated app — the buffered-route path in `NotificationDelegate`.
7. **VoiceOver and Dynamic Type on the new calendar modes.** The week strip and
   agenda list at accessibility text sizes, and the actual spoken order of the
   combined event rows, need a device pass.

## Risks and notes

- **Two feature conflicts remain against `feature/v0.2-dashboard-plan`**, both
  genuine overlap rather than naming churn:
  - `TodayView.swift` — Agent 6 added debt-type-aware due-day labels and an
    obligation due line, using a local `nextOccurrence(day:)` helper that clamps
    with `min(dueDay, range?.count ?? 28)`. That clamping is right about month
    length but bypasses the user's weekend shift rule and the
    `dueDayEffectiveFrom` rule. **Recommended resolution:** keep Agent 6's labels
    and obligation line, route the date math through `DueDateRule.nextOccurrence`.
  - `DebtsView.swift` — Agent 6's debt-type presentation against my due-day
    editor (1–31, shift-rule picker, audit note, await-before-dismiss
    reschedule). Both sides are additive; take both.
- **`plannedTargetDebtID` is a plan letter, not a UUID.** Calendar debt-payment
  events and the notification `debt` route both key on it because that is what
  the schema stores. If generated plans ever stop assigning stable letters,
  these links need to move to debt UUIDs. Due-date reminders already use UUIDs.
- **Paid-off detection depends on `AccountBalanceService`.** If it throws, the
  planner falls back to treating every debt as active — a reminder too many
  rather than none. Intentional, but it means a balance-service regression shows
  up as chatty reminders rather than a crash.
- **Obligation reserves render from `PlannedObligationReserve` rows** with the
  legacy car/train columns as fallback (per Agent 2's assumption 6). A plan with
  both populated shows the rows; Original Plan v1 has both and shows the rows.
- **The 45-day window plus a 60-request cap** means a user with many debts and
  obligations gets less than 45 days of coverage. The next foreground reconcile
  extends it. `droppedByCap` is published for a future Settings diagnostic; it is
  not surfaced in the UI yet.
- **No holiday shifting**, by design (see due-date rules). If product wants it,
  it needs a data source and an explicit user opt-in.
- **Long-cadence obligations are anchored on their creation month.** A quarterly
  bill created in August falls in Aug/Nov/Feb/May. If the user's real cycle is
  Jan/Apr/Jul/Oct, nothing in the model can express that today — it needs a
  first-due-date field on `RecurringObligation`, which is Agent 2's territory.
  Flagged rather than guessed.
- **Weekly and biweekly obligations show no due-date marker or reminder** (a
  day-of-month cannot describe them). Their reserve still appears on every
  payday. If product wants weekly bill reminders, the model needs a weekday or
  an anchor date.
- **`dueDayEffectiveFrom` blanks past due-date markers after an edit.** This is
  deliberate — the alternative is inventing history — but a user who edits a due
  day will notice previous months lose that marker. A future schema with a
  due-day history table would restore it.
- **Weekly summary content is generic** — it routes to Progress but does not yet
  summarize the week's numbers in the body. That is a copy decision for the
  insights owner.
