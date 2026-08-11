# Payday Playbook — Versioning contract (v0.2.0)

Owner: Agent 1 (Product Contract & SemVer). Binding for the 0.2.0 release cycle.

## 1. The five versions, and why they are not the same thing

| Axis | Current | 0.2.0 cycle | Lives in |
| --- | --- | --- | --- |
| App version (SemVer) | 0.1.0 (untagged alpha MVP) | **0.2.0** | `MARKETING_VERSION` in `project.pbxproj` |
| Build number | 1 | **2** (then +1 per distributed build) | `CURRENT_PROJECT_VERSION` |
| Persistence schema | 1 | **2** | `PlanContract.schemaVersion` |
| Calculation version | 1 | **2** for new plans; Original Plan v1 stays **1** | `PlanVersion.calculationVersion` per plan row |
| Backup schema | 1 | **2** (reads 1 and 2) | `ExportService.backupSchemaVersion` |

**User plan versions are data, not software.** "Original Plan v1", "Plan v1", "Plan v2" are
`PlanVersion` rows a user accumulates on their own device. They never track, imply, or
constrain the app version. Do not name code, tags, or releases after them, and do not
rename them to match releases.

## 2. App version decision (SemVer)

- **Found in the repo:** `MARKETING_VERSION = 1.0` with `CURRENT_PROJECT_VERSION = 1` —
  the untouched Xcode scaffold default, present since project creation. There are zero git
  tags, no prior changelog, and the product documents describe the shipped state as an
  alpha MVP.
- **Ruling:** the scaffold `1.0` is not a deliberate version statement and would be wrong
  under SemVer (1.x claims a stable public contract; this is an alpha). The version
  actually released is treated as **0.1.0**. Therefore the mission's `0.1.x → 0.2.0` rule
  applies: target **0.2.0**, prerelease **v0.2.0-alpha.1**. This branch corrects
  `MARKETING_VERSION` to `0.2.0`.
- 0.2.0 is a **minor** bump because every change is backward compatible for the existing
  user: their data migrates losslessly and no capability is removed. Breaking the migrated
  baseline would demand a different conversation, not a bigger version number.

## 3. Tagging rules

- `v0.2.0-alpha.1` — annotated tag, created **only when the alpha build is cut** (build 2,
  all §11 acceptance criteria of `MVP_LAYOUT.md` green on fresh + migrated fixtures).
  Never tag intent, only artifacts.
- Further alpha cuts increment the suffix: `v0.2.0-alpha.2`, …; `v0.2.0` marks the final.
- Recommended housekeeping: retro-tag current `main` (`b0e7443`) as `v0.1.0` so the
  lineage is explicit. (Left to the release integrator; not done on this branch.)

## 4. Build-number rule

`CURRENT_PROJECT_VERSION` is a plain integer, strictly increasing across **all** versions
and prereleases, incremented by exactly 1 for every distributed build (TestFlight or
otherwise), never reset on version bumps. The 0.1.x MVP is retroactively build 1; this
branch sets 2 for the upcoming alpha. CI/release scripts must fail a distribution whose
build number is ≤ the last distributed one.

## 5. Schema and calculation versioning

- **Schema version** guards the SwiftData store shape. Bump only with a written,
  loss-less, tested migration (see `MVP_LAYOUT.md` §7). The app refuses to open a store
  from a *newer* schema rather than guessing.
- **Calculation version** is stamped per `PlanVersion` at generation and frozen. Engines
  dispatch on the stamp; changing math means a new calculation version, never editing an
  old one. Original Plan v1 is calc 1 forever — its stored schedule is authoritative and
  is never recomputed. Calc 2 must reduce exactly to calc 1 for biweekly cadence
  (tested: Lem-equivalence, `MVP_LAYOUT.md` §13).
- **Backup schema version** tracks the export container. Writers emit the current
  version; readers accept all older versions by running the same logical migrations.
  CSV columns are append-only.

## 6. What downstream agents must not do

- Do not tag anything.
- Do not change `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, or the three code
  version constants outside the values above.
- Do not rename user plan versions or Original Plan v1.
- Do not ship a schema change without extending `MigrationService` and its fixture tests.
