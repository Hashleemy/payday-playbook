# Payday Playbook — Product Soul

## Product identity

**Working name:** Payday Playbook
**Platform:** Native iPhone app
**Product type:** Offline-first personal debt execution coach
**Primary user:** Any person with take-home pay and debts to eliminate, configured through onboarding. The first user is Master Lem, whose exact plan (August 20, 2026 through June 24, 2027) is preserved as an immutable personal baseline and bundled template — see "Master Lem's baseline" below.

Payday Playbook exists to turn a financial plan into a simple ritual the user can actually follow. It is not a generic budgeting app, a bank replacement, or a guilt engine. On every payday it should answer, in this order:

1. What money came in?
2. What stays in the spending account?
3. What moves to the reserves account(s)?
4. What must be reserved for essential obligations?
5. Which debt gets paid, and by how much?
6. What did the user actually do?
7. Is the user ahead, on track, or behind—and what is the next best move?

The app should feel like a calm, friendly playbook. It should reduce decision fatigue, make progress visible, and keep the user connected to their larger goal: becoming debt-free without pretending that every dollar of the personal allowance was spent.

As of v0.2.0 the plan itself is generated from the user's own answers: their checking accounts, income, obligations, protected floor, allowance, and debts. Master Lem's plan is no longer hard-coded as the default for fresh installs; it survives, value for value, for the install that already has it and as an optional template.

---

## The promise

When the user opens the app, they should understand their position in under five seconds.

The home screen must clearly show:

- total remaining debt;
- original plan versus actual progress;
- the next payday action;
- the current avalanche target;
- days and paychecks remaining;
- the spending account's actual balance;
- the protected cash floor;
- the spending account's no-spend ceiling;
- reserved amounts for essential obligations;
- whether the current check-in is complete.

The app never assumes the personal allowance was spent. It records the allowance as **available**. Actual spending or the actual spending-account balance is entered separately. (For Master Lem's baseline the allowance is $300 per paycheck; for other users it is whatever they configured.)

---

## Guiding principles

### 1. Execution over theory

For a migrated install, the source PDF already contains the strategy; for a new user, onboarding captures their situation and the app generates the strategy once. Either way, the app's job from that point on is execution. Every important screen should end in a clear action, not another layer of analysis.

### 2. Planned, actual, and reforecast are different truths

The original plan is an immutable baseline. User entries are the actual record. A reforecast is a current estimate. Never overwrite one with another.

- **Plan:** what was expected when the baseline plan was generated (for Master Lem: August 9, 2026).
- **Actual:** what the user confirms happened.
- **Reforecast:** what is now expected based on actual balances and contributions.

This applies identically to generated plans: the first plan a user generates becomes their immutable "Plan v1" baseline, exactly as Original Plan v1 is for Master Lem.

### 3. Available is not spent

The per-paycheck personal allowance is a cap and permission, not a spending target. The app must never subtract it as an actual expense unless the user records spending or confirms a lower spending-account balance.

### 4. One payday, one checklist

Payday check-in should be a guided sequence with prefilled planned values. The user confirms or edits each amount, sees whether the money reconciles, and marks the payday complete.

### 5. Friendly accountability

Use neutral language: “needs attention,” “$84 behind plan,” or “next best move.” Avoid shame, alarmist red, failure streaks, or messages implying moral judgment.

### 6. Local and private by default

The app works without an account, server, subscription, bank login, or internet connection. Financial records remain on the iPhone unless the user explicitly exports a backup.

### 7. Actual balances are authoritative

Interest calculations are estimates. Whenever the user enters a current debt balance, that balance becomes the source of truth for the actual track and reforecast.

### 8. Make the next move obvious

Charts and calendars must support action. The largest visual emphasis belongs to the next action, not decoration.

### 9. Onboarding is a conversation, not a gate

First-run setup asks about goals, posture, accounts, income, obligations, floor, allowance, and debts — in small steps, resumable at any point, with nothing lost on interruption. The user should never have to start over.

---

## Master Lem's baseline — Original Plan v1 (immutable personal baseline and template)

This plan was seeded on first launch of the 0.1.x MVP and must remain available forever as **Original Plan v1** on any install that has it. On upgrade to 0.2.0 migration preserves every existing value — every date, amount, milestone, check-in, and ledger entry — adding new fields and rows around them but never altering one. It is **not** seeded on unrelated fresh installs; new users generate their own baseline in onboarding. The plan also ships as a bundled, clearly labeled template ("Original Plan v1 template") that a user may deliberately load instead of generating a plan.

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

Original Plan v1 is stamped **calculation version 1** forever; regenerating it under any later calculation version is forbidden. Its stored schedule is the truth.

---

## Non-negotiable feature contract (v0.1 — still binding)

Every feature below must remain present. Where v0.2.0 generalizes a feature, the F-row is *amended*, never removed: the amendment is recorded here, authorized by the v0.2.0 product mission.

| ID | Feature | Soul-level requirement |
| --- | --- | --- |
| F-01 | Local onboarding and seeded plan | *(Amended in v0.2.0 — see V2-01…V2-10, V2-16.)* Fresh installs no longer auto-load Original Plan v1; they run the configurable onboarding and generate their own baseline. Installs that already have Original Plan v1 keep it untouched. The rest of F-01 stands: onboarding explains the account system, requests notification permission in context, asks for missing real-world debt names, due dates, and minimums, and never blocks use on optional details. |
| F-02 | Five-second dashboard | Shows remaining debt, percent eliminated, plan status, current target, next action, payoff forecast, spending-account tracking, reserves, and current check-in state. *(Generalized by V2-13 to the user's named accounts.)* |
| F-03 | Guided payday check-in | Prefills the plan, requires the user to record what actually happened, reconciles take-home allocations, supports draft and complete states, and never silently fills actuals from planned values. |
| F-04 | Debt account tracker | Shows each debt's balance, APR, minimum, due date, priority, payoff state, history, and contribution total. Allows balance snapshots at any time. *(Extended by V2-04/V2-05 to all debt types.)* |
| F-05 | Contribution ledger | Records every debt payment, transfer, reserve contribution, buffer addition, windfall, refund, and correction with date, amount, source, destination, and note. |
| F-06 | Original plan timeline | Preserves all 23 baseline paydays, allocations, attack targets, debt targets, and payoff milestones as an immutable reference. *(Generalized: every install's baseline plan version is equally immutable.)* |
| F-07 | Calendar dashboard | Month/week calendar marks paydays, due dates, completed actions, incomplete actions, milestones, and forecast changes. A selected day opens its exact play-by-play. |
| F-08 | Checking 1 tracker | Separately displays protected floor, current allowance, actual balance, allowance actually used, and no-spend ceiling. It never presents the ceiling as actual cash. *(Generalized by V2-03/V2-08 to the configured spending account and floor.)* |
| F-09 | Checking 2 tracker | Tracks planned/actual transfers and separate obligation, minimum-payment, and avalanche-payment buckets. It warns if entered uses exceed available reserve funds. *(Generalized by V2-03/V2-07 to configured reserve accounts and obligations.)* |
| F-10 | Progress and milestones | Includes debt trend, per-debt balances, principal versus modeled interest, percent complete, plan-versus-actual variance, payoff celebrations, and paychecks remaining. |
| F-11 | Local notifications | Supports payday morning, payday evening if incomplete, due-date, weekly summary, and milestone reminders. Notifications deep-link to the relevant check-in or debt. *(Extended by V2-11: due-date edits reschedule immediately.)* |
| F-12 | Reforecast engine | Recalculates the active target, remaining paychecks, interest estimate, and payoff date after actual entries while leaving the baseline plan version untouched. |
| F-13 | Plan and settings editor | Lets the user update paycheck amounts/dates, allowance cap, reserve amounts, APRs, minimums, due dates, notification times, and avalanche order. Changes create a new plan version or future-dated rule. |
| F-14 | Backup and export | User-initiated JSON backup/restore plus CSV exports for contributions, balance history, and paycheck check-ins. No automatic cloud dependency. *(Extended by V2-18: schema-2 backups restore schema-1 files.)* |
| F-15 | Privacy, security, and accessibility | No bank credentials or full card numbers; local storage; optional Face ID/app lock; Dynamic Type; VoiceOver labels; high contrast; reduced-motion support. |
| F-16 | Debt-free transition | On payoff, celebrate once and turn the released-payment amount into a Phase II next-goal dashboard for emergency fund, car, retirement, Roth IRA, or investing without auto-enrolling the user. |

---

## v0.2.0 feature contract (V2-01 … V2-18)

The canonical registry lives in `ALPHA_V0.2.0_MULTI_AGENT_PLAN.md`; the soul-level requirement for each item is stated here. `MVP_LAYOUT.md` §4–§10 carries the screens, models, rules, migration, and services; §11 holds the acceptance criteria for every ID.

| ID | Feature | Soul-level requirement |
| --- | --- | --- |
| V2-01 | Resumable first-run onboarding | Setup is a sequence of small steps. Every completed step is persisted immediately; killing or leaving the app resumes at the next incomplete step with nothing lost. Finishing generates the plan atomically — an interrupted finish never produces duplicates or a half-seeded install. |
| V2-02 | Goals and payoff posture | Onboarding asks what the user is working toward (free text plus optional target debt-free date) and their payoff posture (Full throttle / Steady / Cushion first). Answers shape suggested defaults and dashboard copy only; they never silently change money math after the plan is generated. |
| V2-03 | Multiple checking accounts | The user names their real checking accounts, enters current balances, and assigns roles: income, spending, reserves. Exactly one account is the default income account. The app never asks for credentials — names and balances the user types, nothing more. |
| V2-04 | Debt type picker | Adding a debt begins by choosing its type: credit card, personal loan, car note / auto loan, student loan, medical debt, or other. The type drives which fields appear and how minimums are handled. |
| V2-05 | Debt-specific inputs | Each debt records current balance/principal, original principal, APR, minimum payment, and an editable due date. Credit cards additionally record an optional credit limit, from which utilization is displayed. Each debt carries an extra-principal eligibility flag; ineligible debts receive minimums only. |
| V2-06 | Income setup | The user enters take-home per paycheck, the next payday date, pay cadence (weekly, biweekly, semimonthly, monthly), and which account receives income. Future-dated income changes (raises, cuts) are first-class and feed the plan and reforecast. |
| V2-07 | Essential recurring obligations | The user lists essential recurring obligations with amount, cadence, and optional due date. The plan reserves for them every paycheck using the documented smoothing rule, exactly as Master Lem's car and train were reserved. |
| V2-08 | Protected cash floor | A configurable floor the spending account must never be planned below. The generated plan tops the floor up before any extra debt payment. |
| V2-09 | Allowance cap | A configurable per-paycheck personal allowance. It stays "available, not spent" — the soul principle is unchanged, only the amount is now the user's. |
| V2-10 | Generated avalanche plan | From the user's inputs the engine generates an immutable baseline plan: all minimums paid, every remaining dollar to the highest-APR extra-principal-eligible debt, rolling forward on payoff — designed to minimize estimated interest and reach payoff as quickly as the floor, allowance, and obligations allow. Projections are labeled estimates, never guarantees. |
| V2-11 | Editable due dates drive calendar and notifications | Editing any due date takes effect immediately: calendar markers move and pending local notifications are rescheduled through stable identifiers, with no duplicates and no orphans. |
| V2-12 | Plan calendar | The calendar works for generated plans exactly as it does for Original Plan v1: paydays, due dates, milestones, completed and incomplete actions, and a per-day play-by-play. |
| V2-13 | Friendly dashboard | The five-second promise holds for every user: the dashboard shows their named accounts, their floor, their allowance, their next play — calm, card-based, action-first. |
| V2-14 | Insights | Insight cards translate the numbers into next moves: estimated interest saved versus minimums-only, payoff-date changes, card utilization (30% info / 90% attention), obligation crunch paychecks, allowance usage trend. Every insight is worded as an estimate and never shames. |
| V2-15 | Actual tracking and reforecasting | Check-ins, the ledger, balance snapshots, and reforecasts operate on generated plans with full fidelity. Planned, actual, and reforecast remain three separate truths for every user. |
| V2-16 | Current-user migration | Upgrading a 0.1.x install preserves Original Plan v1's exact 23-paycheck Aug 20, 2026 – Jun 24, 2027 baseline, all history, and all settings, with no re-onboarding. Fresh installs never receive that plan unless they deliberately load the template. |
| V2-17 | Local-only privacy | Nothing changed and nothing may change: local storage, no accounts, no telemetry, no bank credentials, ever. |
| V2-18 | Accessibility, Decimal math, export compatibility | Every new screen meets the existing accessibility bar (Dynamic Type, VoiceOver, Reduce Motion, 44-pt targets). All money stays `Decimal`. Version-2 backups restore version-1 backup files; CSV columns are append-only. |

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

The dashboard should not look like a spreadsheet squeezed onto a phone. The calendar and detail screens may contain tables, but the main experience should be card-based and action-first. Onboarding follows the same language: one question at a time, plain words, no jargon walls.

---

## Hard boundaries

The app must not:

- connect to banks or scrape financial accounts;
- request card numbers, CVVs, bank credentials, SSNs, or login details;
- require a web service, account, subscription, analytics SDK, or advertising SDK;
- imply that projections are guaranteed;
- silently mark a planned payment as completed;
- merge the original plan with actual history;
- count the personal allowance as spent without an actual entry;
- automatically move real money;
- provide investment, tax, or legal advice;
- shame the user for a missed or partial payment;
- regenerate, edit, or delete any baseline plan version — including Original Plan v1;
- force Master Lem's plan, amounts, or dates onto a new user.

---

## Success criteria

The v0.1 criteria remain (offline use, two-minute check-in, unambiguous entry, separated actual/ceiling values, full audit trail, calendar clarity, useful reminders, three-truths integrity, export/restore) — with one recorded amendment: old criterion 2, "see the exact August 20, 2026–June 24, 2027 plan immediately," now applies to migrated installs and deliberate template loads rather than every fresh install. v0.2.0 adds:

1. a brand-new user can go from install to a generated, personalized avalanche plan without ever seeing Master Lem's numbers;
2. onboarding survives any interruption and resumes where it left off;
3. a 0.1.x user upgrades and finds their plan, history, and reminders exactly as they were;
4. every debt type in the picker can be entered with its own fields and appears correctly in plan, calendar, and insights;
5. editing a due date is reflected in calendar and notifications before the user leaves the screen;
6. all ambiguous money behavior is covered by a written rule in `MVP_LAYOUT.md` §5 or explicitly marked as one of its numbered assumptions (A-01…A-08, wherever they appear in §4–§5).

The emotional success condition is equally important: after opening the app, the user should feel oriented and capable of taking the next step.

---

## How to use this document

Treat this file as the product constitution. Read it before planning, coding, or changing the data model. If an implementation shortcut conflicts with the product principles or feature contract, preserve the principles and document the tradeoff. Do not remove, rename, or reinterpret any F-01 through F-16 or V2-01 through V2-18 requirement without explicit user approval. Exactly two amendments exist, both authorized by the v0.2.0 product mission: the F-01 fresh-install amendment and the success-criterion-2 amendment recorded above.
