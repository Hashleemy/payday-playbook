# Agent 7 report — Release Integration & QA (v0.2.0-alpha.1)

Branch: `release/v0.2.0-alpha.1` (from `main` @ `b0e7443`) · Date: 2026-08-11
Role: final gate. No feature development; merges, conflict decisions, cross-agent defect
fixes, contract ratification, and release validation.

## Verdict

# READY FOR ALPHA DEVICE TESTING

Every simulator-provable gate is green: 281 unit tests, 18 UI tests, Release configuration
builds clean, zero known data-loss defects, zero P0/P1 optimizer defects, zero duplicate
calendar/notification defects, and no remaining contradiction between `soul.md`,
`MVP_LAYOUT.md`, and shipped behaviour.

**This is a verdict about putting the build on a phone, not about distributing it.** The
mission's last quality gate — *"any device-only notification limitation is explicitly listed
and tested on a physical iPhone before calling the release ready"* — is half done: the
limitations are listed (below, and as `TESTING.md` items 1–7), but none has been tested on
hardware, because no physical iPhone was available to this session. Until those seven items
pass, the build should not go further than device testing, and the tag should not be
created — `VERSIONING.md` §3 says to tag artifacts, never intent.

## Merge record

Merged in the mandated order. Every merge is `--no-ff`; every conflict was resolved by
inspecting both sides, never by taking a side wholesale.

| # | Agent | Merged commit | Merge commit | Conflicts | Unit tests after |
| --- | --- | --- | --- | ---: | ---: |
| 1 | Product contract | `07bcf2f` | `db6981f` | 0 | — |
| 2 | Data & migration | `65a9236` | `acc2955` | 0 | — |
| 3 | Avalanche engine | `f0885d1` | `ee19468` | 0 | 147 |
| — | *Contract reconciliation* | `bafa07a` (cherry-pick) | `87d6002` | — | 147 |
| 4 | Onboarding | `fdb86b3` | `7e1c550` | 10 | 183 |
| 5 | Calendar & notifications | `4f6dbfd` | `041529f` | 4 | 248 |
| 6 | Dashboard & plan | `43a9c78` | `b303a9e` | 4 | 274 |

Then, as integrator:

| Commit | What |
| --- | --- |
| `e7ad121` | One store→engine conversion (cross-agent defect, below) |
| `0bd8b6a` | `ReleaseIntegrationTests` — 7 regressions pinning the merge-only defects |
| `370aaed` | Ratified the four contract deviations the agents flagged |

Final unit count **281**, UI **18**.

### The structural problem: two reconciliations of the same collision

Agents 2 and 3 branched from Agent 1 in parallel and each declared `PlanningInput`,
`PlanningResult`, `PayCadence`, `ObligationCadence`, `DebtType`, and `IncomeChange`. Neither
branch compiles beside the other. **Three** agents then resolved this independently:

- Agent 5 prefixed the engine types with `Engine`, then **abandoned it** and rebased onto
  Agent 6's.
- Agent 6 (`bafa07a`): engine keeps `PlanningInput`/`PlanningResult`; Agent 2's snapshot DTOs
  become `StoredPlanInput`/`StoredPlanResult`; the engine adopts the model-layer `DebtType`
  and `ObligationCadence` and the *shared* `PlanningIncomeChange`; engine cadence becomes
  `PlanningPayCadence`.
- Agent 4 (`4006e3f`): same decisions, different names — `PlanInputSnapshot`/
  `PlanResultSnapshot`, and an engine-local `IncomeStep`.

**Decision: `bafa07a` is canonical.** Three reasons — Agent 5 had already deferred to it, so
two of the three downstream branches were built on it; it *shares* the income-change struct
with the model layer rather than keeping a duplicate; and it is the resolution the
already-integrated `43a9c78` rests on.

I applied it at step 3, where the collision is actually created, rather than at step 4 or 6
where it merely surfaces. My A1+A2+A3 merge tree was byte-identical to Agent 6's own merge
point (`18c98de`), so the cherry-pick applied cleanly and the result is byte-identical to
`bafa07a` — verified with `git diff`.

### Conflict decisions

**Agent 4 — 10 conflicts.** I diffed each side with the naming difference normalised away,
so only real content drove the decision:

| File | Decision |
| --- | --- |
| `PlanVersion`, `OnboardingProgressService`, `PlanningContractTests`, `AvalanchePlanEngine`, `AvalanchePropertyTests`, `PlanningFixtures` | Rename-only once normalised → canonical names |
| `Planning/PlanningContracts.swift` | Canonical. Agent 4's engine-local `IncomeStep` dropped for the shared struct |
| `Services/PlanningDTO.swift` | **Hand-merged.** Kept the canonical `Sendable PlanningIncomeChange` *and* Agent 4's two real additions: `PlanningDebt.prepayment` (tri-state + `effectivePrepayment` + Codable keys) and `StoredPlanInput.asOf`. Verified the resulting delta against the canonical file was exactly those additions and nothing else |
| `Services/PlanPersister.swift` | Agent 4's content — the `asOf` parameter, the prepayment mapping, and the V2-07 essential-obligations filter are real behaviour with no competing change |
| `OnboardingProgressTests.swift` | Agent 4's expectation (`.accounts` → `.debts`); Agent 4 reordered `OnboardingStep` to the mission's order |

Agent 4's *non-conflicting* files (`PlanGenerationService`, `RemindersStepView`, and their
tests) still referenced the dropped names and were ported by hand. `IncomeStepView` is a
SwiftUI view, not the DTO, and was deliberately left alone.

**Agent 5 — 4 conflicts.**

- `Models/DebtAccount.swift` — **union**. Agent 4 added `setupNote`, `prepaymentRaw`,
  `debtTypeConfirmedAt`, `creditLimitMarkedUnknown`; Agent 5 added `dueDateShiftRuleRaw`,
  `dueDateAuditLog`, `dueDayEffectiveFrom`. Both additive, both required.
- `Services/PlanPersister.swift` — ours. Agent 5 never touched the file (verified against its
  own base); the conflict was a two-merge-base artifact.
- `CalendarEventService.swift`, `NotificationScheduler.swift` — Agent 5's rewrites. Agent 4's
  entire change to both files was one line swapping `existingBaseline` for `currentPlan` so
  generated plans are visible; Agent 5's `schedulePlan` (newest active plan owning payday
  rows, template as fallback) satisfies that intent and is stronger, and
  `NotificationPlanner` routes through it. Taking Agent 5's side **preserves** the fix. I
  audited every remaining `existingBaseline` call site to confirm each is a genuine
  template-only use.

**Agent 6 — 4 conflicts.** Merged via `integration/v0.2-calendar-dashboard` (`43a9c78`)
rather than `feature/v0.2-dashboard-plan`, because that commit already carries Agents 5 and
6's resolution of their two mutual overlaps — and resolves them exactly as Agent 5's report
recommended (TodayView keeps Agent 6's labels but routes date maths through `DueDateRule`;
DebtsView takes Agent 6's editor and re-applies the four due-date pieces). I reviewed that
resolution before adopting it.

All four conflicts were Agent 4's plan-visibility one-liners against Agent 6's rewrites. I
took Agent 6's side in each case **after confirming** its lookups prefer the active plan and
use the template only as a fallback — Agent 6 branched before Agent 4's fix, so this needed
checking rather than assuming.

## Cross-agent defects found and fixed

These existed only in the merged tree: each one's two halves came from different branches, so
no agent could have caught them. All three are now pinned by `ReleaseIntegrationTests`.

**1. The plan on screen could differ from the plan that was saved. (P1)**
The merge left two bridges — Agent 4's `PlanGenerationService` (onboarding: store → engine →
persist) and Agent 6's `GeneratedPlanService` (UI: preview, baseline regeneration, reforecast,
what-if) — each with its own `engineInput(from: StoredPlanInput)`. Because Today, Plan, and
Insights render a calc-v2 plan by *regenerating* it from its snapshot, any disagreement is
user-visible. Agent 6's copy predated the fields Agent 4 added and diverged four ways:

- it ignored `stored.asOf` (using `nextPayday`, not even start-of-day), so a regeneration did
  not reproduce the original engine call — the exact thing Agent 4 added the field for;
- missing semimonthly pay days silently defaulted to the 1st and 15th instead of raising the
  actionable error;
- reversed semimonthly days were not normalised, so a user who entered the 15th and the 1st
  saw a different payday schedule than the one saved;
- it collapsed the prepayment tri-state to `isExtraPrincipalEligible ? .eligible : .ineligible`.

*A correction to my own commit message on `e7ad121`:* I wrote there that the prepayment
divergence meant the Plan screen would show extra principal going to a debt the saved plan
withholds it from. With coherent data that overstates it — the model's setter keeps
`isExtraPrincipalEligible` false for `.unknown`, so the old path produced `.ineligible` and
the *allocation* matched. What was actually lost is the `.prepaymentEligibilityUnknown`
warning, so the plan screen quietly dropped the "confirm whether this debt allows
prepayment" prompt that the saved plan carries. An allocation difference requires
incoherent stored data (`prepaymentRaw = "unknown"` beside `isExtraPrincipalEligible = true`),
which import or a future migration could produce. The fix covers both; the severity claim
in the commit message was too strong.

Fix: `GeneratedPlanService.engineInput` delegates to `PlanGenerationService.engineInput`,
which gained an optional `asOf` override for live previews. The generation path is unchanged.

**2. A new user saw the template user's paycheck. (P1)**
`ReforecastService.currentIncome` read `PlanSeeder.existingBaseline` — template-only since
Agent 2 narrowed it — and fell through to `PlanContract.firstIncome` when that returned nil.
On any generated-plan install that meant **$2,094.00 displayed as the user's own take-home**
on Today, Settings, and the Phase II screen. Agent 4 fixed this class of bug across twelve
call sites; Agent 6 rewrote `ReforecastService` from a pre-fix base and the site returned.
Now reads the current plan's `IncomeRule` rows, falling back to the live `IncomeSchedule`;
it can no longer report another user's number.

**3. Empty variance chart. (P2)**
`ProgressTabView.paydayVariances` had the same template-only lookup, so the payday variance
chart was empty for generated plans. Now uses the file's own `schedulePlan`, matching its two
sibling call sites.

## Contract ratification

Each agent recorded a deviation from `MVP_LAYOUT.md` and deferred it to the doc owner rather
than silently editing the contract. The gate requires no unresolved contradictions, so all
four are now explicit amendments in place (`370aaed`):

| § | Was | Now |
| --- | --- | --- |
| §4 step table | income 4, obligations 5, floor/allowance 6, debts 7, review 8, notifications 9 | The shipped order: goal step carries floor and allowance; debts follow accounts; reminders preview before review |
| §7 step 4 | `originalPrincipal = startingBalance` | Stays `nil` — migration must not fabricate a value the store never recorded |
| R-08 | APR → balance → creation order | Effective APR → due day → balance → creation order → stable ID |
| §9 | Re-register 0.1.x reminder identifiers | Prefix-owned reconciliation (the letter-keyed scheme cannot address a generated plan's debts) |

Agent 6's §8.4 "Edit Card" note needed no change — the text already said "Edit Debt".
V2 parity 18/18 and F parity 16/16 re-verified after editing.

## Version and build

| Axis | Value | Verified |
| --- | --- | --- |
| App version | **0.2.0** | `MARKETING_VERSION` in all 6 build configs |
| Build number | **2** | `CURRENT_PROJECT_VERSION` (was 1) |
| Persistence schema | **2** | `PlanContract.currentSchemaVersion` |
| Calculation version | **2** for new plans; Original Plan v1 frozen at **1** | `PlanContract.currentCalculationVersion` + per-plan stamp |
| Backup schema | **2** (reads 1 and 2) | `ExportService.backupSchemaVersion` |

**Prior version, verified independently:** the repository has no version tags, and `main`
carries `MARKETING_VERSION = 1.0` with `CURRENT_PROJECT_VERSION = 1` — the untouched Xcode
scaffold default. Agent 1's ruling that the shipped MVP is, in SemVer terms, the untagged
**0.1.0** therefore stands, making this a minor bump to 0.2.0 with the patch at zero. It also
matches the release branch name the mission specified. Schema, calculation, and backup
versions were each bumped only because behaviour genuinely required it; the frozen calc-v1
engine is untouched and Original Plan v1 is never recomputed.

**Tag: prepared, not created.** No tag has been written and nothing has been pushed.
When approved:

```bash
git tag -a v0.2.0-alpha.1 -m "Payday Playbook 0.2.0-alpha.1 (build 2)" <final-commit>
# recommended housekeeping, still outstanding from Agent 1:
git tag -a v0.1.0 -m "Payday Playbook 0.1.0 (first alpha MVP)" b0e7443
```

## Test matrix

Run on a dedicated simulator (`PaydayRelease-A7`, iPhone 17 Pro, iOS 26.5) with a
per-worktree `derivedDataPath`.

| Suite | Result |
| --- | --- |
| `PaydayPlaybookTests` | **281 / 281 passed** |
| `PaydayPlaybookUITests` | **18 / 18 passed** |

Progression, which is the evidence the renames preserved behaviour — every step is exactly
additive against the agent's own reported count:

| After | Tests | Expected |
| --- | ---: | --- |
| A1+A2+A3 + reconciliation | 147 | Agent 6 reported 147 at the same point |
| Agent 4 | 183 | Agent 4 reported 183 |
| Agent 5 | 248 | 183 + Agent 5's 65 new |
| Agent 6 | 274 | 248 + Agent 6's 26 new |
| Integrator tests | 281 | 274 + 7 |

### Release validation

| Requirement | Status | Evidence |
| --- | --- | --- |
| Clean install enters onboarding, completes end to end | Pass | `testFirstRunSetupGeneratesAPlanAndLandsOnToday` (UI) |
| Interrupted onboarding resumes, no duplicate accounts/debts/plans | Pass | `testSetupResumesAfterForceQuit` (UI); `OnboardingSetupTests` resume at every step boundary |
| Upgrade preserves every record and the exact 23-paycheck baseline | Pass | `MigrationServiceTests` (23 paydays value-for-value); `UpgradeChecklistTests` |
| Multiple checking accounts; exactly one default income | Pass | `CashAccountRepositoryTests` under add/edit/archive |
| Every debt type add/edit/archive/plan | Pass | `DebtTypeTests`, `OnboardingSetupTests`, `PlanPresentationTests` |
| Card limits/utilization; installment original vs current principal | Pass | `DebtPresentationTests`, `DebtTypeTests` |
| All pay frequencies generate correct dates | Pass | `PayScheduleGeneratorTests` (weekly/biweekly/semimonthly/monthly, short months, leap, DST) |
| Due-date changes update calendar and notifications, no duplicates | Pass | `DueDateRuleTests`, `NotificationSchedulerTests`, `CalendarEventServiceTests` |
| Optimizer: minimums, protected cash, avalanche priority, rollover, cent reconciliation | Pass | `AvalanchePlanEngineTests`, `AvalanchePropertyTests`, `AvalancheLemParityTests` |
| Plan output: payoff, interest, order, transfers, insights, assumptions, minimum-only behaviour | Pass | `PlanPresentationTests` (comparison withheld, not guessed, when inputs insufficient) |
| Today/Plan/Debts/Calendar/Settings/check-ins use production data | Pass | `DashboardStateTests`, `PlanPresentationTests` (fixtures build production-shaped stores) |
| Planned / actual / reforecast stay distinct | Pass | `testBaselineActualAndReforecastComeFromSeparateSources` and siblings |
| Notification denied state | Pass (simulator) | `testDeniedAuthorizationSchedulesNothingAndTouchesNothing` |
| JSON backup/restore and older-schema migration | Pass | `ExportCompatibilityTests`, `ExportServiceTests` |
| Relaunch persistence, offline use | Pass | UI relaunch tests; app makes no network calls |
| Face ID / app lock | Carried from 0.1.x, untouched | Device item 9 |
| Dynamic Type, VoiceOver, high contrast, Reduce Motion, non-colour status | Pass in simulator | AX-size UI tests; status carried in words + icons everywhere |
| No financial values in release logs | Pass | Single `print` in shipping code is `#if DEBUG`-gated |
| No full card numbers, CVVs, credentials, SSNs collected | Pass | Only occurrences are copy *promising* not to collect them; `lastFour` hard-capped to 4 digits |
| Device-only notification behaviour | **Not tested** | No physical iPhone available — `TESTING.md` items 1–7 |

## Regression status

No regressions against 0.1.x. The 54-test 0.1.x suite is carried forward inside the 281 and
green; `DebtCalculationEngineTests` and `PlanSeederTests` still reproduce the documented
23-check schedule, $3,461.16 interest, and $7,900 ceiling from the untouched frozen calc-v1
engine. `ReviewRegressionTests` (the 0.1.x review findings) still pass.

**Environment note, not a product defect.** The UI suite initially reported four failures with
no assertion failure and no app crash log — and a *different* four on each run. The cause was
`SimRenderServer` crashing under parallel test execution with three simulators booted. Run
alone with `-parallel-testing-enabled NO`, the suite is 18/18. This is recorded at the top of
`TESTING.md` because it will otherwise be rediscovered as a phantom regression.

## Known limitations

Carried from the agents, verified as accurate, and listed in `CHANGELOG.md`, `TESTING.md`,
and the release notes:

1. **Notification delivery unverified on hardware** — the blocking item. Real delivery on a
   locked device, provisional authorization, the 64-request system limit in practice,
   lock-screen rendering, physical time-zone travel and DST rollover, and cold-launch deep
   links.
2. Weekly and biweekly obligations get no due-date marker or reminder; their per-paycheck
   reserve is unaffected.
3. Quarterly/semiannual/annual obligations are anchored to their creation month — the model
   has no first-due-date field.
4. Editing a due day blanks that item's markers for months before the edit, rather than
   inventing history.
5. Migrated debts carry no `originalPrincipal`; percent-paid falls back to the starting
   balance exactly as 0.1.x computed it.
6. Plan analysis (baseline + reforecast + two scenarios) runs synchronously on the main
   thread.
7. At the largest accessibility sizes Today's primary action requires a scroll.
8. Interest is simple, 365-day, accrued per payday — not daily compounding or issuer
   statement cycles. Surfaced in-app as assumptions.
9. `plannedTargetDebtID` is a plan letter, not a UUID; calendar debt-payment events and the
   notification `debt` route key on it because that is what the schema stores.
10. Two bridges still exist (`PlanGenerationService`, `GeneratedPlanService`). They no longer
    disagree — the conversion is shared — but the duplication is worth collapsing in 0.2.1.

## Nothing was escalated back to an owning agent

No merge exposed a large missing feature. The three defects I fixed were small, surgical, and
squarely cross-agent — each was a lookup or a duplicated conversion where the fix was to make
the merged tree use the code that already existed and was already tested, not to invent
substitute behaviour. All three are documented above and pinned by tests.

## Release recommendation

**READY FOR ALPHA DEVICE TESTING.** Install build 2 on a physical iPhone and work
`TESTING.md` items 1–7. Do not distribute further, and do not tag, until those pass.

Also worth running on-device: item 13, the upgrade rehearsal — install 0.1.x, use it, then
install this build over it. The migration is covered by 13 unit tests against fixtures, but
a real upgrade over a real store is the one thing that proves the existing user loses
nothing, and it is the highest-consequence path in this release.

When the device pass is clean, tag `v0.2.0-alpha.1` on the final commit and consider
retro-tagging `main` as `v0.1.0`. Neither tag has been created and nothing beyond the
release branch has been pushed.
