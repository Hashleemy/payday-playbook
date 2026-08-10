# Payday Playbook — Testing

## Automated coverage

Run everything:

```bash
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

### Unit tests (PaydayPlaybookTests, 54 tests)

Required tests from MVP_LAYOUT §8 and where they live:

| # | Requirement | Test |
| --- | --- | --- |
| 1 | Original total equals $29,681.61 | `DebtCalculationEngineTests.testOriginalTotalEquals29681_61` |
| 2 | Avalanche order B, D, A, F, C, E | `DebtCalculationEngineTests.testAvalancheOrder` |
| 3 | First paycheck Aug 20, next Sep 3, 2026 | `DebtCalculationEngineTests.testFirstTwoPaydayDates` |
| 4 | First check keeps $400 / moves $1,694 / reserves $386.31 / budgets $1,307.69 | `PlanSeederTests.testFirstCheckAllocations` |
| 5 | Checks 2–8 budget $1,407.69 | `PlanSeederTests.testChecks2Through8Budget` |
| 6 | Dec 10, 2026 income $2,190, budget $1,503.69 | `PlanSeederTests.testDecemberIncomeChange` |
| 7 | Baseline payoffs B/D/A/F/C/E match dates | `DebtCalculationEngineTests.testBaselinePerCardPayoffDates` |
| 8 | Final payoff Jun 24, 2027 after 23 checks | `DebtCalculationEngineTests.testBaselineFinalPayoff` |
| 9 | Modeled interest rounds to $3,461.16 | `DebtCalculationEngineTests.testBaselineModeledInterest` |
| 10 | No-spend ceiling reaches $7,900 | `PlanSeederTests.testNoSpendCeilingProgression` |
| 11 | $100 spending lowers actual C1 only, not the ceiling | `ReconciliationServiceTests.testAllowanceSpendingLowersActualOnly` |
| 12 | Authoritative snapshot changes forecast, not Original Plan v1 | `ReconciliationServiceTests.testSnapshotChangesForecastNotBaseline` |
| 13 | Payoff remainder rolls to the next avalanche card | `DebtCalculationEngineTests.testPayoffRollsRemainderToNextCard` |
| 14 | Negative inputs rejected outside refund/reversal/correction | `ReconciliationServiceTests.testNegativeInputsRejected` |
| 15 | Overallocated income and negative C2 caught | `ReconciliationServiceTests.testOverallocationAndNegativeC2Caught` |

Additional coverage: idempotent/interrupted/persistent seeding, tampered seed
resource rejection, seeded per-card balances, reforecast reproducing the
baseline from a clean start, extra payments accelerating payoff, minimum
formula behavior, atomic check-in completion, exception-gated unreconciled
completion, C2 bucket derivation, milestone achievement, calendar merge,
notification defaults and deep-link routing, JSON round trip, schema-version
rejection, CSV headers/escaping/values, currency rounding, money parsing.
Review-regression coverage: unfunded payments and skipped C1 confirmations
require an explanation, outside funds are not double-counted into Checking 2,
prior-period spending never reduces the new allowance window, already-paid
cards get no phantom payoff dates, an overdue open payday stays in the
forecast, money editing text round-trips exactly, a malformed backup cannot
destroy existing data, and CSV formula characters are neutralized.

### UI tests (PaydayPlaybookUITests, 9 tests)

- Clean install → onboarding shows exact plan → lands on Today (F-01)
- Relaunch keeps the seed without duplicates; data persists (F-01)
- Complete the first payday check-in end to end (F-03)
- Save a draft and resume on the saved step (F-03)
- Record a card payment and an authoritative balance update (F-04/F-05)
- Calendar selected-day panel opens the check-in (F-07)
- Dashboard usable at accessibility text size with labeled controls (F-15)
- Notification settings render without permission; app fully usable (F-11)
- Backup screen produces shareable JSON and CSV files (F-14)

### Verified environments

- iPhone 17 Pro simulator, iOS 26.5 — full suite
- iPhone 15 Pro simulator, iOS 17.0.1 — unit suite (deployment-floor check)
- Release configuration builds cleanly

## Manual checklist (physical iPhone)

Automation cannot cover these; verify on a device before release:

1. **Notification delivery**: enable reminders, set a payday morning time a
   few minutes ahead, background the app, confirm banner arrives and tapping
   it opens the correct check-in. Confirm the 7 PM reminder disappears after
   completing the day's check-in.
2. **Notification-denied path**: deny permission in iOS Settings, open
   Settings → Reminders, confirm the "Open iOS Settings" guidance shows and
   the app works fully.
3. **Face ID lock**: enable in Settings → Security, background the app,
   reopen, confirm the lock overlay and successful Face ID unlock (and
   passcode fallback).
4. **Share sheet**: export JSON and CSVs to Files; re-import the JSON, review
   the restore summary, confirm rollback backup lands in the app's Documents.
5. **Restore round trip**: after restore, spot-check debts, ledger, and the
   completed check-ins survive.
6. **Dynamic Type**: largest accessibility size across Today, Check-In,
   Calendar, Debts, Progress — no clipped or overlapping content.
7. **VoiceOver**: dashboard cards, calendar day cells, chart summaries, and
   the check-in summary bar read meaningful labels.
8. **Reduce Motion**: with Reduce Motion on, the debt-free celebration shows
   without the spring animation.
9. **Relaunch persistence**: force-quit and relaunch; entries, drafts, and
   settings survive.
10. **Plan verification screen** (debug builds): Settings → About → Plan
    verification — plan name, 6 debts, 23 paydays, $29,681.61 total, milestone
    dates, Jun 24 2027 payoff, $3,461.16 interest, $7,900 ceiling.

## Known behaviors and limitations

- Statement due days are clamped to 1–28 to avoid short-month ambiguity. A
  restored backup carrying 29–31 is clamped to the 28th for reminders and the
  calendar.
- The check-in prefills planned values (including the expected C1 balance)
  into editable fields; completion is the user's confirmation. Payments
  prefill as minimums plus an avalanche attack that never exceeds a card's
  balance.
- The reforecast projects the biweekly cadence past June 2027 if the user
  falls behind; the explanation sentence always names the shift and cause.
- Plan dates are interpreted in the device's current time zone. Traveling to
  a time zone west of the seeding zone can shift day boundaries by one day
  until returning (PlanVersion stores the seeding zone for a future fix).
- Milestone titles are formatted at seed time in the seeding locale.
- Calendar notes are stored as zero-amount Checking 1 adjustments (displayed
  as "Note" in the ledger) and appear under that type in CSV exports.
- Balance derivations fetch whole tables and filter in memory — fine at this
  plan's scale (hundreds of rows), revisit if the app ever outlives Phase II.
