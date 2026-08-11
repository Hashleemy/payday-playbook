# Payday Playbook

A native, offline-first iPhone app that turns a debt-elimination plan into a
payday ritual: know today's play, record what actually happened, and see the
finish line.

The **shipped 0.1.x build** executes one exact seeded plan (August 20, 2026 →
June 24, 2027). The **0.2.0 contract** (in progress — nothing below the docs is
implemented yet) generalizes the app to a configurable user with generated
plans, while preserving the existing seeded plan verbatim via migration. See
[`CHANGELOG.md`](CHANGELOG.md).

- **Product constitution:** [`soul.md`](soul.md) — read first; F-01…F-16 (as amended there) and V2-01…V2-18 are non-negotiable.
- **Product/technical spec:** [`MVP_LAYOUT.md`](MVP_LAYOUT.md)
- **v0.2.0 feature registry:** [`ALPHA_V0.2.0_MULTI_AGENT_PLAN.md`](ALPHA_V0.2.0_MULTI_AGENT_PLAN.md); versioning: [`docs/releases/v0.2.0/VERSIONING.md`](docs/releases/v0.2.0/VERSIONING.md)
- **Source plan:** *Personal Debt Elimination & Cash Flow Plan* (PDF)

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

See [`TESTING.md`](TESTING.md) for the full checklist including the manual
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
└── Resources/    OriginalPlanV1.json (validated seed), asset catalog
```

### Key invariants

- **Original Plan v1 is immutable.** Seeded once from the validated
  `OriginalPlanV1.json`; user changes create actual records, future-dated
  income rules, or new plan versions — never edits to the baseline.
- **Planned ≠ actual ≠ reforecast.** Three separate tracks; nothing is ever
  silently copied from planned into actual.
- **Available is not spent.** The $300 allowance is tracked as available;
  actual Checking 1 cash comes only from user-confirmed balances and explicit
  spending entries. The no-spend ceiling is a labeled reference, never cash.
- **Actual balances are authoritative.** A user-entered balance snapshot
  overrides estimates from its effective date forward.
- **Local only.** No backend, accounts, analytics, or bank links. Data leaves
  the device only through user-initiated JSON/CSV exports.

### Calculation convention

Interest accrues per check as `balance × APR × 14 / 365` carried at full
`Decimal` precision; estimated minimums are `max($17.50, 0.5% of the
post-interest balance)`; the remaining budget attacks the highest-APR active
card and rolls over within the same check on payoff. Balances round to cents
at output boundaries. This reproduces every headline value of the source plan:
$3,461.16 modeled interest, June 24 2027 payoff after 23 checks, all six
per-card payoff dates, and the $929.54 final payment.

## Test hooks (DEBUG builds only)

| Launch argument | Effect |
| --- | --- |
| `--uitest` | Isolated store at a temp URL |
| `--uitest-reset` | Wipe that store first (clean install) |
| `--uitest-skip-onboarding` | Seed plan and mark onboarding complete |
| `--uitest-today 2026-08-20` | Pin "today" for deterministic flows |

Release builds ignore all of these and never expose debug screens.
