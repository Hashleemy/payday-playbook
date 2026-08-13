# Agent 1 — Product Contract report (v0.3.0)

- **Role:** Product Contract owner (docs, feature IDs, architecture contracts, versioning, changelog). No feature code — none was written.
- **Branch:** `feature/v0.3-contract`, based on `release/v0.2.0-alpha.1` at `18b5d52` (the most-integrated state; `main` still sits at the 0.1.0 initial commit).
- **Date:** 2026-08-13. Current release verified as **0.2.0-alpha.2, build 3** (schema 2, calc 2, backup 2; tag `v0.2.0-alpha.1` exists locally; 292 unit + 19 UI tests documented green) → targets confirmed as **0.3.0** and **v0.3.0-alpha.1**, no version derivation needed.

This report contains no personal financial values, by design (V3-12/V3-13).

## Outcome

The v0.3.0 contract is authoritative and implementation-ready:

1. `soul.md` and `MVP_LAYOUT.md` carry V3-01…V3-16 in full, retain every non-superseded F/V2 behavior, and no longer contain any of the founding user's financial data.
2. Navigation is defined: a fifth **Accounts** tab (V3-02), consolidated **Bills & Debts** setup step and Settings page (V3-08), **Payoff Scenarios** + extra-payment surfaces reached from Progress/debt detail (V3-04/V3-05), and Settings groups **Back Up & Restore** vs **Reports** (V3-09…V3-11).
3. Storage-independent DTO/protocol contracts are specified in `MVP_LAYOUT.md` §6, mapped onto the repo's **actual** canonical types (no duplicate concepts): `CashAccount`/`LedgerEntry`/`BalanceSnapshot` extensions; `StoredPlanInput` + new `StoredScenarioDefinition`/`StoredExtraPayment`; engine-side `ScenarioInput`/`ExtraPaymentInput`, `ScenarioResult`, `ExtraPaymentInsight`; `PortableDocument` envelope, `TemplatePayload`, `ReportConfiguration`; protocols `ScenarioCalculating`, `ExtraPaymentInsightCalculating`, `CashAccountManaging`, `BackupPorting`, `TemplatePorting`, `ReportGenerating`.
4. The privacy gate is contracted (soul.md hard boundaries + amendment registry; layout §1/§3/§7/§13), and the **docs half of V3-12 is already executed** in this commit (see below).
5. Fastest Safe / Balanced (Recommended) / More Cushion are specified exactly as the release plan states them (layout §5 R-17…R-24), with user-supplied constraints only — no invented lifestyle assumptions; missing constraints yield named missing-input results or clearly labeled neutral suggestions (new assumption A-09).
6. `CHANGELOG.md` gains an honest Unreleased section (contract + docs scrub only; nothing claimed shipped).
7. The V3 feature-parity matrix (requirement → screens → models/services → tests → owning agent) is `MVP_LAYOUT.md` §12.

## Changed files

- `soul.md` — rewritten: V3 contract table; "The founding baseline" section replaces the printed personal plan; F/V2 rows amended where V3 supersedes presentation; new hard boundaries (project-level privacy, preview non-mutation, no auto-upload); v0.3.0 success criteria; explicit amendment registry (5 entries).
- `MVP_LAYOUT.md` — rewritten as the v0.3.0 spec (§1–§18): versioning, founding-baseline de-personalization, consolidated onboarding, calc-v3 rules R-17…R-24 (R-01…R-16 restated with fictional examples), schema-3 model/DTO/protocol contracts, migration 2→3 incl. the legacy-constant derivation contract, five-tab IA and all new screens, notification hardening, canonical service map, V2 (restated) + V3 acceptance criteria, V3 parity matrix, test plan T-1…T-17 with the fictional-fixture re-anchor list, wave build sequence.
- `CHANGELOG.md` — Unreleased section added; personal values scrubbed from historical entries (noted in-file).
- `docs/releases/v0.3.0/VERSIONING.md` — new: six-axis contract (app 0.3.0; build 4 at next cut; schema 3 expected; calc 3 with the v3→v2 reduction rule; export schema 3 reading 1/2/3; plan versions are data).
- `ALPHA_V0.3.0_MULTI_AGENT_PLAN.md` — committed (was untracked); it is the canonical V3 registry and is clean of personal data.
- **V3-12 docs scrub** (personal values, dates, schedules, and the founding user's name removed; semantics preserved; edited historical records carry an in-file redaction note): `README.md`, `ENGINEERING.md`, `TESTING.md`, `RELEASE_NOTES_v0.2.0-alpha.1.md`, `ALPHA_V0.2.0_MULTI_AGENT_PLAN.md`, `docs/releases/v0.2.0/VERSIONING.md`, and `docs/releases/v0.2.0/agent-reports/agent-{1,2,3,4,6,7}-*.md` (agent-5's report was verified clean).
- `docs/releases/v0.3.0/agent-reports/agent-1-contract.md` — this report.

## Key decisions (with rationale)

1. **Docs-scope scrub executed now.** V3-12 spans code and docs; I own docs, Agent 2 owns code/fixtures/tests/resources plus the audit. Doing the docs half in the contract commit means every implementing agent starts from artifacts that already model the rule. Historical records (release notes, v0.2.0 reports) were redacted with in-file notes rather than left as carve-outs — the release plan's audit scope explicitly includes them, and Git history preserves originals regardless. This overrides the v0.2.0 integration report's "do not retroactively edit the alpha.1 notes" stance; the conflict and resolution are recorded here.
2. **Template withdrawal is total.** The bundled founding-plan JSON, `PlanSeeder`/`SeedPlan`/`TemplateCatalog`, the Welcome affordance, and the Release-exclusion build machinery all go, in every configuration (soul.md amendment 4). The crashed-partial-seed repair path retires with it (already the distribution behavior; impossible for completed 0.1.x installs). V3-10 user-owned templates replace the concept.
3. **Legacy migration constants become store-derived.** The 1→2 logical upgrade's hard-coded personal obligation amounts are replaced by inverse-R-04 derivation from the store's own per-check reserves, with a round-trip verification and clean abort — keeping direct 0.1.x upgrades AND v1-backup imports alive with zero personal values in source (layout §7). Fallback (abort → "upgrade via 0.2.x") requires integrator ratification.
4. **Concept mapping kills duplicate bridges.** Release-plan names map to existing repo canon: `CashAccount`→existing model (extended), `CashLedgerEntry`→`LedgerEntry` (extended), `BalanceSnapshot`→already dual-subject (unchanged), `DueDateEventService`→`CalendarEventService`, `NotificationReconciliationService`→`NotificationScheduler`+`Planner`. All scenario math goes through `PlanGenerationService.engineInput` — no third store→engine bridge (the v0.2.0 hazard is pinned in §10).
5. **Transfers are one atomic dual-account ledger row** (the existing `LedgerEntry` shape), presented as paired movements — satisfying the paired-in-one-transaction requirement with fewer reconciliation failure modes than two linked rows.
6. **Scenario constraints live on `UserGoalProfile`** as optional fields; nil → missing-input results. Zero-allowance confirmation is a profile fact captured outside the engine.
7. **Calc v3** extends `PlanCalculationVersion` (`.v3Scenario = 3`) and `StoredPlanInput` (optional scenario/extras keys; v2 snapshots stay decodable). Reduction rule: no constraints + no extras ≡ calc v2, tested (T-5). The four R-16 reconciliation identities and the `PlanEvent` identifier scheme are preserved.
8. **Five-tab IA** (Today, Calendar, Accounts, Debts, Progress) — the presentation change that makes V3-02 first-class; everything else keeps its v0.2.0 place.
9. **Consolidated Bills & Debts sits after Income** (new step order in §4) so reserve smoothing previews use the real cadence; `OnboardingStep` gains an additive `billsAndDebts` case with a contracted resume mapping for v0.2-interrupted stores.
10. **Versioning:** schema 3 is *expected*, bumped only by Agent 2 with the lossless migration; calc 3 is mandated; export schema 3 with `documentKind`; build 4 at the next distributed cut; only Agent 7 touches `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`.
11. **R-14 posture defaults stay** as product-tunable suggestions (A-01). The privacy inventory flagged that one posture's suggested values coincide with the founding user's settings; because these are round product defaults, the contract records them as product data — Agent 2 may retune them without a contract change if the audit prefers breaking the coincidence.

## Checks run

- **V3 ID coverage:** all of V3-01…V3-16 present in both `soul.md` and `MVP_LAYOUT.md` (grep, 16/16 each — see validation transcript in the final summary).
- **Contradiction check:** no hard-coded-personal-plan requirement remains in soul/layout/registry docs; the baseline's immutability and migration guarantees are restated genericly; supersessions are recorded as counted amendments (soul.md registry, entries 3–5).
- **Coupling check:** calculation and portability contracts reference Foundation-only types; no SwiftUI/SwiftData types appear in any §6 DTO or protocol contract.
- **Privacy scan (docs scope):** repo-wide inventory was taken first (11-agent recon + a dedicated scanner using seed-derived ground truth; values never echoed); after editing, a marker/value scan over all tracked `.md` files reports zero personal hits (counts in the final summary; the scan ground-truth file was deleted after use).
- **Unit suite:** the 292-test unit suite was run on this branch per `TESTING.md` (docs-only change; results recorded in the final summary/commit).
- UI suite not run (docs-only change; requires a dedicated serial simulator per TESTING.md — unchanged code paths).

## Risks and open items

1. **Git history still contains everything.** This commit cleans the working tree only; every prior value remains in history and in the `v0.2.0-alpha.1` tag. Agent 2 owns the read-only history audit; remediation (rewrite/no-rewrite) is an owner decision the plan explicitly reserves (release plan §3). The local `v0.2.0-alpha.1` tag and the `.claude/worktrees/pp-0.1.0-device` worktree (a checkout of the 0.1.0 commit) both still contain the full personal seed — flagged for that audit; neither is a tracked current-tree artifact.
2. **Docs briefly lead code.** Until Agent 2 lands, the code still contains the personal seed, constants, comments, and the persona-named test file; `TESTING.md`/`MVP_LAYOUT.md` describe the contracted state (with explicit transitional notes). The privacy gate cannot pass until Agent 2's sweep completes — by design.
3. **Schema-1 derivation contract** (§7) is verified arithmetically in the contract but must be proven by Agent 2's round-trip test against a fictional 0.1.x fixture; the fallback path needs integrator ratification if taken.
4. **Main-thread analysis cost** grows with scenario calculators (known v0.2.0 limitation). Agent 3 must benchmark; Agent 4 must keep calculators out of view bodies. Off-main-actor refactor remains out of scope.
5. **v0.2.0 known model gaps carry forward** (weekly/biweekly bills have no due-date markers; long-cadence bills anchor to creation month). Closing them is optional, additive-only Agent 5 scope.
6. **TESTING.md device items 1–7 remain unvalidated on hardware** for build 3; v0.3.0 inherits that gate.
7. Housekeeping for Agent 7: retro-tag `main` as `v0.1.0` (still outstanding), delete the stray `agent5-pre-rebase-backup` tag, and write alpha.2/alpha.3 release-notes files at the next cut.

## Handoff contracts

- **Agent 2 (privacy/data):** own the code/fixture/resource/test scrub and the read-only history audit; implement §6 model extensions + §7 migration (incl. legacy-constant derivation and seed/template removal); rename persona-named test symbols/files; fictionalize `PlanningFixtures`, UI-test pinned dates, and golden anchors; build `CashLedgerService`/extend `CashAccountRepository`. The §6 DTO names are binding; reconcile the boundary with Agent 3 before Wave 3.
- **Agent 3 (scenario engine):** implement R-17…R-24 as calc v3 through `AvalanchePlanEngine` + `PlanGenerationService.engineInput` only; preserve the R-16 identities, `PlanEvent` identifiers, and the never-guess policy; ship T-5…T-8 plus the reduction property test; benchmark long horizons.
- **Agent 4 (accounts/setup UX):** build the Accounts tab, consolidated Bills & Debts (onboarding + Settings), and scenario/extra-payment surfaces against §6 protocols only; respect the resume mapping, `SetupCompletenessService` as the single gap source, and `GeneratedPlanService.nextPlanName` for any plan creation.
- **Agent 5 (calendar/reminders):** §9 hardening; identifiers stay UUID-keyed and value-free; reconciliation idempotent across the enumerated events; coordinate shared editor files with Agent 4 (one owner per file).
- **Agent 6 (portability/reports):** `PortableDocument` (writes 3, reads 1/2/3), `TemplatePayload` allow-list, staged/atomic restore with safety backup, and `FinancialReportService` per §8.9; limits per A-10; temp-file lifecycle per A-11.
- **Agent 7 (integration):** merge order 1→2→3→4→5→6; per-diff PI review; the §11 gates; set 0.3.0/build 4; tag only at the cut.

## Commits

On `feature/v0.3-contract` (base `18b5d52`):

- `d5326cb` — docs(v0.3.0): adopt the authoritative multi-agent release plan.
- `c0918d9` — docs(v0.3.0): authoritative contract, V3 parity matrix, and docs-scope privacy scrub (17 files).
- (+ one follow-up commit recording these hashes in this report.)

Validation at `c0918d9`: unit suite **292/292 green** (UI suite not run — docs-only change); docs privacy scan clean. Note for other agents: on this machine, `-derivedDataPath` must point **outside** `~/Documents` — the file-provider sync stamps FinderInfo xattrs onto build products inside the repo and CodeSign fails with "resource fork, Finder information, or similar detritus not allowed".
