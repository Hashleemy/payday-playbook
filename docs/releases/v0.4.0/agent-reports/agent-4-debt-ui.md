# Agent 4 — Debt UI Correctness & Accessibility report (v0.4.0)

- **Role:** V4-04 (correct credit utilization, one canonical calculation) and V4-05
  (legible primary actions) for v0.4.0-alpha.1.
- **Branch:** `feature/v0.4-debt-ui`, based on the contract commit `b71e193`
  (verified clean before work began; Wave 2 has not landed on this branch, so the
  engine's inline utilization ratio was still present and its routing fell to this
  agent under the plan's "one sanctioned mechanical edit" clause).
- **Date:** 2026-08-19.

This report contains no personal financial values (V3-12/V3-13, permanent). Every
figure below is a fictional fixture value.

## 1. Utilization root cause (Mission A)

**The "0% of limit" defect is reproduced, root-caused, and pinned by regression
test.** It was not a data or engine defect — the stored ratio was always correct.
The badge (and three sibling call sites) formatted the percent as:

```swift
let percent = (utilization * 100) as NSDecimalNumber
return "\(Int(truncating: percent))% of limit"
```

`Int(truncating:)` reads `NSDecimalNumber`'s integer accessor, which garbles any
`Decimal` carrying a full-width mantissa. A terminating ratio survives it —
`850 ÷ 1000 = 0.85` printed 85% — but **any non-terminating balance ÷ limit
division produces a 38-digit mantissa, and the accessor returns garbage, most
often 0**. Verified empirically (macOS Foundation, same code path):

| Input (fictional) | Ratio | `Int(truncating:)` result |
| --- | --- | --- |
| 850 ÷ 1000 | 0.85 | 85 ✓ |
| 948.27 ÷ 950.00 | 0.99817894…(38 digits) | **0** ✗ |
| 933.10 ÷ 935.00 | 0.99796791… | **0** ✗ |
| 2847.99 ÷ 2900 | 0.98206551… | **0** ✗ |
| 5 ÷ 1000 | 0.005 | **0** ✗ (real sub-1% truncated to a false 0%) |

Real-world balances near a limit essentially always divide non-terminating, which
is exactly why the nonsense clustered on **cards close to their limits** — and why
the level (computed from the correct raw ratio) could say "needs attention" beside
a percentage reading "0%": the warning and the number came from two different
transformations of the same value. Round-number test fixtures divide terminating,
which is why unit tests never caught it.

Secondary defect closed in the same pass: `PlanViewDataLoader` silently substituted
`startingBalance` for every debt whenever `debtBalances()` threw, rendering stale
balances — and utilization computed from them — as if current. It now surfaces a
calm failure note on the Recommended-order card, shows starting balances labeled by
that note, and claims **no** utilization for any non-derived balance.

## 2. Canonical formula location

- **Ratio:** `UtilizationMath.utilization(balance:limit:)`
  (`PaydayPlaybook/Support/UtilizationMath.swift`, landed by Agent 1) — pure
  `Decimal`, `nil` unless `limit > 0`, values above 1 legitimate, original
  principal never an input. Unchanged.
- **Thresholds:** `UtilizationMath.informationalThreshold` (0.30) and
  `.attentionThreshold` (0.90) — now consumed by *every* threshold comparison in
  the app (see §3).
- **Display rounding (new):** `UtilizationMath.wholePercentString(_:)` — nearest
  whole percent via `NSDecimalRound(scale: 0, .plain)`, `"<1%"` for non-zero
  ratios under half a percent (never a false 0%), above-limit ratios render past
  100% ("123%"), negative correction/overpayment balances clamp to "0%". The
  rounded `Decimal` is interpolated directly; nothing routes through
  `NSDecimalNumber`'s integer accessors anywhere in the app any more (grep-verified:
  zero occurrences of `Int(truncating:)`/`intValue` in app sources).

## 3. Duplicate calculations removed / consolidated

| Site | Was | Now |
| --- | --- | --- |
| `Components/DebtPresentation.swift` `UtilizationBadge` | `Int(truncating:)` percent; inline `0.9`/`0.3` literals in `UtilizationDisplayLevel` | `wholePercentString`; thresholds from `UtilizationMath` |
| `Features/Debts/DebtsView.swift` row accessibility label | `Int(truncating:)` | `wholePercentString` |
| `Features/Plan/PlanOverviewView.swift` row accessibility label | `Int(truncating:)` | `wholePercentString` |
| `Features/Insights/InsightsView.swift` utilization card headline | `Int(truncating:)` | `wholePercentString` |
| `Features/Today/TodayState.swift` critical-utilization insight | inline `Decimal(string: "0.9")!` | `UtilizationMath.attentionThreshold` |
| `Services/Planning/AvalanchePlanEngine.swift` `CreditUtilization` assembly | inline `current / limit` + inline `0.9`/`0.3` | `UtilizationMath.utilization` + the threshold constants — the plan's one sanctioned mechanical Services/Planning edit; the engine's own 4-place `.plain` rounding is untouched, so stamped outputs are byte-identical (guard semantics identical: helper returns `nil` exactly when the old `limit > 0` guard failed) |
| `Features/Onboarding/DebtsStepView.swift` editor preview (`utilizationPreview`) | inline `(balance / creditLimit) * 100`, `>= 90`/`>= 30` on the percent scale, two-decimal display | `UtilizationMath.utilization` + thresholds + `wholePercentString` (contract-named reimplementation, retired) |
| `Features/Onboarding/DebtsStepView.swift` row (`utilizationText`/`utilizationColor`) | `.rounded2` two-decimal display; inline threshold literals | `wholePercentString` + thresholds |
| `Features/Onboarding/ReviewStepView.swift` all-cards aggregate (`utilizationText`) | inline `(balance / limit) * 100` | `UtilizationMath.utilization` + `wholePercentString` (contract-named reimplementation, retired) |
| `Features/Plan/PlanViewDataLoader.swift` | silent `startingBalance` fallback wearing live utilization | failure surfaced via `PlanViewData.balanceUnavailableReason`; utilization only from genuinely derived balances |

The onboarding edits are strictly mechanical consumption of the canonical helper
(the mission's boundary clause: setup changes only as strictly required to consume
canonical utilization). They are the exact two reimplementations §3.4 names for
retirement. **Note for Agent 7:** if Agent 2's branch edits the same three
onboarding computed properties per its own prompt, the merge will conflict there —
both sides converge on `UtilizationMath`, so resolution is content-trivial; flagging
here per the ownership map.

Display standardization: whole-percent everywhere (was a mix of garbled integers
and two-decimal strings). `DebtAccount.utilization(currentBalance:)` remains the
model convenience forwarding to the canonical math; unknown limits (including
`creditLimitMarkedUnknown`) still return `nil` → no badge, engine level
`.unknown`, never 0%.

## 4. Button-style root cause (Mission B)

**`AccentColor` was one universal deep navy (#1A3C6B) with no dark-appearance
variant.** In Dark Mode every accent-tinted element rendered that navy on
near-black:

- `.buttonStyle(.bordered)` renders its **label** in the tint color — Today's
  "Add Payment" and "View Full Plan" were navy text on a navy-tinted dark wash at
  ~1.6–1.9:1. That is the reported "extremely dark blue labels"; it also made the
  interactive buttons read as disabled.
- `.borderedProminent` filled with navy on a near-black background — the label
  (white) was readable but the button surface itself vanished.
- Plain accent-tinted icons/links across the app had the same ~1.6:1 problem.

Fix, at the shared-component level (no per-screen color literals):

1. **`AccentColor` gains a dark-appearance variant** — light blue
   sRGB(0.478, 0.678, 0.914). Every accent-tinted element app-wide (bordered
   buttons, links, icons, calendar today-marker, badges) becomes legible in Dark
   Mode through the one asset, including screens owned by other agents, with no
   code changes in their files.
2. **New `PrimaryActionLabel` colorset** — white in light, near-navy-black
   sRGB(0.039, 0.102, 0.184) in dark — pairing with the fill so the filled
   button's label stays ≥ 4.5:1 in *both* appearances (white on light-blue would
   have failed at 2.3:1).
3. **`PrimaryActionButtonStyle` refined** (ownership taken per contract):
   accent fill + `PrimaryActionLabel` label; pressed = uniform 15% black dim over
   fill and label together (reads as pressed, stays ≥ 6:1 in both appearances);
   disabled = gray wash + `.secondary` label, unmistakable against the vivid
   enabled fill in either scheme; `minHeight: 44` + full-rect `contentShape`;
   `.body.semibold` scales with Dynamic Type and the label wraps rather than
   clips (`minHeight`, not fixed height; center-aligned multiline).

Measured contrast (WCAG relative luminance, asserted in code by
`PrimaryActionContrastTests`, not just computed here):

| Pair | Light | Dark |
| --- | --- | --- |
| Primary label on fill | ~11.0:1 (white on navy) | ~7.5:1 (near-navy-black on light blue) |
| Accent as text on grouped backgrounds | ~9.8–11:1 | ~7.3–9:1 (was ~1.6:1) |

## 5. Semantic adoptions (primary vs. secondary preserved)

Adopted `.buttonStyle(.primaryAction)` on the primary CTA of each owned screen:

- **Today:** Start/Continue Check-In (`today.checkInButton`), target card's
  **Add Payment**, finish-line card's **View Full Plan**
  (`today.viewPlanButton`), no-plan recovery "Open Settings", "Confirm
  Debt-Free". All are `Button`s/`NavigationLink`s inside `ScrollView` cards, where
  custom button styles apply.
- **Debt detail:** **Add Payment** — converted from a `NavigationLink` list row
  (List rows ignore custom button styles) to a `Button` +
  `navigationDestination(isPresented:)` in its own clear-background section, so it
  reads as the screen's primary action; Update Balance / Edit Debt / What-if stay
  ordinary list rows. The UI test's `app.buttons["Add Payment"]` element and
  behavior are preserved. **Edit-debt Save** adopts the style (and demonstrates
  the distinct disabled state while saving).
- **Plan:** "Save & Activate New Plan Version" (`plan.activateButton`),
  activation confirm (`plan.confirmActivate`), success "Done".

Kept deliberately secondary (`.bordered`, now legible via the accent dark
variant): Today's "Review Completed Check" and "Adjust Phase II Goal", Plan's
"Show all N paychecks". No destructive styles were touched. Not every button
became bright blue: one primary treatment per screen, system styles for the rest.

Out-of-ownership `.borderedProminent`/`.bordered` sites left for their owners
(inventory for Agent 7): `App/RootView.swift:117`; `Features/Ledger/QuickAddSheet.swift`
(Agent 5, contracted); `Features/Onboarding/*` continue buttons (Agent 2 if
taken); `Features/Settings/*`, `Features/Accounts/*`, `Features/CheckIn/*`,
`Features/Scenarios/*`, `Features/PhaseTwo/*`, `Features/Calendar/DueRuleEditorView.swift`,
`Features/Ledger/LedgerListView.swift`. All of these become *readable* in Dark
Mode via the AccentColor dark variant regardless; adopting the semantic style
there is presentation convergence, not a legibility blocker.

## 6. Accessibility changes

- Every changed CTA keeps its accessibility identifier and text label; the debt
  detail's Add Payment gains an `accessibilityHint`.
- VoiceOver utilization strings now speak the same canonical percent the badge
  shows ("using 85% of its limit" — previously the spoken percent was the garbled
  integer, so VoiceOver users heard the defect too).
- The badge retains text-carried meaning ("— needs attention", "— above 30%"),
  never color alone; the plan screen's balance-derivation failure is a worded,
  calm note (no shaming, no red flood).
- Dynamic Type: the style's label wraps at accessibility sizes instead of
  truncating; 44-pt minimum target preserved everywhere (several call sites
  previously hand-rolled `minHeight: 44` — the style now guarantees it).

## 7. Tests and results

New:

- `PaydayPlaybookTests/UtilizationDisplayTests.swift` (10 tests) — the regression
  pin on the defect's exact shape (948.27 ÷ 950.00 → "100%", never "0%"), the
  mission matrix (850/1000 = 85%; fractional ratio precision round-trip; balance
  0 → 0%; missing/zero limit → unknown; over-limit → "123%" + `.critical`;
  "<1%" for small non-zero; negative clamps to 0%; nearest-whole rounding), and
  warnings/badge consuming the same canonical value and thresholds.
- `PaydayPlaybookTests/PrimaryActionContrastTests.swift` (6 tests) — resolves the
  actual asset-catalog colors under light and dark trait collections and asserts
  WCAG AA ≥ 4.5:1 for label-on-fill and accent-as-text on the three system
  grouped/background surfaces in both appearances, plus that the dark variants
  genuinely exist (the exact defect: a universal navy would fail these).

Results: **full unit suite green — 542/542 (526 existing + 16 new), zero
failures** — run per TESTING.md on a dedicated simulator (`PP-A4-debt-ui`,
iPhone 17 Pro, iOS 26.5) with `-derivedDataPath` outside `~/Documents`.
Existing suites touching this surface (`UtilizationMathTests`,
`DebtPresentationTests`, `DebtTypeTests`, `AvalanchePlanEngineTests` incl. the
`CreditUtilization` safety test, `PlanPresentationTests`, `OnboardingSetupTests`,
`ReleaseIntegrationTests`) all pass unmodified — no test was weakened, changed,
or skipped. The UI suite was not run here (no identifier or interaction contract
changed; the debt-detail conversion preserves the tapped element); flagged for
Agent 7's serial UI pass per the merge protocol.

An adversarial multi-lens review (Decimal correctness, SwiftUI behavior,
contract compliance, privacy) was run over the diff before commit; findings and
resolutions: see §9.

## 8. Files changed

Code: `Support/UtilizationMath.swift`, `Components/DebtPresentation.swift`,
`Components/PrimaryActionButton.swift`, `Features/Debts/DebtsView.swift`,
`Features/Today/TodayView.swift`, `Features/Today/TodayState.swift`,
`Features/Insights/InsightsView.swift`, `Features/Plan/PlanOverviewView.swift`,
`Features/Plan/PlanViewData.swift`, `Features/Plan/PlanViewDataLoader.swift`,
`Features/Plan/PlanActivationView.swift`,
`Services/Planning/AvalanchePlanEngine.swift` (sanctioned mechanical edit),
`Features/Onboarding/DebtsStepView.swift`,
`Features/Onboarding/ReviewStepView.swift` (mechanical consolidation only).

Assets: `Assets.xcassets/AccentColor.colorset` (dark variant added),
`Assets.xcassets/PrimaryActionLabel.colorset` (new).

Tests: `PaydayPlaybookTests/UtilizationDisplayTests.swift` (new),
`PaydayPlaybookTests/PrimaryActionContrastTests.swift` (new).

Docs: this report.

## 9. Adversarial review findings

(filled after the review workflow completes)

## 10. Assumptions, risks, handoff

1. **Onboarding overlap (Agent 2).** The three onboarding computed properties I
   consolidated are also named in Agent 2's prompt. Both implementations converge
   on the same helper; a merge conflict there is textual, not semantic.
2. **Engine byte-identity** is argued (identical guard semantics, identical
   rounding, identical stored `creditLimit` value) and covered by the untouched
   `AvalanchePlanEngineTests`/`CalcV3ReductionTests`; Agent 7's calc-version gates
   re-verify on the merged tree.
3. **Whole-percent display** slightly changes onboarding copy (was two-decimal),
   e.g. "35.50% of the limit used" → "36% of the limit used" — deliberate per
   §3.4 ("display rounding is standardized"); no test asserted the old strings.
4. **Dark-appearance accent tunes the whole app**, including screens other agents
   own — that is the point (one asset), but Agent 7's per-screen accessibility
   pass should eyeball dark-mode screens for any spot where light-blue-on-light
   tinted fills (e.g. `accentColor.opacity(0.1)` washes) look different than
   before. Contrast for text is asserted by test; aesthetics are a human check.
5. **Device validation** items (true Dynamic Type at accessibility sizes on
   hardware, VoiceOver sweep) remain on the TESTING.md device checklist as
   standing gates; nothing here has run on hardware.
6. `App/RootView.swift`'s prominent button and remaining founding-vocabulary CTA
   copy elsewhere are out of my ownership; inventoried in §5 for the registry.

## 11. Commit

(filled at commit time)
