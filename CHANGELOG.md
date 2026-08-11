# Changelog

All notable changes to Payday Playbook are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer 2.0.0](https://semver.org).
App, schema, calculation, backup, and user-plan versions are distinct — see `docs/releases/v0.2.0/VERSIONING.md`.

## [Unreleased]

Nothing yet.

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
- Schema 1→2 migration preserving the existing user's exact 23-paycheck
  Aug 20, 2026 – Jun 24, 2027 baseline, history, and check-ins verbatim, in a single
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
- Freshly onboarded users saw the bundled template's $2,094.00 as their own take-home on
  Today, Settings, and the Phase II screen, because the income lookup read the
  template-only plan and fell back to a hard-coded constant.
- The payday variance chart on Progress was empty for generated plans, for the same
  template-only lookup reason.

### Unchanged guarantees

- Local-only; no accounts, no telemetry, no bank credentials, full card numbers, CVVs, or
  SSNs collected (V2-17). All money is `Decimal`. Planned, actual, and reforecast remain
  three separate truths, and no baseline plan version is ever edited or regenerated.
- Original Plan v1 stays stamped calculation version 1 and is never recomputed; the
  frozen calc-v1 engine is untouched and still reproduces the documented 23-check
  schedule ($3,461.16 interest).

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

- Offline-first iOS app executing Master Lem's exact debt plan: seeded immutable
  Original Plan v1 (23 biweekly paydays, Aug 20, 2026 – Jun 24, 2027, six cards,
  $29,681.61 starting debt), five-second dashboard, guided payday check-in with
  reconciliation, contribution ledger, balance snapshots, calendar, local notifications
  with deep links, reforecast engine, plan/settings editor with plan versions,
  JSON backup + CSV export, Face ID app lock, accessibility support, Phase II
  debt-free transition (F-01…F-16).
- SwiftData persistence (schema version 1), calculation version 1, backup schema
  version 1; 54-test suite plus UI tests.
