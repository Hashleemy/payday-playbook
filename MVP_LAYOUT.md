# Payday Playbook — Product and Technical Layout (v0.4.0)

## 1. Build brief

Build a native, offline-first iPhone app named **Payday Playbook** using SwiftUI. The app is a personal execution companion for a debt plan **generated from the user's own situation** — accounts, income, bills, floor, allowance, and debts. v0.3.0 added a complete cash-account workspace, explainable extra-payment and three-plan payoff scenarios, hardened due-date/calendar behavior, full JSON backup and restore, reusable structure-only templates, a locally generated PDF financial report, a consolidated Bills & Debts setup — and removed all real personal financial data from tracked project artifacts while preserving existing on-device user data through migration. v0.4.0 (V4-01…V4-08) makes debt validation type-aware, makes every derived setup value reactive to upstream edits, upgrades Balanced (Recommended) into a simulation-proven multi-objective strategy (calculation version 4), fixes credit utilization with one canonical calculation, introduces a semantic primary-action button treatment, generalizes the checking-account adjustment flow, and adds a derived pay-cycle debt-allocation service with a Calendar debt dashboard.

Read `soul.md` first. Its principles and the F-01…F-16, V2-01…V2-18, V3-01…V3-16, and V4-01…V4-08 contracts (as amended there) are non-negotiable. The canonical V4 registry is `ALPHA_V0.4.0_MULTI_AGENT_PLAN.md`; V3: `ALPHA_V0.3.0_MULTI_AGENT_PLAN.md`; V2: `ALPHA_V0.2.0_MULTI_AGENT_PLAN.md`.

### Technical baseline

- Language: Swift. UI: SwiftUI. Persistence: SwiftData (local). Charts: Swift Charts.
- Notifications: UserNotifications with calendar-based local triggers.
- Security: LocalAuthentication for optional Face ID/app lock.
- PDF generation (V3-11): Apple frameworks only (e.g. `UIGraphicsPDFRenderer`/PDFKit).
- Deployment target: iOS 17.0 or newer.
- Architecture: feature-oriented MVVM with services; pure calculation engines that never import SwiftData or SwiftUI.
- Dependencies: Apple frameworks only.
- Money type: `Decimal` with explicit currency rounding to two decimals (half-away-from-zero via `.rounded2`), rounded only at persistence/display boundaries.
- Dates: `Calendar` and `DateComponents`; persist normalized local dates and the user time zone; wall-clock semantics survive time-zone moves and DST.
- No backend, login, telemetry, ads, bank linking, or automatic money movement. *(V2-17)*
- **No real person's financial data anywhere in tracked artifacts** — source, resources, fixtures, previews, tests, comments, docs, prompts, logs, screenshots, or reports. Clearly fictional values only. *(V3-12, V3-13)*

---

## 2. Versioning contract

Full detail in `docs/releases/v0.4.0/VERSIONING.md` (current cycle; v0.3.0's record stands in `docs/releases/v0.3.0/VERSIONING.md`). Summary, binding for this release:

| Axis | Value | Rule |
| --- | --- | --- |
| App version (`MARKETING_VERSION`) | **0.4.0** | Current is 0.3.0 (alpha.1, prepared/undistributed). Backward-compatible feature release → minor bump. Set by Agent 7 at integration only. |
| Prerelease tag | **v0.4.0-alpha.1** | Annotated tag created only when the alpha build is actually cut. Never tag intent; never push without owner authorization (external distribution stays blocked on the history decision). |
| Build number (`CURRENT_PROJECT_VERSION`) | **5** at the next distributed build | Strictly increasing integer, +1 per distributed build, never reset. Current: 4. |
| Persistence schema (`PlanContract.currentSchemaVersion`, stamped in `AppSettings.seedSchemaVersion`) | **3** (no bump expected) | v0.4.0 adds no stored field: promotions ride the input snapshot; allocation/dashboard are derived. A genuinely needed bump follows VERSIONING.md §5 — both migration step lists, additive-only, fixture-tested, integrator-ratified. |
| Calculation version (`PlanContract.currentCalculationVersion`, stamped per `PlanVersion`) | **4** for plans generated, previewed, or applied in 0.4.0 | V4-03 changes calculation semantics (Balanced quick-win promotion input). Existing stamps never change: the founding baseline stays 1; v0.2.0 plans stay 2; v0.3.0 plans stay 3. Calc v4 with no promotions reduces exactly to calc v3 (tested), and onward down the chain. `minimumModernCalculationVersion` stays **2** — the two constants are never collapsed. |
| Export schema (portable envelopes) | **4** (writes 4; imports 1, 2, 3, 4) | Semantic bump: a 0.4.0 backup can carry calc-4 plans a schema-3 reader cannot faithfully re-dispatch; the envelope refuses newer documents by name rather than guessing. Envelope shape unchanged; CSV columns append-only. |
| User plan versions | "Plan v1", "Plan v2", … | **Data, not software.** Per-install `PlanVersion` rows, named by `GeneratedPlanService.nextPlanName`. Never conflated with app versions, never renamed to match releases. |

---

## 3. The founding baseline — Original Plan v1 (migrated, immutable, device-local)

The founding install's baseline plan — **Original Plan v1**, created by the 0.1.x seeder and preserved by every migration since — is one real person's finances. As of v0.3.0 (V3-12) its values exist **only** in that device's local store and in exports its owner deliberately creates. This document no longer prints them; the behavioral contract is unchanged:

1. **Immutability.** Original Plan v1 keeps `calculationVersion = 1` and `inputSnapshotData = nil` forever. It is never regenerated (`PlanGenerationService.regenerate` returns nil for snapshot-less plans — keep it that way), never edited, never renamed, never deleted. Every payday row, milestone, check-in, ledger entry, and snapshot it accumulated is preserved value-for-value by every future migration.
2. **Rendering.** The frozen calc-v1 path (`DebtCalculationEngine`, `ReforecastService` dispatch on the calc stamp, `AccountBalanceService`'s legacy derivations, the legacy per-item reserve columns with `PlannedObligationReserve` rows beside them) continues to render the migrated baseline exactly. v0.3.0 must not break any of it.
3. **Template withdrawal (supersession, authorized by the release plan §3 and V3-12).** The bundled `OriginalPlanV1.json`, `SeedPlan`/`SeedPlanLoader`, `PlanSeeder`'s template-load path, `TemplateCatalog`, the Welcome "Load a template" affordance, and the Release-configuration exclusion machinery (`EXCLUDED_SOURCE_FILE_NAMES` + guard build phase) are **removed entirely — every build configuration, developer builds included**. Consequences, contracted:
   - The crashed-partial-seed repair path (which re-read the bundle) is retired; migration keeps aborting cleanly on such a store, exactly as distribution builds already do. This state cannot arise for a completed 0.1.x install.
   - `PlanContract`'s personal seed constants (starting totals, incomes, reserves, dates, per-debt seeds, the real avalanche order) are deleted. `PlanContract` keeps only generic constants: version numbers, plan-name constants, the minimum-payment estimator constants, frequency/cap constants.
   - The `--uitest-skip-onboarding` fixture and every seed/parity/migration test re-anchor on **clearly fictional programmatic fixtures** (§13).
   - The debug Plan Verification screen displays what the store contains; it no longer validates against hard-coded expectations. The founding install's owner verifies it against records kept outside the repository.
   - The 0.1.x plan letters and the `existingBaseline` name-key (`PlanContract.planName`) survive as schema vocabulary — migrated stores still contain them.

### Calculation version 1 (frozen — formulas only)

1. Interest per biweekly check: `balance × APR × 14 ÷ 365`, full `Decimal` precision, rounded at output.
2. Estimated card minimum: `max($17.50, 0.5% × post-interest balance)`, capped at the remaining balance; minimums inside the total card budget, not on top.
3. Minimums first on all active cards; the remaining budget attacks the plan's stored priority order, rolling forward within the same check on payoff.
4. The actual track uses user-entered payments and balances; an authoritative snapshot overrides estimates from its date forward.

These are modeling constants and formulas — product-generic, not personal data.

---

## 4. First-run onboarding (v0.3.0) — V2-01 … V2-09 as amended by V3-08

Migrated installs never see onboarding; they may revisit any step via Settings → "Review setup". The V2-01 resumability contract is unchanged and binding: every step writes real rows immediately (`UserGoalProfile`, `CashAccount`, `IncomeSchedule`, `RecurringObligation`, `DebtAccount`); `OnboardingProgress` tracks position only; finish is atomic and duplicate-proof; validation is calm, specific, and never loses input.

### Step sequence (v0.3.0)

| # | Step | Feature |
| --- | --- | --- |
| 1 | Welcome and privacy promise | V2-17 *(no template affordance — V3-12)* |
| 2 | Goals, payoff posture, floor and allowance | V2-02, V2-08, V2-09 |
| 3 | Checking accounts | V2-03 |
| 4 | Income and paydays | V2-06 |
| 5 | **Bills & Debts** (consolidated) | V3-08, V2-04, V2-05, V2-07 |
| 6 | Dates and reminders preview | F-11 |
| 7 | Review and generate plan | V2-10 |

**Amendment (v0.3.0, authorized by V3-08).** The v0.2.0 shipped order placed debts at step 4 (before income) and obligations at step 6. Consolidating bills and debts onto one page moves the combined step **after income**, so the live per-paycheck reserve preview uses the user's real cadence instead of a provisional default. Every question, field, and validation from v0.2.0 survives; only the page structure changes. `OnboardingStep` gains an additive `billsAndDebts` case; legacy raw values (`debts`, `obligations`, `income`) remain decodable, and resume mapping must land an interrupted v0.2-style store on the correct v0.3 step with all entered rows intact, nothing re-asked, and nothing duplicated (tested at every boundary).

### 4.5 Step 5 — Bills & Debts (consolidated page) — V3-08

"Bill" is the user-facing name for the `RecurringObligation` concept; the model split (obligations vs. debts) is load-bearing for the engine and stays.

1. **Summary header:** bill total (per month-equivalent), debt minimum total, debt principal total, and count of incomplete items.
2. **Bills section** — fields unchanged from v0.2.0 obligations: name (required), amount (required), cadence (weekly / biweekly / monthly / quarterly / semiannual / annual), optional due day, optional linked account (defaults to a reserves-role account), essential flag. Live smoothing preview per R-04, e.g. a fictional "$780/month ≈ $360.00 per paycheck".
3. **Debts section** — the full v0.2.0 type picker and per-type fields, unchanged (type first: credit card, personal loan, car note / auto loan, student loan, medical debt, other; then balance, original principal, APR, minimum, editable due date, credit limit → utilization for cards, tri-state extra-principal eligibility, optional last four). Installment types still require an entered minimum (A-06).
4. **One add flow:** a single `Add Bill or Debt` button; first choice is `Bill` or `Debt`; then only the relevant fields.
5. Inline missing-field chips and duplicate warnings (same name + same amount prompts, never blocks).
6. Edit / reorder / archive actions; swipe-to-delete with undo during onboarding, archival afterward.
7. **Review state** explains how bill and minimum totals reduce the money available to debt and notes that the three scenarios (§5 R-17) will build on these numbers.
8. Resumability: partial bills and partial debts persist independently; interruption anywhere resumes with both sections intact; migration or interruption never duplicates records.

Other steps carry v0.2.0 behavior verbatim (goals/posture with suggested defaults per R-14; accounts with the exactly-one-default-income invariant and the cap of 10 (A-02); income with all four cadences and future-dated changes; review-and-generate's atomic commit per V2-01/V2-10). The notifications step keeps its contextual-permission contract and product defaults: payday play 8:00 AM, incomplete check-in 7:00 PM, due-soon 3 days prior at 9:00 AM, due-today 9:00 AM, weekly summary Sunday 6:00 PM (toggleable), milestone one payday ahead; denial leaves the app fully functional with a path to iOS Settings.

### 4.6 Debt-type field relevance (v0.4.0 — V4-01)

One semantic source, `DebtType` in the model layer, drives what each editor asks, what each chip warns about, and what `SetupCompletenessService` lists. `DebtType.usesOriginalPrincipal` is `false` for `.creditCard` and `true` otherwise; `DebtPresentation.showsOriginalPrincipal` forwards to it. Binding matrix:

| Field | Credit card | Personal / auto / student loan | Medical / other |
| --- | --- | --- | --- |
| Current balance / remaining principal | required | required | required |
| APR | asked; 0%/missing warns, never blocks | asked; warns | asked; warns |
| Minimum / contractual payment | optional → R-06 estimator + gap | **required (blocker, A-06)** | required (blocker) |
| Due day | optional gap | optional gap | optional gap |
| Credit limit | optional gap unless `creditLimitMarkedUnknown` | never asked, never warned | never asked, never warned |
| Original principal | **never asked, never warned, never gap-listed** | optional gap; editor "required" chip is presentation-only, saving blank never blocks | optional gap |
| Prepayment eligibility | always `.eligible` | tri-state; `.unknown` warns (R-07) | tri-state; `.unknown` warns |

The three surfaces — editors, Bills & Debts chips, and the completeness service — must agree exactly; disagreement is a defect. The non-blocking philosophy is unchanged: only missing installment minimums and the structural blockers (no account, no income, no default income account) block plan generation.

### 4.7 Setup reactivity (v0.4.0 — V4-02)

**Inputs persist; derivations don't.** Entered setup values are canonical and survive navigation (V2-01). Every derived value — validation lists, summary totals, per-paycheck reserve previews, utilization aggregates, the generated plan preview — is recomputed from the canonical current input state whenever any of its inputs changes:

1. Cached derived state is invalidated by **content** changes (row IDs + `updatedAt` fingerprints), never by row counts alone — an edit that keeps counts equal must still invalidate.
2. **Commit-staleness guard:** the Review step's Generate captures a content fingerprint of the canonical inputs; Commit re-verifies it and regenerates (or requires re-Generate) on mismatch. Persisting a stale preview is impossible, proven by test.
3. Back-navigation invalidation is a tested contract, not a view-identity accident: after going backward, editing an upstream value, and proceeding forward, every downstream screen reflects the new values at every step boundary.

---

## 5. Calculation rules — calculation version 3

Calc v3 = calc v2 (R-01…R-16, restated below with fictional examples) **plus** the scenario and extra-payment rules R-17…R-24. With no scenario constraints and no extra payments, calc v3 must reproduce calc v2 exactly (tested). Where a v2 rule reduced to a v1 rule, that reduction also still holds (tested).

- **R-01 Paycheck timeline.** Paydays generate from the next-payday anchor by cadence: weekly +7d, biweekly +14d, semimonthly on the two configured days (clamped per R-11), monthly on the configured day (clamped). Future `IncomeChange` rows switch take-home on their effective dates. Horizon: until all debts are paid or 600 paychecks (A-05); hitting the cap flags the plan "not payable as configured".
- **R-02 Per-period interest.** `interest = balance × APR × daysSincePreviousPayday / 365`, full Decimal precision, rounding at output only. Biweekly reduces to calc v1's `× 14 / 365`.
- **R-03 Paychecks per year.** weekly 52, biweekly 26, semimonthly 24, monthly 12.
- **R-04 Obligation smoothing.** Per-paycheck reserve = `round2(amount × occurrencesPerYear / paychecksPerYear)`; occurrences: weekly 52, biweekly 26, monthly 12, quarterly 4, semiannual 2, annual 1. `ObligationMath.perPaycheckReserve` is the single shared implementation. Fictional reduction checks: $780 monthly at biweekly pay → `780 × 12 / 26` → **$360.00**; $91 monthly → **$42.00**. *(v0.3.0 note: the former examples used the founding user's real amounts; V3-12 replaces them. The rule is unchanged.)*
- **R-05 Per-paycheck allocation order.** From take-home (plus explicitly assigned windfalls): (1) allowance reserved as available-not-spent; (2) spending-account floor top-up; (3) obligation reserves (R-04); (4) minimums for all active debts; (5) remainder as extra principal to the avalanche target (R-08), rolling within the same paycheck on payoff.
- **R-06 Minimums.** A user-entered minimum is authoritative. Blank minimums are estimated **for credit cards only**: `max($17.50 × daysSincePreviousPayday / 14, postInterestBalance × 0.005)`, capped at the balance. Installment types require an entered minimum (A-06).
- **R-07 Extra-principal eligibility.** `.ineligible` and `.unknown` debts never receive more than their minimum (`.unknown` also raises the prepayment warning); if the top avalanche debt is ineligible, extra goes to the highest-APR eligible debt; extra with no eligible target stays visible as unassigned cash.
- **R-08 Avalanche order.** Active debts by *effective* APR descending (promo rate while in force); ties: earlier due day first (no due day last), then lower balance, then creation order, then stable ID. 0% APR sorts last. Manual reorder creates a new plan version per F-13.
- **R-09 Shortfall.** If floor top-up + obligations + minimums exceed take-home: extra → $0, then allowance → toward $0, then flag "needs attention" with the exact gap decomposed (floor / obligations / minimums). Minimums are never silently dropped.
- **R-10 Termination and outputs.** Stops at all-zero balances or the R-01 cap. Per-paycheck outputs: income, keep-in-spending, transfer-to-reserves, obligation reserves, debt budget, target, per-debt balances after, total after, no-spend ceiling (seeded from the spending account's starting balance, incremented by each paycheck's planned keep amount). Whole-plan outputs: payoff date, paycheck count, total estimated interest, per-debt payoff dates.
- **R-11 Due-day clamping.** A due day past a month's end clamps to the last day; semimonthly "last day" is stored as day 31 and clamps identically. `PayScheduleGenerator.clampedDate` / `DueDateRule` are the only clamping implementations.
- **R-12 Utilization** *(amended in v0.4.0 — V4-04)*. One canonical implementation, `UtilizationMath.utilization(balance:limit:)` (Foundation-only, exact `Decimal`): `nil` unless `limit > 0`, else `balance ÷ limit`; values above 1 are legitimate. Unknown or non-positive limits stay **unknown** — never 0% — including `creditLimitMarkedUnknown` cards. Original principal is never an input. Display/insights only; thresholds ≥30% info, ≥90% attention (A-07) are declared once in `UtilizationMath` and consumed everywhere. Display surfaces feed it the derived current balance (`AccountBalanceService.debtBalances()`); percent display rounds to the nearest whole percent and renders "<1%" for small non-zero ratios, never truncating a real ratio to a false 0%. No reimplementation of the ratio or the thresholds may exist anywhere.
- **R-13 Goal gap.** Display-only smallest additional per-paycheck amount to meet a target date ($1 resolution, A-08).
- **R-14 Posture suggestions.** Suggested defaults by posture — Full throttle: allowance $150, floor $500; Steady: allowance $300, floor $1,000; Cushion first: allowance $300, floor $2,000. Editable suggestions only; never enforced; affect nothing after generation (A-01; product-tunable without contract change — these are product defaults, definitionally not personal data).
- **R-15 Three truths (+ previews).** Baselines immutable; actuals only from user entries; reforecasts from authoritative snapshots. v0.3.0 adds: **previews** (scenario or extra-payment results) are a fourth, unpersisted kind — engine outputs never persist or activate themselves (V3-15).
- **R-16 Money hygiene.** All rules use `Decimal`; negative inputs rejected outside explicit refund/reversal/correction ledger types. The four reconciliation identities hold on every paycheck of every result: income + windfall = keep + transfer; debt budget + minimums gap = minimums + extra + unassigned; Σ per-debt payments = minimums + extra; shortfall gap = floor gap + obligation gap + minimums gap. Calc v3 preserves all four.

### New in calc v3 — scenarios and extra payments

- **R-17 The three scenarios (V3-05).** Exactly three, computed from the saved profile plus any R-18 override, all through the one avalanche engine (no forked payoff algorithm):
  - **Fastest Safe** — preserve essential bills, required minimums, and the user's **minimum protected cash**; direct the maximum user-approved remaining surplus to eligible debt. A zero discretionary allowance requires explicit confirmation, captured **outside** the engine (`UserGoalProfile.zeroAllowanceConfirmedAt`); the engine never assumes it. Positioning: earliest safe modeled payoff, lowest estimated interest.
  - **Balanced (Recommended)** — preserve the user's **preferred** protected floor, **preferred** allowance, essential bills, and **planned savings**, then avalanche the remainder. Default recommendation because it follows the user's stated sustainable constraints.
  - **More Cushion** — Balanced constraints **plus** the user's chosen additional cash reserve or reduced extra-payment ceiling. More liquidity, later payoff, more estimated interest.
  Constraint values come only from the user (§6 `UserGoalProfile` scenario fields / `StoredScenarioDefinition`). Missing constraints produce a **missing-input result** naming exactly what is needed, or editable neutral defaults clearly labeled as suggestions (A-09). The engine never manufactures lifestyle assumptions (V3-06).
- **R-18 Income override.** The calculator accepts an income amount / pay frequency / effective-date override applied to a **copy** of the inputs; saved data is never mutated. Income alone is never enough — a payoff estimate requires the full R-24 input set.
- **R-19 Scenario outputs.** Each scenario result carries: projected debt-free date; estimated time remaining; total starting/current principal; periodic debt contribution and cash retained; estimated total interest and total paid; interest/time deltas versus Balanced; minimum ending cash position (from the R-23 cash path); assumptions, named missing inputs, and estimate status; and calendar-ready actions. Previewing changes nothing (R-15).
- **R-20 Extra-payment insight (V3-04).** "What if I pay extra?" supports a one-time amount with effective date or a recurring amount per paycheck or per month; a chosen target debt or automatic avalanche target; an optional source checking account (drives cash warnings only — the engine keeps its single-pool model). Output: payoff date before/after; days and paychecks/months saved; estimated interest before/after/saved; total paid; projected principal reduction after modeled accrued interest; downstream avalanche-order or payoff-date changes; warnings per R-21. Results reconcile to the core engine to the cent and preserve the R-16 identities.
- **R-21 Prepayment semantics and warnings.** For revolving debt, payments reduce the outstanding balance after interest and posted charges — never imply a lender-side "principal-only" designation. For installment debt, principal-only guidance appears only when eligibility is known (`PrepaymentEligibility.eligible`) or user-confirmed; `.unknown` warns. Warning taxonomy: missing APR, unknown lender behavior, insufficient available cash (when a source account is named), prepayment penalty, and protected-floor violation.
- **R-22 Determinism and versioning.** Scenario and insight calculations are pure, deterministic (identical inputs → byte-identical results), stamped calculation version 3, and dispatch by stamp like every predecessor. Ties resolve per R-08. The `PlanEvent` identifier scheme is preserved.
- **R-23 Cash path.** Every scenario result includes the projected spending-pool path per paycheck and its minimum ("minimum ending cash position"). The engine retains its single-spending-pool model; multi-account structure is collapsed to pool + reserves exactly as v0.2.0 does, and per-account detail lives outside the engine (§6).
- **R-24 Honest inputs (V3-06).** A scenario or insight requires: debts with balances and APR assumptions, minimums, due dates, bills, pay cadence and next payday, protected cash, and the scenario constraints. Anything missing or estimated is named in the result (`missingInputs` / `assumptions`), following the R-16-comparison precedent: withhold rather than guess.
- **Applying (V3-15).** Applying a scenario or extra-payment plan requires explicit confirmation and creates a **new future-effective `PlanVersion`** — stamped with the current calculation version, `inputSnapshotData` capturing the full inputs including the `StoredScenarioDefinition`, named by `GeneratedPlanService.nextPlanName`, activated through the existing activation path. Baselines and completed history are never rewritten.

### New in calc v4 — the Balanced quick-win policy (v0.4.0, V4-03)

Calc v4 = calc v3 (R-01…R-24) **plus** the promotion input and the Balanced selection rules R-25…R-27. With `quickWinPromotions` empty, calc v4 reproduces calc v3 byte-identically (tested), and the reduction chain to v2 and v1 stands. Fastest Safe and More Cushion remain pure R-08 under their constraints; onboarding generation (no scenario) is unchanged in value, so V2-10 holds to the cent. Product constants (named, tunable, in `PlanContract` — modeling policy, not personal data): `balancedQuickWinHorizonPaychecks = 3`, `balancedQuickWinMaxDelayPaychecks = 1`, `balancedQuickWinMaxExtraInterestRate = 0.01`, `balancedQuickWinMaxExtraInterestCap = 50` (A-12).

- **R-25 Candidates.** Baseline **B0** = Balanced constraints, no promotions. For each debt D that is active, `.eligible`, and not B0's first extra target: D is a *pre-candidate* iff `D.balance ≤ Σ over B0's first balancedQuickWinHorizonPaychecks paychecks of (extraTotal + D's minimum payments)` — an interest-ignoring optimistic bound that can only over-include, so it never excludes a true candidate. Each pre-candidate is simulated as **C(D)** = Balanced constraints + `quickWinPromotions = [D]` (single promotion per candidate — A-14). D is a *candidate* iff C(D) retires D within `balancedQuickWinHorizonPaychecks` paychecks of plan start. Promotion mechanics: promoted debts (active, `.eligible` only) sort ahead of the R-08 extra-principal attack order and the assembled payoff order, in list order, until retired; minimums funding, reserves, floor, allowance, and shortfall math are untouched, so all four R-16 identities hold. Promoting an ineligible or inactive debt is a no-op with note `quickWinPromotionIneligible`.
- **R-26 Guardrails and selection.** C is *admissible* against B0 iff **G1** `C.paycheckCount ≤ B0.paycheckCount + balancedQuickWinMaxDelayPaychecks` and C is not "not payable as configured"; **G2** `C.estimatedTotalInterest − B0.estimatedTotalInterest ≤ min(balancedQuickWinMaxExtraInterestRate × B0.estimatedTotalInterest, balancedQuickWinMaxExtraInterestCap)`; **G3** C's first account payoff date is strictly earlier than B0's (or B0 has none within the horizon and C does). Among admissible candidates, selection is **lexicographic, never weighted scoring**: earliest first-payoff date → lowest estimated total interest → earliest debt-free date → promoted debt earliest in R-08 order at plan start → promoted debt UUID string. No admissible candidate → **B0 is Balanced** (exactly the pre-v0.4.0 behavior). The selector (`BalancedStrategySelector`) is pure and deterministic (R-22 extended); it runs only for `.balanced`; every comparison figure comes from complete engine runs through `PlanGenerationService.engineInput` — no forked payoff algorithm, no third bridge.
- **R-27 Transparency and reproducibility.** The Balanced `ScenarioResult` carries `balancedRationale: BalancedSelectionRationale?` — what was considered, what was selected, and the engine-proven deltas versus the avalanche baseline (interest delta, payoff delay in paychecks, first-payoff advance, released per-paycheck minimum). A quick win that costs more estimated interest states so (`quickWinCostsMoreInterest`, with the amount); the scenario surface keeps the cross-scenario deltas visible so the Fastest Safe comparison stays honest. No claimed saving unless both compared projections finished and the delta proves it (the R-16 precedent). Reason code `quickWinPromotion` marks promoted payments. **Applying pins the selection**: the persisted snapshot's `quickWinPromotions` carries the concrete promotion, so regeneration re-runs the engine, never the selector — applied plans reproduce forever. Candidate runs may skip the minimum-only comparison projection via an internal engine option that cannot change stamped outputs; Agent 3 benchmarks the end-to-end cost.

### Derived-service rules (v0.4.0, app layer — not part of the engine calc version)

R-28/R-29 are deterministic derived arithmetic over stored plan items and ledger rows. They stamp nothing and are deliberately outside the engine's calculation versioning; changing them never requires a calc bump, and they persist no state (the release mandate: derived over redundant persistence).

- **R-28 Pay-cycle allocation (V4-07).** Cycle boundaries come from the active plan's `PaydayPlanItem` dates (the calendar's `schedulePlan` source): current cycle = `[most recent plan payday ≤ today, next plan payday)`, extended past the last item by the live `IncomeSchedule` cadence (the `ReforecastService` precedent); before the first payday there is no current cycle (the upcoming allocation is shown instead). Exactly one implementation of the boundary rule exists, in `DebtAllocationService`. Allocation becoming available for a cycle = the opening payday's `plannedCardBudget` (the plan track's planned debt payment — *planned allocation*, never actual account cash). Qualifying payments in a cycle = `.cardPayment` ledger rows by `effectiveDate`, minus debt-linked `refundReversal`/`correction` rows; check-in payments are already ledger rows, so `PaydayCheckIn`/`CheckInCardPayment` are never also summed (double-count hazard, pinned by test); transfers never count. Carry-in fold, anchored at the active plan's first payday: `carryIn(first) = 0`; `available(N) = carryIn(N) + allocation(N)`; `carryIn(N+1) = max(0, available(N) − used(N))`. Display: `remaining = max(0, available − used)`; `overage = max(0, used − available)` rendered as "$0 remaining · +$X over planned allocation" — never negative spendable money. Activating a different plan re-anchors the fold. All `Decimal`, `.rounded2` at display boundaries only.
- **R-29 Monthly debt progress (V4-08).** "Paid toward debts this month" = the R-28 qualifying-payment sum over the calendar month, labeled exactly that — never "paid off" for dollars. "Debts cleared this month" = debts whose derived balance (`AccountBalanceService.debtBalances()`) is zero now and whose earliest zero-reaching event (authoritative snapshot or payment) falls in the month. The Calendar dashboard consumes `DebtAllocationService` only, performs no arithmetic of its own, and refreshes on content changes (row IDs + `updatedAt`), not row counts.

---

## 6. Data model (schema version 3)

Schema-2 models persist unchanged except as extended below. All v0.3.0 changes are **additive with defaults** (SwiftData lightweight migration), per the pinned migration invariant: never alter an existing stored value.

### Extended: `CashAccount` (typealias `CheckingAccount`) — V3-02

- `+ protectedAmount: Decimal` (default 0) — per-account protected/reserved amount. Migration copies the profile floor onto the spending-role account (§7); the plan-level frozen `protectedBuffer` on `PlanVersion` is untouched.
- `+ balanceAsOf: Date?` (nil → fall back to `updatedAt`) — the as-of moment shown with the balance.
- `availableAmount` is **derived** per role by `AccountBalanceService` (spending: balance − protected; reserves: balance − obligation earmarks), never stored.
- Existing invariant unchanged: exactly one non-archived default income account (`CashAccountRepository`).

### Extended: `LedgerEntry` — V3-02/V3-03

- `+ LedgerEntryType` additive cases: `accountDeposit`, `accountWithdrawal`, `accountTransfer`, `accountAdjustment` (raw strings; legacy cases remain valid for existing rows).
- `+ provenanceRaw: String?` — `user` / `checkIn` / `migration` / `importRestore`; nil = recorded before provenance existed. Never backfilled.
- **Transfer representation (contract decision):** a transfer is **one atomic ledger row** carrying `sourceAccountID` and `destinationAccountID` (the existing shape) — presented as a paired movement in each account's activity view. This satisfies the release plan's paired-entries-in-one-transaction requirement with strictly fewer reconciliation failure modes than two linked rows.

### Unchanged: `BalanceSnapshot`

Already covers debts **and** cash accounts (`cashAccountID`), is append-only with a correction chain (`correctsSnapshotID`, `auditNote`), carries `isAuthoritative` and `SnapshotSourceType` provenance. V3-03's auditable-adjustment requirement is met by this model plus an `accountAdjustment` ledger row; no shape change.

### Extended: `PlanVersion` — V3-15

- `+ scenarioKindRaw: String?` — `fastestSafe` / `balanced` / `moreCushion` / `extraPayment`; nil = not scenario-born.
- `+ effectiveDate: Date?` — when an applied scenario's schedule begins; nil = immediate (legacy behavior).
- `inputSnapshotData` (existing) now encodes the extended `StoredPlanInput` (below); v2 snapshots remain decodable (new keys optional).

### Extended: `UserGoalProfile` — V3-05/V3-06

- `+ minimumProtectedCash: Decimal?` (Fastest Safe), `+ plannedSavingsPerPaycheck: Decimal?` (Balanced), `+ additionalCushionReserve: Decimal?` and `+ extraPaymentCeiling: Decimal?` (More Cushion), `+ zeroAllowanceConfirmedAt: Date?`.
- All nil until the user provides them → scenarios return missing-input results (R-17). Preferred floor/allowance remain the existing `protectedFloor`/`allowanceCap`.

### Extended: `OnboardingProgress` — V3-08

- `OnboardingStep` gains additive case `billsAndDebts`; legacy raws stay decodable; resume mapping per §4.

### Storage-independent DTO and protocol contracts (definitions binding; implementation is Wave-2/3 work)

The canonical names below are **the** names. The v0.2.0 lesson is pinned: duplicated bridges silently disagree — one declaration each, engine code importing Foundation only, and every store→engine conversion routed through `PlanGenerationService.engineInput`.

**Snapshot layer (`PlanningDTO.swift` — Codable, money-as-strings, `PlanningSnapshotCoder` byte-stable):**

- `StoredPlanInput` — extended with `scenario: StoredScenarioDefinition?` and `extraPayments: [StoredExtraPayment]` (default empty; optional keys so v2 snapshots decode).
- `StoredScenarioDefinition` *(new)* — `kind`, `incomeOverride: StoredIncomeOverride?` (`amount`, `cadence`, `effectiveDate`), `minimumProtectedCash: Decimal?`, `preferredFloor: Decimal?`, `preferredAllowance: Decimal?`, `plannedSavingsPerPaycheck: Decimal?`, `additionalReserve: Decimal?`, `extraPaymentCeiling: Decimal?`, `effectiveDate: Date`.
- `StoredExtraPayment` *(new)* — `id`, `kind` (`oneTime` \| `recurringPerPaycheck` \| `recurringMonthly`), `amount: Decimal`, `effectiveDate: Date`, `targetDebtID: UUID?` (nil = automatic avalanche target), `sourceAccountID: UUID?`.
- `StoredPlanResult` — unchanged shape; produced for calc-v3 runs exactly as for v2.

**Engine layer (`PlanningContracts.swift` — Foundation only, pure, deterministic, Sendable):**

- `PlanCalculationVersion` gains `.v3Scenario = 3`.
- `PlanningInput` gains `scenario: ScenarioInput?` and `extraPayments: [ExtraPaymentInput]` (engine-side mirrors of the stored types, converted only by `PlanGenerationService.engineInput`).
- `PlanningResult` unchanged in shape; calc-v3 results keep every existing field, identity, and `PlanEvent` identifier rule.
- `ScenarioResult` *(new)* — wraps a `PlanningResult` with the R-19 card summary: `kind`, `payoffDate`, `duration`, `totalStartingPrincipal`, `totalCurrentPrincipal`, `periodicDebtContribution`, `cashRetainedPerPaycheck`, `estimatedTotalInterest`, `totalPaid`, `minimumEndingCash`, `deltaVsBalanced` (`interestDelta`, `timeDelta`), `assumptions`, `missingInputs`, `warnings`.
- `ExtraPaymentInsight` *(new)* — `payoffDateBefore/After`, `daysSaved`, `periodsSaved`, `interestBefore/After/Saved`, `totalPaid`, `projectedPrincipalReduction`, `downstreamChanges`, `warnings`.

**Portability layer (Codable, no SwiftData types on the wire):**

- `PortableDocument` *(new envelope)* — `documentKind` (`fullBackup` \| `template`), `schemaVersion`, `appVersion`, `calculationVersion`, `exportedAt`, `payload`, `integrity` (record counts per collection). Writers emit export schema 3; readers accept 1, 2 (bare `Backup` shape, no `documentKind`), and 3. Never execute imported content; strict type validation; limits: 50 MB file, 250,000 records (A-10, tunable); duplicate IDs are rejected or explicitly remapped, never silently merged.
- `TemplatePayload` *(new)* — allow-listed setup structure only: account roles and default-income marker (generic placeholder names unless explicitly included), bill/debt categories and cadences, pay cadence, reminder preferences, scenario settings. **Default-excluded:** transaction/check-in history, balances and principal, income amounts, personally identifying labels, notes, plan events. Explicit inclusion of a sensitive category requires a warning enumerating exactly what will be included.
- `ReportConfiguration` *(new)* — `dateRange`, `sections`, `entityScope`, `detailLevel`, `includeAppendix`, `privacyOptions`.

**Protocol contracts (consumed by Wave 3; implemented by their §10 owners):**

- `ScenarioCalculating` — `scenarios(from: StoredPlanInput, definitions: [StoredScenarioDefinition]) throws -> [ScenarioResult]`; missing inputs surface in results, not as thrown errors, unless the input set is unusable (`GenerationError`-style actionable errors).
- `ExtraPaymentInsightCalculating` — `insight(from: StoredPlanInput, extra: StoredExtraPayment) throws -> ExtraPaymentInsight`.
- `CashAccountManaging` — account CRUD/reorder/archive (guarded), default-income enforcement, `record(deposit/withdrawal/transfer/adjustment)`, activity and balance history queries.
- `BackupPorting` — `exportBackup() throws -> URL`; `stage(data:) throws -> RestorePreview` (redacted counts/categories); `commit(preview:)` atomic; `cancel/rollback` leaves the store untouched; safety backup offered before destructive replacement.
- `TemplatePorting` — `exportTemplate(options:) throws -> URL`; `preview(data:) throws -> TemplatePreview`; `apply(preview:, mode: merge|add)` — never silently replaces actual history.
- `ReportGenerating` — `generate(_ config: ReportConfiguration) throws -> URL` (local PDF); documented temp-file lifecycle: report files live in a dedicated temp directory, are shared only via the user-invoked share sheet, and are deleted on next launch or when the report screen closes (A-11).

### v0.4.0 additions (binding names — one declaration each; owners per `ALPHA_V0.4.0_MULTI_AGENT_PLAN.md` §4/§6)

**Landed with the contract commit (Agent 1):**

- `UtilizationMath` (`Support/UtilizationMath.swift`, Foundation-only) — `utilization(balance:limit:) -> Decimal?` plus `informationalThreshold` (0.3) and `attentionThreshold` (0.9). The single R-12 implementation.
- `DebtType.usesOriginalPrincipal` (`Models/DebtAccount.swift`) — the single V4-01 predicate; `DebtPresentation.showsOriginalPrincipal` forwards to it.
- `PrimaryActionButtonStyle` + `ButtonStyle.primaryAction` (`Components/PrimaryActionButton.swift`) — the semantic V4-05 API; visual refinement and ownership pass to Agent 4.

**Specified here, implemented by the owner:**

- Engine (Agent 3): `PlanCalculationVersion.v4BalancedQuickWin = 4`; `ScenarioInput.quickWinPromotions: [UUID]` and `StoredScenarioDefinition.quickWinPromotions: [UUID]` (optional key, default empty; calc-v2/v3 snapshot bytes unchanged); `BalancedSelectionRationale` (Codable/Equatable/Sendable: `selection` avalanche|quickWin, `promotedDebtID`, `promotedDebtName`, `candidatesConsidered`, `interestDeltaVsAvalanche`, `payoffDelayPaychecks`, `firstPayoffAdvanceDays`, `releasedMinimumPerPaycheck`, `explanations`) attached as `ScenarioResult.balancedRationale`; `ReasonCode.quickWinPromotion`; `PlanningNoteCode.quickWinSelected` / `.quickWinCostsMoreInterest` / `.quickWinPromotionIneligible`; `BalancedStrategySelector` (pure); the four `PlanContract.balancedQuickWin*` constants; `PlanContract.currentCalculationVersion = 4`; `ExportService.backupSchemaVersion = 4` / `importableSchemaVersions = 1...4`.
- Allocation (Agent 6): `DebtAllocationCalculating` — `currentCycle(asOf:) throws -> PayCycleAllocation?`, `monthlyProgress(month:) throws -> MonthlyDebtProgress`; implemented by `DebtAllocationService` (`ModelContext` + `DateProviding`); `PayCycleAllocation` (`cycleStart`, `nextPayday`, `allocation`, `carryIn`, `available`, `paidThisCycle`, `remaining`, `overage`, `nextAllocation?`, `nextAllocationDate?`); `MonthlyDebtProgress` (`monthStart`, `paidTowardDebts`, `debtsCleared: [ClearedDebt]` with `id`/`name`/`clearedOn`).

No new persisted model fields; schema stays 3 (§2).

---

## 7. Migration (schema 2 → 3) — V3-01

Runs once, before any UI, single transaction, idempotent, rollback-safe (no store-level batch deletes inside rollback-able transactions — pinned v0.2.0 lesson). It may add fields and rows; it must never alter an existing stored value.

1. Detect `seedSchemaVersion = 2`.
2. `CashAccount.protectedAmount`: copy the profile's `protectedFloor` onto the spending-role account (the same account `AccountBalanceService` treats as the spending pool); 0 elsewhere. `balanceAsOf` stays nil (falls back to `updatedAt`). The profile and plan values are copied, not moved.
3. All other new fields default (`provenanceRaw` nil, `scenarioKindRaw` nil, `effectiveDate` nil, scenario-constraint fields nil).
4. Stamp `seedSchemaVersion = 3`; append a migration audit note to `AppSettings`.
5. **No re-onboarding, no duplicated rows, no touched values** — the full §3 rendering guarantees hold after migration, verified value-for-value on fictional fixture stores.

**Schema-1 stores and v1 backups.** The 1→2 logical upgrade currently hard-codes the founding user's two legacy obligation amounts — tracked personal data that V3-12 removes. Contract: replace the constants with **store-derived values** — reconstruct each legacy obligation's cadence-equivalent amount from the stored per-check reserve by inverse R-04 (`round2(perCheck × paychecksPerYear / occurrencesPerYear)`) and verify the R-04 round-trip reproduces the stored per-check value exactly, aborting cleanly on mismatch (same failure posture as v0.2.0). The legacy names/keys ("Checking 1/2", `car`/`train`) are app-seeded schema vocabulary and stay. This keeps both the direct 0.1.x→0.3.0 store upgrade and v1 **backup-file import** alive with zero personal values in source. If Agent 2 finds the derivation cannot satisfy the value-preservation acceptance, the fallback (a documented clean abort directing schema-1 stores through a 0.2.x build first) requires integrator ratification before it ships.

Fresh installs skip everything: schema-3 store, zero plan rows, onboarding is the only path to a plan. **No seed of any real person's data exists in the product (V3-12).**

---

## 8. Information architecture and screens

**Five tabs (v0.3.0): Today, Calendar, Accounts, Debts, Progress.** Settings stays in the Today navigation bar; the global `+` sheet adds deposit, withdrawal, and transfer alongside payment, balance update, windfall, adjustment, and note. The fifth tab is the presentation change that makes V3-02's workspace first-class; everything else keeps its v0.2.0 place.

**v0.4.0 amendments to this section:** the `+` sheet's adjustment item becomes the generic **"Checking account adjustment"** (§8.10); the Calendar tab gains the debt dashboard (§8.4); the Balanced scenario card gains its rationale (§8.6); primary actions adopt the semantic `.primaryAction` treatment (§8.11).

### 8.1 Today dashboard — F-02, V2-13

Unchanged, plus: account cards deep-link into the Accounts tab detail; if the active plan is scenario-born, the status header names its scenario kind in one calm line.

### 8.2 Accounts — V3-02, V3-03

Every active checking account as a card: user-defined name and roles; current balance with as-of timestamp; protected amount; available amount (derived, §6); default-income marker; next relevant planned movement (from the active plan/calendar); an attention state when ledger-derived and entered balances do not reconcile (with the difference shown and a one-tap path to record an adjustment).

Actions: add, edit, reorder, archive (blocked-or-explained while income routing, obligations, or planned schedules still reference the account); set default income; record deposit, withdrawal, transfer, or balance adjustment; view activity (ledger, newest first, provenance-aware) and balance history (snapshots including corrections).

- **Transfer sheet:** source, destination, amount, effective date, resulting balances for both sides; commits as one atomic ledger row (§6).
- **Balance adjustment:** explicit effective date and optional note; requires confirmation and explains it records a dated snapshot/adjustment — it never rewrites history (V3-03). Negative results warn, never shame.

### 8.3 Guided payday check-in — F-03, V2-15

Unchanged from v0.2.0.

### 8.4 Calendar — F-07, V2-12, V3-07, V4-08

Unchanged views and markers, plus §9 hardening. Calendar events continue to deep-link to the correct bill/debt/payment/check-in detail with tested missing-entity fallbacks.

**v0.4.0 (V4-08):** a **debt dashboard card** at the top of the tab, consuming `DebtAllocationService` only (R-28/R-29): paid toward debts this month; current cycle's planned allocation, carry-in, used, and remaining (overpayment as "$0 remaining · +$X over planned allocation"); the next payday's upcoming allocation labeled with its availability date; debts fully cleared this month when any. Wording is exact — dollars paid toward debt are never "paid off"; planned allocation is never presented as account cash; future allocations are never spendable today. The card refreshes immediately after any ledger/payment change, including edits that keep row counts equal (content-fingerprint observation), and reads correctly under VoiceOver and at accessibility sizes with meaning carried by text, not color.

### 8.5 Debts — F-04, V2-04/05, V3-04

Unchanged, plus: **What if I pay extra?** entry points on debt detail and in the payment entry flow, opening the extra-payment sheet (8.6). Due-date edits keep the §9 immediate-reschedule contract.

### 8.6 Scenarios and extra-payment insight — V3-04, V3-05, V3-06, V3-15

- **Payoff Scenarios screen** — primary entry: a card at the top of Progress ("Compare payoff plans"); also reachable from Settings → Plan versions. Preloads saved inputs; an overrides panel lets the user change income amount, pay frequency, and effective date (R-18) without touching saved data. Renders exactly three cards (R-17/R-19); Balanced is visually "Recommended", never auto-applied. Missing constraints render as a missing-input state that names the fields and offers editable, clearly labeled neutral suggestions (A-09).
- **Detail comparison** — opens from any card; side-by-side versus Balanced with assumptions and warnings.
- **Apply as New Plan** — confirmation step restating what will change and when; creates the future-effective calc-v3 `PlanVersion` (§5); the previous plan and all history remain intact (V3-15).
- **Extra-payment sheet** — one-time or recurring amount, target debt or automatic, optional source account, effective date; renders the R-20 insight as a non-mutating preview with the same Apply path.
- Both surfaces consume `ScenarioCalculating`/`ExtraPaymentInsightCalculating` protocols only — no engine math in views, no new store→engine bridge.
- **v0.4.0 (V4-03):** the Balanced card states its selection rationale in one calm line (quick win chosen and why, or avalanche order kept); the detail comparison renders the full `BalancedSelectionRationale`, including the honest interest tradeoff when a quick win costs more (R-27). Nothing else changes: three cards, Recommended badge, never auto-applied, missing-input behavior intact.

### 8.10 Add Entry — generic checking-account adjustment (v0.4.0 — V4-06)

The `+` sheet's legacy hard-coded "Checking 1 / 2 adjustment" item (seven founding-vocabulary entry kinds) is replaced by **"Checking account adjustment"**, opening one form: account picker (all active checking accounts by user-defined name, preselected when exactly one exists), adjustment type (**Set balance to…** / **Adjust by amount**), amount, effective date, optional note. Both types converge on `CashLedgerService.adjustBalance` — an authoritative `BalanceSnapshot` plus a signed `accountAdjustment` ledger delta written together in one save (provenance `user`), preserving the reconciliation companion-row invariant; "Adjust by amount" routes as stated-balance = current + delta. The legacy `CashAdjustmentView` is retired (soul.md amendment 6): historical legacy-shaped rows remain readable, rendered, and correctly included in every balance derivation forever (byte-for-byte non-mutation fixture test); the zero-amount Note entry is untouched. The Windfall form's "Checking 1"/"Checking 2" labels derive from account roles/names with a legacy fallback — no founding-user terminology survives in the generic flows. Auditability per V3-03: dated events, calm warnings, history never rewritten.

### 8.11 Primary-action treatment (v0.4.0 — V4-05)

`PrimaryActionButtonStyle` (`.primaryAction`) is the one semantic style for primary CTAs: Today's **Add Payment** and **View Full Plan**, debt detail's **Add Payment**, the quick-add forms' submit buttons, and primary onboarding actions. Requirements: text contrast ≥ 4.5:1 in **both** light and dark appearances (`AccentColor` gains a dark-appearance variant); pressed and disabled states visually distinct — an interactive button never resembles a disabled one and vice versa; minimum 44-pt targets; Dynamic Type scaling; VoiceOver labels and traits; safe under Increase Contrast and Reduce Transparency. Secondary and destructive actions keep system styles.

### 8.7 Insights — V2-14

Unchanged card row at the top of Progress, now followed by the Scenarios entry card.

### 8.8 Settings — V3-08 (management), §5.4 of the release plan

- **Bills & Debts** — the consolidated management page (same structure as onboarding step 5) replaces the separate Obligations entry; the Debts tab remains the execution/tracking surface.
- **Back Up & Restore** group: `Create JSON Backup`, `Restore JSON Backup`, `Export Template`, `Import Template`.
- **Reports** group: `Generate Financial Report`. Raw JSON is never labeled a report (V3-11).
- Plan versions screen: every version with calculation-version stamp, immutability badge on baselines, and scenario provenance (`scenarioKindRaw`) when present. The template loader is gone (V3-12).
- Accounts, Goals & posture, Review setup, notification settings: carried from v0.2.0; Review setup uses the consolidated Bills & Debts page.

### 8.9 Backup, template, and report flows — V3-09, V3-10, V3-11

- **Backup export:** system file exporter; warning that the file contains sensitive financial data; never uploaded automatically.
- **Restore:** staged — parse, validate (schema compatibility, relationships, limits, duplicate-ID policy), show a **redacted preview** (counts and categories, raw values only behind an explicit reveal), offer/create a safety backup before destructive replacement, then commit atomically; cancel or failure leaves current data byte-identical.
- **Template export:** §6 allow-list; explicit, warned opt-in per sensitive category. **Template import:** preview, then merge-with or add-to current setup; never silently replaces actual history.
- **Generate Financial Report:** user picks date range, sections/entities, detail level, optional appendix; produces a readable local multi-page PDF containing report date/range, chosen display names, current balances with protected/available amounts, bill and debt summary, active-plan status and next actions, the three-scenario comparison, extra-payment insight when requested, projected payoff order/dates and estimated interest, 30/60/90-day calendar actions, and the assumptions/estimate disclaimer. Layout handles long names, zero/negative states, and multiple pages with headers and page numbers; rendered on device; shared only via explicit user action; temp files cleaned per A-11.

---

## 9. Due dates, calendar, and notifications — V2-11 as hardened by V3-07, V3-13

Everything ratified in v0.2.0 stands: prospective-only edits (`dueDayEffectiveFrom`, append-only `dueDateAuditLog`), R-11 clamping through the single shared implementation, edits completing their reschedule before the editor dismisses, stable UUID-keyed identifiers (`<family>-<entity>[-<occurrence>]`), prefix-owned reconciliation that also cleans the 0.1.x legacy spellings, the 45-day window with the 60-request budget under the iOS 64 cap, fingerprint-diffed replacements, and no-op behavior when permission is denied or undetermined.

v0.3.0 hardening (V3-07):

- Reconciliation runs after every state that can invalidate the pending set: launch, migration, permission change, due-date edit, plan activation/replacement (including scenario application), archive/payoff, time-zone change, and app-settings changes — idempotently (a second run is a no-op).
- Completed/historical events never move; only future events rebuild.
- Month-end, leap-year, semimonthly, DST, and time-zone cases retain the intended local financial day (wall-clock components, no stored absolute instants).
- Deep links recover gracefully from archived/deleted/paid entities.
- Known model gaps carry forward, documented: weekly/biweekly bills have no due-date marker/reminder (day-of-month cannot describe them); long-cadence bills anchor to creation month. Closing them (a first-due-date/weekday anchor field) is optional Agent 5 scope, additive-only if taken.

Privacy (V3-13): identifiers contain no financial value and no user-entered label (already true — keep pinned by test); lock-screen copy is generic by default, detailed only via the existing per-reminder preference; diagnostics screens and logs never print balances, labels, payloads, or report contents. The debug notification-diagnostics screen remains debug-only.

---

## 10. Core services (v0.3.0)

Concept → canonical owner. **Evolve, never duplicate**: if a v0.3.0 concept maps to an existing type, extend it.

| Release-plan concept | Canonical repo type/service | Status |
| --- | --- | --- |
| `CashAccount` | `CashAccount` (typealias `CheckingAccount`) + `CashAccountRepository` | Extended (§6) |
| `CashLedgerEntry` | `LedgerEntry` + new `CashLedgerService` (deposits, withdrawals, atomic transfers, adjustments, activity queries) | Extended / New |
| `BalanceSnapshot` | `BalanceSnapshot` (already dual-subject, append-only) | Unchanged |
| `ScenarioDefinition` / `ScenarioResult` | `StoredScenarioDefinition` / `ScenarioInput` / `ScenarioResult` (§6) | New |
| Scenario calculation | `ScenarioCalculationService` — implements `ScenarioCalculating`; calls `AvalanchePlanEngine` via `PlanGenerationService.engineInput`; **no third bridge, no forked payoff algorithm** | New |
| Extra-payment insight | `ExtraPaymentInsightService` — implements `ExtraPaymentInsightCalculating`; same engine path | New |
| `PortableDocumentEnvelope` | `PortableDocument` in `ExportService`'s layer; `ExportService` evolves to write export schema 3 and read 1/2/3 (`BackupPorting`) | Extended |
| `TemplatePayload` / templates | `TemplateImportExportService` (`TemplatePorting`); may reuse `PlanPersister`'s atomic graph-insert path | New |
| `ReportConfiguration` / report | `FinancialReportService` (`ReportGenerating`) | New |
| `DueDateEventService` | `CalendarEventService` + `DueDateRule` | Extended |
| `NotificationReconciliationService` | `NotificationScheduler` + `NotificationPlanner` | Extended |
| Plan generation/activation | `PlanGenerationService` (single store→engine conversion), `GeneratedPlanService` (previews, activation, `nextPlanName` authority), `PlanPersister` (atomic insert), `PlanningInputBuilder` | Extended |
| Migration | `MigrationService` (§7; legacy amounts become store-derived) | Extended |
| Retired | `PlanSeeder`, `SeedPlan`/`SeedPlanLoader`, `TemplateCatalog`, bundled `OriginalPlanV1.json`, Release-exclusion build machinery | Removed (V3-12) |
| Utilization (V4-04) | `UtilizationMath` (Support; single R-12 implementation + thresholds) | New (v0.4.0, contract commit) |
| Balanced selection (V4-03) | `BalancedStrategySelector` via `ScenarioCalculationService`; engine promotion input; **no third bridge, no forked payoff algorithm** | New (v0.4.0, Agent 3) |
| Pay-cycle allocation (V4-07/V4-08) | `DebtAllocationService` (`DebtAllocationCalculating`); the only cycle-boundary implementation | New (v0.4.0, Agent 6) |
| Primary CTA (V4-05) | `PrimaryActionButtonStyle` (Components) | New (v0.4.0, contract commit → Agent 4) |
| Generic adjustment (V4-06) | existing `CashLedgerService.adjustBalance` + `CashAccountRepository`; legacy `CashAdjustmentView` retired | Extended / Removed (v0.4.0, Agent 5) |

Cross-cutting rules: engines import Foundation only; services take `ModelContext` + `DateProviding`; scenario work multiplies the known synchronous main-thread analysis cost — Agent 3 documents benchmark results and Agent 4 must not run calculators in view bodies (async task off the critical path is acceptable scope); `plannedTargetDebtID` remains a plan letter (calendar/notification routes key on it); the persisted `plannedCardBudget` (planned payment) vs. engine `debtBudget` (cash available) semantic split is respected by every new reader.

---

## 11. Acceptance criteria

### v0.1 and v0.2.0 criteria (regression — still binding)

All sixteen F rows (as amended in `soul.md`) remain binding. The v0.2.0 rows remain binding as restated here, with personal-value anchors superseded per V3-12 (behavior identical, verified against fictional fixtures — and, for the migrated install, against its own on-device values by its owner):

| ID | Still accepted only when… |
| --- | --- |
| V2-01 | Killing the app at every onboarding step boundary and mid-step, then relaunching, resumes at the correct step with all data intact; finishing twice cannot create duplicates. |
| V2-02 | Goal, target date, and posture persist; posture changes only suggested defaults and copy (identical numeric inputs generate identical plans under every posture). |
| V2-03 | 1–10 named, role-assigned accounts; exactly one default income account at all times; no credential-like field anywhere. |
| V2-04 | All six debt types create from the picker with correct type-specific forms and icons everywhere. |
| V2-05 | Balance, original principal, APR, minimum, editable due date, credit limit/utilization, and tri-state extra-principal eligibility round-trip create → edit → generation → display; ineligible debts never receive extra principal. |
| V2-06 | All four cadences generate correct timelines (month-end clamping, semimonthly pairs); future income rules switch amounts on their effective dates in plan and reforecast. |
| V2-07 | Obligation smoothing matches R-04 to the cent (fictional reduction checks in §5); per-paycheck reserves appear in plan items, check-in, and reserves card. |
| V2-08 | No generated schedule plans the spending account below the floor; floor top-ups precede extra principal. |
| V2-09 | The allowance is reserved as available-not-spent; recording spending lowers actuals only. |
| V2-10 | The calc-v2 generator reproduces its committed fictional golden outputs exactly; property tests confirm minimums-first, avalanche targeting, same-check rollover, and R-09 flags; calc v2 still reduces to calc v1 for biweekly cadence. |
| V2-11 | Editing any due date updates calendar markers and replaces exactly the affected notification requests before the editor dismisses; no duplicates, no orphans. |
| V2-12 | A generated plan's calendar renders identically to the migrated baseline's (markers, filters, day panel, shortfall flags). |
| V2-13 | The dashboard shows the user's named accounts, floor, allowance, goal line, and next play — the full F-02 five-second list. |
| V2-14 | All five insight cards render from stored data with accessible, estimate-honest wording; utilization badges only with a real limit at R-12 thresholds. |
| V2-15 | Check-in, ledger, snapshots, and reforecast behave identically on generated plans; baseline values are unchanged across any sequence of actual entries. |
| V2-16 | Upgrading a 0.1.x-lineage store preserves every pre-existing field value with no re-onboarding; a fresh install contains zero founding-user data (the template path no longer exists — V3-12). |
| V2-17 | Release build makes no network connections; no credential-type fields; storage local; export is the only, user-initiated egress. |
| V2-18 | New screens pass Dynamic Type, VoiceOver, Reduce Motion, 44-pt checks; no Double/Float money; older backups restore; CSV columns append-only. |

### v0.3.0 criteria

| ID | v0.3.0 is accepted when… |
| --- | --- |
| V3-01 | Upgrading a v0.2.x fixture store preserves every account, debt, bill, actual entry, plan version, due date, and notification preference — value-for-value, exactly once, idempotent across relaunches; a fresh install contains zero real-person data. |
| V3-02 | The Accounts tab shows every active account with name, roles, balance + as-of, protected, available, default-income marker, and next planned movement; add/edit/reorder/archive (guarded), default-income selection, deposits, withdrawals, transfers, and adjustments all work; transfers commit atomically with both sides visible in activity. |
| V3-03 | Every manual balance change produces a dated snapshot or adjustment row with optional note; history is never rewritten; unreconciled and negative states show calm warnings; the correction chain renders in balance history. |
| V3-04 | From debt detail and payment entry, one-time and recurring extra payments produce insights (payoff delta, time saved, interest saved, principal effect, downstream changes) that reconcile to the engine to the cent; nothing mutates until Apply; warnings fire per R-21. |
| V3-05 | The calculator renders exactly Fastest Safe, Balanced (Recommended), and More Cushion from saved inputs plus overrides; every R-19 field appears on each card; Balanced is recommended but never auto-applied; deltas versus Balanced are correct. |
| V3-06 | With any required input missing, scenarios name it instead of inventing values; all money math is Decimal; identical inputs produce identical results; results carry calculation version 3. |
| V3-07 | Editing any due date from setup or detail updates future calendar events and reconciles to exactly one correct set of notifications before the editor dismisses — no duplicates, no orphans, no moved history; reconciliation is idempotent across launch/migration/permission/time-zone/plan-replacement events. |
| V3-08 | Onboarding presents one Bills & Debts page with summary, two sections, and a single type-first add flow; every v0.2.0 field, validation, and debt type survives; interrupting anywhere resumes with both sections intact and zero duplicates; v0.2-interrupted stores resume correctly on the new step map. |
| V3-09 | A full backup exports with the v3 envelope and imports through staged validation, redacted preview, and atomic commit; v1 and v2 files import; corrupted/oversized/wrong-kind/duplicate-ID files are rejected with the store untouched; a safety backup is offered before destructive replacement; the sensitive-data warning appears. |
| V3-10 | Template export excludes history, balances/principal, income amounts, personal labels, notes, and plan events by default; explicit inclusion warns per category; import previews and merges/adds without ever replacing actual history; backups and templates are never confused (documentKind enforced). |
| V3-11 | Generate Financial Report produces a readable, multi-page local PDF matching the user's selected inputs with every §8.9 section, correct with long names, zero/negative states, and page furniture; JSON never appears as "the report"; temp files follow the documented lifecycle. |
| V3-12 | The tracked tree passes the privacy scan: no real balances, income, account labels, plan dates, payoff schedules, or the founding user's name in any source, resource, fixture, preview, test, doc, prompt, screenshot, or log; fixtures are clearly fictional; the migrated install's data survives on device untouched. |
| V3-13 | No balance, account name, imported payload, or report content appears in logs, breadcrumbs, notification identifiers, diagnostics, test output, or agent reports; lock-screen copy stays generic unless the detail preference is on. |
| V3-14 | Comments in changed code explain intent, invariants, platform limits, security, or formulas; narration, personal context, and stale plans are gone; useful warnings and API docs remain. |
| V3-15 | Previewing any scenario or insight changes no stored value (verified byte-for-byte); applying creates a new future-effective calc-v3 PlanVersion with a captured input snapshot; baselines and completed history are unchanged after any sequence of previews and applies. |
| V3-16 | Every new screen passes Dynamic Type (accessibility sizes), VoiceOver, high contrast, Reduce Motion, and focus checks, with real empty/error/loading states; interrupted imports, denied notifications, and failed report generation recover with data intact. |

### v0.4.0 criteria

| ID | v0.4.0 is accepted when… |
| --- | --- |
| V4-01 | No surface — editor, chip, Review gap, or Settings checklist — asks a credit card for original principal or lists it as missing; installment debts keep it as an optional gap; the §4.6 matrix holds field-by-field for all six types; the three validation surfaces agree exactly; only installment minimums and the structural blockers block generation; the V2-01 kill/resume matrix stays green. |
| V4-02 | At every step boundary: go back, change an upstream value (income amount, cadence, floor, allowance, a bill, a debt), proceed forward — every downstream validation, summary, reserve preview, utilization aggregate, and plan preview reflects the new value; an edit that keeps row counts equal still invalidates; committing a plan preview whose inputs changed since Generate is impossible (fingerprint-guarded, tested); no entered input is ever lost by navigation. |
| V4-03 | Balanced compares B0 plus every R-25 candidate via complete engine runs; guardrails G1–G3 and the lexicographic selection hold on fixture families covering every tie level and the no-admissible-candidate case; identical inputs select identically; the rationale's every figure reconciles to the two engine runs it cites; a costlier quick win is disclosed with its amount; calc v4 with no promotions is byte-identical to calc v3; stamps 1/2/3 never change; new plans stamp 4; `minimumModernCalculationVersion` is still 2 and the dispatch guards pass mutation checks; applied Balanced plans pin their promotion in the snapshot and regenerate identically. |
| V4-04 | Exactly one utilization implementation exists (`UtilizationMath`); every badge, insight, plan row, and engine result routes through it and its thresholds; a fictional near-limit card shows its true percent on every screen; unknown/zero/unknown-marked limits show "unknown", never 0%; an over-limit balance renders above 100%; display rounding is nearest-whole-percent with "<1%" for small non-zero ratios; the reported 0%-at-high-balance case is root-caused and pinned by a regression test. |
| V4-05 | The named CTAs and every swept primary action use `.primaryAction`; measured text contrast ≥ 4.5:1 in light and dark appearances; pressed/disabled states are distinct and disabled never mimics enabled; 44-pt targets, Dynamic Type at accessibility sizes, VoiceOver labels verified on the changed screens. |
| V4-06 | The `+` menu offers exactly "Checking account adjustment"; the form covers account picker, both adjustment types, amount, date, note for 1–10 fictional accounts; "Set balance to…" computes and appends the correct delta with its paired authoritative snapshot in one save; reconciliation still matches companion rows; a migrated fixture's legacy rows remain byte-identical, rendered, and included in derivations; no founding-user vocabulary remains in the generic flows; the Note entry still works. |
| V4-07 | Cycle boundaries are correct across all four cadences, month-end, leap-year, and DST fixtures; the carry-in fold is deterministic and re-anchors on plan activation; recording, editing, or deleting a payment recomputes immediately; a check-in payment and a quick-add payment on the same day count once each, never twice; overpayment renders "$0 remaining · +$X over planned allocation"; planned allocation, actual cash, and recorded payments are labeled distinctly; future allocations are never shown as spendable today. |
| V4-08 | The Calendar dashboard shows month-paid, cycle allocation, carry-in, used, remaining, upcoming allocation, and cleared debts, each reconciling to the ledger to the cent; wording never says "paid off" for dollars; the card updates immediately after any ledger change including same-count edits; VoiceOver and accessibility sizes pass. |

---

## 12. Parity matrices

### V2 ↔ F (carried from v0.2.0, still binding)

| V2 ID | soul.md | This document | Related F |
| --- | --- | --- | --- |
| V2-01 | v0.2 contract table | §4, §11 | F-01 (amended) |
| V2-02 | v0.2 contract table | §4, §6 UserGoalProfile, §11 | F-02 |
| V2-03 | v0.2 contract table | §4, §6 CashAccount, §11 | F-08, F-09 |
| V2-04 | v0.2 contract table | §4.5, §8.5, §11 | F-04 |
| V2-05 | v0.2 contract table | §4.5, §6, §11 | F-04 |
| V2-06 | v0.2 contract table | §4, §5 R-01/R-03, §11 | F-13 |
| V2-07 | v0.2 contract table | §4.5, §5 R-04, §11 | F-09 |
| V2-08 | v0.2 contract table | §4, §5 R-05/R-09, §11 | F-08 |
| V2-09 | v0.2 contract table | §4, §5 R-05, §11 | F-08 |
| V2-10 | v0.2 contract table | §4, §5, §11 | F-06, F-12 |
| V2-11 | v0.2 contract table | §8.5, §9, §11 | F-07, F-11 |
| V2-12 | v0.2 contract table | §8.4, §11 | F-07 |
| V2-13 | v0.2 contract table | §8.1, §11 | F-02 |
| V2-14 | v0.2 contract table | §8.7, §5 R-12/R-13, §11 | F-10 |
| V2-15 | v0.2 contract table | §8.3, §5 R-15, §11 | F-03, F-05, F-12 |
| V2-16 | v0.2 contract table | §3, §7, §11 | F-01 (amended), F-06 |
| V2-17 | v0.2 contract table | §1, §4, §11 | F-15 |
| V2-18 | v0.2 contract table | §1, §8.9, §11 | F-14, F-15 |

### V3 feature-parity matrix (canonical for the release)

| V3 ID | soul.md | This doc | Screens | Models / services | Tests (§13) | Owner | Related |
| --- | --- | --- | --- | --- | --- | --- | --- |
| V3-01 | v0.3 table | §2, §7, §11 | — (launch path) | `MigrationService`, `AppSettings.seedSchemaVersion` | T-1, T-2 | Agent 2 | V2-16, F-01 |
| V3-02 | v0.3 table | §6, §8.2, §10, §11 | Accounts tab, transfer/adjustment sheets | `CashAccount`, `LedgerEntry`, `CashAccountRepository`, `CashLedgerService`, `AccountBalanceService` | T-3, T-4 | Agent 2 (data) + Agent 4 (UI) | F-05, F-08, F-09 |
| V3-03 | v0.3 table | §6, §8.2, §11 | Adjustment sheet, balance history | `BalanceSnapshot`, `LedgerEntry.provenanceRaw` | T-4 | Agent 2 + Agent 4 | F-05 |
| V3-04 | v0.3 table | §5 R-20/R-21, §8.6, §11 | Extra-payment sheet (debt detail, payment entry) | `StoredExtraPayment`, `ExtraPaymentInsightService` | T-5, T-6 | Agent 3 (math) + Agent 4 (UI) | F-12 |
| V3-05 | v0.3 table | §5 R-17…R-19, §8.6, §11 | Payoff Scenarios screen, comparison detail | `StoredScenarioDefinition`, `ScenarioCalculationService`, `UserGoalProfile` | T-5, T-7 | Agent 3 + Agent 4 | F-12, V2-10 |
| V3-06 | v0.3 table | §5 R-24, §11 | Missing-input states | engine validation, `ScenarioResult.missingInputs` | T-7, T-8 | Agent 3 | V2-14 |
| V3-07 | v0.3 table | §9, §11 | Due-date editors, calendar | `DueDateRule`, `CalendarEventService`, `NotificationPlanner`/`Scheduler` | T-9, T-10 | Agent 5 | V2-11, F-07, F-11 |
| V3-08 | v0.3 table | §4, §8.8, §11 | Bills & Debts (onboarding + Settings) | `OnboardingProgress.billsAndDebts`, existing editors, `SetupCompletenessService` | T-11 | Agent 4 | V2-01…V2-07 |
| V3-09 | v0.3 table | §6, §8.9, §11 | Back Up & Restore group, restore preview | `PortableDocument`, `ExportService` (`BackupPorting`) | T-12 | Agent 6 | F-14, V2-18 |
| V3-10 | v0.3 table | §6, §8.9, §11 | Template export/import flows | `TemplatePayload`, `TemplateImportExportService` | T-13 | Agent 6 | F-14 |
| V3-11 | v0.3 table | §8.9, §11 | Reports group, report options, share sheet | `ReportConfiguration`, `FinancialReportService` | T-14 | Agent 6 | F-14 |
| V3-12 | v0.3 table | §1, §3, §7, §11 | Welcome (no template) | removal of seed/template stack; fictional fixtures | T-15, scan gate | Agent 2 (code/fixtures) + Agent 1 (docs, done) + Agent 7 (gate) | F-15, V2-17 |
| V3-13 | v0.3 table | §9, §11 | Diagnostics (debug) | logging discipline, identifier scheme | T-10, T-15 | Agent 2 + Agent 5 + Agent 7 | F-15 |
| V3-14 | v0.3 table | §11 | — | comment cleanup in owned files | review gate | Every agent, own files | — |
| V3-15 | v0.3 table | §5, §6 PlanVersion, §11 | Apply confirmation flows | `PlanVersion.scenarioKindRaw/effectiveDate`, `GeneratedPlanService` | T-6, T-16 | Agent 3 + Agent 4 | F-06, F-12, V2-15 |
| V3-16 | v0.3 table | §8, §11 | All new screens | states + recovery paths | T-17, UI suite | Agents 4, 5, 6 + Agent 7 | F-15, V2-18 |

### V4 feature-parity matrix (canonical for the release)

| V4 ID | soul.md | This doc | Screens | Models / services | Tests (§13) | Owner | Related |
| --- | --- | --- | --- | --- | --- | --- | --- |
| V4-01 | v0.4 table | §4.6, §11 | Bills & Debts editors/chips, Review, Settings checklist | `DebtType.usesOriginalPrincipal`, `SetupCompletenessService`, `DebtFormRules`, `BillsAndDebtsState` | T-18 | Agent 2 | V2-04, V2-05, V3-08 |
| V4-02 | v0.4 table | §4.7, §11 | Every onboarding/Settings setup step | content fingerprints, Review commit guard | T-19 | Agent 2 | V2-01, V3-08 |
| V4-03 | v0.4 table | §5 R-25…R-27, §8.6, §11 | Payoff Scenarios, comparison detail | `BalancedStrategySelector`, `quickWinPromotions`, `BalancedSelectionRationale`, `PlanContract` calc/export constants | T-20, CalcV4ReductionTests | Agent 3 (math+versions) + Agent 4 (card UI) | V3-05, V3-06, V3-15 |
| V4-04 | v0.4 table | §5 R-12, §11 | Debt rows/detail, insights, plan screen, onboarding previews | `UtilizationMath`, `AccountBalanceService.debtBalances` | T-21 | Agent 4 (+ Agent 2 in onboarding files, Agent 3 in engine) | V2-14, F-04 |
| V4-05 | v0.4 table | §8.11, §11 | Today, Debts, quick-add forms, onboarding CTAs | `PrimaryActionButtonStyle`, `AccentColor` dark variant | T-22, UI suite | Agent 4 (+ Agent 5 adoption in Ledger) | F-15, V2-18, V3-16 |
| V4-06 | v0.4 table | §8.10, §11 | Add Entry menu, adjustment form | `CashLedgerService.adjustBalance`, `CashAccountRepository`, `LedgerEntry` | T-23 | Agent 5 | F-05, V3-02, V3-03 |
| V4-07 | v0.4 table | §5 R-28, §11 | (service; surfaced by §8.4) | `DebtAllocationService`, `PayCycleAllocation`, `PaydayPlanItem`, `LedgerEntry` | T-24 | Agent 6 | F-05, F-12, V2-15 |
| V4-08 | v0.4 table | §5 R-29, §8.4, §11 | Calendar tab dashboard | `DebtAllocationService`, `MonthlyDebtProgress` | T-25 | Agent 6 | F-07, V2-12 |

---

## 13. Validation and tests

### Fixture policy (V3-12 — binding for every suite)

All fixtures, previews, golden files, and pinned assertions use **clearly fictional data**. The existing suites anchored on the founding user's values are re-anchored, not weakened:

- `AvalancheLemParityTests` → renamed `AvalancheBaselineParityTests`; asserts calc-v2 ↔ calc-v1 check-by-check equivalence on a **fictional** multi-debt biweekly fixture (the reduction property needs no real data).
- `DebtCalculationEngineTests` → frozen calc-v1 engine tested against a fictional golden projection (order, dates, payoffs, interest) committed as the new anchor.
- `MigrationServiceTests` → fictional schema-1 and schema-2 fixture stores, still verifying every pre-existing field value-for-value, idempotence, and induced-failure rollback; plus the new §7 derivation round-trip.
- `PlanSeederTests` / `TemplatePrivacyTests` → replaced: seeding tests move to a fictional programmatic fixture used by `--uitest-skip-onboarding`; the privacy suite now asserts **no bundled personal resource exists in any configuration** and that the seed/template symbols are gone.
- `PlanningFixtures` / UI tests → fictional values and a fictional pinned "today"; persona-named symbols, comments, and file names renamed.
- Test counts may change with the re-anchor; `ReviewRegressionTests` and `ReleaseIntegrationTests` keep their defect coverage with fictionalized constants.

### Required new tests (v0.3.0)

1. **T-1 Migration 2→3:** fixture v2 store → v3 with every value unchanged, additive fields defaulted, idempotent, rollback on induced failure.
2. **T-2 Fresh install:** schema-3 store contains zero plan rows and zero real-person data; onboarding is the only plan path.
3. **T-3 Cash ledger:** deposits/withdrawals/transfers/adjustments produce correct rows; transfers atomic with both sides in activity; archive guards; exactly-one-default-income invariant preserved under all operations.
4. **T-4 Auditable adjustments:** adjustment → snapshot + ledger evidence; correction chains render; reconciliation warning math; no history rewrite (byte-for-byte store diff).
5. **T-5 Engine reduction:** calc v3 with no scenario/extras ≡ calc v2 output, byte-identical; R-16 identities hold on every scenario and insight result (property tests).
6. **T-6 Extra payments:** one-time and recurring extras across cadences; chosen vs automatic target; eligibility (R-07) respected; insight deltas reconcile to full engine runs; Apply creates a calc-v3 plan version and mutates nothing else.
7. **T-7 Scenario correctness:** the three constraint sets produce ordered outcomes (Fastest Safe ≤ Balanced ≤ More Cushion payoff dates; interest ordered accordingly, ties allowed); deltas vs Balanced; minimum-ending-cash path; determinism across repeated runs.
8. **T-8 Honest inputs:** each missing input (APR, minimum, cadence, constraints, …) yields the named missing-input result; zero-allowance requires the confirmation flag; overrides never mutate saved inputs.
9. **T-9 Due-date hardening:** month-end/leap/semimonthly/DST/time-zone cases; prospective-only rebuilds; historical events immovable.
10. **T-10 Notification reconciliation:** idempotent across launch/migration/permission/plan-replacement/archive/payoff; exactly-one-correct-set after edits; identifiers and content free of financial values and labels.
11. **T-11 Consolidated setup:** resume at every boundary of the new step map, including v0.2-interrupted fixture stores; no duplicates on any path; field/validation parity with v0.2.0.
12. **T-12 Backup:** v3 round-trip; v1 and v2 import; corrupted/wrong-kind/newer-schema/oversize/duplicate-ID rejection; staged preview counts; atomic rollback; safety backup.
13. **T-13 Templates:** default exclusion list enforced field-by-field; explicit-inclusion warnings; merge/add import; never touches actual history; documentKind cross-rejection (backup ≠ template).
14. **T-14 Report:** PDF generates from fixture data across sections/ranges; multi-page, long-name, zero/negative layouts render; temp-file lifecycle; failure leaves data intact.
15. **T-15 Privacy:** no financial payload in captured logs or notification content; the repo-wide PI scan (value-pattern + marker checks) passes on the tracked tree and on generated test artifacts.
16. **T-16 Plan separation:** any sequence of previews and applies leaves baselines and completed history byte-identical; applied plans are future-effective and correctly stamped.
17. **T-17 Accessibility/recovery:** new screens at accessibility sizes, VoiceOver labels, Reduce Motion; interrupted import, denied notifications, failed report generation.

### Required new tests (v0.4.0)

18. **T-18 Debt-type validation matrix:** per type × field, the §4.6 matrix holds on every surface — a card never sees an original-principal ask, warning, or gap anywhere; loans keep the optional gap; blocking set unchanged; editors, chips, and `SetupCompletenessService` agree on identical fixtures.
19. **T-19 Reactive setup:** the back-edit-forward matrix at every step boundary; same-count edits invalidate; the Review commit-staleness guard (mutate the store between Generate and Commit — the stale preview must not persist); the V2-01 kill/resume matrix regression-green.
20. **T-20 Balanced selector:** R-25 enumeration (pre-filter over-inclusion proof, horizon check), G1/G2/G3 edge cases (zero-baseline-interest G2, cap boundary, exact-tie at every lexicographic level, no-admissible-candidate → B0), determinism across repeated runs, promotion mechanics (eligibility no-op + warning, R-16 identities on every promoted run), rationale figures reconciling to their engine runs, `CalcV4ReductionTests` (v4 no-promotions ≡ v3 byte-identical; chain to v2/v1 intact), stamping and dispatch guards (calc-2/3 plans reach the modern engine; calc-1 stays off; new plans stamp 4; both calc-version representations agree), applied-plan snapshot pinning and regeneration.
21. **T-21 Canonical utilization:** property tests on `UtilizationMath` (nil/zero/negative limit → nil; exact Decimal ratios; >100%; threshold boundaries at 0.30/0.90); display rounding nearest-whole with "<1%"; the 0%-report regression pin; no surviving reimplementation (review gate + targeted assertions on the retired sites).
22. **T-22 Primary CTA:** style unit coverage (enabled/pressed/disabled distinctness), UI-suite checks for the named CTAs at accessibility sizes in both appearances, contrast evidence recorded in the agent report.
23. **T-23 Generic adjustment:** menu copy; picker across 1–10 fictional accounts; set-balance delta math (positive/negative/zero-delta = snapshot only); snapshot+row same-save pairing and reconciliation companion matching; migrated-fixture legacy rows byte-identical and still derived; windfall labels role-derived with legacy fallback; Note entry unaffected.
24. **T-24 Allocation service:** boundaries across all four cadences with month-end/leap/DST fixtures; fold determinism and plan-activation re-anchor; payment record/edit/delete recompute; the double-count guards (check-in + quick-add same day); refund/correction handling; overage display rule; no-cycle-before-first-payday state.
25. **T-25 Calendar dashboard:** every figure reconciles to the ledger to the cent on fixtures; precise wording assertions ("paid toward", never "paid off" for dollars); same-count-edit refresh; VoiceOver labels; accessibility sizes.

### Operational rules (unchanged, non-optional)

Per `TESTING.md`: every concurrent checkout gets its own `-derivedDataPath` and its own simulator; the UI suite runs alone with `-parallel-testing-enabled NO`. Device-only checks (notification delivery, provisional auth, lock-screen rendering, DST travel, cold-launch deep links, share-sheet/file-importer behavior) are documented separately and gate distribution, not merge.

---

## 14. Updated project structure (delta)

```text
PaydayPlaybook/
├── Models/          CashAccount, LedgerEntry, PlanVersion, UserGoalProfile,
│                    OnboardingProgress extended per §6 (additive only)
├── Services/        + CashLedgerService.swift, ScenarioCalculationService.swift,
│                    ExtraPaymentInsightService.swift, TemplateImportExportService.swift,
│                    FinancialReportService.swift
│                    − PlanSeeder.swift, SeedPlan.swift, TemplateCatalog.swift (V3-12)
│                    (ExportService, MigrationService, CalendarEventService,
│                     NotificationScheduler/Planner, PlanningDTO, PlanningContracts extended)
├── Features/
│   ├── Accounts/    new: Accounts tab, account detail, transfer/adjustment sheets
│   ├── Scenarios/   new: Payoff Scenarios, comparison, extra-payment sheet
│   ├── Onboarding/  Bills & Debts consolidated step (+ resume mapping)
│   └── Settings/    Bills & Debts management, Back Up & Restore + Reports groups
├── Resources/       − OriginalPlanV1.json (V3-12)
└── Tests/           re-anchored fixtures + T-1…T-17 suites (§13)
```

---

## 15. Build sequence for 0.4.0 (dependency waves)

*(The 0.3.0 sequence completed at integration commit `9615c35`/release `a402413`; its record stands in the v0.3.0 plan and reports.)*

1. **Wave 1 — Contract (`feature/v0.4-contract`):** docs, V4 registry, versioning, and the three shared leaf types (`UtilizationMath`, `DebtType.usesOriginalPrincipal`, `PrimaryActionButtonStyle`). No feature code.
2. **Wave 2 — Foundations, parallel:** Agent 2 (`feature/v0.4-validation-reactivity`: V4-01 relevance matrix, V4-02 reactivity + commit guard) and Agent 3 (`feature/v0.4-balanced-strategy`: calc-v4 promotion input, `BalancedStrategySelector`, rationale DTO, calc/export version bumps with dispatch guards). Disjoint by file; the §6 names are binding — do not mint alternatives.
3. **Wave 3 — Surfaces, parallel, isolated worktrees:** Agent 4 (`feature/v0.4-utilization-design`: canonical utilization adoption + root-cause, semantic CTA treatment, Balanced rationale card UI), Agent 5 (`feature/v0.4-account-adjustment`: generic adjustment flow), Agent 6 (`feature/v0.4-allocation-calendar`: `DebtAllocationService` + Calendar dashboard).
4. **Wave 4 — Integration (Agent 7, `release/v0.4.0-alpha.1`):** merge in order 1→2→3→4→5→6, build + unit suite after every merge (the v0.3.0 clean-merge-compile-fail lesson), per-diff PI review, full regression + privacy gates, version/build stamp, truthful changelog, release recommendation.

Do not skip calculation, migration, or privacy tests to rush visual work. Only an owning agent (or Agent 7) edits a shared file; interface disputes resolve through the §6/plan-§4 contract, not parallel edits. Pre-assigned hot spots: onboarding utilization call sites → Agent 2; `QuickAddSheet.swift` (including its `.primaryAction` adoption) → Agent 5; `TodayView.swift` → Agent 4; `CalendarTabView.swift` → Agent 6.

---

## 16. Exclusions (v0.3.0)

Still out of scope: bank/card APIs, cloud sync, Android/web, automatic payments, receipt scanning, household accounts, AI recommendations, trading, widgets/watch/Siri, debt snowball mode, multi-income households. (Scenario comparison, previously listed here, ships in v0.3.0 as V3-04/V3-05.) Git-history remediation for previously committed personal data is explicitly **not** part of v0.3.0 implementation — it is a read-only audit plus an owner decision (release plan §3).

---

## 17. Definition of done (v0.3.0)

v0.3.0 is done only when:

- every §11 V3 criterion and every carried-forward F/V2 criterion passes;
- a migrated v0.2.x store keeps every pre-existing value intact through schema 3, exactly once;
- a fresh install reaches a generated plan fully offline with zero real-person data;
- the tracked tree, fixtures, logs, test artifacts, and reports pass the privacy scan;
- previews never mutate; applied scenarios are future-effective calc-v3 plan versions;
- due-date edits reconcile calendar and notifications with no duplicates and no orphans;
- backup v1/v2/v3 import, v3 round-trip, template exclusions, and the PDF report are verified;
- accessibility and failure-state checks pass, with device-only items documented;
- `CHANGELOG.md` claims exactly what shipped, nothing more.

### v0.4.0 addendum

v0.4.0 is additionally done only when every §11 v0.4.0 criterion passes, the
`ALPHA_V0.4.0_MULTI_AGENT_PLAN.md` §10 definition of done holds in full (no stored plan
changes value; the reduction chain and dispatch guards are mutation-checked; export
schema 4 round-trips with 1–3 still importing; the pay-cycle figures reconcile to the
ledger to the cent), and Agent 7 returns `READY FOR ALPHA DEVICE TESTING`.

---

## 18. Apple implementation references

- SwiftData persistence: <https://developer.apple.com/documentation/swiftdata>
- SwiftData migration: <https://developer.apple.com/documentation/swiftdata/schemamigrationplan>
- User Notifications: <https://developer.apple.com/documentation/usernotifications>
- Calendar triggers: <https://developer.apple.com/documentation/usernotifications/uncalendarnotificationtrigger>
- File import/export: <https://developer.apple.com/documentation/swiftui/fileimporter> / <https://developer.apple.com/documentation/swiftui/fileexporter>
- PDF rendering: <https://developer.apple.com/documentation/uikit/uigraphicspdfrenderer> / <https://developer.apple.com/documentation/pdfkit>

Use the current stable Apple documentation and SDK installed with Xcode while preserving the behavior specified here.
