# Agent 1 report — Product Contract & Semantic Versioning (v0.2.0)

*(Edited 2026-08-13 under V3-12: personal financial values and the founding user's name redacted; all technical content, decisions, and results otherwise unchanged.)*

Branch: `feature/v0.2-product-contract` · Date: 2026-08-10 · Docs only — no feature code.

## Decisions

1. **The referenced plan file did not exist.** Neither `AGENTS.md` nor
   `ALPHA_V0.2.0_MULTI_AGENT_PLAN.md` existed anywhere in the repo or its history. As
   contract owner I authored `ALPHA_V0.2.0_MULTI_AGENT_PLAN.md`, deriving the canonical
   V2-01…V2-18 registry one-to-one from the mission's required scope (18 scope items →
   18 IDs). Downstream agents now have a real referent; the file records its own
   provenance.
2. **SemVer ruling.** The repo's `MARKETING_VERSION = 1.0` is the untouched Xcode
   scaffold default (paired with build 1, zero git tags, alpha-MVP docs). Ruled it a
   template artifact, not a version statement: the shipped MVP is treated as **0.1.0**,
   so the mission's 0.1.x rule applies — target **0.2.0**, prerelease **v0.2.0-alpha.1**
   (tagged only when the alpha build is cut). Corrected `MARKETING_VERSION` to `0.2.0`
   and `CURRENT_PROJECT_VERSION` to `2` (all six build configs). Rationale and rules in
   `docs/releases/v0.2.0/VERSIONING.md`. Version config is SemVer ownership, not feature
   code. Recommended (not done): retro-tag `main` as `v0.1.0`.
3. **F-contract preserved by amendment, not replacement.** soul.md forbids removing
   F-01…F-16 without user approval; the v0.2.0 mission is that approval. Exactly two
   amendments are recorded in soul.md (F-01 fresh-install seeding; success-criterion 2),
   and soul.md now states that count explicitly. Everything else — hard boundaries,
   privacy rules, exact plan tables (verified byte-identical), three-truths separation —
   survives untouched, with two boundaries added (no baseline regeneration; never force
   the founding user's plan on new users).
4. **Original Plan v1 = migrated data + deliberate template.** Fresh installs never see
   it; migration preserves every existing value (adds fields/rows, never alters one);
   the bundled JSON becomes an explicit, warned template load.
5. **Version separation.** Five axes documented and pinned: app 0.2.0 · build 2 (+1 per
   distributed build, never reset) · schema 2 · calculation 2 for new plans with
   Original Plan v1 frozen at 1 · backup 2 (reads 1). User plan versions ("Original
   Plan v1", "Plan v1", "Plan v2") are data, never software versions.
6. **Ambiguity → rules.** All generalized money behavior is in `MVP_LAYOUT.md` §5 as
   testable rules R-01…R-16 (cadence timelines, day-gap interest, obligation smoothing
   `round2(annualized ÷ paychecksPerYear)` — reproduces the baseline's two per-paycheck
   obligation amounts exactly —
   allocation order, shortfall handling, avalanche tie-breaks, eligibility, clamping,
   utilization). Calc v2 reduces exactly to calc v1 under biweekly cadence (tested).

## Changed files

| File | Change |
| --- | --- |
| `soul.md` | Configurable-user identity; principle 9 (onboarding); the founding user's plan re-framed as immutable baseline/template (tables verbatim); F-table amendments; new V2-01…V2-18 contract table; two hard boundaries added |
| `MVP_LAYOUT.md` | Rewritten for v0.2.0: §2 versioning, §3 migrated baseline (calc v1 frozen), §4 onboarding sequence + screen states, §5 rules R-01…R-16, §6 schema-2 models, §7 migration, §8 screens/insights, §9 due-date→calendar/notification behavior, §10 services, §11 V2 acceptance criteria, §12 parity table, §13 tests, §14 structure, §15 build sequence |
| `ALPHA_V0.2.0_MULTI_AGENT_PLAN.md` | New — canonical V2 registry, release identity, agent map, ground rules |
| `CHANGELOG.md` | New — Keep-a-Changelog; Unreleased (targeting 0.2.0, explicitly unshipped) + 0.1.0 record |
| `docs/releases/v0.2.0/VERSIONING.md` | New — full five-axis versioning contract, tagging and build-number rules |
| `README.md`, `ENGINEERING.md` | Pointers updated to the amended contract and V2 registry; shipped-vs-contract distinction made explicit |
| `PaydayPlaybook.xcodeproj/project.pbxproj` | `MARKETING_VERSION` 1.0→0.2.0, `CURRENT_PROJECT_VERSION` 1→2 (6 configs) |

## Validation

- **Parity report:** every ID V2-01…V2-18 present in `soul.md` (18/18), `MVP_LAYOUT.md`
  (18/18), and the registry (18/18); every F-01…F-16 present in both docs (16/16 each).
  `MVP_LAYOUT.md` §12 maps each V2 ID to its soul row, spec sections, and related F IDs.
- **Adversarial review:** an independent review agent diffed the branch against `main`
  hunting contradictions in first launch, migration, immutability, version names, lost
  non-negotiables, internal cross-references, and changelog honesty. It verified the
  exact-plan tables byte-identical, all version numbers consistent across all files, and
  no surviving fresh-install-seeds claim — and raised 15 findings (1 high, 7 medium,
  7 low). **All 15 were fixed**, notably: the ceiling formula in R-10 corrected to the
  keep-in-spending construction (the corrected construction yields a materially higher
  ceiling than the earlier arithmetic); the baseline-equivalence test
  respecified to honor the documented ±$0.01–$0.06 seed-table float artifacts instead of
  demanding the forbidden "fix"; the dropped v0.1 success criterion recorded as a proper
  amendment; stale §-references, circular acceptance references, PlanSeeder/migration
  ambiguity, R-08 immutability wording, and overstated "bit-for-bit" claims corrected.

## Assumptions (numbered in MVP_LAYOUT.md)

A-01 posture → suggested defaults only (tunable values in R-14) · A-02 account cap 10 ·
A-03 "Other" debt behaves as personal loan · A-04 fresh-install baseline named
"Plan v1" · A-05 600-paycheck generation cap · A-06 minimum estimator is credit-card
only; installment debts require an entered minimum · A-07 utilization thresholds
30% / 90% · A-08 goal-gap insight via $1-resolution search, display only.

## Unresolved questions (for the user / downstream agents)

1. Should `main` be retro-tagged `v0.1.0` (recommended, not done — tagging left to the
   release integrator)?
2. R-14's posture suggestion dollar values ($150/$500 etc.) are placeholders — product
   may want different ones; changing them needs no contract change.
3. Semimonthly cadence uses actual day-gap interest (R-02); if real users need
   twice-monthly paydays pinned to statement cycles instead, that's a calc-v3 topic.
4. The template load path exposes the founding user's real numbers to any user who taps
   it; if that's a privacy concern for distribution beyond the founding user, drop the
   template from the bundle (one-line change to §3/§4.1).

## What downstream agents must know

- Read order: `soul.md` → `MVP_LAYOUT.md` → `docs/releases/v0.2.0/VERSIONING.md` → this
  report. IDs V2-01…V2-18 and rules R-01…R-16 are fixed vocabulary — use them in
  commits and reports.
- Do not touch version numbers or tags (VERSIONING.md §6). Do not rename plan versions.
- Migration (§7) may add fields/rows but must never alter an existing stored value;
  Original Plan v1 stays `calculationVersion = 1` and is never recomputed.
- Calc v2 must reduce exactly to calc v1 under biweekly cadence — write that test first
  (§13 tests 2–3), honoring the ±$0.01–$0.06 seed-table artifact note in
  `ENGINEERING.md`.
- The 0.1.x 54-test suite must stay green on both fresh and migrated fixtures.
