# Agent 5 — Due Dates, Calendar, and Local Notifications report (v0.3.0)

- **Role:** Due-date editing integration, calendar events, notification reconciliation (V3-07, V3-13; MVP_LAYOUT §9).
- **Branch:** `feature/v0.3-calendar-reminders`, based on Agent 2's `6029107` (schema 3 + privacy scrub), which is itself based on Agent 1's contract.
- **Date:** 2026-08-15.
- **Scope discipline:** no payoff math, no scenario engine, no report or backup code, no migration outside the due-rule adapters. Plan/calendar-ready state is consumed through the existing shared contracts only.

This report contains no personal financial values, by design (V3-12/V3-13).

## Outcome

The v0.2.0 machinery was already close to the contract: prospective edits, UUID-keyed identifiers, prefix-owned reconciliation, fingerprint diffing, a 45-day/60-request window, and no-op behavior under denied permission were all present and tested. The work here was verification plus five concrete defects, one shared editor, and 27 tests that pin the behaviors the mission names.

**Defects found and fixed**

1. **A weekend-rule change was retroactive.** Both v0.2.0 editors stamped `dueDayEffectiveFrom` only when the *day number* changed. Switching the weekend rule therefore re-rendered every already-drawn past occurrence up to two days off — completed history moved. Now a change to *either* half of the rule is prospective and audited. Regression: `testWeekendRuleChangeDoesNotMovePastMarkers` (verified to fail against the old rule — see "Mutation check").
2. **Bill-due calendar markers dead-ended.** `obligationDue` events carried `link: nil`, so the one row type that looked tappable did nothing, while the matching *reminder* deep-linked fine. Bills now carry `.obligation(obligationID:)` end to end.
3. **Debt deep links keyed on a reusable plan letter.** `SetupRepositories.nextPlanID()` hands out the lowest free slot, so deleting `D1` and adding a debt reuses the letter. A notification already delivered — or a calendar row already rendered — could open a debt the user never tapped. Routes and links now carry the debt's `UUID`; the letter survives as a documented fallback for pre-upgrade reminders and for plan-item avalanche targets, which genuinely have no UUID.
4. **A missing bill failed silently.** `revealObligation` returned early for an archived or deleted bill, so the tap appeared to do nothing. It now resolves through the same path a tapped row uses and shows the same calm explanation.
5. **Permission grants waited for the next foreground.** Granting in Settings or in onboarding step 8 did not reconcile at the grant; the schedule appeared only after a background/foreground cycle. `requestAuthorizationAndReconcile` closes it.

**Hardening, not defects**

- Reconciliation trigger points are now a named enum rather than a comment, and every call site passes one. `lastTrigger`/`lastSkipReason` make "which triggers have actually run, and why did that pass schedule nothing" answerable on device instead of inferable.
- One shared `DueRuleEditorView` replaces the per-screen forms; `DueRuleEditService` is the single mutation path. This is the file Agent 4 embeds (see Handoff).

## Event taxonomy

`CalendarEventService.EventKind` is unchanged from v0.2.0 — the taxonomy was already right, and churning it would break V2-12 parity for no gain. Recorded here as the contract this agent is accountable for:

| Kind | Source | Status semantics | Deep link |
| --- | --- | --- | --- |
| `payday` | `PaydayPlanItem` | `completed`/`needsAttention` from the check-in; `needsAttention` for an R-09 shortfall or an overdue open check-in; else `planned` | `.checkIn(itemID:)` |
| `transfer`, `reserve`, `debtPayment` | plan item + `PlannedObligationReserve` | inherits the payday's truth state | `.checkIn(itemID:)`; `debtPayment` → `.debt(debtID:planID:)` when a target exists |
| `debtDue` | `DebtAccount.dueRule`, prospective from `dueDayEffectiveFrom` | always `planned` — the app has no payment matching, so calling a past due date "actual" would claim knowledge it does not have | `.debt(debtID:planID:)` |
| `obligationDue` | `RecurringObligation.dueRule` + cadence | always `planned` | `.obligation(obligationID:)` **(new)** |
| `milestone` | `Milestone` | `completed` when achieved, `reforecast` when moved, else `planned` | `.milestone(milestoneID:)` |
| `entry` | `LedgerEntry`, debt `BalanceSnapshot` | `actual` | `.entry(entryID:)` / `.debt(planID:)` |
| `reforecast` | `ForecastSnapshot` (initial seed excluded) | `reforecast` | none |

Two properties matter for V3-07 and are tested:

- **Future-only rebuild.** Due-date rows are derived from the *current* rule, clipped at `effectiveWindowStart`, so months before the last edit are left blank rather than redrawn under a rule that was not in force then. Everything else (plan items, check-ins, ledger entries, snapshots, forecasts) is stored history and is not recomputed at all.
- **Status never depends on color.** Each event carries icon + text and an `accessibilityDescription` that speaks kind, title, and status.

## Identifier scheme

Format `<family>-<entity>[-<occurrence>]`, unchanged in shape from v0.2.0 and now pinned structurally by test.

- **family** — one of eight fixed slugs (`payday-morning`, `payday-evening`, `debt-due-soon`, `debt-due-today`, `obligation-due-soon`, `obligation-due-today`, `milestone-approaching`, `weekly-summary`).
- **entity** — a `UUID` string; for the weekly summary, a `yyyyMMdd` day key (there is no entity to key on).
- **occurrence** — `yyyyMMdd` of the **due** date for date-recurring families, absent otherwise. Note the due date, not the fire date: a due-soon reminder for the 20th fires on the 17th but is named for the 20th, so changing the lead time moves the trigger without renaming the request.

Privacy (V3-13): no amount, no user-entered label, no plan letter appears in an identifier, in `userInfo`, or in default copy. `testNoIdentifierCarriesALabelOrAnAmount` asserts the *shape* (family + UUID/day-key + optional 8-digit key) rather than scanning for digit substrings — a UUID is hex, so substring scanning is both noisy and meaningless. `testDefaultCopyCarriesNoFinancialPayloadForAnyFamily` asserts no default title or body contains any figure or currency symbol at all, and that `detailedLockScreenContent` is off in every seeded default.

The `userInfo` payload is exactly three keys: `route`, `reference` (an entity UUID string, or empty for tab-level routes), and `fingerprint`.

**Legacy prefixes.** `NotificationFamily.ownedPrefixes` also claims the 0.1.x spellings (`due-soon-`, `due-today-`, `milestone-`), so an upgrade removes old requests instead of firing both. Requests the app does not own are never touched.

## Reconciliation algorithm

One pass, `NotificationScheduler.rescheduleAll(context:dateProvider:trigger:)`:

1. Read the authorization status. Not authorized → record `SkipReason.notAuthorized`, schedule nothing, **touch nothing pending**, return. The app stays fully usable; the calendar is the surface that needs no permission.
2. Snapshot the store into `NotificationScheduleInput` (plain values — no SwiftData types cross into the planner).
3. `NotificationPlanner.plan` — a pure function — builds the desired set over a rolling 45-day window, drops moments already past, sorts soonest-first, and truncates at 60 requests (under the iOS 64 cap, with headroom), reporting the truncated count rather than dropping it silently.
4. Read pending requests, each with its stored fingerprint.
5. Diff: a desired entry whose identifier is pending **with an equal fingerprint** is left alone; anything else is (re-)added. A pending identifier this app owns and no longer wants is cancelled.
6. Apply removals, then additions. Record the reconciliation, the cap overflow, and the trigger.

**Why it is idempotent.** Step 3 is a pure function of the store and the clock; identifiers are stable; the diff is taken against reality rather than against a remembered intent. A second pass with nothing changed produces an empty add list and an empty remove list. `testRepeatedReconciliationIsIdempotentAcrossEveryTrigger` runs a settled schedule through **all eleven** triggers and asserts the pending set, the add count, and the remove count are all unchanged each time.

**The fingerprint** is `title|body|route|reference|yyyyMMddThhmm`. It includes the whole fire moment, not just the time of day, so a reminder whose identifier is unchanged but whose date moved (a raised lead time, a reforecast moving a milestone) is rewritten rather than left firing on the old trigger.

**Trigger points** (`ReconcileTrigger`, all wired):

| Trigger | Where |
| --- | --- |
| `launch` | first `scenePhase == .active` of a session — which is also the pass after `MigrationService` runs in `App.init` |
| `foreground` | every later `.active` — the catch-all that self-heals anything a screen forgot |
| `permissionChange` | Settings "Enable notifications", onboarding step 8 |
| `dueDateEdit` | the shared due-rule editor, and the debt detail editor |
| `planActivation` | `PlanActivationView`, end of onboarding |
| `checkInCompleted` | check-in completion (plus an immediate targeted cancel of that payday's two reminders) |
| `timeZoneChange` | `NSSystemTimeZoneDidChange` and `UIApplication.significantTimeChangeNotification` |
| `appSettingsChange` | any reminder preference edit |
| `manualDiagnostics` | the DEBUG diagnostics screen |
| `migration`, `archiveOrPayoff` | named for callers; `migration` is covered by the launch pass today, and `archiveOrPayoff` is the name Agent 4 should pass from the consolidated setup's archive action (foreground covers it either way) |

**Failure posture.** If the store snapshot throws, the pass records `SkipReason.scheduleUnavailable` and leaves the existing schedule standing. Cancelling on a read failure would be the worst outcome — a transient store hiccup would silently disarm every reminder.

## Edge cases

| Case | Behavior | Where proven |
| --- | --- | --- |
| Nonexistent month day (29–31) | clamped to the month's last valid day by the single R-11 implementation (`PayScheduleGenerator.clampedDate`); disclosed in the editor with the actual next clamped date, and on the calendar row | `testClampDisclosureNamesTheNextShortMonthAndStaysSilentBelow29`, `testEveryDayAndShiftRuleProducesUniqueOrderedMonthlyOccurrences` |
| Leap years | Feb 29 is a real day in a leap year and clamps to the 28th otherwise; one reminder per month either way | `testLeapYearFebruaryKeepsDay29AndNonLeapClampsToThe28th` |
| Semimonthly | pay dates come from the plan's own items, so reminders inherit the generator's clamping and its collision rule (30 & 31 collapse to one February payday) | `testSemimonthlyPaydayRemindersKeepTheirLocalDay` |
| Time zones | triggers are wall-clock `DateComponents`, never absolute instants. Planning the same store under `America/Los_Angeles` and `Pacific/Auckland` yields identical day and hour | `testTimeZoneMoveKeepsTheIntendedLocalFinancialDayAndHour` |
| DST | same mechanism; occurrence math is component-based across spring-forward and fall-back | `DueDateRuleTests.testOccurrencesKeepTheirLocalDayAcrossDSTTransitions` (v0.2.0, still green) |
| Weekend shifting | opt-in only (`exactDay` default); never silently moves a date. Holiday shifting is deliberately unsupported — iOS has no holiday calendar and a wrong guess is worse than none | `testEveryDayAndShiftRuleProducesUniqueOrderedMonthlyOccurrences` |
| Denied permission | nothing scheduled, nothing pending touched, reason recorded; the calendar still renders every due date; the editor says so instead of letting the user think the edit failed | `testDeniedPermissionSchedulesNothingRecordsWhyAndLeavesTheAppUsable` |
| Granted later | the first authorized pass removes stale requests left from before and installs exactly the desired set | `testGrantingPermissionLaterConvergesToExactlyTheDesiredSet` |
| Notification limit | 60-request cap under the iOS 64 limit; soonest-first, overflow counted and surfaced | `testTheCapKeepsTheSoonestRemindersAndNeverExceedsTheSystemLimit` |
| Archived / paid off | an archived bill and a debt at zero both stop reminding on the next pass | `testArchivingABillAndPayingOffADebtCancelTheirReminders` |
| Deleted entity | prefix-owned cleanup removes the orphan | `testDeletingAnEntityLeavesNoOrphanRequests` |
| Deep-link recovery | archived, deleted, and reused-letter targets all resolve to an explanation, never a dead tap or a wrong row | `testArchivedAndDeletedBillsExplainInsteadOfDeadEnding`, `testAReusedPlanLetterCannotRedirectALinkToAnotherDebt` |

## Tests

**New:** `PaydayPlaybookTests/CalendarRemindersHardeningTests.swift` — 27 tests, grouped as due-rule editing (7), calendar future-vs-history (3), deep links (3), reconciliation (4), permission states (2), privacy (3), date edge cases (4), rolling window (1).

Mission checklist coverage:

| Required test | Test |
| --- | --- |
| due-date edit updates future calendar rows immediately | `testDueDateEditUpdatesFutureCalendarRowsImmediately` |
| historical/completed events do not move | `testHistoricalMarkersAndCompletedWorkDoNotMoveWhenTheRuleChanges`, `testWeekendRuleChangeDoesNotMovePastMarkers` |
| old pending requests removed, exactly one correct replacement | `testDueDateEditRemovesOldRequestsAndLeavesExactlyOneReplacement` |
| repeated reconciliation is idempotent | `testRepeatedReconciliationIsIdempotentAcrossEveryTrigger` |
| month-end and time-zone cases keep the intended local financial day | `testLeapYearFebruaryKeepsDay29AndNonLeapClampsToThe28th`, `testTimeZoneMoveKeepsTheIntendedLocalFinancialDayAndHour`, `testSemimonthlyPaydayRemindersKeepTheirLocalDay` |
| archived/paid items cancel reminders | `testArchivingABillAndPayingOffADebtCancelTheirReminders` |
| deep links handle missing entities gracefully | `testArchivedAndDeletedBillsExplainInsteadOfDeadEnding`, `testAReusedPlanLetterCannotRedirectALinkToAnotherDebt` |
| identifiers/content reveal no financial payload by default | `testNoIdentifierCarriesALabelOrAnAmount`, `testDefaultCopyCarriesNoFinancialPayloadForAnyFamily`, `testDebtReminderReferenceIsEntityIdentityNotAPlanLetter` |

**Updated:** `CalendarEventServiceTests` — two deep-link assertions updated for the entity-carrying `DeepLink.debt(debtID:planID:)`, plus a new assertion that a legacy letter-only link still resolves and comes back carrying the entity it found.

**Mutation check.** Because a hardening suite that passes on the first run proves nothing, the shift-rule fix was reverted to the old "stamp only when the day changes" rule and the suite re-run: `testWeekendRuleChangeAloneIsAlsoProspectiveAndAudited` and `testWeekendRuleChangeDoesNotMovePastMarkers` both failed, the latter showing a real July 5 → July 6 movement of an already-drawn past marker. The fix was restored and the suite is green. That run also exposed a flaw in my own first draft of `testNoIdentifierCarriesALabelOrAnAmount` — it scanned identifiers for the digit substring "137", which a randomly generated UUID happened to contain — so the assertion was rewritten structurally.

**Commands** (dedicated simulator `PP-Agent5` and a `-derivedDataPath` outside `~/Documents`, both per TESTING.md and Agent 1's note):

```bash
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,id=<PP-Agent5>' \
  -derivedDataPath "$JOB_TMP/dd-agent5" \
  -only-testing:PaydayPlaybookTests test
```

**Result: 338 unit tests, 0 failures** (311 inherited from Agent 2's branch + 27 new). UI suite: run separately and serially — result recorded in the commit message.

## Device-only validation

None of the following can be asserted in the simulator; they are the device checklist, not claims:

1. **Delivery on the trigger.** A due-today reminder actually fires at the configured local time on the configured day.
2. **Lock-screen copy.** With detail off (the default), the lock screen shows only the generic line — no name, no amount — including under a Face ID "hide previews" setting. With detail on for one reminder kind, only that kind shows detail.
3. **Time-zone move.** Schedule a reminder, fly the device zone forward and back (Settings → General → Date & Time), confirm the reminder still fires on the intended local day at the intended local hour and that no duplicate appears.
4. **DST transition.** Same check across a spring-forward and a fall-back boundary.
5. **Permission revocation and re-grant.** Revoke in iOS Settings, use the app (it must stay fully usable), re-grant, and confirm the pending set converges to exactly the current schedule with no stale entry firing.
6. **Duplicate hunt after an edit.** Edit a due date, then read the DEBUG diagnostics screen's pending snapshot: exactly one request per family per occurrence, no legacy identifier left beside its replacement. A stale trigger is indistinguishable from a correct one until it fires, which is why this is a diagnostics read rather than a wait.
7. **Cold-start deep link.** Tap a delivered reminder with the app terminated; confirm it lands on the right debt/bill/check-in, and that a reminder for an entity deleted in the meantime lands with an explanation rather than a blank screen.
8. **Notification budget.** With a dense store, confirm iOS holds all requested pending items (the cap keeps us under 64) and that the diagnostics screen reports any window overflow honestly.

Items 1–7 of the inherited v0.2.0 device checklist remain unvalidated on hardware for build 3; v0.3.0 inherits that gate.

## Handoff

**Agent 4 (accounts/consolidated setup) — the coordination point.** Shared UI files stay single-owner:

- **You own** `BillsAndDebtsSetupView` and any new setup surfaces. **I own** `DueRuleEditorView.swift`, `DueRuleEditService.swift`, `DueDateRule.swift`, `CalendarEventService.swift`, `NotificationPlanner.swift`, `NotificationScheduler.swift`, `ObligationDueDatesView.swift`.
- To offer due-rule editing from the consolidated page, add `@State private var dueRuleTarget: DueRuleEditorTarget?`, attach `.dueRuleEditor($dueRuleTarget)`, and set `dueRuleTarget = DueRuleEditorTarget(billOrDebt)`. That is the whole integration. Do not reimplement the form, the validation, the audit trail, the effective date, or the reschedule — a second copy is exactly the duplicated-bridge failure pinned in MVP_LAYOUT §10.
- If your setup page ever writes `dueDayOfMonth`/`dueDay`/`dueDateShiftRule` directly (e.g. an add flow that captures a due day at creation), that is fine for a *new* row, which has no history to protect. For an **edit**, route through `DueRuleEditService.apply`.
- Your archive action should call `rescheduleAll(..., trigger: .archiveOrPayoff)`. If you forget, the next foreground pass cleans up — but the reminder will look stale until then.
- I edited three files that touch your area, minimally and additively: `DebtsView.swift` (the due-rule half of the debt editor now calls the shared service; a new `openPendingDebt` handles entity-keyed links), `RemindersStepView.swift` (reconcile on grant), and `SettingsView.swift` (reconcile on grant + trigger tags). Take my version if we collide there.

**Agent 6 (portability/reports):** notification preferences are template-exportable configuration; `detailedLockScreenContent` must default to **false** on import regardless of the file, or an imported template can silently turn on detailed lock-screen copy. Due rules (`dueDay`, `dueDateShiftRule`) are configuration and belong in a template; `dueDayEffectiveFrom` and `dueDateAuditLog` are history and must not be.

**Agent 7 (integration):** merge after Agent 4. Watch `DebtsView.swift`, `SettingsView.swift`, `RemindersStepView.swift`, and `CalendarEventServiceTests.swift` for overlap. The `DeepLink.debt` case gained a `debtID`; a `debt(planID:)` factory keeps old call sites compiling, so a merge that reintroduces `.debt(planID: x)` will still build — check it is intentional rather than a lost fix.

## Assumptions

1. **A-05-1.** History that predates a due-rule edit stays *blank* rather than being reconstructed under the old rule. This is the ratified v0.2.0 behavior (MVP_LAYOUT §9) and the audit log holds enough to reconstruct it later; doing so now would contradict a ratified decision for a cosmetic gain.
2. **A-05-2.** A past due date stays `planned` forever. The app has no payment matching, so marking it "actual" would claim knowledge it does not have.
3. **A-05-3.** The window cap prioritizes strictly by fire time. With a 60-request budget over 45 days this only bites on very dense stores, and "soonest first" is the only ordering that cannot drop something urgent in favor of something distant.
4. **A-05-4.** Revoked permission leaves already-pending requests in place rather than cancelling them. They cannot fire while permission is off, and the first authorized pass reconciles them away; cancelling would require scheduling work in exactly the state where the app has no scheduling rights.

## Risks and open items

1. **Weekly and biweekly bills still get no due-date marker or reminder.** A day-of-month cannot describe them. Closing it needs a first-due-date/weekday anchor field on `RecurringObligation` — a schema change, which is Agent 2's to own. Carried forward from v0.2.0, documented, additive if ever taken.
2. **Long-cadence bills anchor to their creation month.** A quarterly bill created in August fires Aug/Nov/Feb/May regardless of when it is actually due. Same root cause and same fix as item 1.
3. **The `migration` and `archiveOrPayoff` triggers have no direct caller yet.** Migration is covered by the launch pass; archive/payoff is covered by the foreground pass and is named for Agent 4 to call explicitly. Both are correct today and would be more precise with direct calls.
4. **Debt reminder references changed shape**, so the first reconcile after upgrade re-adds every debt due reminder once (the fingerprint changed). That is one round of churn, is idempotent afterward, and is strictly safer than leaving letter-keyed references in delivered notifications.
5. **Detailed lock-screen copy still includes a name and an amount when explicitly enabled** — that is the point of the preference, but it means the V3-13 guarantee is "generic by default", not "never detailed". Device check 2 exists to confirm the default actually holds on a real lock screen.
6. **`NotificationScheduler` remains main-actor and synchronous with the store snapshot.** On a very large store the pass costs a main-thread read. It is bounded by the same analysis cost Agent 3 is benchmarking; no reason to move it off-actor yet, but the two share a ceiling.

## Commits

On `feature/v0.3-calendar-reminders` (base `6029107`):

- see the commit hash recorded at the end of this file after the commit lands.
