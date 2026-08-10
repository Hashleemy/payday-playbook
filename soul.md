# Payday Playbook — Product Soul

## Product identity

**Working name:** Payday Playbook  
**Platform:** Native iPhone app  
**Product type:** Offline-first personal debt execution coach  
**Primary user:** Master Lem  
**Plan window:** August 20, 2026 through June 24, 2027

Payday Playbook exists to turn a financial plan into a simple ritual the user can actually follow. It is not a generic budgeting app, a bank replacement, or a guilt engine. On every payday it should answer, in this order:

1. What money came in?
2. What stays in Checking 1?
3. What moves to Checking 2?
4. What must be reserved for the car and train?
5. Which card gets paid, and by how much?
6. What did the user actually do?
7. Is the user ahead, on track, or behind—and what is the next best move?

The app should feel like a calm, friendly playbook. It should reduce decision fatigue, make progress visible, and keep the user connected to the larger goal: becoming credit-card debt-free without pretending that every dollar of the personal allowance was spent.

---

## The promise

When the user opens the app, they should understand their position in under five seconds.

The home screen must clearly show:

- total remaining credit-card debt;
- original plan versus actual progress;
- the next payday action;
- the current avalanche target;
- days and paychecks remaining;
- Checking 1 actual balance;
- Checking 1 protected floor;
- Checking 1 no-spend ceiling;
- Checking 2 reserved amounts;
- whether the current check-in is complete.

The app never assumes the $300 personal allowance was spent. It records the allowance as **available**. Actual spending or the actual Checking 1 balance is entered separately.

---

## Guiding principles

### 1. Execution over theory

The PDF already contains the strategy. The app's job is to help execute it. Every important screen should end in a clear action, not another layer of analysis.

### 2. Planned, actual, and reforecast are different truths

The original plan is an immutable baseline. User entries are the actual record. A reforecast is a current estimate. Never overwrite one with another.

- **Plan:** what was expected on August 9, 2026.
- **Actual:** what the user confirms happened.
- **Reforecast:** what is now expected based on actual balances and contributions.

### 3. Available is not spent

The $300-per-paycheck personal allowance is a cap and permission, not a spending target. The app must never subtract it as an actual expense unless the user records spending or confirms a lower Checking 1 balance.

### 4. One payday, one checklist

Payday check-in should be a guided sequence with prefilled planned values. The user confirms or edits each amount, sees whether the money reconciles, and marks the payday complete.

### 5. Friendly accountability

Use neutral language: “needs attention,” “$84 behind plan,” or “next best move.” Avoid shame, alarmist red, failure streaks, or messages implying moral judgment.

### 6. Local and private by default

The app works without an account, server, subscription, bank login, or internet connection. Financial records remain on the iPhone unless the user explicitly exports a backup.

### 7. Actual balances are authoritative

Interest calculations are estimates. Whenever the user enters a current card balance, that balance becomes the source of truth for the actual track and reforecast.

### 8. Make the next move obvious

Charts and calendars must support action. The largest visual emphasis belongs to the next action, not decoration.

---

## Exact plan contract

This plan is seeded on first launch and must remain available as **Original Plan v1**.

### Starting position

| Item | Exact value |
| --- | ---: |
| Starting Checking 1 cash before first payday | $900.00 |
| First payday | August 20, 2026 |
| Current biweekly take-home | $2,094.00 |
| Increased biweekly take-home | $2,190.00 beginning December 10, 2026 |
| Monthly car payment | $726.00 |
| Monthly train pass | $111.00 |
| Exact biweekly fixed-expense reserve | $386.31 |
| Car portion per paycheck | $335.08 |
| Train portion per paycheck | $51.23 |
| Protected Checking 1 floor | $1,000.00 |
| Personal allowance cap | $300.00 per paycheck |
| Starting credit-card debt | $29,681.61 |
| Payoff method | Debt avalanche |
| Baseline projected payoff | June 24, 2027 |
| Baseline paychecks | 23 |
| Baseline modeled interest | $3,461.16 |
| Checking 1 no-spend ceiling at payoff | $7,900.00 |

### Debt inventory

| Priority | Card | Starting balance | APR |
| ---: | --- | ---: | ---: |
| 1 | B | $1,049.00 | 29.99% |
| 2 | D | $4,987.00 | 28.99% |
| 3 | A | $3,787.65 | 27.24% |
| 4 | F | $3,495.00 | 26.49% |
| 5 | C | $11,650.40 | 24.49% |
| 6 | E | $4,712.56 | 21.99% |

Avalanche order is permanently seeded as **B → D → A → F → C → E**. The app pays all entered minimums first and directs all extra card money to the highest-APR active card. When a card reaches zero, capacity rolls forward immediately.

### Baseline payday schedule

| # | Payday | Take-home | Keep in C1 | Move to C2 | Fixed reserve | Planned card payment | Attack | Planned debt after | C1 no-spend ceiling |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| 1 | Aug 20, 2026 | $2,094.00 | $400.00 | $1,694.00 | $386.31 | $1,307.69 | B | $28,665.71 | $1,300.00 |
| 2 | Sep 3, 2026 | $2,094.00 | $300.00 | $1,794.00 | $386.31 | $1,407.69 | D | $27,537.95 | $1,600.00 |
| 3 | Sep 17, 2026 | $2,094.00 | $300.00 | $1,794.00 | $386.31 | $1,407.69 | D | $26,397.48 | $1,900.00 |
| 4 | Oct 1, 2026 | $2,094.00 | $300.00 | $1,794.00 | $386.31 | $1,407.69 | D | $25,244.17 | $2,200.00 |
| 5 | Oct 15, 2026 | $2,094.00 | $300.00 | $1,794.00 | $386.31 | $1,407.69 | D | $24,077.88 | $2,500.00 |
| 6 | Oct 29, 2026 | $2,094.00 | $300.00 | $1,794.00 | $386.31 | $1,407.69 | A | $22,898.52 | $2,800.00 |
| 7 | Nov 12, 2026 | $2,094.00 | $300.00 | $1,794.00 | $386.31 | $1,407.69 | A | $21,706.74 | $3,100.00 |
| 8 | Nov 26, 2026 | $2,094.00 | $300.00 | $1,794.00 | $386.31 | $1,407.69 | A | $20,502.42 | $3,400.00 |
| 9 | Dec 10, 2026 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | F | $19,189.43 | $3,700.00 |
| 10 | Dec 24, 2026 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | F | $17,863.03 | $4,000.00 |
| 11 | Jan 7, 2027 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | F | $16,523.09 | $4,300.00 |
| 12 | Jan 21, 2027 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | C | $15,169.92 | $4,600.00 |
| 13 | Feb 4, 2027 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | C | $13,804.02 | $4,900.00 |
| 14 | Feb 18, 2027 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | C | $12,425.27 | $5,200.00 |
| 15 | Mar 4, 2027 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | C | $11,033.55 | $5,500.00 |
| 16 | Mar 18, 2027 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | C | $9,628.75 | $5,800.00 |
| 17 | Apr 1, 2027 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | C | $8,210.73 | $6,100.00 |
| 18 | Apr 15, 2027 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | C | $6,779.38 | $6,400.00 |
| 19 | Apr 29, 2027 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | C | $5,334.57 | $6,700.00 |
| 20 | May 13, 2027 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | C | $3,876.17 | $7,000.00 |
| 21 | May 27, 2027 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | E | $2,405.17 | $7,300.00 |
| 22 | Jun 10, 2027 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $1,503.69 | E | $921.76 | $7,600.00 |
| 23 | Jun 24, 2027 | $2,190.00 | $300.00 | $1,890.00 | $386.31 | $929.54 | E | $0.00 | $7,900.00 |

### Baseline payoff milestones

| Card | Baseline payoff date |
| --- | --- |
| B | August 20, 2026 |
| D | October 15, 2026 |
| A | November 26, 2026 |
| F | January 7, 2027 |
| C | May 13, 2027 |
| E | June 24, 2027 |

### Projection assumptions

- Interest is modeled every 14 days as `balance × APR × 14 ÷ 365`.
- The baseline estimates a biweekly minimum for each active card as the greater of $17.50 or 0.5% of the post-interest balance, capped at the remaining balance.
- Minimums are included inside the total card-payment budget, not added on top.
- Actual issuer interest, statement minimums, posting dates, and current balances will differ. User-entered balances and minimums control the actual track.
- Currency math must use `Decimal`, never binary floating-point.

---

## Non-negotiable feature contract

Every feature below must be present in the MVP specification and represented in the shipped app.

| ID | Feature | Soul-level requirement |
| --- | --- | --- |
| F-01 | Local onboarding and seeded plan | Fresh install loads Original Plan v1, explains the two-account system, requests notification permission in context, and asks for missing real-world card names, due dates, and minimums without blocking use. |
| F-02 | Five-second dashboard | Shows remaining debt, percent eliminated, plan status, current target, next action, payoff forecast, C1 tracking, C2 reserves, and current check-in state. |
| F-03 | Guided payday check-in | Prefills the plan, requires the user to record what actually happened, reconciles take-home allocations, supports draft and complete states, and never silently fills actuals from planned values. |
| F-04 | Debt account tracker | Shows each card's balance, APR, minimum, due date, priority, payoff state, history, and contribution total. Allows balance snapshots at any time. |
| F-05 | Contribution ledger | Records every card payment, C2 transfer, fixed reserve contribution, buffer addition, windfall, refund, and correction with date, amount, source, destination, and note. |
| F-06 | Original plan timeline | Preserves all 23 baseline paydays, allocations, attack targets, debt targets, and payoff milestones as an immutable reference. |
| F-07 | Calendar dashboard | Month/week calendar marks paydays, due dates, completed actions, incomplete actions, milestones, and forecast changes. A selected day opens its exact play-by-play. |
| F-08 | Checking 1 tracker | Separately displays protected floor, current allowance, actual balance, allowance actually used, and no-spend ceiling. It never presents the ceiling as actual cash. |
| F-09 | Checking 2 tracker | Tracks planned/actual transfers and separate car, train, minimum-payment, and avalanche-payment buckets. It warns if entered uses exceed available C2 funds. |
| F-10 | Progress and milestones | Includes debt trend, per-card balances, principal versus modeled interest, percent complete, plan-versus-actual variance, card payoff celebrations, and paychecks remaining. |
| F-11 | Local notifications | Supports payday morning, payday evening if incomplete, card due-date, weekly summary, and milestone reminders. Notifications deep-link to the relevant check-in or card. |
| F-12 | Reforecast engine | Recalculates the active target, remaining paychecks, interest estimate, and payoff date after actual entries while leaving Original Plan v1 untouched. |
| F-13 | Plan and settings editor | Lets the user update paycheck amounts/dates, allowance cap, reserve amounts, APRs, minimums, due dates, notification times, and avalanche order. Changes create a new plan version or future-dated rule. |
| F-14 | Backup and export | User-initiated JSON backup/restore plus CSV exports for contributions, balance history, and paycheck check-ins. No automatic cloud dependency. |
| F-15 | Privacy, security, and accessibility | No bank credentials or full card numbers; local storage; optional Face ID/app lock; Dynamic Type; VoiceOver labels; high contrast; reduced-motion support. |
| F-16 | Debt-free transition | On payoff, celebrate once and turn the released-payment amount into a Phase II next-goal dashboard for emergency fund, car, retirement, Roth IRA, or investing without auto-enrolling the user. |

---

## Experience and visual language

The visual style should be warm, modern, and financially calm.

- Background: warm off-white or very light gray.
- Primary: deep navy for structure and trust.
- Progress: mint/green for completed or ahead.
- Information: soft blue.
- Allowance/flex cash: warm amber.
- Attention: coral used sparingly; never flood the screen red.
- Cards should have generous spacing, rounded corners, and clear labels.
- Amounts should use tabular numerals and always include currency formatting.
- Charts must have text summaries and remain understandable without color.
- Prefer phrases such as “Today's play,” “On track,” “Needs attention,” “Available—not spent,” and “Next card.”

The dashboard should not look like a spreadsheet squeezed onto a phone. The calendar and detail screens may contain tables, but the main experience should be card-based and action-first.

---

## Hard boundaries

The MVP must not:

- connect to banks or scrape financial accounts;
- request card numbers, CVVs, bank credentials, SSNs, or login details;
- require a web service, account, subscription, analytics SDK, or advertising SDK;
- imply that projections are guaranteed;
- silently mark a planned payment as completed;
- merge the original plan with actual history;
- count the $300 allowance as spent without an actual entry;
- automatically move real money;
- provide investment, tax, or legal advice;
- shame the user for a missed or partial payment.

---

## Success criteria

The MVP succeeds when the user can:

1. install and use it entirely offline;
2. see the exact August 20, 2026–June 24, 2027 plan immediately;
3. complete a payday check-in in under two minutes;
4. enter payments and updated balances without ambiguity;
5. see Checking 1 actual cash and the no-spend ceiling as separate values;
6. see where every planned and actual dollar went;
7. open the calendar and understand past, current, and future actions;
8. receive useful local reminders;
9. see original-plan, actual, and reforecast results without data loss;
10. export a human-readable record and a restorable backup.

The emotional success condition is equally important: after opening the app, the user should feel oriented and capable of taking the next step.

---

## How to use this document

Treat this file as the product constitution. Read it before planning, coding, or changing the data model. If an implementation shortcut conflicts with the product principles or feature contract, preserve the principles and document the tradeoff. Do not remove, rename, or reinterpret any F-01 through F-16 requirement without explicit user approval.
