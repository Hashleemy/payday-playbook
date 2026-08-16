# Payday Playbook

A native, offline-first iPhone app that turns a debt-elimination plan into a
payday ritual: know today's play, record what actually happened, and see the
finish line.

The shipped **0.1.x** build executed one exact seeded plan. **0.2.0**
generalized the app to any user: guided, resumable onboarding, named checking
accounts, all debt types, and a generated avalanche plan — while preserving the
founding install's plan verbatim via migration. **0.3.0**
(current: 0.3.0-alpha.1, build 4 — prepared, not yet distributed) adds a
Checking Accounts workspace with an auditable ledger, a three-plan payoff
calculator, extra-payment insights, hardened due-date behavior, full JSON
backup/restore, reusable structure-only templates, a generated PDF financial
report, and the removal of all real personal financial data from tracked
project artifacts. See [`CHANGELOG.md`](CHANGELOG.md).

- **Product constitution:** [`soul.md`](soul.md) — read first; F-01…F-16,
  V2-01…V2-18, and V3-01…V3-16 (as amended there) are non-negotiable.
- **Product/technical spec:** [`MVP_LAYOUT.md`](MVP_LAYOUT.md)
- **v0.3.0 release plan and feature registry:** [`ALPHA_V0.3.0_MULTI_AGENT_PLAN.md`](ALPHA_V0.3.0_MULTI_AGENT_PLAN.md); versioning: [`docs/releases/v0.3.0/VERSIONING.md`](docs/releases/v0.3.0/VERSIONING.md)
- **v0.2.0 feature registry:** [`ALPHA_V0.2.0_MULTI_AGENT_PLAN.md`](ALPHA_V0.2.0_MULTI_AGENT_PLAN.md); versioning: [`docs/releases/v0.2.0/VERSIONING.md`](docs/releases/v0.2.0/VERSIONING.md)
- **Source plan:** the founding user's personal plan document — kept outside
  the repository, deliberately (V3-12).

## Requirements

- Xcode 26 or newer (built and tested with Xcode 26.6)
- iOS 17.0+ deployment target (verified on iOS 17.0.1 and iOS 26.5 simulators)
- No third-party dependencies — Apple frameworks only (SwiftUI, SwiftData,
  Swift Charts, UserNotifications, LocalAuthentication)

## Build & run

```bash
open PaydayPlaybook.xcodeproj
```

Select the **PaydayPlaybook** scheme and an iPhone simulator or device, then run.

Command line:

```bash
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Tests

```bash
# Everything (unit + UI)
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

# Unit tests only
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:PaydayPlaybookTests test
```

See [`TESTING.md`](TESTING.md) for the full checklist — including the two
non-optional isolation rules for concurrent test runs and the manual
physical-device pass.

## Architecture

Feature-oriented MVVM with services. All monetary math uses `Decimal`; values
are rounded to two decimals only at persistence/display boundaries.

```
PaydayPlaybook/
├── App/          Entry point, root view, router (deep links), service container
├── Models/       SwiftData @Model types (PlanVersion, DebtAccount, LedgerEntry, …)
├── Services/     PlanSeeder, DebtCalculationEngine, ReconciliationService,
│                 AccountBalanceService, ReforecastService, MilestoneService,
│                 NotificationScheduler, CalendarEventService, ExportService,
│                 AppLockService, PlanContract, SeedPlan
├── Features/     Onboarding, Today, CheckIn, Calendar, Debts, Ledger,
│                 Progress, Settings, PhaseTwo
├── Components/   MoneyText/MoneyField, StatusBadge, PlanActualRow, cards
├── Support/      Decimal money helpers, date normalization, DateProviding
└── Resources/    OriginalPlanV1.json (already excluded from Release builds;
                  scheduled for full removal under V3-12), asset catalog
```

### Key invariants

- **Original Plan v1 is immutable.** The founding install's baseline plan;
  user changes create actual records, future-dated income rules, or new plan
  versions — never edits to a baseline. Its values live only in that device's
  local store, not in tracked project artifacts (V3-12).
- **Planned ≠ actual ≠ reforecast.** Three separate tracks; nothing is ever
  silently copied from planned into actual. Scenario previews (v0.3.0) are a
  fourth, on-screen-only track until explicitly applied.
- **Available is not spent.** The personal allowance is tracked as available;
  actual spending-account cash comes only from user-confirmed balances and
  explicit spending entries. The no-spend ceiling is a labeled reference,
  never cash.
- **Actual balances are authoritative.** A user-entered balance snapshot
  overrides estimates from its effective date forward.
- **Local only.** No backend, accounts, analytics, or bank links. Data leaves
  the device only through user-initiated exports.

### Calculation convention

Interest accrues per pay period as `balance × APR × daysSincePreviousPayday /
365`, carried at full `Decimal` precision; card minimums without an entered
amount use a documented heuristic; the remaining budget attacks the
highest-effective-APR eligible debt and rolls over within the same check on
payoff. Balances round to cents at output boundaries. Calculation versions are
frozen per plan: the engine reproduces every stored baseline schedule exactly,
and each newer calculation version reduces to its predecessor on the
predecessor's inputs (tested).

## Test hooks (DEBUG builds only)

| Launch argument | Effect |
| --- | --- |
| `--uitest` | Isolated store at a temp URL |
| `--uitest-reset` | Wipe that store first (clean install) |
| `--uitest-skip-onboarding` | Seed a fictional plan and mark onboarding complete |
| `--uitest-today <ISO date>` | Pin "today" (e.g. `2026-01-15`) for deterministic flows |

Release builds ignore all of these and never expose debug screens.
