# Engineering guide — Payday Playbook

## Read first

`soul.md` is the product constitution; `MVP_LAYOUT.md` is the spec. The F-01
through F-16 feature contract (as amended in `soul.md` for v0.2.0) and the
V2-01 through V2-18 contract are non-negotiable — never remove, rename, or
reinterpret a requirement without explicit user approval. The reference PDF
(*Personal Debt Elimination & Cash Flow Plan*) is the source plan for the
migrated baseline. Versioning rules: `docs/releases/v0.2.0/VERSIONING.md`.

## Build & test commands

```bash
# Build
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Full test suite (unit + UI)
xcodebuild -project PaydayPlaybook.xcodeproj -scheme PaydayPlaybook \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

# Unit only
... -only-testing:PaydayPlaybookTests test
```

Xcode 26.6 requires the iOS 26.5 simulator runtime
(`xcodebuild -downloadPlatform iOS` if destinations are "ineligible").

## Hard rules

- **Money is `Decimal`, never Double/Float.** Round with `.rounded2`
  (half-away-from-zero) only at persistence/display boundaries. The engine
  carries full precision internally.
- **Original Plan v1 is immutable.** Seeded from
  `PaydayPlaybook/Resources/OriginalPlanV1.json`, which is validated against
  `PlanContract` constants before insertion — keep JSON, contract, and tests
  in agreement if the plan ever changes (only with user approval).
- **Never fill actuals from planned values silently.** Prefilled fields are
  fine; recording requires user confirmation (save draft / complete).
- **Apple frameworks only.** No packages, no backend, no analytics, no ads.
- **Never weaken or skip a test to get green.**
- The documented plan tables carry ±$0.01–$0.06 float artifacts in the
  avalanche-target column (see TESTING.md); seeds use the documented values
  verbatim, the engine uses clean Decimal math. Don't "fix" either direction.

## Architecture notes

- Services are structs taking `ModelContext` + `DateProviding`; the engine
  (`DebtCalculationEngine`) is pure and SwiftData-free. Views assemble state
  via services in `onAppear`/`onChange(of: query.count)` and use `@Query` for
  reactive lists.
- Deep links: `NotificationScheduler.Route` → `AppRouter.handleNotificationRoute`.
- Check-in completion is atomic via `ReconciliationService.completeCheckIn`
  (one save), then reforecast + milestone refresh + notification reschedule.
- C1/C2 balances derive from authoritative `BalanceSnapshot`s plus later
  ledger deltas; reserve earmarks are internal checking2→checking2 entries.
- SwiftUI `Form`/`List` are lazy: anything UI tests must tap belongs in
  toolbars or always-visible bars, or the test must scroll first.
- Unit tests build in-memory containers; the app host detects
  `XCTestConfigurationFilePath` and stays off the real store. UI-test launch
  args are documented in README.md.
