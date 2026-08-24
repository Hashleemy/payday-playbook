# Payday Playbook — Product Soul

## Product identity

**Working name:** Payday Playbook
**Platform:** Native iPhone app
**Product type:** Offline-first personal debt execution coach
**Primary user:** Any person with take-home pay and debts to eliminate, configured through onboarding. The app's founding install predates the v0.3.0 privacy gate; its original plan (known on that device as **Original Plan v1**) remains preserved there as immutable, user-owned data — see "The founding baseline" below.

Payday Playbook exists to turn a financial plan into a simple ritual the user can actually follow. It is not a generic budgeting app, a bank replacement, or a guilt engine. On every payday it should answer, in this order:

1. What money came in?
2. What stays in the spending account?
3. What moves to the reserves account(s)?
4. What must be reserved for essential obligations?
5. Which debt gets paid, and by how much?
6. What did the user actually do?
7. Is the user ahead, on track, or behind—and what is the next best move?

The app should feel like a calm, friendly playbook. It should reduce decision fatigue, make progress visible, and keep the user connected to their larger goal: becoming debt-free without pretending that every dollar of the personal allowance was spent.

As of v0.2.0 the plan itself is generated from the user's own answers: their checking accounts, income, obligations, protected floor, allowance, and debts. The founding user's plan is no longer hard-coded as the default for fresh installs; it survives, value for value, on the install that already has it. As of v0.3.0 it is also no longer bundled as a template or printed anywhere in the project's tracked artifacts (V3-12): it lives only in that device's local store and in exports its owner deliberately creates.

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

The app never assumes the personal allowance was spent. It records the allowance as **available**. Actual spending or the actual spending-account balance is entered separately. The allowance amount is whatever the user configured.

---

## Guiding principles

### 1. Execution over theory

For a migrated install, the user's own source plan document (kept outside the repository) already contains the strategy; for a new user, onboarding captures their situation and the app generates the strategy once. Either way, the app's job from that point on is execution. Every important screen should end in a clear action, not another layer of analysis.

### 2. Planned, actual, and reforecast are different truths

The original plan is an immutable baseline. User entries are the actual record. A reforecast is a current estimate. Never overwrite one with another.

- **Plan:** what was expected when the baseline plan was generated.
- **Actual:** what the user confirms happened.
- **Reforecast:** what is now expected based on actual balances and contributions.

This applies identically to generated plans: the first plan a user generates becomes their immutable "Plan v1" baseline, exactly as Original Plan v1 is for the founding install. As of v0.3.0 there is also a fourth, throwaway kind of truth: a **scenario preview** exists only on screen until the user deliberately applies it, which creates a new future-effective plan version and changes nothing else (V3-15).

### 3. Available is not spent

The per-paycheck personal allowance is a cap and permission, not a spending target. The app must never subtract it as an actual expense unless the user records spending or confirms a lower spending-account balance.

### 4. One payday, one checklist

Payday check-in should be a guided sequence with prefilled planned values. The user confirms or edits each amount, sees whether the money reconciles, and marks the payday complete.

### 5. Friendly accountability

Use neutral language: “needs attention,” “$84 behind plan,” or “next best move.” Avoid shame, alarmist red, failure streaks, or messages implying moral judgment.

### 6. Local and private by default

The app works without an account, server, subscription, bank login, or internet connection. Financial records remain on the iPhone unless the user explicitly exports a backup. As of v0.3.0 this principle extends to the project itself: no real person's financial data may appear in tracked artifacts — source, fixtures, previews, tests, docs, prompts, logs, screenshots, or reports (V3-12, V3-13).

### 7. Actual balances are authoritative

Interest calculations are estimates. Whenever the user enters a current debt balance, that balance becomes the source of truth for the actual track and reforecast.

### 8. Make the next move obvious

Charts and calendars must support action. The largest visual emphasis belongs to the next action, not decoration.

### 9. Onboarding is a conversation, not a gate

First-run setup asks about goals, posture, accounts, income, obligations, floor, allowance, and debts — in small steps, resumable at any point, with nothing lost on interruption. The user should never have to start over.

---

## The founding baseline — Original Plan v1 (immutable, device-local)

The first install of Payday Playbook (0.1.x) seeded a complete, hand-computed debt plan — **Original Plan v1** — and the app was originally hard-wired to it. That plan is one real person's finances. Two obligations follow, and both hold forever:

1. **On the install that has it, it is untouchable.** Original Plan v1 remains available on that device as an immutable baseline plan version. Every payday row, allocation, attack target, milestone, check-in, and ledger entry it accumulated is preserved value-for-value by every migration. It stays stamped `calculationVersion = 1` forever; regenerating it under any later calculation version is forbidden. Its stored schedule is the truth.
2. **Everywhere else, it does not exist.** As of v0.3.0 (V3-12), no tracked project artifact — source, resource, fixture, preview, test, document, prompt, screenshot, log, or report — may carry its values: no amounts, no dates, no schedule rows, no account or debt inventory, no APRs, no payoff milestones, and no real name. Earlier revisions of this document printed the full plan; those tables are removed, not relocated. The values now live only in the founding device's local store and in exports its owner deliberately creates. (Removing data from the working tree does not erase Git history; history remediation is a separate, owner-decided step — see the v0.3.0 release plan §3.)

The v0.2.0 bundled template ("Original Plan v1 template") is **withdrawn entirely in v0.3.0** — from every build configuration, developer builds included. A real person's plan is not a template. Reusable templates become a user-owned feature instead (V3-10): any user may export their own structure-only template and share it deliberately. Contracted consequences of the withdrawal:

- The 0.1.x crashed-partial-seed repair path, which re-read the bundled resource, is retired. Migration keeps aborting cleanly on such a store — the distribution-build behavior since v0.2.0-alpha.2, and a state that cannot arise for any install whose 0.1.x seed completed.
- Seed and template test suites re-anchor on clearly fictional fixtures. The founding baseline itself is verified only on its own device, by its owner, against records kept outside the repository.

### Calculation version 1 (frozen — formulas only)

Plans stamped `calculationVersion = 1` keep these rules forever:

1. Interest accrues per biweekly check as `balance × APR × 14 ÷ 365`, carried at full `Decimal` precision and rounded only at output.
2. A card's estimated biweekly minimum is `max($17.50, 0.5% of the post-interest balance)`, capped at the remaining balance. Minimums are included inside the total card-payment budget, not added on top.
3. All active cards' minimums are paid first; the remaining card budget attacks the plan's stored priority order, rolling forward to the next card within the same check when a payoff occurs.
4. Actual issuer interest, statement minimums, posting dates, and current balances will differ. User-entered payments and balance snapshots control the actual track; a snapshot overrides accumulated estimates from its date forward.
5. Currency math uses `Decimal`, never binary floating-point.

The constants above are modeling constants, not personal data. The plan's specific inputs — balances, APRs, priorities, dates, schedule — are data on the owning device, not in this document.

---

## Non-negotiable feature contract (v0.1 — still binding)

Every feature below must remain present. Where a later release generalizes a feature, the F-row is *amended*, never removed: the amendment is recorded here, authorized by that release's product mission.

| ID | Feature | Soul-level requirement |
| --- | --- | --- |
| F-01 | Local onboarding and seeded plan | *(Amended in v0.2.0 — see V2-01…V2-10, V2-16.)* Fresh installs no longer auto-load Original Plan v1; they run the configurable onboarding and generate their own baseline. Installs that already have Original Plan v1 keep it untouched. The rest of F-01 stands: onboarding explains the account system, requests notification permission in context, asks for missing real-world debt names, due dates, and minimums, and never blocks use on optional details. *(Amended in v0.3.0: the deliberate template load of the founding plan is withdrawn — V3-10, V3-12.)* |
| F-02 | Five-second dashboard | Shows remaining debt, percent eliminated, plan status, current target, next action, payoff forecast, spending-account tracking, reserves, and current check-in state. *(Generalized by V2-13 to the user's named accounts.)* |
| F-03 | Guided payday check-in | Prefills the plan, requires the user to record what actually happened, reconciles take-home allocations, supports draft and complete states, and never silently fills actuals from planned values. |
| F-04 | Debt account tracker | Shows each debt's balance, APR, minimum, due date, priority, payoff state, history, and contribution total. Allows balance snapshots at any time. *(Extended by V2-04/V2-05 to all debt types.)* |
| F-05 | Contribution ledger | Records every debt payment, transfer, reserve contribution, buffer addition, windfall, refund, and correction with date, amount, source, destination, and note. *(Extended by V3-02/V3-03: deposits, withdrawals, paired account transfers, and manual balance adjustments are equally first-class, auditable events. Quick-entry adjustment presentation generalized in v0.4.0 — V4-06, amendment 6; every historical row remains readable and derivable forever.)* |
| F-06 | Original plan timeline | Preserves every baseline payday, allocation, attack target, debt target, and payoff milestone as an immutable reference. *(Generalized: every install's baseline plan version is equally immutable.)* |
| F-07 | Calendar dashboard | Month/week calendar marks paydays, due dates, completed actions, incomplete actions, milestones, and forecast changes. A selected day opens its exact play-by-play. |
| F-08 | Checking 1 tracker | Separately displays protected floor, current allowance, actual balance, allowance actually used, and no-spend ceiling. It never presents the ceiling as actual cash. *(Generalized by V2-03/V2-08 to the configured spending account and floor; surfaced as a first-class Accounts workspace by V3-02.)* |
| F-09 | Checking 2 tracker | Tracks planned/actual transfers and separate obligation, minimum-payment, and avalanche-payment buckets. It warns if entered uses exceed available reserve funds. *(Generalized by V2-03/V2-07 to configured reserve accounts and obligations; extended by V3-02/V3-03.)* |
| F-10 | Progress and milestones | Includes debt trend, per-debt balances, principal versus modeled interest, percent complete, plan-versus-actual variance, payoff celebrations, and paychecks remaining. |
| F-11 | Local notifications | Supports payday morning, payday evening if incomplete, due-date, weekly summary, and milestone reminders. Notifications deep-link to the relevant check-in or debt. *(Extended by V2-11: due-date edits reschedule immediately. Extended by V3-07/V3-13: full reconciliation hardening; privacy-safe lock-screen copy by default.)* |
| F-12 | Reforecast engine | Recalculates the active target, remaining paychecks, interest estimate, and payoff date after actual entries while leaving the baseline plan version untouched. *(Extended by V3-04/V3-05: scenario and extra-payment previews reuse the same engine without mutating any plan.)* |
| F-13 | Plan and settings editor | Lets the user update paycheck amounts/dates, allowance cap, reserve amounts, APRs, minimums, due dates, notification times, and avalanche order. Changes create a new plan version or future-dated rule. |
| F-14 | Backup and export | User-initiated JSON backup/restore plus CSV exports for contributions, balance history, and paycheck check-ins. No automatic cloud dependency. *(Extended by V2-18: schema-2 backups restore schema-1 files. Extended by V3-09…V3-11: versioned portable envelopes, structure-only templates, and a distinct human-readable PDF report; CSV exports remain.)* |
| F-15 | Privacy, security, and accessibility | No bank credentials or full card numbers; local storage; optional Face ID/app lock; Dynamic Type; VoiceOver labels; high contrast; reduced-motion support. *(Extended by V3-12/V3-13/V3-16.)* |
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
| V2-07 | Essential recurring obligations | The user lists essential recurring obligations with amount, cadence, and optional due date. The plan reserves for them every paycheck using the documented smoothing rule. *(Presented as **Bills** from v0.3.0 — V3-08.)* |
| V2-08 | Protected cash floor | A configurable floor the spending account must never be planned below. The generated plan tops the floor up before any extra debt payment. |
| V2-09 | Allowance cap | A configurable per-paycheck personal allowance. It stays "available, not spent" — the soul principle is unchanged, only the amount is the user's own. |
| V2-10 | Generated avalanche plan | From the user's inputs the engine generates an immutable baseline plan: all minimums paid, every remaining dollar to the highest-APR extra-principal-eligible debt, rolling forward on payoff — designed to minimize estimated interest and reach payoff as quickly as the floor, allowance, and obligations allow. Projections are labeled estimates, never guarantees. |
| V2-11 | Editable due dates drive calendar and notifications | Editing any due date takes effect immediately: calendar markers move and pending local notifications are rescheduled through stable identifiers, with no duplicates and no orphans. |
| V2-12 | Plan calendar | The calendar works for generated plans exactly as it does for the migrated baseline: paydays, due dates, milestones, completed and incomplete actions, and a per-day play-by-play. |
| V2-13 | Friendly dashboard | The five-second promise holds for every user: the dashboard shows their named accounts, their floor, their allowance, their next play — calm, card-based, action-first. |
| V2-14 | Insights | Insight cards translate the numbers into next moves: estimated interest saved versus minimums-only, payoff-date changes, card utilization (30% info / 90% attention), obligation crunch paychecks, allowance usage trend. Every insight is worded as an estimate and never shames. |
| V2-15 | Actual tracking and reforecasting | Check-ins, the ledger, balance snapshots, and reforecasts operate on generated plans with full fidelity. Planned, actual, and reforecast remain three separate truths for every user. |
| V2-16 | Current-user migration | Upgrading a 0.1.x install preserves Original Plan v1's exact baseline — every payday, value, milestone, and check-in — plus all history and settings, with no re-onboarding. Fresh installs never receive that plan. *(Amended in v0.3.0: the deliberate template load is withdrawn — V3-10, V3-12.)* |
| V2-17 | Local-only privacy | Nothing changed and nothing may change: local storage, no accounts, no telemetry, no bank credentials, ever. |
| V2-18 | Accessibility, Decimal math, export compatibility | Every new screen meets the existing accessibility bar (Dynamic Type, VoiceOver, Reduce Motion, 44-pt targets). All money stays `Decimal`. Newer backups restore older backup files; CSV columns are append-only. |

---

## v0.3.0 feature contract (V3-01 … V3-16)

The canonical registry lives in `ALPHA_V0.3.0_MULTI_AGENT_PLAN.md`; the soul-level requirement for each item is stated here. `MVP_LAYOUT.md` carries the screens, rules, models, migration, and services (§4–§10) and the acceptance criteria (§11).

| ID | Feature | Soul-level requirement |
| --- | --- | --- |
| V3-01 | Release and migration | v0.3.0 upgrades a v0.2.x install without losing a single account, debt, bill, actual entry, plan version, due date, or notification preference — and without duplicating any of them. Fresh installs start empty, with no real person's data anywhere. |
| V3-02 | Checking Accounts page | One calm, first-class place shows every active checking account — name, roles, current balance with its as-of moment, protected amount, available amount, default-income marker, next planned movement — and supports add, edit, reorder, archive, transfer, and balance adjustment. |
| V3-03 | Auditable balance adjustments | Correcting a balance is a recorded event: a dated adjustment or authoritative snapshot with an optional note. It never silently rewrites transaction history. Negative or unreconciled states get calm, specific warnings. |
| V3-04 | Extra-payment insight | "What if I pay extra?" answers with estimates — payoff-date change, time saved, interest saved, projected principal reduction — for one-time and recurring extra payments, and never touches the active plan until the user explicitly applies a scenario. |
| V3-05 | Three-plan payoff calculator | From saved inputs plus a user-entered income/paycheck override, the app computes exactly three scenarios — **Fastest Safe**, **Balanced (Recommended)**, and **More Cushion** — each showing payoff date, time remaining, estimated interest, total paid, periodic debt contribution, cash retained, and tradeoffs. *(Amended in v0.4.0 — V4-03: Balanced selects its attack order by the guardrailed quick-win policy, defaulting to avalanche; the three names, cards, and never-auto-apply rule are unchanged.)* |
| V3-06 | Honest scenario inputs | A payoff estimate requires real inputs: debts, balances, APR assumptions, minimums, due dates, bills, pay cadence, protected cash, and scenario constraints. The app names what is missing or estimated instead of inventing values. Money math stays `Decimal`; calculations are versioned and deterministic. |
| V3-07 | Editable due dates | Debt and bill due dates stay editable from setup and from every detail/settings surface. A prospective edit immediately rebuilds the affected calendar events and reconciles local notifications — no duplicates, no stale reminders, history untouched. |
| V3-08 | Consolidated Bills & Debts setup | Bills and debts live on one setup page: two clear sections, one add flow whose first choice is `Bill` or `Debt`. Every v0.2 field, validation, debt type, and the resumability contract survive intact. |
| V3-09 | Full JSON backup and restore | The user can export all local data to a versioned JSON backup and restore it through a validated preview and an atomic import. The app warns that the file contains sensitive financial data and never uploads it anywhere. |
| V3-10 | Reusable JSON templates | A template is a separate, versioned, structure-only document: configuration in, history and personal values out unless the user explicitly and knowingly includes them. Templates are previewable before they are applied and never silently replace actual history. |
| V3-11 | Generate Report | One distinct **Generate Financial Report** action produces a readable, local PDF of the user's current inputs and computed results. Raw JSON stays under **Back Up Data** and is never presented as the report. |
| V3-12 | Personal-data removal | No real person's balances, income, account labels, dates, payoff schedules, or name appears in any tracked artifact — source, fixtures, previews, comments, tests, docs, prompts, screenshots, or logs. Test and preview data is clearly fictional. Existing user data survives only in the local store and migration path. |
| V3-13 | Privacy-safe diagnostics | No raw balance, account name, imported payload, or report content reaches analytics, crash breadcrumbs, debug output, notification identifiers, test reports, or agent reports. Notifications stay discreet unless the user opts into detail. |
| V3-14 | Comment cleanup | Comments explain non-obvious intent, invariants, platform limitations, security decisions, or formulas. Narration, personal context, obsolete plans, and doc duplication go. Useful warnings and API documentation stay. |
| V3-15 | Plan separation | Scenario previews, active plans, historical plans, and actual entries remain distinct. Applying a scenario creates a new future-effective plan version and never rewrites a baseline or completed history. |
| V3-16 | Accessibility and recovery | New screens support Dynamic Type, VoiceOver, high contrast, Reduce Motion, and sensible focus behavior, with real empty/error/loading states. Interrupted imports, denied notifications, and failed report generation recover calmly, with the user's data intact. |

---

## v0.4.0 feature contract (V4-01 … V4-08)

The canonical registry lives in `ALPHA_V0.4.0_MULTI_AGENT_PLAN.md`; the soul-level
requirement for each item is stated here. `MVP_LAYOUT.md` carries the screens, rules,
models, services, and acceptance criteria; `docs/releases/v0.4.0/VERSIONING.md` carries
the version contract.

| ID | Feature | Soul-level requirement |
| --- | --- | --- |
| V4-01 | Debt-type-specific validation | The app only ever asks for what a debt type can meaningfully answer. A revolving credit card has no fixed "original principal" and is never asked for one, warned about one, or listed as needing one — anywhere. Installment-style debts keep it as a helpful optional detail. One semantic rule per debt type drives every editor, chip, gap list, and checklist; three surfaces never disagree. |
| V4-02 | Reactive onboarding and setup | Setup answers are the user's canonical truth, and everything derived from them follows immediately. Going back, changing an answer, and moving forward recomputes every downstream validation, summary, preview, projection, and recommendation — nothing stale ever survives because a screen was already visited. Entered inputs are never lost by navigation (V2-01 stands whole). |
| V4-03 | Smarter Balanced strategy | Balanced (Recommended) earns its recommendation: it weighs the pure avalanche order against genuinely simulated quick-win alternatives — retiring a small debt early to simplify the stack and release its minimum — and chooses by transparent, deterministic guardrails, never by hidden scoring. It explains its choice in plain words, admits when a quick win costs more estimated interest, and claims nothing the engine did not prove. Fastest Safe stays the mathematically aggressive baseline. No plan a user already has changes value. |
| V4-04 | Correct credit utilization | Utilization is one honest number: current revolving balance against a real credit limit, in exact decimal math. An unknown limit means "unknown", never 0%. A balance above the limit reads above 100%. Every screen and every warning threshold consumes the same calculation. |
| V4-05 | Legible primary actions | The next action must be visible before it is read: primary buttons use one semantic treatment with real contrast in light and dark appearance. An interactive button never looks disabled, and a disabled one never looks interactive. Dynamic Type, VoiceOver, and comfortable touch targets are part of the treatment, not an afterthought. |
| V4-06 | Generic checking-account adjustment | Recording a balance correction speaks the user's language, not the founding install's: "Checking account adjustment," then the user's own account, type, amount, date, and note. Every correction is an auditable dated event through the one ledger service — history is never rewritten, "set balance to…" records the computed difference, and every ledger row ever written stays readable. |
| V4-07 | Pay-cycle debt allocation | The app can always answer "how much of my planned debt money is left right now?" — as a pay-cycle fact, not a calendar-month blur. Available = carry-in + this cycle's planned allocation; recording a payment lowers the remainder immediately; unused funds roll forward; overspending shows $0 remaining plus the honest overage, never invented negative money. Planned allocation, actual cash, and recorded payments are three labeled truths, and money that arrives next payday is never spendable today. |
| V4-08 | Calendar debt dashboard | The Calendar tells the debt story at a glance: paid toward debts this month, this cycle's allocation with carry-in, used, and remaining, what becomes available next payday, and any debts fully cleared this month. Dollars paid toward debt are never called "paid off." The numbers move the moment the ledger does. |

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
- Scenario names are exactly **Fastest Safe**, **Balanced (Recommended)**, and **More Cushion**. Balanced is visually recommended, never auto-applied, and every scenario card speaks in tradeoffs and labeled estimates, not promises.

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
- force the founding user's plan, amounts, or dates onto any other user;
- apply, persist, or activate a scenario preview without the user's explicit confirmation;
- upload or transmit a backup, template, or report anywhere automatically.

And the project must not:

- carry any real person's financial data in tracked artifacts — code, fixtures, previews, tests, docs, prompts, screenshots, logs, commits, or reports (V3-12);
- print financial payloads in logs, diagnostics, notification identifiers, or test output (V3-13).

---

## Success criteria

The v0.1 criteria remain (offline use, two-minute check-in, unambiguous entry, separated actual/ceiling values, full audit trail, calendar clarity, useful reminders, three-truths integrity, export/restore) — with one recorded amendment: old criterion 2, seeing the install's exact original plan immediately, applies to migrated installs rather than every fresh install. v0.2.0 adds:

1. a brand-new user can go from install to a generated, personalized avalanche plan without ever seeing another person's financial data;
2. onboarding survives any interruption and resumes where it left off;
3. a 0.1.x user upgrades and finds their plan, history, and reminders exactly as they were;
4. every debt type in the picker can be entered with its own fields and appears correctly in plan, calendar, and insights;
5. editing a due date is reflected in calendar and notifications before the user leaves the screen;
6. all ambiguous money behavior is covered by a written rule in `MVP_LAYOUT.md` §5 or explicitly marked as one of its numbered assumptions.

v0.3.0 adds:

1. the tracked repository contains no real person's financial data, and a fresh install contains none either;
2. a v0.2.x upgrade preserves every local record exactly once — nothing lost, nothing duplicated;
3. the user can see all their cash accounts in one place, and every balance change is an auditable event;
4. the three scenarios and any extra-payment preview reconcile to the core engine to the cent, name their assumptions and missing inputs, and never touch the active plan until deliberately applied;
5. a full JSON backup round-trips atomically, a template stays structure-only by default, and the financial report is a readable local PDF — three documents never confused for one another;
6. a due-date edit lands on the calendar and in exactly one correct set of reminders before the editor closes.

The emotional success condition is equally important: after opening the app, the user should feel oriented and capable of taking the next step.

---

## How to use this document

Treat this file as the product constitution. Read it before planning, coding, or changing the data model. If an implementation shortcut conflicts with the product principles or feature contract, preserve the principles and document the tradeoff. Do not remove, rename, or reinterpret any F-01…F-16, V2-01…V2-18, V3-01…V3-16, or V4-01…V4-08 requirement without explicit user approval.

**Amendment registry** (every amendment is authorized by the named release's product mission):

1. *(v0.2.0)* F-01 fresh-install amendment: fresh installs onboard and generate their own plan instead of auto-loading Original Plan v1.
2. *(v0.2.0)* Success-criterion-2 amendment: "see the exact original plan immediately" applies to migrated installs, not fresh ones.
3. *(v0.3.0 — privacy gate, V3-12)* Personal-data presentation supersession: every tracked document keeps each requirement's behavior, but the founding user's values, dates, schedules, and name are removed from all tracked artifacts. The behavior contracts are unchanged; only their presentation with real data is superseded.
4. *(v0.3.0 — V3-10/V3-12)* Template withdrawal: the bundled "Original Plan v1 template" and its loader affordances are removed from every build configuration. This supersedes the v0.2.0 template provision and the v0.2.0-alpha.2 Release-exclusion amendment (full removal is strictly stronger). User-exported structure-only templates (V3-10) replace the concept.
5. *(v0.3.0 — V3-08)* Consolidated setup: the separate bills and debts setup pages are superseded by one Bills & Debts page — presentation only; every field, validation, and resumability guarantee survives.
6. *(v0.4.0 — V4-06)* Quick-entry adjustment supersession: the Add Entry menu's legacy "Checking 1 / 2 adjustment" sheet — seven hard-coded entry kinds carrying the founding install's account and reserve vocabulary — is superseded by the generic "Checking account adjustment" flow over the user's own accounts, routed through the auditable ledger service. Every historical row of every legacy entry type remains readable, rendered, and included in balance derivations forever; only the writer of new legacy-shaped rows is retired (the zero-amount Note entry is unaffected). F-05 and F-09 behavior contracts are unchanged; only the entry vocabulary is generalized.
7. *(v0.4.0 — V4-03)* Balanced strategy enrichment: Balanced (Recommended)'s attack order is chosen by the deterministic, guardrailed quick-win policy (`MVP_LAYOUT.md` §5 R-25…R-27) over complete engine simulations, defaulting to the pure avalanche order when no quick win passes the guardrails. The scenario names, the recommended-but-never-auto-applied rule, the honest-inputs contract, and every existing stored plan's value are unchanged; V2-10's generated baseline plan (no scenario) still reduces to the pure avalanche result exactly.
