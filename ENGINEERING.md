# Engineering guide — Payday Playbook

## Read first

`soul.md` is the product constitution; `MVP_LAYOUT.md` is the spec. The F-01…F-16,
V2-01…V2-18, and V3-01…V3-16 contracts (as amended in `soul.md`) are
non-negotiable — never remove, rename, or reinterpret a requirement without
explicit user approval. The founding user's source plan document is kept
outside the repository, deliberately (V3-12); on the migrated install the
stored baseline is its own authority. Versioning rules:
`docs/releases/v0.3.0/VERSIONING.md` (current cycle).

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
- **Original Plan v1 is immutable.** It exists only on the founding install's
  device. The bundled `PaydayPlaybook/Resources/OriginalPlanV1.json` is already
  excluded from Release builds and its **full removal from every build
  configuration is contracted under V3-12** — never extend it, copy it, or add
  new dependencies on it.
- **No real personal financial data in tracked artifacts.** Code, fixtures,
  previews, tests, comments, logs, docs, prompts, and reports use clearly
  fictional values only (V3-12/V3-13).
- **Never fill actuals from planned values silently.** Prefilled fields are
  fine; recording requires user confirmation (save draft / complete).
- **Apple frameworks only.** No packages, no backend, no analytics, no ads.
- **Never weaken or skip a test to get green.**
- The migrated baseline's stored schedule preserves its (untracked) source
  document verbatim, which carries ±$0.01–$0.06 float artifacts in the
  avalanche-target column relative to clean Decimal recomputation; stores keep
  the documented values verbatim, the engine uses clean Decimal math. Don't
  "fix" either direction.

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
