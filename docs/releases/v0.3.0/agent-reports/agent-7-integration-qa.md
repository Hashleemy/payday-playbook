# Agent 7 — Integration and Release QA (v0.3.0-alpha.1)

- **Role:** merge the six feature branches in dependency order, settle the issues that only
  exist once they are together, validate every V3 requirement and every v0.2 behaviour,
  enforce the privacy gate, and return a truthful recommendation.
- **Branch:** `release/v0.3.0-alpha.1`, from Agent 1's contract `4be5c57` (itself based on
  `release/v0.2.0-alpha.1` at `18b5d52`).
- **Date:** 2026-08-15.
- **Final versions:** app **0.3.0** · build **4** · schema **3** · calc **3** · export **3**.

This report contains no personal financial value. Where the privacy audit found something,
it is described by file, category, and count only.

---

## 1. Recommendation

**READY FOR ALPHA DEVICE TESTING** — and *only* device testing. Two things are explicitly
not authorised by this report:

1. **Nothing is tagged, pushed, or released.** The branch is local. `VERSIONING.md` §3 says
   a tag marks an artifact, not an intent, and the artifact is not cut until the device
   pass is done.
2. **External distribution is BLOCKED on an owner decision** about Git history (§8). The
   working tree is clean of personal data; history is not, and the repository has been
   pushed. That is the owner's call, not mine, and it is not a code defect — it does not
   block *device* testing on the owner's own hardware, which is the next step.

Every blocker gate in the mission passes in the simulator. What has never run on hardware
still has never run on hardware, and that is the whole point of the next phase.

---

## 2. Merge record

Merged in the mandated order. Each merge was preceded by an ownership check and a
privacy scan of that branch's added lines.

| # | Agent | Branch tip merged | Merge commit | Added lines scanned | PI hits |
| --- | --- | --- | --- | ---: | ---: |
| 1 | Contract | `4be5c57` | *(branch base)* | — | 0 |
| 2 | Privacy / data / migration | `6029107` | `f5aa25b` | 3,720 | 0 |
| 3 | Scenario engine | `46348b2` | `ae3cc6d` | 3,287 | 0 |
| 4 | Accounts / setup UX | `4559fa6` | `f4b3646` | 6,890 | 0 |
| 5 | Calendar / reminders | `d465f00` | `d08ba51` | 1,704 | 0 |
| 6 | Portability / reports | `b19c1df` | `eb663de` | 7,262 | 0 |

Integration commits between and after the merges:

| Commit | What |
| --- | --- |
| `763a141` | Removed a withdrawn balance figure left in a test comment (§7.1) |
| `eaf83a8` | Keyed a balance-update calendar row to its debt's identity (§5.3) |
| `8c87c90` | One `ScenarioKind` vocabulary and one scenario-definitions mapping (§5.2) |
| `bf4b784` | Calc 3 stamped on new plans without stranding v0.2.0 plans (§4) |
| `9615c35` | Three cross-feature gaps closed, one superseded screen retired (§5.4–5.6) |
| `a402413` | Version bump to 0.3.0 / build 4, changelog, `TESTING.md`, `README.md`, versioning amendment, this report |

**Integrated release head: `a402413`** (plus one follow-up commit recording this hash and
the device-rehearsal ordering in §8, as Agents 1, 3, 4 and 6 each did).

### 2.1 Conflicts

Only one textual conflict arose in six merges. The damaging collisions did **not** conflict.

| Where | Kind | Resolution |
| --- | --- | --- |
| `AvalanchePlanEngine.swift` | Real conflict: one doc-comment line, Agent 2's privacy rewrite vs Agent 3's calc-v3 rewrite | Agent 3's wording. It is their file, both phrasings are equivalent and de-personalised, and it matches the tree Agents 4 and 6 validated against. |
| `PlanningDTO.swift` | **Silent**: Agents 2 and 3 both declared `StoredScenarioDefinition` and `StoredExtraPayment`, with different fields. Merges textually clean; fails at compile. | Agent 2's variants removed (§5.1). |
| `ScenarioDefinitionBuilder` / `ScenarioPlanActivationService` | **Silent**: Agents 4 and 6 both extended `ScenarioKind` with `displayName` and `isRecommended`. Compile error. | Agent 4's kept, Agent 6's rationale moved onto it (§5.2). |
| Two store → scenario-definitions mappings | **Silent and it compiled** — the worst kind | Consolidated onto `ScenarioDefinitionBuilder` (§5.2). |
| `SettingsView.swift`, `DebtsView.swift`, `RemindersStepView.swift` | Predicted three-way overlap (Agents 4, 5, 6) | No conflict — the three edited different sections. Verified by compile and by suite. |

The pattern is worth recording for the next release: **every collision that mattered here
merged cleanly.** Git only protects against edits to the same lines. Two agents adding the
same *declaration* in different places, or two agents writing the same *mapping* in
different files, produce either a compile error or — worse — a tree that builds and
quietly disagrees with itself. The v0.2.0 retrospective pinned this hazard; it recurred
three times in this release. The defence that worked was compiling and running the whole
suite after every merge, not reading diffs.

### 2.2 No work was lost

Every test function present on each feature branch is present in the merged tree:

| Branch | Tests on branch | Missing from merged tree |
| --- | ---: | ---: |
| `feature/v0.3-privacy-data` | 329 | 0 |
| `feature/v0.3-scenario-engine` | 379 | 37 (see below) |
| `feature/v0.3-accounts-setup` | 452 | 0 |
| `feature/v0.3-calendar-reminders` | 356 | 0 |
| `feature/v0.3-portability-reports` | 462 | 0 |

The 37 are Agent 3's only because Agent 3 branched from the contract *before* Agent 2's
scrub. All 37 are seed/template suites Agent 2 deliberately deleted with the withdrawn
resource, or persona-named cases they renamed, or a test asserting a withdrawn total.
None is a lost capability.

---

## 3. Test matrix

Run on dedicated simulators (iPhone 17 Pro, iOS 26.5) created for this integration, with
`-derivedDataPath` outside `~/Documents` throughout — the file-provider xattr / CodeSign
trap Agents 1, 2, 3, 4 and 6 all hit.

| Suite | Result |
| --- | --- |
| Unit (`PaydayPlaybookTests`) | **515 tests, 0 failures** |
| UI (`PaydayPlaybookUITests`) | **35 tests, 0 failures** — run alone, `-parallel-testing-enabled NO`, own simulator |
| Debug build | `** BUILD SUCCEEDED **` |
| Release build | `** BUILD SUCCEEDED **` |
| PDF visual QA | 6 sample reports rendered, exported, and looked at (§6) |

Branch baselines for comparison: Agent 2 311, Agent 3 362, Agent 4 422, Agent 5 338,
Agent 6 442. The integrated total exceeds every branch because the branches are disjoint
in what they added.

### 3.1 Blocker gates

| Gate | Evidence |
| --- | --- |
| Upgrade from v0.2.x preserves every local record and duplicates none | `SchemaThreeMigrationTests`: `testEveryExistingRecordSurvivesUnchanged` fingerprints every stored row before and after; `testRepeatedLaunchesChangeNothing` covers re-entry; `testTheUserIsNeverReonboarded`; `testAUserEditedProtectedAmountIsNeverOverwritten` |
| Fresh install has no real-person seed data | `PrivacyScrubTests`; `UpgradeChecklistTests.testFreshInstallHasNoSeededDataAndBlocksUntilSetupIsDone`; Release bundle contains no JSON resource at all |
| Tracked tree and generated artifacts pass PI scans | §7 — 0 hits across 143 tracked files; 0 hits in 6 generated PDFs; 0 hits in the Release binary's 47,949 strings |
| Accounts: add / edit / reorder / archive, auditable adjustments, atomic transfers | `AccountsWorkspaceTests` (19), `CashLedgerServiceTests`; a transfer is one row reconciling both sides |
| One default income account; reference and archive rules | `CashAccountRepositoryTests`, `OnboardingSetupTests.testMultipleAccountsKeepExactlyOneDefaultIncome`, `testIncomeAccountAndBillsPaidFromItBlockArchiveWithNamedReasons` |
| Combined Bills & Debts onboarding resumes without duplicate records | `OnboardingSetupTests` incl. `testDebtsEnteredUnderTheOldFlowAreNotReAskedOrDuplicated`; UI first-run walk on the new step order |
| Three scenarios use saved inputs plus overrides, show assumptions, reconcile to the cent | `ScenarioCalculationTests` (34), `CalcV3ReductionTests` (12); `ScenarioFixtures.assertReconciles` runs on every projection every suite produces |
| Previewing never mutates the active plan; applying creates a future plan version | `testScenariosProduceNoPersistableSideEffects`, `testInsightNeverMutatesTheSnapshot`, `ScenarioSurfaceTests` future-effective calc-v3 plan with the earlier plan's rows intact |
| Extra-payment insight agrees with the engine; respects cash and prepayment constraints | `ExtraPaymentInsightTests` (24) — the insight *is* the difference between two engine runs, so agreement is by construction |
| Due-date edits update future events and reconcile one correct set of notifications | `CalendarRemindersHardeningTests` (28) incl. `testDueDateEditRemovesOldRequestsAndLeavesExactlyOneReplacement`, `testRepeatedReconciliationIsIdempotentAcrossEveryTrigger` |
| JSON backup round-trips; restore failure is atomic; templates exclude sensitive fields by default | `BackupPortingTests` (21), `TemplatePortingTests` (18) — atomicity tested against a real failing restore, not an injected one |
| Generate Financial Report produces a readable multi-page local PDF | `FinancialReportTests` (22), `FinancialReportVisualQATests`, and §6 |
| Logs, notification identifiers, tests, and reports expose no financial payload | §7.2 |
| Comments explain why and pin invariants | Reviewed across every merged diff; one stale, wrong, value-bearing comment found and replaced (`763a141`) |
| Dynamic Type, VoiceOver, high contrast, Reduce Motion, denied permission, empty and error states | §6.2 |
| No v0.2 core behaviour regresses | Whole v0.2 suite still green; the calc-3 stamp guarded explicitly (§4) |

---

## 4. The calculation-version decision

Agents 2, 4 and 6 each flagged `PlanContract.currentCalculationVersion` still at 2, and
each declined to move it. They were right to. The constant was doing two jobs:

1. the version stamped on newly generated plans, and
2. the threshold deciding whether a plan is handled by the modern engine or the frozen
   calc-v1 path.

`VERSIONING.md` §5 mandates calc 3 for this release. Raising the single constant would also
raise the dispatch threshold, so every plan a v0.2.0 user already has — stamped 2 — would
fail `>= 3`, fall through to the calc-v1 legacy path, and find nothing there on any install
that never had a 0.1.x baseline. Reforecast, insights, Today's projection and the plan
screen would all go blank on upgrade, silently.

The two jobs are now two constants: `currentCalculationVersion = 3` for stamping,
`minimumModernCalculationVersion = 2` for the legacy boundary. The five dispatch sites ask
the boundary question they were always asking; the stamping sites take the current version,
which also makes the backup envelope stop recording `calculationVersion: 2`, which it did
until now and which was wrong.

Nothing recomputes. Existing stamps are never rewritten, a calc-2 snapshot still routes to
`.v2Avalanche`, and calc v3 reduces to calc v2 exactly without scenario or extra payments.
Applied scenarios already stamped themselves 3 independently of this constant.

Three guards were added to `ReleaseIntegrationTests`. The important one —
"an upgraded calc-2 plan still reaches the modern engine" — was **mutation-checked**:
setting the boundary to 3 fails it on both the baseline and the reforecast path, which is
precisely the regression described above.

---

## 5. Cross-feature issues found and settled

### 5.1 Two incompatible `StoredScenarioDefinition` / `StoredExtraPayment` types

Agents 2 and 3 independently declared both types with different fields. Agents 4 and 6 each
hit this on their own branch and each removed Agent 2's variants; I reached the same
resolution, but verified it rather than inheriting it: Agent 2's distinguishing members
(`startingSequence`, `baselinePlanVersionID`) have **zero** references outside their own
declaration, in this tree and on all three unmerged branches — so removing them could not
break a merge still to come. Agent 3's shapes are the ones MVP_LAYOUT §6 makes binding and
the ones every consumer already uses. The saved-scenario metadata Agent 2's shape carried
has no consumer in v0.3.0; if named saved scenarios are wanted later, that belongs on its
own type, not on the engine's input DTO.

### 5.2 Two `ScenarioKind` vocabularies, and two scenario-definitions mappings

The duplicate `displayName` / `isRecommended` was a hard compile error — the merged tree
did not build. Bodies were byte-identical, so there was no behavioural question; Agent 6's
copy went, its rationale (screen and printout must name the cards identically) moved onto
the surviving declaration.

The second one compiled, which makes it worse. `ScenarioWorkspaceLoader.definitions` (the
screen) and `ScenarioDefinitionBuilder` (the report) were two independent store →
definitions mappings, and they differed on `preferredFloor` / `preferredAllowance`: the
screen passed the profile's values, the builder leaves them nil, which §6 defines as "keep
what is already in the snapshot". A disagreement here surfaces as a **report that
contradicts the screen it was generated from**.

I verified they cannot diverge *today* — `PlanningInputBuilder` fills the snapshot from the
same `UserGoalProfile` row — so consolidating is behaviour-neutral now and closes a latent
divergence rather than fixing a live one. The screen now uses `ScenarioDefinitionBuilder`,
which is what Agent 6 designated and handed to Agent 4. Two tests that pinned the removed
mapping now assert the contracted nil, with the reason recorded at the assertion.

### 5.3 A calendar row that threw away the identity it held

`CalendarEventService` emits a balance-update row only for snapshots carrying a debt
reference — the loop guard proves the debt's UUID is in hand — and then built the deep link
from the plan letter alone. Letters are reused (the repository hands out the lowest free
slot), so a rendered row could open a debt the user never tapped: the exact misrouting
Agent 5's entity-keyed link exists to close. Not a merge regression — the same code is on
Agent 5's branch, so this is a producer their hardening missed. Fixed, and pinned by a
mutation-checked test.

### 5.4 Applying a scenario promised something it did not do

`ApplyScenarioView`'s confirmation says "Your reminders are rebuilt to match the new
schedule". Nothing rebuilt them. Agent 4 flagged the copy and correctly declined to wire a
scheduler they do not own. Applying a scenario activates a new plan version, which is the
same event `PlanActivationView` handles, so the apply path now does exactly what that path
does: `rescheduleAll(trigger: .planActivation)` plus a reforecast — the latter because
reforecasts run only on explicit actions, so the stored forecast would otherwise keep
projecting the plan the user just replaced.

### 5.5 A template could switch on detailed lock-screen copy

Agent 5 handed this rule to Agent 6, whose branch predates Agent 5's work, so it never
arrived: the importer copied `detailedLockScreenContent` verbatim from the file. Detailed
copy puts a debt's name and an amount on a screen readable without unlocking the phone, and
a template arrives from someone else. It is now always false on import, whatever the file
says; timing and lead days still cross. Pinned by a mutation-checked test.

### 5.6 A superseded screen left reachable only by accident of the compiler

`SettingsObligationsView` lost its Settings entry to the consolidated Bills & Debts page and
was left in the tree, unreferenced. Agent 4 explicitly left the removal to the integrator
"once the consolidation is ratified". It is ratified. Two bill-editing screens where one is
reachable is how the reachable one later drifts from the one someone edits.

---

## 6. What was looked at, not just asserted

### 6.1 Generated PDFs

Six sample reports were rendered via `FinancialReportVisualQATests` with
`TEST_RUNNER_PP_QA_PDF_DIR` set, and inspected as images:

- **Full detail (7 pages)** — header and footer on every page, "Page N of M", the estimate
  disclaimer on every page, fictional 2054 dates, and an attention callout that carries an
  icon *and* a title rather than resting on colour.
- **Scenario comparison** — two charts, not one: interest in dollars and time in months,
  because a shared axis would misrepresent whichever measure lost. Sequential single-hue
  ramp light → dark, each bar directly labelled, no legend, no axis ticks. Balanced marked
  "(recommended)". The table, the charts, and the "Compared with Balanced" deltas agree.
- **Masked (6 pages)** — names replaced with generic labels, and balance columns *removed
  entirely* rather than blanked, with the report saying so. Take-home is gone from the
  inputs section too. Structure — APR, due day, type — survives, which is what makes the
  masked report still useful.

The PDFs are **not committed**. They are generated from fictional fixtures, but a report
file living in the repository is exactly the artifact that later gets mistaken for real
data.

### 6.2 Accessibility

| Requirement | Status |
| --- | --- |
| Dynamic Type | Exercised at `UICTContentSizeCategoryAccessibilityL` across four UI test files (dashboard/plan, accounts, setup, scenarios) |
| VoiceOver | `testCardAccessibilityLabelNamesEveryFigureItShows` — one element per account card whose label speaks every figure the card shows; comparison rows read as comparisons rather than loose numbers; each calendar event carries an `accessibilityDescription` speaking kind, title and status |
| Never colour alone | Icon + text paired on every status, badge, warning and callout; `testEveryDebtTypeHasItsOwnLabelsAndIcon`; verified by eye in the PDFs, which must also survive a greyscale printer |
| High contrast | Covered *by construction* (no meaning rests on colour) and asserted through the icon+text pairing tests. **Not exercised as a separate simulator appearance run** — it stays a manual check. |
| Reduce Motion | The only custom animation in the app (the debt-free celebration) honours `accessibilityReduceMotion`; no new animation was added this release. Device checklist item 12. |
| Denied permission | `testDeniedPermissionSchedulesNothingRecordsWhyAndLeavesTheAppUsable` — nothing scheduled, nothing pending touched, reason recorded, calendar still renders every due date |
| Empty states | Every new list and every report section has one; `05-empty` renders all of them |
| Error states | `accounts.loadFailure` with retry, inline sheet errors, restore failures named by collection and field, missing-input panels naming the screen that answers each gap |
| Tone | `testReconciliationCopyCarriesNoShameLanguage` and its sibling — a below-floor result is stated as a fact with its consequence, never as a judgement |

Two accessibility findings carried forward from Agent 4, neither a correctness gap: two
reorder lists nest a `List` in a `ScrollView` with a computed minimum height (fragile at the
largest sizes if rows wrap to three lines), and the account card is one combined element, so
VoiceOver users reach the four money actions via the detail screen rather than the card.

### 6.3 Screens

New screens were exercised through the UI suite rather than screenshotted. Screenshots of
these screens show account names, balances and payoff dates; against the simulator fixture
that is invented and safe, but the same capture step run against a populated store would put
real financial data into a tracked artifact. The UI tests assert on accessibility labels and
identifiers, which is stronger evidence and carries no such risk.

---

## 7. Privacy gate

### 7.1 Scans

Ground truth was rebuilt independently rather than taken from Agent 2's report: the marker
set was recovered **read-only** from the 0.1.0 commit that still carries the withdrawn
resource, and every scan prints counts only, so no value entered a transcript, a log, or
this document.

Calibration first, because a scanner that finds nothing proves nothing until you have seen
it find something. Run against the pre-scrub contract tree it reports **27 files** carrying
at least one marker — the same count Agent 2 independently reported at the same commit.

| Target | Files with hits | Total hits |
| --- | ---: | ---: |
| Tracked tree at the contract commit (calibration) | 27 | 426 |
| Tracked tree after Agent 2's merge | 1 | 1 |
| **Tracked tree, final (143 files)** | **0** | **0** |
| Added lines of all five feature branches (22,863 lines) | 0 | 0 |
| 6 generated PDF reports (58 distinct money figures recovered) | 0 | 0 |
| Release binary (47,949 strings) | 0 | 0 |

The one residual hit was a comment in a test carrying a figure from the pre-scrub fixture.
It was also **stale and wrong** — the assertion beside it had been re-anchored to the
invented fixture, so the comment stated a different result than the test required. Replaced
with the invariant the assertion actually pins (`763a141`).

Two notes on method, so the numbers can be trusted rather than believed:

- A first marker set harvested from the Swift files as well as the resource produced hits in
  ~100 files, including documents Agent 1 had already cleaned. Those files carry ordinary
  code constants — the R-06 estimator, rounding factors — and harvesting them makes generic
  vocabulary into "markers". Ground truth is the withdrawn resource alone, which is a
  superset for identity purposes because every personal figure elsewhere derived from it.
- Extracted PDF text arrives kerned, with spaces inside words *and inside numbers*, so a
  naive scan of it is falsely clean. The scanned variant rejoins whitespace only *inside*
  numeric runs, which restores split figures without fusing two separate ones. Verified
  non-vacuous: 58 distinct money-shaped tokens were recovered from the samples before
  scanning, and probe strings from the fixtures are findable in the normalised text.

### 7.2 Diagnostics and payloads

- **App source has exactly one logging call site**, `#if DEBUG` only, printing a migration
  error. Both migration error strings were read: they describe structure ("the stored plan
  graph is not internally consistent") and a legacy category key, never an amount. It cannot
  emit a financial payload, and it cannot ship.
- **Notification identifiers** are `family` + entity UUID + optional date key; asserted
  structurally rather than by digit-substring scanning, which is meaningless against hex.
- **Default reminder copy** carries no figure or currency symbol for any family, and
  `detailedLockScreenContent` is off in every seeded default — and can no longer be turned on
  by an imported file (§5.5).
- **Error text names where, never what** — the backup error that used to quote a raw amount
  is gone, with a test asserting the value does not appear in the message.
- **Release bundle** contains no JSON resource, and the Release binary contains zero
  occurrences of `DebugBaselineFixture`, `OriginalPlanV1`, `PlanSeeder`, `TemplateCatalog`,
  or `SeedPlan`.

---

## 8. Git history — read-only audit, and why external release is blocked

No history was rewritten. No branch was force-pushed. No tag was moved or created.

| Finding | Value |
| --- | --- |
| Commits touching the withdrawn resource | 4 |
| Refs whose **tip** still contains it | 28 of 35 (16 of 21 local branches, 10 of 12 remote-tracking, **2 of 2 tags**) |
| Remote configured | `github.com/Hashleemy/payday-playbook` |
| Local evidence of a push | 12 remote-tracking refs exist for `origin` |

**Does the repository appear shared or pushed?** Yes. Remote-tracking refs only exist after
communication with that remote, and ten of them carry the withdrawn resource at their tip.
That is direct local evidence the data reached GitHub. Agent 2 reports the remote is
private; I record that as their finding, not mine — **repository visibility cannot be
determined from local evidence**, and "private" is a claim that should be re-checked against
the hosting account before it is relied on.

So: the working tree is clean going forward, and history is not. Per MVP_LAYOUT §3 this is
an owner decision, and I am explicitly not taking it. **External release is marked blocked
until the owner chooses a remediation path.** Removing it from history means a rewrite
across every branch and both tags plus a coordinated force-push, which invalidates every
open branch — so the sequencing Agent 2 recommends is right: finish this release, then
decide history separately.

Two local artifacts need handling, neither tracked, and the order matters:

- `.claude/worktrees/pp-0.1.0-device` is a 0.1.0 checkout that still holds the withdrawn
  resource on disk. Agent 2 recommended deleting it. **Do not delete it yet** — device
  checklist item 13, the upgrade rehearsal, builds 0.1.x to the phone *from this worktree*,
  and it is the only proof outside fixtures that an existing user loses nothing. Delete it
  once the rehearsal has passed. (Flagging the conflict because two reports otherwise give
  opposite advice.)
- The stray `agent5-pre-rebase-backup` tag should be deleted. It is one of the two tags
  whose tip still carries the resource, so it is also part of the §8 decision.

---

## 9. Known limitations carried into the alpha

Product and engineering limitations are in `CHANGELOG.md` and `TESTING.md`. What matters to
the release decision:

1. **Nothing has been validated on hardware.** Notification delivery, lock-screen copy under
   a real "hide previews" setting, provisional authorisation, time-zone travel across a real
   DST boundary, cold-launch deep links, Face ID lock, the share sheet, the system file
   importer against a real Files provider, PDF rendering on device, and the **upgrade
   rehearsal** are all simulator-only. The upgrade rehearsal is the only proof outside
   fixtures that an existing user loses nothing, and `TESTING.md` puts it first for that
   reason. Items 1–7 of the v0.2.0 device checklist were already outstanding for build 3;
   v0.3.0 inherits them.
2. **High contrast is not exercised as a separate simulator run** (§6.2).
3. **Main-thread cost is managed, not removed.** Three scenarios plus one insight is roughly
   1.3 s on an eight-debt, 77-paycheck plan; report rendering shares the ceiling. Both show
   a loading state. Moving the engine off the main actor stays out of scope.
4. **Weekly and biweekly bills still get no due-date marker or reminder**, and long-cadence
   bills anchor to their creation month. Carried from v0.2.0; closing either needs a schema
   field.
5. **The first reconcile after upgrade re-adds every debt due reminder once**, because the
   reference shape changed. One round of churn, idempotent afterwards — and precisely what
   device checklist item 6 exists to observe.
6. **A structure-only template cannot create bills, installment debts, or a pay schedule.**
   Honest, stated up front in the preview, and still worth a product decision before the
   alpha copy is finalised.
7. **The 50 MB / 250,000-record import limits are untested at scale** — the guard is
   verified, performance near it is not.
8. **Same-tick ledger ordering** cannot distinguish a movement recorded in the same clock
   tick before a snapshot from one after it. Resolving it properly needs a monotonic
   sequence column.

---

## 10. Versioning

| Axis | Before | Now |
| --- | --- | --- |
| App (`MARKETING_VERSION`) | 0.2.0 | **0.3.0** — verified as v0.2.x first, in all 6 build configurations |
| Build (`CURRENT_PROJECT_VERSION`) | 3 | **4** — +1, strictly increasing, all 6 configurations |
| Persistence schema | 2 | **3** — Agent 2's tested, lossless 2 → 3 |
| Calculation | 2 | **3** for newly generated and applied plans; every existing stamp untouched (§4) |
| Export schema | 2 | **3**; reads 1, 2 and 3 |

Confirmed on the built artifact: `CFBundleShortVersionString = 0.3.0`, `CFBundleVersion = 4`.

`VERSIONING.md` needs one amendment recorded: §5's calculation-version rule now depends on
the two-constant split in §4 above. The mandate itself is unchanged and met.

**No tag was created.** `v0.3.0-alpha.1` is cut when the artifact is cut, per §3 of the
versioning contract. The outstanding housekeeping Agent 1 assigned — retro-tagging `main` as
`v0.1.0`, deleting the stray `agent5-pre-rebase-backup` tag — is deliberately left with the
history decision in §8, since both touch refs.

---

## 11. What the owner has to decide

1. **Git history remediation** (§8) — blocks external distribution only. Device testing on
   your own hardware can proceed now.
2. **Run the device checklist**, upgrade rehearsal first (`TESTING.md`). That is the gate
   between this branch and a tag.
3. **Structure-only templates** cannot create the rows that need amounts (§9.6) — a product
   call on the alpha copy, not a defect.
