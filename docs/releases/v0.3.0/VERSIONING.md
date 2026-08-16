# Payday Playbook — Versioning contract (v0.3.0)

Owner: Agent 1 (Product Contract & SemVer). Binding for the 0.3.0 release cycle.
Predecessor: `docs/releases/v0.2.0/VERSIONING.md` (still the record for the 0.2.0 cycle).

## 1. The six versions, and why they are not the same thing

| Axis | Current (0.2.0-alpha.2) | 0.3.0 cycle | Lives in |
| --- | --- | --- | --- |
| App version (SemVer) | 0.2.0 | **0.3.0** | `MARKETING_VERSION` in `project.pbxproj` |
| Build number | 3 | **4** at the next distributed build, then +1 per distributed build | `CURRENT_PROJECT_VERSION` |
| Persistence schema | 2 | **3** expected (§5) | `PlanContract.schemaVersion` |
| Calculation version | 2 for new plans; Original Plan v1 stays 1 | **3** for plans generated or applied in 0.3.0; every existing stamp unchanged | `PlanVersion.calculationVersion` per plan row |
| Export schema (portable envelopes: backup + template) | 2 | **3** (writes 3; imports 1, 2, and 3) | the export service's schema-version constant, carried in every envelope |
| User plan versions | per-install `PlanVersion` rows | unchanged concept | data, not software |

**User plan versions are data, not software.** "Original Plan v1", "Plan v1", "Plan v2" are
`PlanVersion` rows a user accumulates on their own device. They never track, imply, or
constrain the app version. Do not name code, tags, or releases after them, and do not
rename them to match releases. A plan version created by applying a v0.3.0 scenario is
just another data row — named for the user's sequence, stamped calculation version 3.

## 2. App version decision (SemVer)

- **Found in the repo:** `MARKETING_VERSION = 0.2.0`, `CURRENT_PROJECT_VERSION = 3`
  (0.2.0-alpha.2), with the annotated tag `v0.2.0-alpha.1` present. The current release is
  therefore v0.2.x, and the release plan's rule applies directly: target **0.3.0**,
  first prerelease **v0.3.0-alpha.1**. No derivation was needed.
- 0.3.0 is a **minor** bump: every V3 requirement is a backward-compatible addition
  (screens, workflows, data portability, reporting, calculations). Existing user data
  migrates losslessly and no capability the user relies on is removed. The one removed
  affordance — the bundled founding-plan template — is a privacy withdrawal of another
  person's data, not of a user capability; user-owned templates (V3-10) replace it.
- Only Agent 7 (integration) changes `MARKETING_VERSION`, and only after re-verifying the
  current version is v0.2.x. Feature agents never touch it.

## 3. Tagging rules

- `v0.3.0-alpha.1` — annotated tag, created **only when the alpha build is actually cut**
  (build 4, all `MVP_LAYOUT.md` §11 acceptance criteria green on fresh + migrated
  fixtures, privacy gate passed). Never tag intent, only artifacts.
- Further alpha cuts increment the suffix (`v0.3.0-alpha.2`, …); the bare `v0.3.0` tag
  marks the final. Defects found after `v0.3.0` ships may receive `0.3.x` patch releases.
- Do not reuse or move an existing tag, ever.

## 4. Build-number rule

`CURRENT_PROJECT_VERSION` is a plain integer, strictly increasing across **all** versions
and prereleases, incremented by exactly 1 for every distributed build (TestFlight or
otherwise), never reset on version bumps. History: 0.1.x = 1, 0.2.0-alpha.1 = 2,
0.2.0-alpha.2 = 3. The first distributed 0.3.0 alpha is therefore **4**. A distribution
whose build number is ≤ the last distributed one must fail.

## 5. Schema, calculation, and export-schema versioning

- **Persistence schema** guards the SwiftData store shape. The v0.3.0 data-model work
  (`MVP_LAYOUT.md` §6: cash-account and ledger extensions, plan-version scenario fields)
  changes stored models, so schema **3** is expected. The bump is made by Agent 2 with a
  written, lossless, tested 2→3 migration (§7) — never speculatively. If, against
  expectation, v0.3.0 lands with zero store-shape changes, the stamp stays 2 and the
  integrator amends this document. The app continues to refuse to open a store from a
  *newer* schema rather than guessing.
- **Calculation version** is stamped per `PlanVersion` at generation and frozen. The
  release plan mandates a bump: scenario and extra-payment behavior are new calculation
  capabilities, so plans generated or applied in v0.3.0 are stamped **3**. Existing stamps
  are never touched: the founding baseline stays 1 forever; v0.2.0-generated plans stay 2.
  Engines dispatch on the stamp. **Reduction rule:** with no scenario constraints and no
  extra payments, calc v3 must reproduce calc v2 exactly (tested on fictional fixtures),
  just as calc v2 reduces to calc v1 for biweekly cadence.

  **Amendment 1 (integration, v0.3.0-alpha.1).** "The current stamp" and "the boundary
  below which a plan is handled by the frozen calc-v1 engine" are two different facts and
  are now two constants: `PlanContract.currentCalculationVersion` (**3** — what a newly
  generated plan is stamped, and what the export envelope records) and
  `PlanContract.minimumModernCalculationVersion` (**2** — the legacy boundary that
  reforecast, insights, Today's projection and the plan screen dispatch on).

  They were one constant, and raising it to satisfy the mandate above would also have
  raised the dispatch threshold: every plan a v0.2.0 user already has would fail `>= 3`,
  fall through to the calc-v1 path, and find nothing there on any install that never had a
  0.1.x baseline — blanking those four surfaces on upgrade, silently. The mandate is
  unchanged and met; only the mechanism is split. The boundary constant moves **only** when
  a calculation version is genuinely retired, which is a separate decision from stamping a
  new one. Guarded by `ReleaseIntegrationTests`.
- **Export schema** tracks the portable document envelope, which v0.3.0 extends with
  `documentKind` (`fullBackup` | `template`) and validation metadata. Writers emit
  version **3**; readers accept 1, 2, and 3 by running the same logical migrations used
  by the store. Backups and templates share this axis — the `documentKind` field, not the
  version, distinguishes them. CSV columns remain append-only: existing columns keep
  their names and order.

## 6. What downstream agents must not do

- Do not tag anything.
- Do not change `MARKETING_VERSION` or `CURRENT_PROJECT_VERSION` (Agent 7 only, at
  integration, per §2 and §4).
- Do not change a schema, calculation, or export version constant outside the values and
  conditions above.
- Do not rename user plan versions or Original Plan v1.
- Do not ship a schema change without extending the migration service and its fixture
  tests.
- Do not use any real person's financial values in versioning or migration fixtures —
  every fixture is clearly fictional (V3-12).
