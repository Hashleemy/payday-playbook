# Payday Playbook — MVP Product and Technical Layout

## 1. Build brief

Build a native, offline-first iPhone app named **Payday Playbook** using SwiftUI. The app is a personal execution companion for the exact debt plan in this document. It must allow the user to record real contributions and balances, compare actual progress with the original plan, receive local notifications, and understand the entire payoff calendar at a glance.

Read `soul.md` first. Its principles and F-01 through F-16 feature contract are non-negotiable.

### Technical baseline

- Language: Swift.
- UI: SwiftUI.
- Persistence: SwiftData with local storage.
- Charts: Swift Charts.
- Notifications: UserNotifications with calendar-based local triggers.
- Security: LocalAuthentication for optional Face ID/app lock.
- Deployment target: iOS 17.0 or newer.
- Architecture: feature-oriented MVVM with services for calculations, notifications, exports, and plan seeding.
- Dependencies: Apple frameworks only for MVP.
- Money type: `Decimal` with explicit currency rounding to two decimals.
- Dates: `Calendar` and `DateComponents`; persist a normalized local date and user time zone.
- No backend, login, telemetry, ads, bank linking, or automatic money movement.

---

## 2. Exact seeded plan

Create **Original Plan v1** on first launch. Make it immutable. User changes create actual records, future-dated settings, or a new plan version; they never rewrite Original Plan v1.

### Core values

| Setting | Seed value |
| --- | ---: |
| Starting Checking 1 cash | $900.00 before Aug 20, 2026 |
| First payday | Aug 20, 2026 |
| Pay frequency | Every 14 days |
| Take-home through Nov 26, 2026 | $2,094.00 |
| Take-home beginning Dec 10, 2026 | $2,190.00 |
| Checking 1 protected floor | $1,000.00 |
| Allowance cap | $300.00/check; available, not assumed spent |
| First-check buffer addition | $100.00 |
| Car reserve | $335.08/check |
| Train reserve | $51.23/check |
| Total fixed reserve | $386.31/check |
| Starting card debt | $29,681.61 |
| Method | Debt avalanche |
| Baseline payoff | Jun 24, 2027 |
| Baseline modeled interest | $3,461.16 |
| Baseline no-spend C1 ceiling at payoff | $7,900.00 |

### Seed debts

| Priority | ID | Starting balance | APR | Baseline payoff |
| ---: | --- | ---: | ---: | --- |
| 1 | B | $1,049.00 | 29.99% | Aug 20, 2026 |
| 2 | D | $4,987.00 | 28.99% | Oct 15, 2026 |
| 3 | A | $3,787.65 | 27.24% | Nov 26, 2026 |
| 4 | F | $3,495.00 | 26.49% | Jan 7, 2027 |
| 5 | C | $11,650.40 | 24.49% | May 13, 2027 |
| 6 | E | $4,712.56 | 21.99% | Jun 24, 2027 |

The setup screen may let the user assign a friendly issuer/card name, statement due day, and current minimum to A–F. Do not require or store full account numbers.

### Seed paydays

| # | Date | Income | C1 keep | C2 transfer | Fixed reserve | Card budget | Target | Planned debt after | C1 ceiling |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| 1 | 2026-08-20 | $2,094.00 | $400.00 | $1,694.00 | $386.31 | $1,307.69 | B | $28,665.71 | $1,300.00 |
| 2 | 2026-09-03 | $2,094.00 | $300.00 | $1,794.00 | $386.31 | $1,407.69 | D | $27,537.95 | $1,600.00 |
| 3 | 2026-09-17 | $2,094.00 | $300.00 | $1,794.00 | $386.31 | $1,407.69 | D | $26,397.48 | $1,900.00 |
| 4 | 2026-10-01 | $2,094.00 | $300.00 | $1,794.00 | $386.31 | $1,407.69 | D | $25,244.17 | $2,200.00 |
| 5 | 2026-10-15 | $2,094.00 | $300.00 | $1,794.00 | $386.31 | $1,407.69 | D | $24,077.88 | $2,500.00 |
| 6 | 2026-10-29 | $2,094.00 | $300.00 | $1,794.00 | $386.31 | $1,407.69 | A | $22,898.52 | $2,800.00 |
| 7 | 2026-11-12 | $2,094.00 | $300.00 | $1,794.00 | $386.31 | $1,407.69 | A | $21,706.74 | $3,100.00 |
| 8 | 2026-11-26 | $2,094.00 | $300.00 | $1,794.00 | $386.31 | $1,407.69 | A | $20,502.42 | $3,400.00 |
| 9 | 2026-12-10 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | F | $19,189.43 | $3,700.00 |
| 10 | 2026-12-24 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | F | $17,863.03 | $4,000.00 |
| 11 | 2027-01-07 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | F | $16,523.09 | $4,300.00 |
| 12 | 2027-01-21 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | C | $15,169.92 | $4,600.00 |
| 13 | 2027-02-04 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | C | $13,804.02 | $4,900.00 |
| 14 | 2027-02-18 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | C | $12,425.27 | $5,200.00 |
| 15 | 2027-03-04 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | C | $11,033.55 | $5,500.00 |
| 16 | 2027-03-18 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | C | $9,628.75 | $5,800.00 |
| 17 | 2027-04-01 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | C | $8,210.73 | $6,100.00 |
| 18 | 2027-04-15 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | C | $6,779.38 | $6,400.00 |
| 19 | 2027-04-29 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | C | $5,334.57 | $6,700.00 |
| 20 | 2027-05-13 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | C | $3,876.17 | $7,000.00 |
| 21 | 2027-05-27 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | E | $2,405.17 | $7,300.00 |
| 22 | 2027-06-10 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | E | $921.76 | $7,600.00 |
| 23 | 2027-06-24 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $929.54 | E | $0.00 | $7,900.00 |

### Baseline calculation rules

1. Accrue 14 days of estimated interest before each planned payment: `balance × APR × 14 / 365`.
2. Estimated biweekly minimum per active card is `max($17.50, postInterestBalance × 0.005)`, capped at its remaining balance.
3. Pay minimums on all active cards.
4. Apply the rest of the card budget to the first active debt in B → D → A → F → C → E order.
5. Roll unused attack money to the next card in the same transaction if the target is paid off.
6. The actual track uses user-entered payment and balance records. A balance snapshot overrides accumulated estimates from that date forward.

---

## 3. Information architecture

Use a four-tab layout.

| Tab | Purpose | Primary action |
| --- | --- | --- |
| Today | Immediate status and next move | Start/continue payday check-in |
| Calendar | Dates, due items, history, and milestones | Open a day's play-by-play |
| Debts | Card balances, priorities, and histories | Add payment or balance update |
| Progress | Charts, variance, milestones, and forecast | Review and reforecast |

Settings is reached from the Today navigation bar. A global `+` action may open a sheet for payment, balance update, windfall, C1/C2 adjustment, or note.

---

## 4. Screen layouts

### 4.1 Onboarding — F-01

**Screen 1: Welcome**

- Product promise: “Know today's play. Record what happened. See the finish line.”
- State that all data stays local unless exported.
- Button: `Load My Plan`.

**Screen 2: Confirm starting plan**

- Show $29,681.61 starting debt, 23 planned checks, and June 24, 2027 baseline payoff.
- Show $900 starting Checking 1 cash and the $1,000 protected floor.
- Show the two-account model.
- Button: `Use Original Plan v1`.

**Screen 3: Label cards**

- A–F are preloaded with balance/APR.
- Optional fields: nickname/issuer, last four digits, statement due day, current minimum.
- Last four must be optional; never ask for a full account number.
- Skipping must not block onboarding.

**Screen 4: Notifications**

- Explain payday, incomplete-check-in, and due-date reminders before requesting permission.
- Default payday morning: 8:00 AM local time.
- Default incomplete reminder: 7:00 PM local time.
- Default due reminder: three days before at 9:00 AM and due date at 9:00 AM.
- Default weekly summary: Sunday 6:00 PM; toggleable.

**Done state**

- Seed all entities in one transaction.
- Set onboarding complete only after the seed succeeds.
- On relaunch after an interrupted seed, resume safely without duplicate rows.

### 4.2 Today dashboard — F-02

Order content vertically for one-handed scanning.

1. **Status header**
   - “On track,” “Ahead by $X,” or “Needs $X to return to plan.”
   - Remaining debt and percent eliminated.
   - Original payoff and current reforecast payoff.

2. **Today's play card**
   - If payday is today: Keep → Move → Reserve → Pay.
   - If between checks: next payday date, days remaining, current avalanche card, and next planned card payment.
   - Primary button: `Start Check-In`, `Continue Check-In`, or `Review Completed Check`.

3. **Current target card**
   - Card nickname/ID, actual balance, APR, planned attack amount, and due date.
   - Button: `Add Payment`.

4. **Checking 1 card — F-08**
   - Actual C1 balance.
   - Protected floor: $1,000.
   - Current allowance available.
   - No-spend ceiling for the current date.
   - Label ceiling: `Maximum if no allowance had been spent`.
   - Never infer actual C1 balance from the ceiling.

5. **Checking 2 card — F-09**
   - Actual/estimated C2 balance.
   - Reserved for car.
   - Reserved for train.
   - Available for minimums and avalanche payment.
   - Warn on negative or overallocated buckets.

6. **Upcoming strip**
   - Next payday, next card due date, next projected card payoff.

### 4.3 Guided payday check-in — F-03

Use a five-step flow with a persistent summary at the bottom.

**Step 1 — Income**

- Prefill planned paycheck.
- User enters actual take-home.
- Optional note for overtime, deduction, or correction.

**Step 2 — Checking 1**

- Prefill planned allowance cap and buffer addition.
- User enters actual amount kept in C1.
- Optional: actual spending since prior check.
- User enters or confirms current C1 balance.
- Clearly show protected floor and no-spend ceiling.

**Step 3 — Checking 2 and reserves**

- Prefill planned C2 transfer, car reserve, and train reserve.
- User records actual transfer and actual reserve amounts.
- Show remaining C2 money available for cards.

**Step 4 — Card payments**

- Prefill planned total card budget and recommended target.
- User enters actual payment for each card.
- Minimums may be prefilled from the user's current settings but remain editable.
- Show total payments and unallocated/overallocated amount.
- Permit a partial check-in but require an explanation before marking a mathematically unreconciled check complete.

**Step 5 — Reconcile and finish**

- Equation: actual income + explicitly selected outside funds = C1 kept + C2 transfer + any unallocated amount.
- Show planned versus actual for each category.
- Offer optional post-payment balance entry for every paid card.
- Buttons: `Save Draft` and `Mark Payday Complete`.
- Completion writes actual ledger entries atomically, recalculates the forecast, refreshes notifications, and records a completion timestamp.

Never create actual payments merely because the user marks a check complete. Actual amount fields must be confirmed.

### 4.4 Calendar dashboard — F-07

**Views**

- Default month view.
- Optional week/list toggle.
- Jump to Today and jump to Debt-Free Date controls.

**Markers**

- Blue filled dot: future payday.
- Green check: completed payday.
- Amber ring: payday due/incomplete.
- Coral dot: card due date.
- Mint star: card payoff milestone.
- Gray dot: manual balance snapshot or note.

Do not rely on color alone; each event also needs an icon and text label.

**Selected-day panel**

- Planned events and amounts.
- Actual entries and completion state.
- Plan-versus-actual variance.
- `Open Check-In`, `Add Entry`, or `View Milestone` action.

**Filters**

- All.
- Paydays.
- Card due dates.
- Milestones.
- Actual entries.

### 4.5 Debts list and detail — F-04

**List**

- Sort by avalanche order by default.
- Each row: ID/nickname, actual balance, APR, next due date, status, percent paid.
- Paid-off cards remain visible in a collapsed `Paid Off` section.

**Detail**

- Actual balance as the primary number.
- Original starting balance and baseline balance for today.
- APR, actual minimum, due day, priority, and payoff status.
- Planned payoff versus reforecast payoff.
- Payment history and balance-snapshot history.
- Buttons: `Add Payment`, `Update Balance`, `Edit Card`.

**Balance update**

- Enter amount and effective date.
- Optional source: app estimate, current online balance, statement balance, issuer payoff quote.
- Snapshot becomes authoritative from its effective date for the actual track.
- Never delete previous snapshots during correction; append a correction record or explicitly edit with an audit note.

### 4.6 Contribution entry and ledger — F-05

Entry types:

- card payment;
- C1 buffer addition;
- C1 spending;
- C1 balance adjustment;
- C2 transfer;
- car reserve contribution/use;
- train reserve contribution/use;
- windfall;
- refund/reversal;
- correction.

Each entry stores date, amount, source, destination/category, related card/payday, optional note, creation timestamp, and modification timestamp. Negative amounts require an explicit refund/reversal/correction type.

Ledger screen/search must support filters by date, account, card, entry type, and payday. All edits should preserve an audit note.

### 4.7 Progress — F-10

Provide these charts with `Plan`, `Actual`, and `Reforecast` selectors where applicable:

- total debt over time;
- balance by card;
- cumulative principal paid versus modeled interest;
- percent debt eliminated;
- plan-versus-actual variance by payday;
- Checking 1 actual balance versus protected floor and no-spend ceiling;
- card payoff timeline.

Also show:

- dollars eliminated;
- current modeled daily interest cost;
- paychecks remaining;
- days to forecast payoff;
- total contributions logged;
- next milestone;
- all earned milestone cards.

### 4.8 Reforecast — F-12

Reforecast after every completed payday, balance snapshot, APR change, paycheck change, or extra payment.

The engine must:

1. start from the latest authoritative actual balance per card;
2. generate future biweekly dates from the current plan version;
3. reserve the allowance, buffer need, car amount, and train amount;
4. apply known minimums, or use the baseline estimate when missing;
5. follow the active avalanche order;
6. apply windfalls only when the user explicitly assigns them;
7. stop when all card balances round to $0.00;
8. return payoff date, paychecks, estimated interest, per-card payoff dates, and future schedule.

Display a variance explanation such as: `Forecast moved 14 days later because this payday's card contributions were $620 below plan.` Do not imply certainty.

### 4.9 Local notifications — F-11

Notification types:

| Notification | Default trigger | Deep link |
| --- | --- | --- |
| Payday play | 8:00 AM on each payday | Relevant check-in |
| Incomplete payday | 7:00 PM only if the day's check-in is incomplete | Relevant check-in |
| Card due soon | 9:00 AM three days before configured due date | Card detail |
| Card due today | 9:00 AM on configured due date | Card detail |
| Weekly summary | Sunday 6:00 PM | Today/Progress |
| Milestone approaching | User-configurable, default one payday before | Milestone detail |

Requirements:

- Ask permission only after showing the value.
- Check authorization status whenever notification settings opens.
- If permission is denied, show how to open iOS Settings; the app still works fully.
- Schedule only local notifications.
- Cancel/reschedule affected requests when dates, due days, completion state, or settings change.
- Use stable identifiers so updates replace, rather than duplicate, requests.
- The evening reminder must be removed immediately when the payday is completed.
- Notification content must avoid sensitive details on the lock screen by default. Use “Your payday check-in is ready” rather than exact debt balances unless the user enables detailed previews.

### 4.10 Plan/settings editor — F-13

Settings groups:

- Plan versions.
- Pay schedule and future paycheck changes.
- Allowance and protected buffer.
- Car/train reserve amounts and optional due dates.
- Debt names, APRs, minimums, due days, and priority.
- Notification types/times and lock-screen detail.
- Face ID/app lock.
- Data export/import.
- Calculation assumptions.

Edits must show impact before saving. The user chooses:

- `Apply to future dates` for a rule change; or
- `Save as New Plan Version` for a scenario change.

Original Plan v1 stays readable and can be compared at any time.

### 4.11 Backup/export — F-14

- Export a versioned JSON file containing all models and metadata needed for full restore.
- Restore validates schema version and shows a summary before writing.
- Export CSV files for ledger entries, balance snapshots, debts, and paycheck check-ins.
- Use the iOS share sheet or Files picker; user initiates every export/import.
- Never log financial data to the debug console in release builds.
- Before destructive restore, create a local rollback backup and require confirmation.

### 4.12 Privacy, security, accessibility — F-15

- Store no full card numbers, credentials, CVVs, SSNs, or bank login information.
- Use local SwiftData storage and iOS file protection appropriate for user financial records.
- Optional Face ID/app lock after app backgrounding.
- App-lock fallback uses device authentication; do not invent a custom financial PIN store for MVP.
- Support Dynamic Type, VoiceOver, Reduce Motion, high contrast, and 44-point minimum hit targets.
- Every chart must include a text summary and accessible values.
- Privacy screen can explain exactly what is stored and exported.

### 4.13 Debt-free transition — F-16

When all actual card balances reach zero:

- verify with a confirmation screen before declaring completion;
- celebrate once with reduced-motion support;
- preserve all history;
- show the estimated released cash per paycheck;
- offer a Phase II goal choice: larger emergency fund, car principal, retirement, Roth IRA, or taxable investing;
- create only a goal tracker and suggested allocation placeholder; do not make investment recommendations or automatically move money.

---

## 5. Data model

Use SwiftData `@Model` types. Names below are suggested and may be refined without changing behavior.

### `PlanVersion`

- `id: UUID`
- `name: String`
- `createdAt: Date`
- `isOriginalBaseline: Bool`
- `isActive: Bool`
- `firstPayday: Date`
- `payFrequencyDays: Int`
- `startingChecking1: Decimal`
- `protectedBuffer: Decimal`
- `allowanceCap: Decimal`
- `carReservePerCheck: Decimal`
- `trainReservePerCheck: Decimal`
- `calculationVersion: Int`

### `IncomeRule`

- `id`, `planVersionID`
- `effectiveDate`
- `netPaycheckAmount`

Seed $2,094 effective Aug 20, 2026 and $2,190 effective Dec 10, 2026.

### `DebtAccount`

- `id`
- `planID: String` such as A–F
- `displayName`
- `optionalLastFour`
- `startingBalance`
- `apr`
- `minimumAmount`
- `dueDayOfMonth`
- `priority`
- `isArchived`

### `PaydayPlanItem`

- `id`, `planVersionID`
- `sequenceNumber`
- `date`
- `plannedIncome`
- `plannedC1Keep`
- `plannedBufferAdd`
- `plannedAllowance`
- `plannedC2Transfer`
- `plannedCarReserve`
- `plannedTrainReserve`
- `plannedCardBudget`
- `plannedTargetDebtID`
- `plannedDebtAfter`
- `plannedC1NoSpendCeiling`
- `plannedPerCardBalances` as related rows, not encoded JSON if practical

### `PaydayCheckIn`

- `id`, `paydayPlanItemID`
- `status: draft/completed/needsAttention`
- `actualIncome`
- `outsideFundsUsed`
- `actualC1Kept`
- `actualC1Balance`
- `actualAllowanceSpent`
- `actualC2Transfer`
- `actualCarReserve`
- `actualTrainReserve`
- `unallocatedAmount`
- `note`
- `completedAt`

### `LedgerEntry`

- `id`
- `effectiveDate`
- `createdAt`, `updatedAt`
- `type`
- `amount`
- `sourceAccount`
- `destinationAccount`
- `debtAccountID`
- `paydayCheckInID`
- `note`
- `isCorrection`
- `correctsEntryID`

### `BalanceSnapshot`

- `id`
- `debtAccountID` or cash-account ID
- `effectiveDate`
- `amount`
- `sourceType`
- `note`
- `isAuthoritative`

### `CashBucket`

- `id`
- `type: checking1Actual/checking1Buffer/checking2Car/checking2Train/checking2Debt`
- `currentAmount`

Derive bucket values from the ledger when possible. Cache only if needed and verify cached totals against the ledger.

### `ForecastSnapshot`

- `id`
- `calculatedAt`
- `sourcePlanVersionID`
- `triggerType`
- `projectedPayoffDate`
- `remainingPaychecks`
- `estimatedRemainingInterest`
- `projectedPerCardPayoffDates`
- `summaryExplanation`

### `NotificationPreference`

- type, enabled, hour, minute, leadDays, detailedLockScreenContent.

### `Milestone`

- type, threshold, baselineDate, forecastDate, achievedDate, relatedDebtID.

---

## 6. Core services

| Service | Responsibility |
| --- | --- |
| `PlanSeeder` | Idempotently seeds Original Plan v1, debts, schedule, milestones, and defaults. |
| `DebtCalculationEngine` | Baseline calculation, avalanche allocation, interest estimate, and reforecast. Pure functions where possible. |
| `ReconciliationService` | Validates payday equations and creates atomic ledger/check-in records. |
| `AccountBalanceService` | Derives C1/C2 bucket balances and distinguishes actual from ceiling. |
| `NotificationScheduler` | Requests authorization, creates stable requests, reschedules changes, and handles deep links. |
| `CalendarEventService` | Merges paydays, due dates, milestones, and actual entries into display events. |
| `ExportService` | Versioned JSON backup/restore and CSV exports. |
| `AppLockService` | LocalAuthentication state and background-lock timing. |

---

## 7. Feature acceptance criteria

This section mirrors every feature in `soul.md`.

| ID | MVP is accepted when… |
| --- | --- |
| F-01 | A clean install produces exactly one Original Plan v1 with six debts and 23 paydays; onboarding can be interrupted and resumed without duplicates. |
| F-02 | Today shows remaining debt, variance status, current target, next action, payoff forecast, C1/C2 status, and check-in state without scrolling on a common iPhone Pro-sized screen where practical. |
| F-03 | A payday can be saved as draft or completed; all planned and actual amounts remain distinct; completion reconciles or records an explicit exception. |
| F-04 | The user can view/edit six debt records, add payments and authoritative balance snapshots, and inspect full history. |
| F-05 | Every money action is represented by a filterable ledger entry and corrections retain an audit link. |
| F-06 | All 23 dates and seed values match this document; Original Plan v1 cannot be edited or deleted. |
| F-07 | Calendar displays paydays, due dates, milestones, entries, and completion states; selecting a date opens the relevant detail. |
| F-08 | C1 shows actual, protected floor, allowance usage, and no-spend ceiling as separately labeled values; no-spend never mutates actual. |
| F-09 | C2 shows car, train, and debt buckets and prevents an unnoticed negative allocation. |
| F-10 | All specified charts and milestones render from stored data and have accessible text equivalents. |
| F-11 | Local notification permission is contextual; enabled reminders deep-link correctly; completing a payday cancels its incomplete reminder. |
| F-12 | Changing an actual balance or contribution updates the forecast while baseline values remain unchanged and visible. |
| F-13 | Future plan changes show impact and create a future rule/new version; baseline remains immutable. |
| F-14 | A JSON round-trip restores equivalent records; CSV exports open with correct headers and currency values. |
| F-15 | No prohibited sensitive fields exist; Face ID lock, Dynamic Type, VoiceOver, Reduce Motion, and secure local behavior are testable. |
| F-16 | Reaching zero produces one confirmation/celebration and exposes a Phase II goal tracker without moving money or giving individualized investment advice. |

---

## 8. Validation and tests

### Required unit tests

1. Original total equals $29,681.61.
2. Avalanche order equals B, D, A, F, C, E.
3. First paycheck is Aug 20, 2026 and the next is Sep 3, 2026.
4. First check keeps $400, transfers $1,694, reserves $386.31, and budgets $1,307.69 to cards.
5. Checks 2–8 budget $1,407.69 to cards.
6. Dec 10, 2026 income changes to $2,190 and card budget changes to $1,503.69.
7. Baseline card payoff dates match B Aug 20, D Oct 15, A Nov 26, F Jan 7, C May 13, E Jun 24.
8. Baseline final payoff is Jun 24, 2027 after 23 checks.
9. Baseline modeled interest rounds to $3,461.16.
10. Baseline no-spend ceiling reaches $7,900.
11. Recording $100 of actual allowance spending lowers actual C1 only; it does not change the baseline ceiling.
12. An authoritative debt balance snapshot changes the forecast but not Original Plan v1.
13. A payoff that leaves extra attack money applies the remainder to the next avalanche card.
14. Negative currency inputs are rejected except explicit refund/reversal/correction entries.
15. Reconciliation catches overallocated income and negative C2 buckets.

### Required integration/UI tests

- Clean install and idempotent seed.
- Complete the first payday check-in.
- Save and resume a draft.
- Enter a card payment and balance update.
- Calendar deep link from payday notification.
- Notification-denied experience.
- Export and restore JSON.
- Dynamic Type at accessibility sizes.
- VoiceOver labels on dashboard and charts.
- Reduce Motion celebration.
- App background lock and successful Face ID return.

### Manual data verification

Add a debug-only `Plan Verification` screen or test helper that prints:

- plan version;
- number of debts;
- number of paydays;
- original total;
- each milestone date;
- final payoff date;
- total modeled interest;
- final no-spend ceiling.

The release UI must not expose debug logs containing financial data.

---

## 9. Suggested project structure

```text
PaydayPlaybook/
├── App/
│   ├── PaydayPlaybookApp.swift
│   ├── AppRouter.swift
│   └── AppEnvironment.swift
├── Models/
│   ├── PlanVersion.swift
│   ├── IncomeRule.swift
│   ├── DebtAccount.swift
│   ├── PaydayPlanItem.swift
│   ├── PaydayCheckIn.swift
│   ├── LedgerEntry.swift
│   ├── BalanceSnapshot.swift
│   ├── CashBucket.swift
│   ├── ForecastSnapshot.swift
│   ├── NotificationPreference.swift
│   └── Milestone.swift
├── Services/
│   ├── PlanSeeder.swift
│   ├── DebtCalculationEngine.swift
│   ├── ReconciliationService.swift
│   ├── AccountBalanceService.swift
│   ├── NotificationScheduler.swift
│   ├── CalendarEventService.swift
│   ├── ExportService.swift
│   └── AppLockService.swift
├── Features/
│   ├── Onboarding/
│   ├── Today/
│   ├── CheckIn/
│   ├── Calendar/
│   ├── Debts/
│   ├── Ledger/
│   ├── Progress/
│   ├── Settings/
│   └── PhaseTwo/
├── Components/
│   ├── MoneyText.swift
│   ├── StatusBadge.swift
│   ├── PlanActualRow.swift
│   ├── EmptyState.swift
│   └── AccessibleChartSummary.swift
├── Resources/
│   ├── OriginalPlanV1.json
│   └── Assets.xcassets
└── Tests/
    ├── DebtCalculationEngineTests.swift
    ├── PlanSeederTests.swift
    ├── ReconciliationServiceTests.swift
    ├── ExportServiceTests.swift
    └── PaydayPlaybookUITests/
```

The plan may be seeded from a bundled, versioned JSON resource. Validate it before insertion and include a hash or schema version so accidental changes are caught in tests.

---

## 10. Build sequence

### Phase 1 — Foundation

- Create project and models.
- Implement Decimal helpers and date normalization.
- Implement/verify Original Plan v1 seed.
- Add calculation tests before UI.

### Phase 2 — Core execution

- Build Today, Debts, and payday check-in.
- Implement ledger, balance snapshots, and reconciliation.
- Implement actual versus plan status.

### Phase 3 — Time and accountability

- Build calendar event merge and calendar UI.
- Add notification permission flow, scheduler, and deep links.
- Add reminders for only the rolling relevant window and reschedule on changes.

### Phase 4 — Insight and resilience

- Build charts, milestones, reforecast explanations, and settings.
- Add JSON/CSV export/restore and app lock.
- Add accessibility and privacy pass.

### Phase 5 — Verification

- Run all tests.
- Validate every baseline date and amount against this document.
- Test on a physical iPhone for notification delivery, Face ID, share sheet, calendar sizing, and app relaunch persistence.
- Produce a short `README.md` with build/run steps and a `TESTING.md` checklist.

Do not skip foundational calculation tests to rush into visual work.

---

## 11. MVP exclusions and future options

Not part of MVP:

- bank/card API connections;
- cloud sync or multi-device collaboration;
- Android or web clients;
- automatic payment initiation;
- receipt scanning;
- shared household accounts;
- AI financial recommendations;
- securities trading or portfolio management;
- widgets, watch app, or Siri shortcuts.

Potential post-MVP work after the local app is stable:

- iCloud sync as an explicit opt-in;
- lock-screen/widget next-action view;
- Shortcuts/App Intents for quick balance updates;
- scenario comparison without changing the active plan;
- PDF progress report generation;
- configurable debt snowball mode;
- biometric privacy screen snapshot protection.

---

## 12. Definition of done

The MVP is done only when:

- all F-01 through F-16 acceptance criteria pass;
- every seeded value matches the exact plan;
- a fresh install works fully offline;
- user entries persist across relaunch;
- planned values never masquerade as actual values;
- C1 no-spend ceiling never masquerades as actual cash;
- the user can complete an end-to-end payday workflow;
- calendar and notifications take the user to the correct action;
- reforecast changes do not alter Original Plan v1;
- backup/restore is verified;
- accessibility and privacy checks pass on a physical device;
- no prohibited financial credentials are collected or logged.

At handoff, provide the Xcode project, passing test results, `README.md`, `TESTING.md`, and a list of any known limitations. Do not call the MVP complete with placeholder data, nonfunctional buttons, or mocked persistence.

---

## 13. Apple implementation references

- SwiftData persistence: <https://developer.apple.com/documentation/swiftdata>
- Adding/editing SwiftData records: <https://developer.apple.com/documentation/swiftdata/adding-and-editing-persistent-data-in-your-app>
- User Notifications: <https://developer.apple.com/documentation/usernotifications>
- Scheduling local notifications: <https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app>
- Requesting notification permission: <https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications>
- Calendar notification triggers: <https://developer.apple.com/documentation/usernotifications/uncalendarnotificationtrigger>

Use the current stable Apple documentation and SDK installed with Xcode while preserving the behavior specified here.
