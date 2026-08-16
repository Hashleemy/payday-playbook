# Changelog

All notable changes to Payday Playbook are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer 2.0.0](https://semver.org).
App, build, schema, calculation, export-schema, and user-plan versions are distinct — see
`docs/releases/v0.3.0/VERSIONING.md` (current cycle) and `docs/releases/v0.2.0/VERSIONING.md`.

## [Unreleased]

Nothing yet. `0.3.0-alpha.1` is prepared but **not tagged and not distributed** — see the
release note below and `docs/releases/v0.3.0/agent-reports/agent-7-integration-qa.md`.

## [0.3.0-alpha.1] — 2026-08-15

App version **0.3.0** · build **4** · persistence schema **3** · calculation version **3**
· export schema **3** (reads 1, 2, and 3). 515 unit tests and 35 UI tests green in the
simulator. The authoritative feature registry is `ALPHA_V0.3.0_MULTI_AGENT_PLAN.md`
(V3-01…V3-16).

**Not validated on hardware.** Notification delivery, lock-screen copy, the share sheet,
the system file importer, and the upgrade rehearsal are simulator-only so far; the device
checklist in `TESTING.md` gates distribution.

### Added

- **Checking Accounts, as its own tab** (V3-02/V3-03). Every account shows its balance and
  when that balance was last stated, what is protected, and what is therefore available.
  Add, edit, reorder, archive, and set which account receives your paycheck. Deposits,
  withdrawals, transfers, and dated balance adjustments all write to one ledger, and a
  transfer is a single row carrying both endpoints, so both balances move together or
  neither does. A balance correction records the difference as its own dated row plus the
  figure you stated — history is never rewritten. Archiving is either allowed or explained:
  the app names what still points at the account and where to change it.
- **Payoff Scenarios** (V3-04/V3-05/V3-06): Fastest Safe, Balanced (Recommended), and More
  Cushion, computed from your own saved inputs with optional income and date overrides.
  Every card states its assumptions, and a constraint you have not given produces a named
  missing-input card rather than a number nobody entered. Nothing is auto-applied;
  previewing writes nothing, and applying creates a new future-effective plan version while
  the previous one keeps every row.
- **"What if I pay extra?"** (V3-04) from debt detail and the payment flow: interest saved,
  days saved, and principal reduction, computed as the difference between two full engine
  runs so the figures agree with the plan to the cent. It says plainly that a credit card
  has no principal-only instruction to give, and warns rather than guessing when the cash
  or the lender's prepayment terms cannot support the payment.
- **Consolidated Bills & Debts setup** (V3-08), one page in onboarding and in Settings,
  with one add action, inline warnings for incomplete rows, reorder, and archive. It hosts
  the existing editors rather than reimplementing them, so no field was lost.
- **Full JSON backup and restore** (V3-09). Documents now carry a header stating what kind
  of document they are, what schema they speak, and how many rows they should contain, so
  a truncated or edited file is refused by name instead of failing deep inside a decode.
  Restore stages and previews before it commits, writes a safety backup first, and either
  completes or leaves the store untouched.
- **Reusable structure-only templates** (V3-10): your setup's shape without your money.
  The format has no field for history, ledger rows, plans, or notes, so none can be
  emitted. Names, balances, income, bill amounts, and guardrails are each opt-in, and each
  states exactly what turning it on writes into the file.
- **Generate Financial Report** (V3-11): a paginated PDF built from your selected sections,
  date range, and detail level, rendered on device and shared only when you tap share.
  Optional privacy reductions replace names with generic labels and leave balances out
  entirely. Every report ends with the estimate disclaimer.
- **Calculation version 3** — the scenario and extra-payment engine. With no scenario and
  no extra payments it reproduces calculation version 2 exactly, so no existing plan
  changes value.

### Changed

- **Personal financial data removed from the project** (V3-12), in documentation *and* in
  code. The bundled Original Plan v1 template, the seeder, the template catalog, and every
  constant, fixture, golden value, pinned date, and comment derived from that one person's
  plan are gone from every build configuration, replaced by an invented development
  fixture whose schedule is computed by the engine rather than transcribed. A fresh install
  now stores nothing at all.
- **Eleven screens stopped showing one person's numbers to everyone.** Where a plan could
  not be read, the app used to fall back to hard-coded values — another user's income,
  totals, payoff order, and dates, presented as if they were yours. Each now degrades
  honestly: zero, a dash, your own rows, or a prompt to enter what is missing.
- **A fifth tab.** Accounts sits between Calendar and Debts; everything else keeps its
  place.
- **Settings splits Back Up & Restore from Reports**, and "Essential bills" becomes
  "Bills & debts", pointing at the consolidated page.
- **The 1 → 2 migration no longer carries hard-coded obligation amounts.** It recovers each
  amount from the store's own per-check reserve and refuses to migrate unless the recovered
  figure reproduces the stored one exactly. Its integrity pre-check is now structural
  rather than a comparison against one plan's row counts, which used to reject valid stores
  of a different size.
- **Restoring an older backup now runs every migration step the file predates**, instead of
  stopping at schema 2 and being migrated again on the next launch.
- **Exports are order-stable**, so two exports of unchanged data are identical files.

### Fixed

- **A weekend-rule change was retroactive.** Changing only the weekend rule re-drew past
  due-date markers up to two days off — completed history appeared to move. Both halves of
  a due rule are now prospective and audited.
- **Bill due-date markers on the calendar did nothing when tapped.** They now open the bill.
- **Debt links could open the wrong debt.** Deep links keyed on the reusable plan letter, so
  deleting a debt and adding another could point an already-delivered reminder or an
  already-drawn calendar row at a debt you never tapped. Links now carry the debt's own
  identity; the letter remains only where there genuinely is no identity to carry.
- **A reminder permission granted in Settings or onboarding did not take effect** until the
  app was backgrounded and reopened.
- **A tap on a deleted or archived bill silently did nothing** instead of explaining.
- **An error message could quote a raw amount from a backup file.** It now names the
  collection and field and never the value.

### Security and privacy

- No financial value is logged anywhere: the app has no logging call site that can emit
  one, notification identifiers are built from entity identifiers and never amounts, and
  reminder copy carries no figure unless you turn detailed lock-screen content on yourself.
- **Importing a template can never turn detailed lock-screen content on**, whatever the
  file says — that decision belongs to whoever holds the device.
- Backups, templates, and reports are written to the app's own temporary storage with file
  protection, leave only through a share sheet you tap, and are purged when you are done
  with them. Nothing is ever uploaded.
- **Removing this data from the working tree does not remove it from Git history**, where
  it remains reachable from most refs and both existing tags. The repository has been
  pushed to a remote. History remediation is an owner decision and is deliberately not
  taken here; external distribution is blocked until that decision is made.

### Known limitations

- Weekly and biweekly bills still get no due-date marker or reminder, and quarterly,
  semiannual, and annual bills recur from the month they were created.
- Plan analysis, the scenario calculators, and report rendering are synchronous on the main
  thread. Three scenarios plus one insight take roughly 1.3 s on an eight-debt, 77-paycheck
  plan; both screens show a loading state rather than blocking silently.
- A structure-only template cannot create bills, installment debts, or a pay schedule,
  because those require amounts the template deliberately omits. It reports what each one
  still needs instead of inventing a figure.
- The paycheck snapshot cannot carry a promotional APR, so a promo rate reaches the engine
  only through a directly-built input.

## [0.2.0-alpha.2] — 2026-08-11

App version 0.2.0 · **build 3**. Supersedes alpha.1 (build 2), which was tagged before
device testing. 286 unit tests and 19 UI tests green.

### Changed

- **The Original Plan v1 template no longer ships in distribution builds.** It is one real
  person's finances, and a resource in the app bundle is readable by anyone who unzips the
  `.ipa` — so hiding the button was not sufficient. The Release configuration now excludes
  `OriginalPlanV1.json` from the bundle outright, and a Release build phase fails the build
  if it is ever present. Availability is derived from the resource existing, so a build
  without it also draws no "Load a template" affordance. Developer builds keep the
  template: the crashed-partial-seed migration repair and the seed test suites need it.
  Resolves the open question Agent 1 raised in the v0.2.0 product contract.

### Fixed

- A clean install could appear to "remember" the user. It did not — the Welcome screen's
  "Load a template instead" button seeded Original Plan v1 and completed setup in a single
  tap, and because that template is the current user's own real plan, the result was
  indistinguishable from the app having restored their data. Found on a physical iPhone
  during alpha.1 device testing. The onboarding routing itself was never at fault.

### Known limitations

- Unchanged from alpha.1, including the notification device-testing gate. A distribution
  build that meets a 0.1.x store whose *initial seed had crashed mid-write* can no longer
  repair it, because that repair re-reads the bundled template. Migration already aborts
  cleanly and leaves the store untouched in that case, and it cannot arise for an install
  whose 0.1.x seed completed — which is every real 0.1.x install.

## [0.2.0-alpha.1] — 2026-08-11

App version 0.2.0 · build 2 · persistence schema 2 · calculation version 2 · backup schema 2.

Alpha prerelease. Everything below is integrated on `release/v0.2.0-alpha.1` with 281 unit
tests and 18 UI tests green. Feature IDs refer to `ALPHA_V0.2.0_MULTI_AGENT_PLAN.md`
(V2-01…V2-18). Local notification *delivery* has not yet been validated on a physical
device — see "Known limitations".

### Added

- Resumable first-run onboarding: goals and payoff posture, protected cash floor and
  allowance cap, multiple named checking accounts with roles and exactly one default
  income account, income with cadence and future-dated changes, and essential recurring
  obligations. Every step persists real rows as it is completed, so an interruption or
  force-quit resumes exactly where it left off without duplicate accounts, debts, or
  plans (V2-01…V2-03, V2-06…V2-09).
- Debt type picker — credit card, personal loan, car note/auto loan, student loan,
  medical debt, other — with type-specific inputs: current balance, original principal,
  APR, minimum payment, editable due date, card limit with utilization, and tri-state
  extra-principal eligibility (V2-04, V2-05).
- Generated avalanche plan built from the user's own inputs by the new calculation-version-2
  engine: minimums funded by due date, protected cash and obligations reserved, remaining
  capacity to the highest effective-APR eligible debt, rolling to the next debt within the
  same paycheck on payoff, with every paycheck reconciling to the cent (V2-10).
- Plan screen: inputs and assumptions, recommended order with per-debt reasoning, projected
  payoff, minimums-only comparison, per-debt timeline, a paycheck-by-paycheck playbook
  behind a Plan / Actual / Reforecast selector, what-if scenarios, and explicit plan
  activation as a new version (V2-10, V2-15).
- Insight cards: interest saved versus minimums-only, payoff-date delta, utilization
  alerts, obligation crunch warnings, and allowance usage trend — each withheld rather
  than guessed when the inputs cannot support it (V2-14).
- Plan calendar covering paydays, transfers, reserves, debt payments, debt and obligation
  due dates, milestones, ledger entries, balance snapshots, and reforecasts, with five
  explicit statuses and typed deep links that never dead-end (V2-12).
- Schema 1→2 migration preserving the existing user's exact baseline schedule, history,
  and check-ins verbatim, in a single
  transaction that rolls back untouched on any failure. Migrated users are never asked
  to re-onboard; an upgrade checklist asks only about what migration could not know
  (V2-16).
- Original Plan v1 available as a deliberate, warned template load instead of a forced
  default for every new install.

### Changed

- Fresh installs no longer auto-seed Original Plan v1 (F-01 amended in `soul.md`). Today,
  Plan, Debts, Calendar, Progress, Settings, and check-ins now read the user's own named
  accounts, obligations, and all six debt types rather than the seeded plan's hard-coded
  cards and "Checking 1/Checking 2" (V2-11…V2-13, V2-15).
- Due dates accept days 1–31 and clamp to the last valid day of shorter months; weekend
  shifting is opt-in and never applied by default. Editing a due date updates the calendar
  and reschedules notifications before the edit screen dismisses, and is prospective —
  history is never rewritten (V2-11).
- Local notifications are rescheduled by diffing desired against pending requests instead
  of clearing and rebuilding, using namespaced, entity-keyed (UUID) identifiers. Identical
  requests are left untouched, changed ones replace in place, and ours-but-unwanted ones
  are removed — so an upgrade from the 0.1.x letter-keyed scheme cannot double-fire (F-11).
- Backup schema 2: writes version 2, restores version 1 and 2 files through the same
  logical migration; restore is a single transaction; CSV columns are append-only (V2-18).
- App marketing version corrected from the Xcode scaffold default `1.0` to `0.2.0` — the
  shipped MVP was, in SemVer terms, the untagged 0.1.0 alpha. Build number 1 → 2.

### Fixed

- The plan shown on screen could differ from the plan that was saved. The presentation
  layer regenerated plans through its own copy of the store→engine conversion, which
  ignored the snapshot's `asOf` stamp, collapsed the tri-state prepayment flag to a
  boolean, defaulted missing semimonthly pay days instead of failing, and did not
  normalise reversed semimonthly days. There is now one conversion.
- Freshly onboarded users saw the bundled template's take-home amount as their own on
  Today, Settings, and the Phase II screen, because the income lookup read the
  template-only plan and fell back to a hard-coded constant.
- The payday variance chart on Progress was empty for generated plans, for the same
  template-only lookup reason.

### Unchanged guarantees

- Local-only; no accounts, no telemetry, no bank credentials, full card numbers, CVVs, or
  SSNs collected (V2-17). All money is `Decimal`. Planned, actual, and reforecast remain
  three separate truths, and no baseline plan version is ever edited or regenerated.
- Original Plan v1 stays stamped calculation version 1 and is never recomputed; the
  frozen calc-v1 engine is untouched and still reproduces that plan's stored schedule
  exactly.

### Known limitations

- **Notification delivery is unverified on hardware.** Everything is tested against a
  fake notification centre: what the app *asks* the system for is correct, but real
  delivery on a locked device, provisional authorization, the 64-request system limit in
  practice, lock-screen rendering, physical time-zone travel and DST rollover, and
  cold-launch deep links all still require a physical iPhone. See `TESTING.md` §Device.
- Weekly and biweekly obligations get no due-date marker or reminder — a day-of-month
  cannot describe them. Their per-paycheck reserve still appears on every payday.
- Quarterly, semiannual, and annual obligations are anchored to their creation month; the
  model cannot yet express a specific first due date.
- Editing a due day blanks that item's markers for months before the edit, rather than
  inventing a history the app never recorded.
- Migrated debts carry no `originalPrincipal`; percent-paid falls back to the starting
  balance exactly as 0.1.x computed it, and the upgrade checklist offers to fill it in.
- The plan analysis (baseline, reforecast, and two what-if scenarios) runs synchronously
  on the main thread. Fast for a 23-paycheck plan; a very long plan would benefit from
  moving off the main actor.
- At the largest accessibility text sizes the primary action on Today sits below the fold
  and requires a scroll.
- Interest is simple, 365-day, accrued per payday — not daily compounding or issuer
  statement cycles — so real card interest will differ. Every plan surfaces these
  assumptions in the UI.

## [0.1.0] — 2026-08-10

First alpha MVP (untagged at release; retro-tag `v0.1.0` recommended on `main`).

### Added

- Offline-first iOS app executing the founding user's exact debt plan: seeded immutable
  Original Plan v1 (a fixed biweekly payday schedule across a set of credit cards),
  five-second dashboard, guided payday check-in with
  reconciliation, contribution ledger, balance snapshots, calendar, local notifications
  with deep links, reforecast engine, plan/settings editor with plan versions,
  JSON backup + CSV export, Face ID app lock, accessibility support, Phase II
  debt-free transition (F-01…F-16).
- SwiftData persistence (schema version 1), calculation version 1, backup schema
  version 1; 54-test suite plus UI tests.
