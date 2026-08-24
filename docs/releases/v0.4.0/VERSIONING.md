# Payday Playbook — Versioning contract (v0.4.0)

Owner: Agent 1 (Release Contract & Architecture). Binding for the 0.4.0 release cycle.
Predecessors: `docs/releases/v0.3.0/VERSIONING.md` (still the record for the 0.3.0 cycle)
and `docs/releases/v0.2.0/VERSIONING.md`.

## 1. The six versions, and why they are not the same thing

| Axis | Current (0.3.0-alpha.1, prepared) | 0.4.0 cycle | Lives in |
| --- | --- | --- | --- |
| App version (SemVer) | 0.3.0 | **0.4.0** | `MARKETING_VERSION` in `project.pbxproj` |
| Build number | 4 | **5** at the next distributed build, then +1 per distributed build | `CURRENT_PROJECT_VERSION` |
| Persistence schema | 3 | **3 — no bump expected** (§5) | `PlanContract.currentSchemaVersion`, stamped in `AppSettings.seedSchemaVersion` |
| Calculation version | 3 for new plans; existing stamps 1/2/3 frozen | **4** for plans generated, previewed, or applied in 0.4.0; every existing stamp unchanged | `PlanVersion.calculationVersion` per plan row |
| Export schema (portable envelopes: backup + template) | 3 (reads 1–3) | **4** (writes 4; reads 1, 2, 3, and 4) (§5) | `ExportService.backupSchemaVersion` / `importableSchemaVersions`, carried in every envelope |
| User plan versions | per-install `PlanVersion` rows | unchanged concept | data, not software |

**User plan versions are data, not software.** "Original Plan v1", "Plan v1", "Plan v2" are
`PlanVersion` rows a user accumulates on their own device. They never track, imply, or
constrain the app version. Do not name code, tags, or releases after them, and do not
rename them to match releases.

## 2. App version decision (SemVer)

- **Found in the repo:** `MARKETING_VERSION = 0.3.0`, `CURRENT_PROJECT_VERSION = 4`
  on `main` at `3b20669` (the merged v0.3.0-alpha.1 integration). 0.3.0-alpha.1 is
  **prepared but untagged and undistributed**; external distribution remains blocked on the
  owner's Git-history decision (v0.3.0 integration report §8). The current release lineage
  is therefore v0.3.x, and the next backward-compatible feature release is **0.4.0**,
  first prerelease **v0.4.0-alpha.1**. No derivation was needed.
- 0.4.0 is a **minor** bump: every V4 requirement is a backward-compatible fix or addition
  (debt-type-aware validation, reactive setup state, a smarter Balanced scenario, one
  canonical utilization calculation, a semantic primary-button treatment, a generic
  checking-account adjustment flow, a derived pay-cycle allocation service, a Calendar
  debt dashboard). No user capability is removed. The one retired affordance — the legacy
  hard-coded "Checking 1 / 2 adjustment" quick-entry sheet — is superseded by a strictly
  more general flow; its historical ledger rows remain readable forever (soul.md
  amendment 6).
- Only Agent 7 (integration) changes `MARKETING_VERSION`, and only after re-verifying the
  current version is 0.3.x. Feature agents never touch it.

## 3. Tagging rules

- `v0.4.0-alpha.1` — annotated tag, created **only when the alpha build is actually cut**
  (build 5, all v0.4.0 acceptance criteria green on fresh + migrated fixtures, privacy
  gate passed). Never tag intent, only artifacts.
- **The v0.3.0-alpha.1 tag does not exist and must not be created retroactively by this
  cycle.** Whether 0.3.0 is ever tagged is the owner's call, coupled to the history
  decision. v0.4.0 work does not depend on it.
- Further alpha cuts increment the suffix; the bare `v0.4.0` tag marks the final. Do not
  reuse or move an existing tag, ever.
- **External distribution remains blocked** until the owner resolves the Git-history
  question recorded in the v0.3.0 integration report §8. Tagging locally at the cut is
  permitted; pushing tags or distributing builds is not.

## 4. Build-number rule

`CURRENT_PROJECT_VERSION` is a plain integer, strictly increasing across **all** versions
and prereleases, incremented by exactly 1 for every distributed build, never reset.
History: 0.1.x = 1, 0.2.0-alpha.1 = 2, 0.2.0-alpha.2 = 3, 0.3.0-alpha.1 = 4 (prepared).
The first distributed 0.4.0 alpha is therefore **5**. A distribution whose build number is
≤ the last distributed one must fail.

## 5. Schema, calculation, and export-schema versioning

### Persistence schema — stays 3

No v0.4.0 requirement adds a stored field:

- V4-03's Balanced quick-win promotion travels inside `PlanVersion.inputSnapshotData`
  (an additive optional key of the JSON `StoredPlanInput`; calc-v3 and calc-v2 snapshot
  bytes are unchanged).
- V4-07/V4-08 are **derived** services over existing plan items and ledger rows —
  deliberately no new persisted balance (the release mandate: prefer derived state).
- V4-01/V4-02/V4-04/V4-05 are validation, reactivity, display, and styling.
- V4-06 writes only existing schema-3 row shapes (`accountAdjustment` ledger entries plus
  authoritative `BalanceSnapshot` rows, provenance `user`).

If an implementing agent discovers a genuine need for a stored field, the bump to 4 is
made by that field's owning agent **with integrator ratification**, following both halves
of the duplicated step list — `MigrationService.migrateIfNeeded` **and**
`ExportService.restore` each enumerate the upgrade steps, and a step added to only one
leaves imported old backups or fresh launches unmigrated. Additive-with-defaults only;
never alter an existing stored value; fixture-tested per the T-1 pattern. Do not bump
speculatively.

### Calculation version — 4

V4-03 changes calculation semantics: Balanced (Recommended) becomes a multi-objective
selection over complete engine simulations, and the engine gains an attack-promotion
input (`quickWinPromotions`). Plans generated, previewed, or applied by 0.4.0 are
stamped **4**. Existing stamps are never touched: the founding baseline stays 1 forever;
v0.2.0 plans stay 2; v0.3.0 plans stay 3. Engines dispatch on the stamp.

**Reduction chain (all tested):** calc v4 with no quick-win promotions reproduces calc v3
byte-identically; calc v3 with no scenario and no extra payments reproduces calc v2; calc
v2 reduces to calc v1 for biweekly cadence. A plan generated from onboarding (no scenario,
no promotions) therefore has identical value under 4 as under 2 — only the stamp differs.

**The two-constant rule is preserved (v0.3.0 VERSIONING §5 Amendment 1, load-bearing).**
`PlanContract.currentCalculationVersion` becomes **4** (what a newly generated plan is
stamped, and what the export envelope records). `PlanContract.minimumModernCalculationVersion`
**stays 2** — it is the frozen-calc-v1 dispatch boundary, and it moves only when a
calculation family is genuinely retired, which v0.4.0 does not do. Re-unifying them, or
raising the boundary, recreates the blank-on-upgrade regression that
`ReleaseIntegrationTests` mutation-checked in v0.3.0. Those guards must be extended, not
weakened: an upgraded calc-2 or calc-3 plan still reaches the modern engine; the calc-v1
baseline stays off it; a newly generated plan is stamped 4.

**Both calc-version representations move together.** The repo has two: the constant
`PlanContract.currentCalculationVersion` and the enum `PlanCalculationVersion`
(`PlanningContracts.swift`), which gains `.v4BalancedQuickWin = 4`. Known stamping sites
that currently write `.v3Scenario` / rely on the constant, all owned by Agent 3 this
cycle: `PlanningInputBuilder` (via `PlanContract.currentCalculationVersion`),
`ScenarioCalculationService.scenarios` (stamps the snapshot copy),
`ScenarioPlanActivationService.apply`, `ExtraPaymentInsightService`, and
`PlanGenerationService.engineInput`'s version inference. Bumping one representation
without the other silently splits stamps; the reduction and stamping tests must pin every
site.

### Export schema — 4

Writers emit **4**; readers accept **1, 2, 3, and 4**. The envelope shape is unchanged —
this bump is semantic, not structural: a 0.4.0 backup can contain plans stamped
calculation version 4 whose snapshots carry the quick-win promotion key. A schema-3
reader would restore rows it cannot faithfully re-dispatch (its
`PlanCalculationVersion(rawValue: 4)` does not exist), violating the project's
"refuse a newer document by name rather than guess" posture that the envelope was built
for. Since export schema is the envelope's compatibility gate, it is the axis that must
say no.

Mechanics (Agent 3, alongside the calc bump; verified by Agent 7):
`ExportService.backupSchemaVersion` 3→4 and `importableSchemaVersions` `1...3`→`1...4`,
plus the second stamping site in the envelope path — the written schema appears in both
the `Backup` payload and the `PortableDocument` envelope, and `readBackup` enforces their
equality. Templates share the axis; `documentKind`, not the version, distinguishes them.
Import of 1/2/3 files continues to run the same logical migrations as the store. CSV
columns remain append-only.

## 6. What downstream agents must not do

- Do not tag anything, push anything, or distribute anything.
- Do not change `MARKETING_VERSION` or `CURRENT_PROJECT_VERSION` (Agent 7 only, at
  integration, per §2 and §4).
- Do not change a schema, calculation, or export version constant outside the values and
  conditions above; do not touch `minimumModernCalculationVersion` at all.
- Do not bump one calc-version representation without the other (§5).
- Do not rename user plan versions or Original Plan v1.
- Do not ship a schema change without extending **both** migration step lists and the
  fixture tests.
- Do not use any real person's financial values in versioning or migration fixtures —
  every fixture is clearly fictional (V3-12, still binding).
