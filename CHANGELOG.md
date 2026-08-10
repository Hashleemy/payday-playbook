# Changelog

All notable changes to Payday Playbook are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer 2.0.0](https://semver.org).
App, schema, calculation, backup, and user-plan versions are distinct — see `docs/releases/v0.2.0/VERSIONING.md`.

## [Unreleased] — targeting 0.2.0

> Nothing below is shipped yet. This section records the agreed product contract for the
> 0.2.0 alpha (`v0.2.0-alpha.1` will be tagged when the build is cut). Feature IDs refer to
> `ALPHA_V0.2.0_MULTI_AGENT_PLAN.md` (V2-01…V2-18).

### Added (planned)

- Resumable, configurable first-run onboarding: goals and payoff posture, multiple named
  checking accounts with roles and one default income account, income with cadence and
  future changes, essential recurring obligations, protected cash floor, allowance cap
  (V2-01…V2-03, V2-06…V2-09).
- Debt type picker (credit card, personal loan, car note/auto loan, student loan, medical
  debt, other) with type-specific inputs: balance/principal, original principal, APR,
  minimum, editable due date, card limit with utilization, extra-principal eligibility
  (V2-04, V2-05).
- Generated avalanche plan from the user's own inputs — minimums first, remainder to the
  highest-APR eligible debt — with calculation version 2 rules (V2-10).
- Insight cards: interest saved, payoff delta, utilization, obligation crunch, allowance
  trend (V2-14).
- Schema 1→2 migration preserving the existing user's exact 23-paycheck
  Aug 20, 2026 – Jun 24, 2027 baseline, history, and notifications verbatim (V2-16).
- Original Plan v1 available as a deliberate template instead of a forced default.

### Changed (planned)

- Fresh installs no longer auto-seed Original Plan v1 (F-01 amended in `soul.md`);
  dashboard, check-in, calendar, and notifications generalize to configured accounts,
  obligations, and all debt types (V2-11…V2-13, V2-15).
- Due-date edits update calendar events and reschedule local notifications immediately
  (V2-11).
- Backup schema 2: writes v2, restores v1 files; CSV columns append-only (V2-18).
- App marketing version corrected from the Xcode scaffold default `1.0` to `0.2.0`
  (the shipped MVP was, in SemVer terms, the untagged 0.1.0 alpha).

### Unchanged guarantees

- Local-only, no bank credentials, no telemetry (V2-17); Decimal money math and the
  accessibility bar (V2-18); planned/actual/reforecast separation and baseline
  immutability for every plan version.

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
