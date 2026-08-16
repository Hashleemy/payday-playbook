# Agent 6 report — JSON Portability and PDF Reporting (v0.3.0)

- **Role:** Backup, template, and financial-reporting owner.
- **Branch:** `feature/v0.3-portability-reports`, based on Agent 2's
  `6029107` with Agent 3's `46348b2` merged in (merge commit `970ba66`).
- **Requirements delivered:** **V3-09** (full JSON backup/restore), **V3-10**
  (reusable structure-only templates), **V3-11** (Generate Financial Report as
  a local PDF), plus the V3-13 slice that applies to exported files, generated
  documents, and error strings.
- **Validation:** unit suite **442/442 green**; UI suite **22/22 green** on a
  dedicated simulator; six representative PDFs rendered and visually inspected.

This report contains no personal financial values. Every number and label it
mentions comes from the fictional fixtures introduced here.

---

## 1. What shipped, in one paragraph

Three things that used to be one thing. v0.2.0 had a single "Backup & export"
screen mixing a JSON backup with CSV files, no template concept, and no report
at all. v0.3.0 separates **machine-readable protection** (a versioned JSON
backup that restores atomically), **shareable structure** (a template that
carries setup without money), and **human-readable reporting** (a PDF a user
can read, print, or hand to someone). Each is a distinct Settings action with
its own document kind, its own validation, and its own file lifecycle.

---

## 2. Document schemas

### 2.1 The envelope — `PortableDocument`

Every document this app writes now carries a header that a reader can trust
before it parses a byte of payload:

```jsonc
{
  "documentKind": "fullBackup",   // or "template"
  "schemaVersion": 3,
  "appVersion": "0.2.0",
  "calculationVersion": 2,
  "exportedAt": "2054-03-02T00:00:00Z",
  "integrity": { "recordCounts": { "debts": 3, "cashAccounts": 2, … } },
  "payload": { … }
}
```

Three questions get answered up front: *what kind of document is this*, *what
schema does it speak*, and *does the payload still contain what the writer said
it contained*. v0.2.0 could answer none of them — a backup was a bare `Backup`
object, so a template and a backup were indistinguishable until decoding failed
somewhere deep inside a payload.

**Version routing.** The writer emits export schema **3**; the reader accepts
**1, 2, and 3**. Schemas 1 and 2 predate the envelope and are bare `Backup`
objects, so the absence of `documentKind` *is* the signal that a file is a
legacy full backup — it is never guessed at. `PortableDocumentProbe` decodes
only the header (with `documentKind` read as a `String`, so an unrecognized
kind is a named error rather than a decoder failure) and routes from there.

**Integrity.** `integrity.recordCounts` is written per collection and
re-derived on read. A mismatch means the file was truncated or edited after
export, and it is refused with the collection name and both counts. The counts
are structural — how many rows, never what is in them.

### 2.2 Schema-3 backup payload additions

The payload gained exactly the fields Agent 2's schema-3 models added. All are
optional so schema-1 and schema-2 files still decode:

| Collection | Added | Notes |
| --- | --- | --- |
| `cashAccounts` | `protectedAmount`, `balanceAsOf` | V3-02 |
| `ledgerEntries` | `provenanceRaw` | V3-02/V3-03; nil is meaningful ("written before provenance existed") and is copied verbatim, never backfilled |
| `planVersions` | `scenarioKindRaw`, `effectiveDate` | V3-15 |
| `userGoalProfiles` | `minimumProtectedCash`, `plannedSavingsPerPaycheck`, `additionalCushionReserve`, `extraPaymentCeiling`, `zeroAllowanceConfirmedAt` | V3-05/V3-06 |

`PlanVersion.inputSnapshotData` needed no new key: Agent 3's extended
`StoredPlanInput` encodes its scenario and extra payments inside the same blob,
and calc-v2 snapshots remain decodable.

### 2.3 Template payload — `TemplatePayload`

A template is an **allow-list, not a redaction pass.** `TemplatePayload` has no
field for a check-in, a ledger row, a balance snapshot, a plan, a payday, a
plan event, a milestone, or a free-text note — so no amount of misconfiguration
can emit one. A test asserts the payload's key set is a subset of
`{accounts, bills, debts, income, reminders, settings, includedSensitiveCategories}`,
which fails the moment anyone widens the format.

**Always included** (structure): account roles and the default-income marker,
bill cadence / due day / essential flag, debt type / APR / due day / priority /
prepayment eligibility, pay cadence and day-of-month fields, reminder
preferences, payoff posture.

**Never included, structurally**: history, ledger, snapshots, plans, paydays,
plan events, milestones, forecasts, notes.

**Off by default, opt-in per category**, each with copy enumerating exactly
what turning it on writes into the file:

| Category | What it adds |
| --- | --- |
| `displayNames` | account, bill, and debt names, and last-four digits |
| `balances` | account balances and protected amounts; debt balance, original principal, credit limit |
| `incomeAmounts` | take-home per paycheck |
| `billAmounts` | bill amounts and debt minimum payments |
| `guardrails` | protected floor, allowance cap, and the four scenario constraints |

Two deliberate calls worth recording:

1. **APR and due day are structure, not sensitive values.** They are terms of
   the credit agreement rather than facts about the user's money, and a
   template without them cannot reproduce a payoff shape at all. Flagged as a
   judgment call in §7.
2. **The template carries no anchor payday.** A specific date is a fact about
   the exporting user's calendar. The importer's own start date is used and the
   Income step corrects it.

---

## 3. Import transaction design

### 3.1 Restore: stage → preview → commit

```
stage(data:)   size → probe → decode → validate      (writes nothing)
                       ↓
               RestorePreview: counts, categories, warnings
                       ↓  (user reviews; details only on explicit request)
commit(_:)     safety backup → ExportService.restore  (one transaction)
```

**Cancelling is not an operation.** Staging never touches the store, so
abandoning a preview leaves it bit-for-bit identical. This is asserted
literally: a test stages a foreign backup, reveals its details, drops the
preview, and compares a full structural fingerprint of the store before and
after.

**Validation order is cheapest-rejection-first**, so a hostile file is refused
before it can make the app do work:

1. **Size** — 50 MB ceiling, checked on the raw `Data` before the decoder ever
   allocates (A-10).
2. **Shape** — header probe: unknown `documentKind`, wrong kind, unsupported
   schema. A future-format file is told to update the app, not that its file is
   broken.
3. **Envelope agreement** — the envelope's `schemaVersion` must equal the
   payload's, and the declared record counts must match the payload.
4. **Structure** (`BackupValidator`) — record ceiling (250,000), amount
   readability per collection and field, duplicate identifiers, relationship
   resolution.

**Duplicate IDs are rejected outright, never merged.** A restore replaces the
whole store, so "merge them" has no honest meaning: two rows claiming one
identity means the file is wrong, and picking a winner would silently discard
the other. Debt `planID` letters are checked too — the avalanche order, planned
balances, and ledger rows all key on them, so a collision would silently
reroute payments.

**Relationship validation is split by consequence**, and the split is a
deliberate compatibility decision:

- **Errors** — references without which a restored row would be orphaned inside
  its own document: `incomeRules.planVersionID`, `paydayPlanItems.planVersionID`,
  `plannedCardBalances.paydayPlanItemID`, `checkIns.paydayPlanItemID`,
  `checkInCardPayments.checkInID`, `plannedObligationReserves.{paydayPlanItemID,
  obligationID}`, `incomeChanges.scheduleID`.
- **Warnings** — optional links that are nil-able by design (account links,
  forecast provenance, debt-plan-ID references). Rejecting a real backup that
  v0.2.0 restored happily would be a worse failure than importing a row with a
  stale pointer, so these are surfaced in the preview and the row restores with
  the link empty.

**Atomicity** is inherited from `ExportService.restore`, which parses and
constructs every row *before* deleting anything, deletes through the context
(never the store-level batch API, so `rollback()` can bring rows back), and
commits in a single `save()`. A failure anywhere rolls the whole context back.
This is tested against a real failure path rather than an injected one: a
schema-1 document whose per-check reserves break the §7 inverse-R-04 round trip
aborts *after* the delete-and-insert, which is the only point where a restore
can fail with rows already gone. The store is byte-identical afterwards.

**Safety backup.** Written before the destructive replace, and deliberately
**not** deleted on success — a restore that turns out to be the wrong file is
only recoverable if the previous data still exists. It is bounded instead: the
newest three, nothing older than 14 days. A test proves the safety file is
itself restorable, not merely present.

### 3.2 Template apply

`apply(preview:mode:)` only ever **inserts** setup rows and fills settings that
have no value yet. It never deletes, never rewrites an existing amount, and
cannot touch a history table — those have no field in the format to read from.
A test fingerprints every history and plan collection before and after applying
a template with every sensitive category enabled, and requires them identical.

- **merge** — fill the gaps: add what has no counterpart, fill settings that are
  unset. Matching is by name when the template carries one, else by shape
  (role set for accounts; cadence + due day for bills; type + due day for
  debts). Merge *never overwrites*, so a mismatch at worst adds a row the user
  can delete — never data loss.
- **add** — insert everything as new records and read nothing existing.

Every inserted row gets a freshly minted identifier. Templates carry no IDs at
all, so there is nothing to collide with; the outcome reports the remap count
explicitly rather than leaving it implied.

**The honest-inputs consequence (worth reading).** A structure-only template
carries no bill amounts, no take-home, and no installment minimums — and the
app's own `ModelValidation` requires all three to be greater than zero. Rather
than fabricate them, `apply` **skips those rows and names what each one needs**,
and the *preview* says so before the user chooses a mode. Inventing a bill
amount would flow straight into the R-04 per-paycheck reserve math and produce a
plan built on a number nobody entered. Applying a pure structure template to an
empty store therefore adds accounts, credit cards, and reminders, and reports
that the bills, the auto loan, and the pay schedule each need an amount.

---

## 4. The financial report

### 4.1 Structure

Split in three so that "does it say the right thing" and "does it fit on the
page" are separable questions, and only the second needs UIKit:

- `FinancialReport` — the content model. Foundation-only, `Equatable`. A test
  asserts the exact rows a configuration produces without rasterizing anything.
- `FinancialReportBuilder` — store → content.
- `FinancialReportRenderer` — content → PDF.

**Nothing is computed twice.** Scenarios come from
`ScenarioCalculationService`, insights from `ExtraPaymentInsightService`, the
plan from `PlanGenerationService`, the calendar from `CalendarEventService`. A
test asserts the report's printed interest and paycheck count equal the
engine's own values — a report that recomputed its own payoff date would
eventually print a number the app disagrees with, and the printed one is the
one the user would act on.

### 4.2 Sections (user-selectable, all on by default except the last)

| Section | Contents |
| --- | --- |
| Your current inputs | pay schedule, take-home, next payday, posture, floor, allowance, target date, and only those scenario limits the user has actually stated |
| Accounts | name, roles, balance, protected, **derived available**, as-of date, totals; callouts for undated balances and negative available cash |
| Bills and debts | bill table with monthly-equivalent total (via the canonical R-04 rule, not a second one); debt table with type, balance, APR, minimum, due day, total |
| Active plan | name, status, created, calc version, scenario provenance, effective date, immutability, payday count, recorded check-ins |
| Next actions | next payday's income / keep / reserves / to-debt split, per-debt payments, shortfall callout |
| Payoff scenarios | the three cards, two charts, deltas vs Balanced, and a named missing-input callout per uncomputable scenario |
| Extra payment | opt-in; amount, target, interest saved, days saved, principal reduction, per-debt movement |
| Projected payoff | payoff date, paychecks, interest, remaining principal, payoff-order table, minimum-only comparison |
| Next 30/60/90 days | calendar actions per window, clipped to the chosen date range |
| Appendix | assumptions, warnings, full-detail paycheck schedule, and how the report was made |

Every report ends with the estimate disclaimer, at every detail level — an
estimate presented without it is a claim.

**Configuration**: date range (30d–12m), section selection, entity scope
(specific accounts/debts/bills, archived or not), detail level
(summary caps long tables and says so / standard / full adds the paycheck
schedule), optional appendix, and two privacy reductions — replace names with
generic labels, leave out balances.

### 4.3 Charts — one measure per chart, never two axes

The scenario comparison emits **two** charts, not one: interest is dollars and
time is months, and a shared axis would misrepresent whichever measure lost.

The bars use a **sequential ramp — one hue, light → dark by magnitude**
(`#6da7ec → #2a78d6 → #104281`), validated against a white paper surface for
monotone lightness, adjacent-step separation, and light-end contrast. This is
the choice that matters for a document meant to be printed: lightness alone
encodes the ranking, so it survives a grayscale printer. Bars are horizontal
because the categories are words, every bar is directly labeled with its value
(so there are no axis ticks and no legend), the baseline is a single hairline,
and values wear text ink rather than the series color.

### 4.4 Layout

US Letter, 54pt margins, per-page header (title + range) and footer (page N of
M + a standing "estimates" line). Page numbers require the total before the
first page is drawn, so the same composer runs twice against `ReportCanvas` —
once with no graphics context, where every draw call is a no-op and only the
cursor moves, then once for real. There is no separate measuring
implementation to drift out of sync.

Handled: long labels wrap inside their column; tables split across pages and
repeat their header; a section heading will not be left orphaned at the foot of
a page; zero, negative, and missing states print explicitly (a negative
available balance is marked in the attention ink *and* carries a titled
callout, so meaning never rests on color); empty sections print "nothing here"
rather than vanishing.

### 4.5 File lifecycle (A-11)

`PortableFileStore` owns it. Generated files live in the app's own temporary
container (not Documents — the v0.2.0 restore path wrote its rollback backup
into Documents, where it stayed forever), are written with
`.completeFileProtection`, and leave only through a share sheet the user taps.
Reports are purged when the report screen closes (`onDisappear`) and again on
cold launch; backups, templates, and CSVs are purged on cold launch; safety
backups survive relaunch and are pruned by count and age.

---

## 5. Changed files

**New — services**

- `PortableDocument.swift` — envelope, kinds, A-10 limits, integrity, probe, error taxonomy.
- `PortableFileStore.swift` — generated-file directories, A-11 purge, safety-backup pruning.
- `BackupPortingService.swift` — `BackupPorting`, `RestorePreview` / `RestoreDetails` / `RestoreOutcome`, and `BackupValidator`.
- `TemplateImportExportService.swift` — `TemplatePorting`, `TemplatePayload`, sensitive categories, merge/add apply.
- `FinancialReport.swift` — `ReportConfiguration` and the content model.
- `FinancialReportBuilder.swift` — store → content, including the label mask.
- `FinancialReportRenderer.swift` — content → PDF.
- `FinancialReportService.swift` — `ReportGenerating` and the report lifecycle.
- `ScenarioDefinitionBuilder.swift` — the single store → `StoredScenarioDefinition` mapping (see §7).

**Changed — services**

- `ExportService.swift` — export schema 3 with the envelope; reads 1/2/3; schema-3 DTO fields; deterministic collection ordering; `ExportError.decimalParse(raw)` replaced (see §6).

**New — UI**

- `Features/Settings/BackupRestoreViews.swift` — Create JSON Backup, Restore JSON Backup, Export CSV Files.
- `Features/Settings/TemplateViews.swift` — Export Template, Import Template.
- `Features/Settings/FinancialReportView.swift` — Generate Financial Report.

**Changed — UI**

- `Features/Settings/SettingsView.swift` — **Back Up & Restore** and **Reports** groups replace the single "Backup & export" row; the superseded `ExportView` is removed. Deliberately the smallest possible diff in a file shared with Agent 4.
- `App/RootView.swift` — cold-launch `PortableFileStore.purgeTransient()`.

**Changed — merge repair**

- `Services/PlanningDTO.swift` — removed duplicate `StoredScenarioDefinition` / `StoredExtraPayment` declarations (see §7.1).

**Tests**

- New: `PortabilityFixtures.swift`, `BackupPortingTests.swift` (21),
  `TemplatePortingTests.swift` (17), `FinancialReportTests.swift` (22),
  `FinancialReportVisualQATests.swift` (1).
- Updated: `ExportCompatibilityTests.swift`, `ExportServiceTests.swift`
  (pinned export schema 2 and the old error type), `PaydayPlaybookUITests.swift`
  (new Settings IA + three new cases).

---

## 6. Security and privacy notes

1. **Nothing logs.** No `print`, `os_log`, `NSLog`, or `dump` in any file added
   here — verified by grep. A rendering trace would put the user's whole
   financial position in the device console.
2. **Imported JSON is never executed.** Every read is `Decodable` into a fixed
   typed shape. No `NSKeyedUnarchiver`, no dynamic dispatch on file contents,
   no expression evaluation. Unknown keys are ignored, never interpreted.
3. **An existing leak was fixed.** `ExportService.ExportError.decimalParse(raw)`
   put a raw money string into a user-visible error message — "The backup
   contains an invalid amount: 4183.62" is a financial-data leak dressed as
   diagnostics, and error text reaches screenshots and bug reports. It is
   replaced by `amountUnreadable(collection:field:)`, which names *where* and
   never *what*. A test asserts the bad value does not appear in the message.
   Decoding failures likewise report a coding path, never field contents.
4. **The restore preview is redacted by construction.** The staged payload is
   `fileprivate`; a view cannot reach a balance by accident. It has to call
   `revealDetails()`, which exists so that showing real values is a deliberate,
   auditable act. The test does not take this on faith: it searches everything
   the preview would render for every amount and label the fixture store holds.
5. **Report masking is a whole-document pass.** Masking table columns is not
   enough — the engine writes sentences like "Enter *<debt>*'s required monthly
   payment", and scenario, shortfall, warning, and assumption prose all carry
   names the user typed. The mask is applied once over the finished content
   rather than at each of two dozen sites, because a privacy control that
   depends on every future call site remembering it will eventually be
   forgotten. Substring replacement over-masks rather than under-masks by
   design. **This was caught by a test, not by review** — the first
   implementation masked the tables and printed the names in the paragraph
   underneath.
6. **PDF metadata carries no user data** — a generic title and creator only.
   Metadata travels with the file and is read by every viewer and indexer.
7. **Files stay local.** Nothing is uploaded, ever. Backups, templates, and
   reports leave the device only through a share sheet the user taps, and the
   warning that a JSON backup contains readable financial data sits on the
   screen that writes the file, not a level away.
8. **Fixtures are fictional.** `PortabilityFixtures` invents round balances, a
   first payday in 2054, and placeholder names ("Blue card", "Everyday
   checking", "Housing"). Nothing here derives from anything real.

---

## 7. Key decisions and cross-agent findings

### 7.1 The merge produced two incompatible `StoredScenarioDefinition` types — resolved

Merging Agent 2 (`6029107`) and Agent 3 (`46348b2`) produced **duplicate
declarations** of `StoredScenarioDefinition` and `StoredExtraPayment` in
`PlanningDTO.swift`: the exact "duplicated bridges silently disagree" hazard the
v0.2.0 retro pinned, except here it was a hard compile error rather than a
silent disagreement. The whole tree failed to build.

Agent 3's pair matches MVP_LAYOUT §6 field for field. Agent 2's pair invented a
different shape (`debtID` / `startingSequence` / `occurrences`; `name` /
`baselinePlanVersionID` / nested `input`) and was **referenced by nothing**
outside its own declaration and Codable conformance — Agent 3's is what
`ScenarioCalculationService`, `ExtraPaymentInsightService`,
`PlanGenerationService`, and their tests all use. Agent 1's contract makes the
§6 names binding and says explicitly: do not mint alternatives.

I removed Agent 2's non-conforming duplicates in the merge commit rather than on
either agent's branch. **Agent 7 will hit this at merge and should expect the
resolution to be already made here.** The dead code was never called, so nothing
regressed; the full suite passing on the merged tree is the evidence.

### 7.2 No store → scenario-definitions mapping existed

The report needs the three-scenario comparison, which needs
`[StoredScenarioDefinition]` built from the user's profile. Agent 3 (correctly)
takes definitions as given; Agent 4's scenario screen would otherwise build its
own. Two independent mappings would produce a report that contradicts the screen
it was generated from.

I added **`ScenarioDefinitionBuilder`** as the single mapping, deliberately
named and documented as such. **Handoff to Agent 4: use it; do not write a
second one.** It maps a zero-valued profile constraint to `nil` (zero is the
storage default, not an answer) and leaves `preferredFloor` / `preferredAllowance`
nil so the snapshot's own saved values are used rather than giving one number
two sources.

### 7.3 Exports were not order-stable — fixed

`FetchDescriptor` with no sort returns rows in store order, which differs
between a store the user built up and the same data after a restore. Two
exports of identical data therefore differed, so a user diffing yesterday's
backup against today's saw churn that meant nothing — and a round-trip test
could not compare documents at all. `buildBackup` now sorts every collection by
`id`. The encoder already used `.sortedKeys`, so this finishes a job that was
half done.

### 7.4 A pruning bug the tests caught

`pruneSafetyBackups` originally took the injected `DateProviding`. File
modification times come from the filesystem, which knows only the real clock, so
comparing them against a fixed test date (2054) measured the gap between two
different clocks and deleted the file it had just written. It now uses the wall
clock, documented at both the call site and the definition: the injected
provider governs dates the *user* sees, not filesystem housekeeping.

### 7.5 Smaller calls

- **CSV exports kept**, under Back Up & Restore rather than Reports. F-14 still
  binds and the layout says CSVs remain; putting them under Reports would
  undercut V3-11's whole point, which is that raw data is not a report.
- **Relationship validation split by consequence** (§3.1) rather than made
  uniformly strict, to keep v1/v2 imports alive.
- **Restore screens split per action.** Backing up and replacing everything you
  own are not the same kind of decision and should not sit two rows apart under
  one heading.

---

## 8. Tests

| Suite | Count | Covers |
| --- | --- | --- |
| `BackupPortingTests` | 21 | T-12: envelope shape, probe routing, v3 round trip incl. every schema-3 field, byte-stable re-export, v1/v2 import + upgrade stamping, newer-schema rejection, corrupted / headerless / truncated files, wrong and unknown document kind, oversize, duplicate IDs, dangling required references, tampered counts, unreadable amounts, preview redaction, explicit reveal, staging non-mutation, failed-commit rollback, cancel, safety backup + its restorability, pruning |
| `TemplatePortingTests` | 17 | T-13: field-by-field default exclusion, byte-level absence of every fixture value and label, allow-list key set, opt-in categories and their warnings, preview reporting, backup↔template cross-rejection both ways, older/newer formats, tampered counts, structure-only apply with no invented amounts, full apply, merge gap-filling, merge never overwriting, income never overwritten |
| `FinancialReportTests` | 22 | T-14: every contracted section, engine agreement, three scenarios + two charts, named missing inputs, empty store, negative available cash, section selection, summary capping, entity scope, privacy masking, range clipping, opt-in extra payment, full-detail appendix, multi-page with headers and correct page numbers at every detail level, long-label wrapping, chart ranking, all-zero chart, metadata, temp-file lifecycle, cold-launch purge, report generation never writing to the store |
| `FinancialReportVisualQATests` | 1 | six representative reports rendered; per-character bounds checked against the printable area; every page numbered; PDFs and per-page PNGs exported for inspection |
| `PaydayPlaybookUITests` (added/updated) | 4 | backup screen + its warning, CSV export, report → PDF, template export defaulting to structure-only |

**Results:** unit **442/442**, UI **22/22** (dedicated simulator,
`-parallel-testing-enabled NO`, per `TESTING.md`). Three pre-existing export
tests were updated because they pinned export schema 2 and the old error type;
both changes are intended consequences of V3-09, and the assertions were
strengthened rather than deleted.

---

## 9. Visual QA

Six reports were rendered and **looked at**, not merely asserted:

| Sample | Pages | What it exercises |
| --- | --- | --- |
| `01-full-detail` | 7 | every section, both charts, extra-payment insight, full paycheck schedule |
| `02-summary` | 5 | capped tables with truncation notes |
| `03-masked` | 6 | generic labels, balance columns removed entirely rather than blanked |
| `04-long-labels` | 6 | a 60-character debt name and a long bill name wrapping in-column |
| `05-empty` | 2 | every section in its "nothing here" state |
| `06-negative-and-missing` | 4 | overdrawn account, protected > balance, undated balance, unstated constraints |

Findings and fixes:

- **Orphaned subheading** — "Payments on this payday" was stranded at the foot
  of a page with its table overleaf. The subheading now reserves room for the
  shape that follows it. Confirmed fixed by re-rendering.
- Confirmed by eye: the sequential ramp reads correctly light → dark; bar
  lengths are proportional; direct labels sit in an aligned column; masked
  reports drop balance columns rather than blanking them; empty states read as
  plain language in a tinted box; headers and page numbers are on every page.

A machine check backs up the eye: every glyph's bounding box on every page of
every sample is asserted to fall inside the printable area, which catches the
overflow a screenshot shows instantly and a content test never sees.

Reproduce with:

```
TEST_RUNNER_PP_QA_PDF_DIR=/some/dir xcodebuild … \
  test -only-testing:PaydayPlaybookTests/FinancialReportVisualQATests
```

Without the variable the export is skipped and only the assertions run, so CI
never depends on a path. The PDFs and PNGs are **not** committed — they are
generated from fictional fixtures, but a report file in the repository is
exactly the kind of artifact that later gets mistaken for real data.

---

## 10. Risks and open items

1. **`PlanContract.currentCalculationVersion` is still 2.** The envelope stamps
   it, so schema-3 backups currently record `calculationVersion: 2`. Agent 1's
   contract mandates calc 3 for the release; whoever flips that constant makes
   the envelope correct for free. Nothing in the read path gates on it.
2. **Agent 4 must reuse `ScenarioDefinitionBuilder`** (§7.2) rather than build
   its own store → definitions mapping.
3. **`SettingsView.swift` is shared with Agent 4.** My diff is one section
   replacement plus the removal of the superseded `ExportView`; a conflict is
   likely if Agent 4 also edits the section list.
4. **Substring-based name masking can over-mask** — a debt literally named
   "Card" would rewrite the word "Card" elsewhere in the prose. Deliberate: the
   error direction is safe. A structured redaction (engine notes carrying entity
   IDs instead of interpolated names) would be the real fix and is a reasonable
   v0.4 item.
5. **Structure-only templates cannot create bills, installment debts, or a pay
   schedule** (§3.2) because the model requires amounts the template
   deliberately omits. This is the honest behavior, and the preview says so up
   front, but it does make a pure structure template less useful than it sounds.
   Worth a product decision before alpha copy is finalized.
6. **Device-only checks remain**: share-sheet behavior, the system file importer
   against a real Files provider, and PDF rendering on device hardware. All
   three are simulator-verified only, and `TESTING.md` already gates them at
   distribution rather than merge.
7. **Report generation is synchronous on the main thread.** A full-detail report
   over the fixture store renders in well under a second, but it shares the
   known main-thread analysis cost with the scenario calculators. The screen
   shows a progress indicator; an off-main-actor refactor stays out of scope.
8. **The 50 MB / 250,000-record limits are untested at scale** — the oversize
   test uses a synthetic buffer rather than a genuinely large document, which
   verifies the guard without verifying performance near it.

---

## 11. Handoff

- **Agent 7 (integration):** expect the §7.1 duplicate-DTO resolution to be
  already applied in this branch's merge commit `970ba66` — do not re-introduce
  Agent 2's variants when merging in order. The V3-09/10/11 gates are covered by
  the three new suites; the "PDF report visually verified" gate has rendered
  evidence described in §9 and reproducible via the documented command. Three
  pre-existing export tests were legitimately updated for the format bump.
- **Agent 4:** `ScenarioDefinitionBuilder` is the scenario-definitions mapping;
  `SettingsView.swift` is shared — coordinate the section list.

## 12. Commits

On `feature/v0.3-portability-reports`:

- `970ba66` — merge of Agent 3's `46348b2` into Agent 2's `6029107` (one
  comment-only conflict, resolved).
- **`1548c00`** — feat(v0.3.0): versioned backups, structure-only templates, and
  PDF reports (25 files).
- (+ one follow-up commit recording these hashes here, as Agents 1 and 3 did.)

Validation at `1548c00`: unit suite **442/442 green**; UI suite **22/22 green**
on a dedicated simulator (`pp-a6-ui`) with `-parallel-testing-enabled NO`. The
branch is local only — no v0.3 branch has been pushed to `origin` by any agent,
and this one follows that convention and waits for the integration owner.

Build note, confirming Agent 1's: `-derivedDataPath` must point **outside**
`~/Documents` on this machine or CodeSign fails on file-provider xattrs.
