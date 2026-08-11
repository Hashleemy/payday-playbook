# Payday Playbook — Product and Technical Layout (v0.2.0)

## 1. Build brief

Build a native, offline-first iPhone app named **Payday Playbook** using SwiftUI. As of v0.2.0 the app is a personal execution companion for a debt plan **generated from the user's own situation** — accounts, income, obligations, floor, allowance, and debts — while preserving the original seeded plan (Master Lem's Original Plan v1) verbatim for the install that already has it. The app must allow the user to record real contributions and balances, compare actual progress with their original plan, receive local notifications, and understand the entire payoff calendar at a glance.

Read `soul.md` first. Its principles, the F-01…F-16 contract (as amended), and the V2-01…V2-18 contract are non-negotiable. The canonical V2 registry is `ALPHA_V0.2.0_MULTI_AGENT_PLAN.md`.

### Technical baseline

- Language: Swift.
- UI: SwiftUI.
- Persistence: SwiftData with local storage.
- Charts: Swift Charts.
- Notifications: UserNotifications with calendar-based local triggers.
- Security: LocalAuthentication for optional Face ID/app lock.
- Deployment target: iOS 17.0 or newer.
- Architecture: feature-oriented MVVM with services for calculations, notifications, exports, and plan generation.
- Dependencies: Apple frameworks only.
- Money type: `Decimal` with explicit currency rounding to two decimals (half-away-from-zero via `.rounded2`), rounded only at persistence/display boundaries. *(V2-18)*
- Dates: `Calendar` and `DateComponents`; persist a normalized local date and user time zone.
- No backend, login, telemetry, ads, bank linking, or automatic money movement. *(V2-17)*

---

## 2. Versioning contract

Full detail in `docs/releases/v0.2.0/VERSIONING.md`. Summary, binding for this release:

| Version | Value | Rule |
| --- | --- | --- |
| App version (`MARKETING_VERSION`) | **0.2.0** | SemVer. The 0.1.x MVP is the baseline (the scaffold `1.0` value was a template artifact, corrected in this branch). Backward-compatible feature release → minor bump. |
| Prerelease tag | **v0.2.0-alpha.1** | Annotated git tag created only when the alpha build is actually cut. `-alpha.N` increments per alpha cut; the bare `v0.2.0` tag marks the final. Recommend retro-tagging current `main` as `v0.1.0`. |
| Build number (`CURRENT_PROJECT_VERSION`) | 2 | A plain integer, strictly increasing across every distributed build of every version, incremented by exactly 1 per distributed build, never reset. The 0.1.x MVP is build 1. |
| Persistence schema version (`PlanContract.schemaVersion`) | **2** | Bumped because v0.2.0 adds/changes stored models (§6). Migration from 1 is mandatory and lossless (§7). |
| Calculation version | **2** for newly generated plans | Original Plan v1 keeps `calculationVersion = 1` forever; its stored schedule is never recomputed. Calc v2 (§5) reduces exactly to calc v1 for a biweekly cadence. |
| Backup schema version (`ExportService.backupSchemaVersion`) | **2** | Writes v2; imports v1 and v2. Importing v1 runs the same logical migration as §7. |
| User plan versions | "Original Plan v1", "Plan v1", "Plan v2", … | **Data, not software.** Per-install `PlanVersion` rows. Never conflate with the app version: "Original Plan v1" is Master Lem's baseline row, not app 1.0. |

---

## 3. Master Lem's baseline — Original Plan v1 (migrated, immutable)

In 0.1.x this plan was seeded on first launch. In v0.2.0 it is **not** seeded on fresh installs *(V2-16)*. It exists in exactly two ways:

1. **By migration:** an upgraded 0.1.x install keeps its Original Plan v1, check-ins, ledger, snapshots, milestones, and settings value-for-value — migration adds new fields and rows but never alters an existing value (§7).
2. **By template:** the bundled `OriginalPlanV1.json` remains in the app as a clearly labeled template a user may deliberately load from onboarding's advanced option or Settings → Plan versions → "Load Original Plan v1 template". Loading it creates an immutable plan version exactly as 0.1.x seeding did.

Original Plan v1 is immutable in either case. User changes create actual records, future-dated settings, or a new plan version; they never rewrite it. It stays stamped `calculationVersion = 1`.

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

### Baseline calculation rules (calculation version 1 — frozen)

1. Accrue 14 days of estimated interest before each planned payment: `balance × APR × 14 / 365`.
2. Estimated biweekly minimum per active card is `max($17.50, postInterestBalance × 0.005)`, capped at its remaining balance.
3. Pay minimums on all active cards.
4. Apply the rest of the card budget to the first active debt in B → D → A → F → C → E order.
5. Roll unused attack money to the next card in the same transaction if the target is paid off.
6. The actual track uses user-entered payment and balance records. A balance snapshot overrides accumulated estimates from that date forward.

These rules remain frozen for any plan stamped `calculationVersion = 1`. New plans use §5.

---

## 4. First-run onboarding (v0.2.0) — V2-01 … V2-09

Replaces the 0.1.x four-screen seeded onboarding for fresh installs. Migrated installs (§7) never see it; they may revisit any step later via Settings → "Review setup".

### 4.0 Resumability contract — V2-01

- Progress lives in a persisted `OnboardingState` row: `lastCompletedStep`, per-step draft payloads, `startedAt`, `completedAt`.
- Every `Continue` writes that step's data and advances `lastCompletedStep` in one transaction before the next screen appears.
- On launch with `completedAt == nil` and `lastCompletedStep > .none`, the app resumes at the first incomplete step with all prior answers intact and shows "Picking up where you left off."
- `Back` is always available and never destroys saved data; editing an earlier step preserves later steps unless they become invalid (then those steps are flagged, not wiped).
- Finishing (§4.9) generates the plan atomically: either the whole plan version, accounts, obligations, debts, and milestones commit together and `completedAt` is set, or nothing commits and the user can retry. A relaunch mid-generation resumes safely without duplicate rows (same idempotency bar as the 0.1.x seeder).
- Screen states for every step: **empty → partially filled (validation inline) → valid (Continue enabled) → saved**. Validation errors are calm, specific, and never lose input.

### Step sequence

| # | Step | Feature |
| --- | --- | --- |
| 1 | Welcome and privacy promise | V2-17 |
| 2 | Goals and payoff posture | V2-02 |
| 3 | Checking accounts | V2-03 |
| 4 | Income and paydays | V2-06 |
| 5 | Essential obligations | V2-07 |
| 6 | Floor and allowance | V2-08, V2-09 |
| 7 | Debts (repeatable) | V2-04, V2-05 |
| 8 | Review and generate plan | V2-10 |
| 9 | Notifications | (F-11) |

### 4.1 Step 1 — Welcome

- Promise: "Know today's play. Record what happened. See the finish line."
- Statement that all data stays on this iPhone unless the user exports it; no accounts, no bank logins, ever.
- Primary: `Set Up My Plan`. Secondary (advanced, de-emphasized): `Load a template` → Original Plan v1 template (§3), shown with Master Lem's headline numbers and an explicit warning that it is a specific person's plan, not a recommendation.

### 4.2 Step 2 — Goals and payoff posture — V2-02

- "What are you working toward?" — free-text goal (optional, e.g. "debt-free before the wedding"), shown later on the dashboard.
- Optional target debt-free date (month/year picker). Used for the goal-gap insight (§5 R-13) only; it never alters allocation.
- Payoff posture, single choice:
  - **Full throttle** — every spare dollar attacks debt.
  - **Steady** — strong payments with breathing room.
  - **Cushion first** — build the cash floor before going hard.
- **Rule:** posture affects *suggested defaults* in steps 5–6 and dashboard copy tone only. After plan generation it never changes math. *(ASSUMPTION A-01: posture→suggestion mapping in §5 R-14; product may retune the suggestions without a contract change.)*

### 4.3 Step 3 — Checking accounts — V2-03

- Add 1–10 checking accounts *(ASSUMPTION A-02: cap of 10)*. For each: name (required), current balance (required, `Decimal ≥ 0`), role (required): **income** (receives paychecks), **spending** (day-to-day + floor), **reserves** (obligations and debt money).
- One account may hold multiple roles (a single-account user is valid: all roles on one account).
- Exactly one account is marked **default income account**; the first income-role account is preselected. Adding, renaming, or re-roling accounts later (Settings → Accounts) must keep exactly one default income account.
- Never ask for account numbers, routing numbers, or credentials — a name and a typed balance only. *(V2-17)*
- Migration mapping for Lem's install: "Checking 1" = income + spending (default income), "Checking 2" = reserves (§7).

### 4.4 Step 4 — Income and paydays — V2-06

- Take-home per paycheck (`Decimal > 0`).
- Next payday date (today or future).
- Pay cadence: **weekly** (every 7 days), **biweekly** (every 14 days), **semimonthly** (two days of month, e.g. 1st and 15th; either may be "last day"), **monthly** (day of month, clamped per §5 R-11).
- Which account receives the paycheck (defaults to the default income account).
- Future income changes: zero or more future-dated `IncomeRule` rows ("raises to $2,300 on 2027-01-15"), editable later in Settings. The generator and reforecast both honor them.

### 4.5 Step 5 — Essential obligations — V2-07

- Repeatable list of essential recurring obligations: name (required), amount (required), cadence (weekly / biweekly / monthly / quarterly / semiannual / annual), optional due day, optional linked account (defaults to a reserves-role account).
- Posture-based starter suggestions (rent/mortgage, car, transit, insurance, utilities) are offered as empty chips — never prefilled amounts.
- Per-paycheck reservation follows the smoothing rule (§5 R-04). The step shows the computed per-paycheck reserve live, e.g. "$726/month ≈ $335.08 per paycheck", so the math is visible before the plan exists.

### 4.6 Step 6 — Protected floor and allowance — V2-08, V2-09

- Protected cash floor (`Decimal ≥ 0`) on the spending account. Suggested default by posture (§5 R-14); Lem-equivalent is $1,000.
- Per-paycheck personal allowance cap (`Decimal ≥ 0`). Explained exactly as the soul demands: "This is available, not spent. We'll never count it as spent unless you tell us."
- Both editable later; edits follow the F-13 rule (future rule or new plan version).

### 4.7 Step 7 — Debts — V2-04, V2-05

**Type picker first.** `Add a debt` → choose: **Credit card**, **Personal loan**, **Car note / auto loan**, **Student loan**, **Medical debt**, **Other**.

**Fields by type** (✓ required, ○ optional):

| Field | Credit card | Personal loan | Auto loan | Student loan | Medical | Other |
| --- | :-: | :-: | :-: | :-: | :-: | :-: |
| Nickname / issuer | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Current balance / principal | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Original principal | ○ | ✓ | ✓ | ✓ | ○ | ○ |
| APR (≥ 0%, may be 0%) | ✓ | ✓ | ✓ | ✓ | ✓ (often 0%) | ✓ |
| Minimum / contractual payment | ○ (estimated per §5 R-06 if blank) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Due date (editable day-of-month) | ✓ | ✓ | ✓ | ✓ | ○ | ○ |
| Credit limit (→ utilization display) | ○ | — | — | — | — | — |
| Extra-principal eligible | ✓ default on | ✓ default on | ✓ default on (off if penalty) | ✓ default on | ✓ default on | ✓ default on |
| Last four digits | ○ | ○ | ○ | ○ | ○ | ○ |

- Original principal defaults to current balance when omitted; used for percent-paid display, never allocation.
- Utilization = current balance ÷ credit limit, display and insights only (§5 R-12).
- Extra-principal-ineligible debts receive minimums only (§5 R-07); the toggle explains this in one sentence.
- Never a full account number, ever. "Other" behaves as a personal loan. *(ASSUMPTION A-03)*
- Zero debts is allowed (the user may be here for the payday ritual); the plan then only reserves obligations, floor, and allowance, and Insights explains there is nothing to attack.

### 4.8 Screen states (steps 3, 5, 7 lists)

- Empty state with one-line explanation and a single add button.
- Row states: valid / incomplete (amber "needs a detail" chip, tappable to the missing field).
- Swipe-to-delete with undo; deletion during onboarding only (post-onboarding archival keeps history).

### 4.9 Step 8 — Review and generate — V2-10

- Summary cards: accounts, income and cadence, obligations with per-paycheck reserve, floor, allowance, debts sorted in avalanche order (§5 R-08) with the order explained ("highest APR first — this minimizes interest").
- `Generate My Plan` runs the §5 generator and shows: projected debt-free date, total estimated interest, paychecks count, first payday play, and per-debt payoff dates — all labeled as estimates.
- `Use This Plan` commits atomically (see 4.0): an immutable `PlanVersion` named **"Plan v1"** (`isOriginalBaseline = true`, `calculationVersion = 2`) with its full `PaydayPlanItem` schedule and milestones. *(ASSUMPTION A-04: fresh-install naming "Plan v1"; the migrated install's row keeps its historical name "Original Plan v1".)*
- `Adjust` returns to any step without losing the others.

### 4.10 Step 9 — Notifications

Unchanged contract from 0.1.x (F-11): explain value before requesting permission; defaults — payday play 8:00 AM, incomplete check-in 7:00 PM, due-soon 3 days prior 9:00 AM, due-today 9:00 AM, weekly summary Sunday 6:00 PM (toggleable), milestone one payday ahead. Denial leaves the app fully functional with a path to iOS Settings.

---

## 5. Calculation rules (calculation version 2) — V2-10

Numbered, testable, and binding. Where a rule reduces to a calc-v1 rule under Lem's inputs (biweekly, $1,000 floor, $300 allowance, car+train obligations), the reduction is part of the rule and must be covered by a test.

- **R-01 Paycheck timeline.** Paydays are generated from the next-payday anchor by cadence: weekly +7d, biweekly +14d, semimonthly on the two configured days (clamped per R-11), monthly on the configured day (clamped). Future `IncomeRule` rows switch the take-home amount on their effective date. Horizon: generation runs until all debts are paid or 600 paychecks, whichever comes first; hitting the cap flags the plan "not payable as configured" instead of looping. *(ASSUMPTION A-05: 600-paycheck cap.)*
- **R-02 Per-period interest.** For each debt with APR > 0: `interest = balance × APR × daysSincePreviousPayday / 365`, full Decimal precision, rounding only at output. For biweekly cadence this is exactly calc v1's `× 14 / 365`.
- **R-03 Paychecks per year.** weekly 52, biweekly 26, semimonthly 24, monthly 12.
- **R-04 Obligation smoothing.** Per-paycheck reserve for an obligation = `round2(amount × occurrencesPerYear / paychecksPerYear)`; occurrences: weekly 52, biweekly 26, monthly 12, quarterly 4, semiannual 2, annual 1. Reduction check: $726 monthly at biweekly pay → `726 × 12 / 26` → **$335.08**; $111 monthly → **$51.23** (Lem's exact reserves).
- **R-05 Per-paycheck allocation order.** From take-home (plus explicitly assigned windfalls): (1) allowance cap reserved as available-not-spent; (2) spending-account floor top-up to the protected floor; (3) obligation reserves (R-04); (4) minimum payments for all active debts; (5) everything remaining is extra principal to the avalanche target (R-08), rolling to the next eligible debt within the same paycheck when a payoff occurs (calc-v1 rule 5).
- **R-06 Minimums.** A user-entered minimum is authoritative. Blank minimums are estimated **for credit cards only**: `max($17.50 × daysSincePreviousPayday / 14, postInterestBalance × 0.005)`, capped at the balance — identical to calc v1 under biweekly cadence. Installment types (personal, auto, student, medical, other) require an entered minimum at input; no estimator. *(ASSUMPTION A-06)*
- **R-07 Extra-principal eligibility.** Ineligible debts never receive more than their minimum. If the top avalanche debt is ineligible, extra principal goes to the highest-APR *eligible* debt.
- **R-08 Avalanche order.** Active debts sorted by APR descending; ties broken by lower current balance first; remaining ties by creation order. 0% APR debts sort last. The user may still reorder manually; per F-13 that creates a new plan version (or future-dated rule) carrying the manual order — baseline versions are never edited.
- **R-09 Shortfall.** If floor top-up + obligations + minimums exceed take-home for a paycheck: reduce extra principal to $0, then reduce that paycheck's allowance toward $0, and if still short, mark the paycheck "needs attention" with the exact gap. Minimums are never silently dropped; the plan generates with the flag visible in review, calendar, and dashboard.
- **R-10 Termination and outputs.** Generation stops when every balance rounds to $0.00 (or R-01's cap). Outputs per paycheck: income, keep-in-spending, transfer-to-reserves, obligation reserve, debt budget, target debt, planned per-debt balances, planned total after, and no-spend ceiling. The ceiling seeds from the spending account's starting balance and increments each paycheck by that paycheck's planned keep-in-spending amount (allowance plus any floor top-up) — the 0.1.x construction: $900 + $400 = $1,300 after check 1, reaching $7,900 at check 23. Whole-plan outputs: payoff date, paycheck count, total estimated interest, per-debt payoff dates.
- **R-11 Due-day clamping.** A due day greater than the days in a month clamps to the last day (Jan 31 → Feb 28/29). Semimonthly "last day" behaves the same.
- **R-12 Utilization.** `balance ÷ limit` when a limit exists. Display and insights only — never an allocation input. Thresholds: ≥ 30% informational, ≥ 90% "needs attention". *(ASSUMPTION A-07)*
- **R-13 Goal gap.** With a target debt-free date set, Insights computes the smallest additional per-paycheck amount (binary search, $1 resolution) that would meet the target, displayed as "about $X more per paycheck". Display only. *(ASSUMPTION A-08)*
- **R-14 Posture suggestions.** Suggested defaults by posture — Full throttle: allowance $150, floor $500; Steady: allowance $300, floor $1,000; Cushion first: allowance $300, floor $2,000. Suggestions are editable defaults, never enforced, and affect nothing after generation. *(ASSUMPTION A-01 — values are product-tunable.)*
- **R-15 Three truths.** Generated plans obey the same separation as Original Plan v1: the baseline `PlanVersion` is immutable; actuals come only from user entries; reforecasts (F-12) start from authoritative snapshots and never touch the baseline. *(V2-15)*
- **R-16 Money hygiene.** All rules use `Decimal`; negative inputs are rejected outside explicit refund/reversal/correction ledger types (calc-v1 rule preserved).

---

## 6. Data model (schema version 2)

Schema v1 models (`PlanVersion`, `IncomeRule`, `DebtAccount`, `PaydayPlanItem`, `PaydayCheckIn`, `LedgerEntry`, `BalanceSnapshot`, `CashBucket`, `ForecastSnapshot`, `NotificationPreference`, `Milestone`, `AppSettings`) persist. Changes:

### New: `CheckingAccount` — V2-03

- `id: UUID`, `name: String`, `currentBalance: Decimal`
- `roles: Set<AccountRole>` — `.income` / `.spending` / `.reserves`
- `isDefaultIncome: Bool` — exactly one true, enforced by service invariant + test
- `sortOrder: Int`, `isArchived: Bool`, `createdAt/updatedAt`

### New: `Obligation` — V2-07

- `id`, `name`, `amount: Decimal`, `cadence: ObligationCadence`
- `dueDay: Int?` (clamped per R-11), `accountID: UUID?`
- `perPaycheckReserve` is **derived** (R-04), not stored, except frozen into `PaydayPlanItem` rows at generation.
- `isArchived`, timestamps.

### New: `UserProfile` — V2-02

- `goalText: String?`, `targetDebtFreeDate: Date?`, `posture: PayoffPosture` (`fullThrottle/steady/cushionFirst`), `createdAt`.

### New: `OnboardingState` — V2-01

- `lastCompletedStep: OnboardingStep`, per-step draft payload (typed optionals, not JSON blobs where practical), `startedAt`, `completedAt: Date?`.

### Extended: `DebtAccount` — V2-04, V2-05

Adds: `debtType: DebtType` (`creditCard/personalLoan/autoLoan/studentLoan/medicalDebt/other`; migrated rows → `.creditCard`), `originalPrincipal: Decimal?`, `creditLimit: Decimal?`, `isExtraPrincipalEligible: Bool` (default true). Existing `minimumAmount`, `dueDayOfMonth` (editable, V2-11), `apr`, `priority`, `optionalLastFour`, `isArchived` unchanged.

### Extended: `PlanVersion`

Adds: `payCadence: PayCadence` (`weekly/biweekly(default for migrated)/semimonthly(day1,day2)/monthly(day)`), `incomeAccountID: UUID?`, `generatedFromProfile: Bool`. Existing fields (`isOriginalBaseline`, `isActive`, `payFrequencyDays`, `protectedBuffer`, `allowanceCap`, `calculationVersion`, …) unchanged; `carReservePerCheck`/`trainReservePerCheck` remain for the migrated baseline and are superseded by `Obligation` rows for new plans (kept in sync for Original Plan v1 by migration, §7).

### Extended: `PaydayPlanItem`

Adds: `plannedObligationReserves` as related rows `(obligationID, amount)` replacing the fixed car/train pair for generated plans; migrated items keep their existing car/train values and also gain equivalent obligation-reserve rows pointing at the migrated car/train obligations.

### Unchanged semantics

`PaydayCheckIn`, `LedgerEntry`, `BalanceSnapshot`, `ForecastSnapshot`, `NotificationPreference`, `Milestone` keep their v1 shapes; ledger `sourceAccount`/`destinationAccount` now reference `CheckingAccount` ids where applicable (migration maps the legacy C1/C2 constants).

---

## 7. Migration (schema 1 → 2) — V2-16

Runs once, before any UI, wrapped in a single transaction with a pre-migration integrity check; on failure the store is left untouched and the app retries next launch (never a half-migrated store).

1. Detect schema v1 (`PlanContract.schemaVersion` stamp / store metadata).
2. Create `CheckingAccount` rows: **"Checking 1"** (roles income + spending, `isDefaultIncome = true`) and **"Checking 2"** (role reserves). Balances derive from the existing C1/C2 bucket state; nothing is invented.
3. Create `Obligation` rows: Car — $726.00 monthly; Train pass — $111.00 monthly. Verify R-04 reproduces $335.08 and $51.23 exactly; a mismatch aborts migration (it cannot happen while R-04 holds, and the check keeps it that way).
4. Stamp every existing `DebtAccount` with `debtType = .creditCard`, `originalPrincipal = startingBalance`, `isExtraPrincipalEligible = true`, `creditLimit = nil`.
5. Set `PlanVersion.payCadence = .biweekly`, `incomeAccountID` = Checking 1, `generatedFromProfile = false`. **Do not touch** any `PaydayPlanItem` value, check-in, ledger entry, snapshot, forecast, milestone, or notification preference. Original Plan v1 keeps `calculationVersion = 1` and its stored 23-item schedule verbatim.
6. Add obligation-reserve rows to plan items mirroring the stored car/train amounts (per §6), values copied, not recomputed.
7. Create a default `UserProfile` (posture `.steady`, no goal text) and a completed `OnboardingState` — the migrated user never re-onboards.
8. Bump the stored schema stamp to 2; record a migration audit note in `AppSettings`.

**Acceptance:** after migration, the §3 baseline checklist as exercised by §13's manual verification (23 paydays, $29,681.61, all milestone dates, $3,461.16 interest, Jun 24 2027 payoff, $7,900 ceiling, $929.54 final payment) passes value-for-value; all pending notifications still fire; a v1 JSON backup taken before upgrade restores into the v2 app (backup import runs steps 2–7 logically).

Fresh installs skip all of this: schema v2 store, no plan rows, onboarding (§4) is the only path to a plan besides the template.

---

## 8. Information architecture and screens

Four tabs, unchanged: **Today**, **Calendar**, **Debts**, **Progress**. Settings from the Today navigation bar; global `+` sheet for payment, balance update, windfall, account adjustment, or note.

### 8.1 Today dashboard — F-02, V2-13

As in 0.1.x, generalized: the status header, today's-play card, and current-target card are unchanged in shape; the account cards render the user's **named** accounts by role instead of hard-coded "Checking 1/2":

- Spending account card (F-08 semantics): actual balance, protected floor, allowance available, no-spend ceiling labeled "Maximum if no allowance had been spent"; ceiling never mutates actual.
- Reserves card (F-09 semantics): per-obligation reserved amounts (car, train, rent, …), available-for-debts, overallocation warnings.
- The user's goal text (V2-02), when present, appears as a single calm line under the status header.
- Upcoming strip: next payday, next due date (any debt type), next projected payoff.

### 8.2 Guided payday check-in — F-03, V2-15

Five-step flow unchanged; wording generalizes "cards" to "debts", reserve step iterates the user's obligations instead of fixed car/train, and account names come from `CheckingAccount`. All 0.1.x reconciliation rules stand, including the outside-funds equation and "never create actuals from planned values".

### 8.3 Calendar — F-07, V2-12

Same views, markers, filters, selected-day panel as 0.1.x, now also rendering: obligation due dates (when set), all debt types' due dates, and shortfall-flagged paydays (amber "needs attention" ring, R-09). Generated plans get identical treatment to Original Plan v1.

### 8.4 Debts — F-04, V2-04, V2-05

- List: avalanche order default, type icon + nickname, balance, APR, next due, status, percent paid (uses `originalPrincipal` when present).
- Detail adds: debt type, original principal, credit limit + utilization badge (cards, R-12), extra-principal-eligibility state.
- `Edit Card` becomes `Edit Debt` and includes the editable due date; saving a due-date change triggers §9 immediately. Balance-snapshot rules unchanged.
- Add-debt from this tab uses the same type picker + per-type form as onboarding step 7.

### 8.5 Insights — V2-14

Lives at the top of the Progress tab as a card row (no fifth tab). Cards, each with accessible text and estimate-honest wording:

1. **Interest saved** — generated plan versus minimums-only projection.
2. **Payoff delta** — reforecast payoff versus baseline, with the R-09/variance explanation sentence.
3. **Utilization** — per-card badges at the R-12 thresholds; only shown when limits exist.
4. **Obligation crunch** — upcoming paychecks where obligations + minimums crowd out extra principal (R-09 flags).
5. **Allowance trend** — allowance used versus available over the last paychecks; neutral wording, never shaming.

### 8.6 Progress, reforecast, ledger, settings, backup, phase II

F-05, F-10, F-12, F-13, F-14, F-16 carry forward unchanged in structure. Deltas:

- Reforecast (F-12) uses calc v2 (§5) for plans stamped `calculationVersion = 2` and calc v1 for Original Plan v1 — the engine dispatches on the plan's stamp. *(V2-15)*
- Settings adds: **Accounts** (V2-03 management), **Obligations** (V2-07), **Goals & posture** (V2-02), **Review setup** (re-enter any onboarding step; changes flow through F-13's future-rule/new-version choice).
- Export (F-14) writes backup schema 2, imports 1 and 2 (§2). CSV column sets are append-only; existing columns keep names and order. *(V2-18)*
- Plan versions screen shows every version with its calculation-version stamp and an immutability badge on baselines; the template loader lives here too (§3).

---

## 9. Calendar and notification behavior on due-date edits — V2-11

- Editing `dueDayOfMonth` on any debt, or `dueDay` on any obligation, immediately: (1) recomputes that item's calendar events (R-11 clamping); (2) cancels and reschedules its pending due-soon/due-today notifications using the existing stable-identifier scheme, so updates replace rather than duplicate; (3) appends an audit note to the item.
- The reschedule completes before the edit screen is dismissed; the calendar reflects the new date on next render with no stale markers.
- All 0.1.x notification rules stand (contextual permission, rolling window, completion cancels the evening reminder, discreet lock-screen content by default).
- Notification identifiers extend to `debt-due-<uuid>` / `obligation-due-<uuid>` families; migration re-registers existing card reminders under the same identifiers they already use (no duplicate fires after upgrade).

---

## 10. Core services (v0.2.0)

| Service | Responsibility | Status |
| --- | --- | --- |
| `PlanSeeder` | Loads the Original Plan v1 **template** idempotently — deliberate template loads only. It never runs against a migrated store (§7 preserves those); the idempotency guard stays as a second line of defense. | Repurposed |
| `PlanGenerationService` | New. Runs §5 R-01…R-14 to produce an immutable baseline `PlanVersion` from onboarding inputs. Pure functions where possible. | New |
| `MigrationService` | New. §7 schema 1→2, plus v1-backup import migration. | New |
| `OnboardingStateService` | New. Step persistence and resume (§4.0). | New |
| `DebtCalculationEngine` | Interest, minimums, avalanche allocation; dispatches calc v1/v2 by plan stamp. | Extended |
| `ReconciliationService` | Payday equations, atomic ledger/check-in writes; obligation-aware. | Extended |
| `AccountBalanceService` | Derives balances/buckets per `CheckingAccount` and obligation; actual vs. ceiling. | Extended |
| `ReforecastService` | F-12 on both calc versions. | Extended |
| `NotificationScheduler` | Stable-ID scheduling incl. obligation due dates and §9 reschedules. | Extended |
| `CalendarEventService` | Event merge incl. obligations and shortfall flags. | Extended |
| `ExportService` | Backup schema 2 write, 1+2 read; append-only CSV. | Extended |
| `MilestoneService`, `AppLockService`, `PlanContract` | As in 0.1.x; `PlanContract` gains schema/calc version 2 constants alongside the frozen v1 constants. | Extended |

---

## 11. Acceptance criteria

### v0.1 criteria (F-01…F-16)

All sixteen 0.1.x acceptance rows remain binding as amended in `soul.md` (F-01's fresh-install clause is replaced by the V2 rows below; every other row unchanged, applied to generalized accounts/debts).

### v0.2.0 criteria

| ID | v0.2.0 is accepted when… |
| --- | --- |
| V2-01 | Killing the app at every onboarding step boundary and mid-step, then relaunching, resumes at the correct step with all entered data intact; finishing twice cannot create duplicate plans, accounts, obligations, or debts. |
| V2-02 | Goal, target date, and posture persist; posture changes only suggested defaults and copy (verified by generating identical plans under different postures with identical numeric inputs). |
| V2-03 | 1–10 accounts with names, balances, and roles can be created and edited; the app enforces exactly one default income account at all times; no credential-like field exists anywhere. |
| V2-04 | All six debt types can be created from the picker and render correct type-specific forms and icons in every screen. |
| V2-05 | Balance, original principal, APR, minimum, editable due date, credit limit/utilization, and extra-principal eligibility round-trip through create → edit → plan generation → display; ineligible debts never receive extra principal in any generated or reforecast schedule. |
| V2-06 | All four cadences generate correct payday timelines (including month-end clamping and semimonthly pairs); future income rules switch amounts on their effective dates in plan and reforecast. |
| V2-07 | Obligation smoothing matches R-04 to the cent, including the $726→$335.08 and $111→$51.23 reductions; per-paycheck reserves appear in plan items, check-in, and reserves card. |
| V2-08 | No generated schedule plans the spending account below the floor; floor top-ups precede extra principal (R-05 order verified). |
| V2-09 | The configured allowance is reserved every paycheck as available-not-spent; recording actual spending lowers actual only, never planned or ceiling values. |
| V2-10 | Under Lem-equivalent inputs, the calc-v2 generator reproduces Original Plan v1's headline values exactly ($3,461.16 interest, 23 checks, Jun 24 2027, $929.54 final, all six payoff dates); property tests confirm minimums-first, avalanche targeting, same-check rollover, and R-09 shortfall flags. |
| V2-11 | Editing any due date updates calendar markers and replaces the exact affected notification requests (verified by pending-request inspection) before the editor dismisses; no duplicates, no orphans. |
| V2-12 | A generated plan's paydays, due dates, milestones, and shortfall flags render on the calendar with the same markers, filters, and day panel as the migrated baseline. |
| V2-13 | The dashboard shows the user's named accounts, floor, allowance, goal line, and next play; F-02's five-second content list is fully present for a generated plan. |
| V2-14 | All five insight cards render from stored data with accessible text summaries and estimate-honest wording; utilization badges appear only when a limit exists and at R-12 thresholds. |
| V2-15 | Check-in, ledger, snapshots, and reforecast behave identically on a generated plan; every baseline field value is unchanged across any sequence of actual entries. |
| V2-16 | Upgrading a seeded 0.1.x store passes the §7 acceptance — every pre-existing field value unchanged, baseline checklist green, live notifications, no re-onboarding; a fresh v0.2.0 install contains zero Lem data unless the template is deliberately loaded. |
| V2-17 | Release build makes no network connections; no credential-type fields exist; all storage is local; export remains the only data egress and is user-initiated. |
| V2-18 | New screens pass Dynamic Type (accessibility sizes), VoiceOver, Reduce Motion, and 44-pt target checks; a grep-level audit finds no Double/Float money; a v1 backup file restores successfully and equivalently in v0.2.0. |

---

## 12. F ↔ V2 parity check table

| V2 ID | soul.md | This document | Related F |
| --- | --- | --- | --- |
| V2-01 | v0.2 contract table | §4.0, §11 | F-01 (amended) |
| V2-02 | v0.2 contract table | §4.2, §6 UserProfile, §11 | F-02 |
| V2-03 | v0.2 contract table | §4.3, §6 CheckingAccount, §11 | F-08, F-09 |
| V2-04 | v0.2 contract table | §4.7, §8.4, §11 | F-04 |
| V2-05 | v0.2 contract table | §4.7, §6 DebtAccount, §11 | F-04 |
| V2-06 | v0.2 contract table | §4.4, §5 R-01/R-03, §11 | F-13 |
| V2-07 | v0.2 contract table | §4.5, §5 R-04, §6 Obligation, §11 | F-09 |
| V2-08 | v0.2 contract table | §4.6, §5 R-05/R-09, §11 | F-08 |
| V2-09 | v0.2 contract table | §4.6, §5 R-05, §11 | F-08 |
| V2-10 | v0.2 contract table | §4.9, §5, §11 | F-06, F-12 |
| V2-11 | v0.2 contract table | §8.4, §9, §11 | F-07, F-11 |
| V2-12 | v0.2 contract table | §8.3, §11 | F-07 |
| V2-13 | v0.2 contract table | §8.1, §11 | F-02 |
| V2-14 | v0.2 contract table | §8.5, §5 R-12/R-13, §11 | F-10 |
| V2-15 | v0.2 contract table | §8.2, §8.6, §5 R-15, §11 | F-03, F-05, F-12 |
| V2-16 | v0.2 contract table | §3, §7, §11 | F-01 (amended), F-06 |
| V2-17 | v0.2 contract table | §1, §4.1, §4.3, §11 | F-15 |
| V2-18 | v0.2 contract table | §1, §8.6, §11 | F-14, F-15 |

---

## 13. Validation and tests

### Carried-forward v0.1 suites

The full 0.1.x suite — 54 unit and UI tests, including the fifteen spec-required calculation tests — remains green, unchanged. The migrated store must still satisfy every one (run against a migrated fixture, not only a fresh seed).

### Required new unit tests (v0.2.0)

1. R-04 smoothing: $726 monthly/biweekly → $335.08; $111 → $51.23; weekly, semimonthly, monthly, quarterly, and annual cases to the cent.
2. R-02 reduction: biweekly calc v2 interest equals calc v1 for identical inputs across the full Lem schedule.
3. Lem-equivalence: calc-v2 generation from Lem-equivalent inputs reproduces every §3 headline value ($3,461.16 interest, 23 checks, Jun 24 2027, $929.54 final payment, all six payoff dates, $7,900 ceiling) and the 23-check date/target/allocation structure. Per-check planned-debt-after values must match the clean-Decimal engine output — which may differ from the printed seed tables by the documented ±$0.01–$0.06 artifacts in the source document (see `ENGINEERING.md`); do not "fix" either direction.
4. R-08 ordering incl. APR ties, 0% APR, and manual override.
5. R-07: ineligible debts capped at minimums in every generated paycheck.
6. R-09 shortfall: extra→0, allowance→0, flag with exact gap; minimums never dropped.
7. R-06: card estimate scaling by cadence; installment debts reject blank minimums.
8. R-01: month-end clamping (Jan 31 → Feb 28 and 29), semimonthly pairs, 600-cap flag.
9. R-05 order: floor top-up precedes extra principal; allowance reserved first.
10. Migration §7: fixture v1 store → v2 passes the §3 baseline checklist value-for-value with every pre-existing field unchanged; idempotent (re-running is a no-op); aborts cleanly on induced failure.
11. Exactly-one-default-income-account invariant under add/edit/archive.
12. Backup: v1 file imports; v2 round-trips; CSV headers superset of v1.
13. R-12 utilization thresholds and nil-limit behavior.
14. R-13 goal gap monotonicity (more extra never later payoff).
15. OnboardingState: every step boundary persists and resumes; double-finish creates no duplicates.

### Required integration/UI tests

- Full fresh-install onboarding through plan generation, with a mid-flow force-quit and resume.
- Upgrade launch on a seeded v1 fixture: no onboarding, dashboard intact, baseline verification screen matches.
- Add one debt of each of the six types; verify plan, calendar, debts list.
- Edit a due date; assert pending notification requests and calendar markers changed before dismissal.
- Template load path shows the warning and produces the exact Original Plan v1.
- Accessibility passes (Dynamic Type, VoiceOver, Reduce Motion) on every new screen.

### Manual verification

The debug-only Plan Verification screen extends to print: schema version, calculation version per plan version, account count, obligation reserves, and — on migrated stores — the full §3 baseline checklist. Release builds expose none of it.

---

## 14. Updated project structure (delta)

```text
PaydayPlaybook/
├── Models/          + CheckingAccount.swift, Obligation.swift, UserProfile.swift,
│                      OnboardingState.swift  (DebtAccount/PlanVersion/PaydayPlanItem extended)
├── Services/        + PlanGenerationService.swift, MigrationService.swift,
│                      OnboardingStateService.swift  (others extended per §10)
├── Features/
│   ├── Onboarding/  rebuilt: one view per §4 step + resume coordinator
│   ├── Insights/    new: insight cards (hosted in Progress tab)
│   └── Settings/    + AccountsView, ObligationsView, GoalsView, ReviewSetupView
└── Tests/           + PlanGenerationServiceTests, MigrationServiceTests,
                       ObligationSmoothingTests, OnboardingResumeTests
```

Everything else in the 0.1.x structure stands.

---

## 15. Build sequence for 0.2.0

1. **Contract** (this branch): docs, versioning, changelog — no feature code.
2. **Schema + migration**: §6 models, §7 migration, fixtures, tests green before UI.
3. **Generation engine**: §5 rules, Lem-equivalence test first.
4. **Onboarding UI**: §4 with resume tests.
5. **Generalized surfaces**: dashboard, check-in, calendar, debts, insights, settings.
6. **Compatibility pass**: backup import, notification re-registration, accessibility, privacy audit.
7. **Alpha cut**: full suite green on fresh + migrated fixtures → tag `v0.2.0-alpha.1`, build 2.

Do not skip calculation and migration tests to rush into visual work.

---

## 16. Exclusions (unchanged)

Still out of scope: bank/card APIs, cloud sync, Android/web, automatic payments, receipt scanning, household accounts, AI recommendations, trading, widgets/watch/Siri. The post-MVP options list from 0.1.x stands, now including: debt snowball mode, scenario comparison, and multi-income households.

---

## 17. Definition of done (v0.2.0)

v0.2.0 is done only when:

- every §11 V2 criterion and every carried-forward F criterion passes;
- a migrated 0.1.x store keeps every pre-existing value intact on its baseline and history;
- a fresh install reaches a generated plan fully offline with zero Lem data;
- planned, actual, and reforecast never cross-contaminate on either plan kind;
- backup v1 import, v2 round-trip, and append-only CSVs are verified;
- accessibility and privacy checks pass on a physical device;
- `CHANGELOG.md` claims exactly what shipped, nothing more.

---

## 18. Apple implementation references

- SwiftData persistence: <https://developer.apple.com/documentation/swiftdata>
- SwiftData migration (`SchemaMigrationPlan`): <https://developer.apple.com/documentation/swiftdata/schemamigrationplan>
- Adding/editing SwiftData records: <https://developer.apple.com/documentation/swiftdata/adding-and-editing-persistent-data-in-your-app>
- User Notifications: <https://developer.apple.com/documentation/usernotifications>
- Scheduling local notifications: <https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app>
- Requesting notification permission: <https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications>
- Calendar notification triggers: <https://developer.apple.com/documentation/usernotifications/uncalendarnotificationtrigger>

Use the current stable Apple documentation and SDK installed with Xcode while preserving the behavior specified here.
