# Payday Playbook — Alpha v0.2.0 Multi-Agent Plan

> **Status:** authoritative feature registry for the 0.2.0 minor release.
> *(Edited 2026-08-13 under V3-12: personal financial values and the founding user's name redacted; registry semantics unchanged.)*
> **Provenance:** this file was authored by Agent 1 (Product Contract & SemVer owner)
> because the orchestration referenced it but no copy existed in the repository or its
> history. The V2-01…V2-18 registry below is derived directly from the user's alpha
> feedback (the required scope of the v0.2.0 mission) and is now canonical. Downstream
> agents must treat the IDs, names, and definitions here as fixed; propose changes via
> a report, never by silent edit.

## Release identity

| Item | Value |
| --- | --- |
| App version (SemVer) | **0.2.0** (backward-compatible minor over the 0.1.0 alpha MVP) |
| Prerelease tag | **v0.2.0-alpha.1** — created when the alpha build is cut, not before |
| Baseline being extended | Untagged 0.1.0 alpha MVP (`b0e7443` lineage); recommend retro-tag `v0.1.0` |
| Persistence schema version | 2 (migrates from 1) |
| Calculation version | 2 for newly generated plans; Original Plan v1 stays stamped 1 |
| Backup schema version | 2 (imports version-1 backups) |
| User plan versions | Data, not software: "Original Plan v1", "Plan v1", "Plan v2", … are per-install `PlanVersion` rows and are unrelated to the app version |

See `docs/releases/v0.2.0/VERSIONING.md` for the full versioning contract, and
`CHANGELOG.md` for the Keep-a-Changelog record.

## V2 feature registry (canonical)

Every one of these IDs must appear explicitly in both `soul.md` and `MVP_LAYOUT.md`.
None of them removes or weakens an F-01…F-16 requirement; where behavior changes
(notably F-01 first-launch seeding), the change is recorded as an explicit amendment.

| ID | Feature | One-line definition |
| --- | --- | --- |
| V2-01 | Resumable first-run onboarding | A multi-step guided setup that persists progress after every step and resumes exactly where it left off after interruption, force-quit, or relaunch. |
| V2-02 | Goals and payoff posture | Onboarding asks what the user is working toward and how aggressively they want to pay debt down; answers personalize copy and suggested defaults, never post-generation math. |
| V2-03 | Multiple checking accounts | The user creates 1–10 checking accounts with name, current balance, and role (income / spending / reserves); exactly one is the default income account. |
| V2-04 | Debt type picker | Adding a debt starts from a type: credit card, personal loan, car note / auto loan, student loan, medical debt, or other. |
| V2-05 | Debt-specific inputs | Per-type fields: current balance/principal, original principal, APR, minimum payment, editable due date, card limit with utilization (cards), and extra-principal eligibility. |
| V2-06 | Income setup | Take-home per paycheck, next payday, pay cadence (weekly / biweekly / semimonthly / monthly), receiving income account, and future-dated income changes. |
| V2-07 | Essential recurring obligations | Named recurring must-pay items (rent, car, transit, insurance, …) with amount, cadence, and optional due date; reserved per paycheck by the smoothing rule. |
| V2-08 | Protected cash floor | A configurable never-go-below cash floor on the spending account that the generated plan must respect. |
| V2-09 | Allowance cap | A configurable per-paycheck personal allowance, preserved as available-not-spent. |
| V2-10 | Generated avalanche plan | The engine generates an immutable baseline plan from the user's own inputs: minimums first, then all remaining capacity to the highest-APR eligible debt, minimizing estimated interest and payoff time within the floor/allowance/obligation constraints. |
| V2-11 | Editable due dates drive calendar and notifications | Changing any debt or obligation due date immediately updates calendar events and reschedules local notifications via stable identifiers. |
| V2-12 | Plan calendar | The calendar renders paydays, due dates, milestones, and actual entries for generated plans exactly as it did for the seeded plan. |
| V2-13 | Friendly dashboard | The five-second dashboard generalizes beyond "Checking 1/Checking 2" to the user's named accounts and roles while keeping the calm, action-first layout. |
| V2-14 | Insights | Named, estimate-honest insight cards: interest saved vs. minimums-only, payoff-date delta, utilization alerts, obligation crunch warnings, allowance usage trend. |
| V2-15 | Actual tracking and reforecasting | Check-ins, ledger, balance snapshots, and the reforecast engine work identically for generated plans; planned / actual / reforecast stay separate truths. |
| V2-16 | Current-user migration | A schema 1→2 migration preserves the founding user's exact baseline schedule, history, and check-ins verbatim — without seeding that plan on unrelated fresh installs. |
| V2-17 | Local-only privacy | Everything stays on device; no accounts, no telemetry, and never bank credentials, full card numbers, CVVs, or SSNs. |
| V2-18 | Accessibility, Decimal math, export compatibility | Dynamic Type / VoiceOver / Reduce Motion coverage for all new screens; all money in `Decimal`; version-2 backups restore version-1 files. |

## Agent map

| Agent | Ownership | Depends on |
| --- | --- | --- |
| Agent 1 | Product contract (`soul.md`, `MVP_LAYOUT.md`), SemVer, changelog, this registry | — |
| Downstream agents | Models & migration; onboarding UI; plan-generation engine; calendar/notifications; dashboard/insights; QA | Agent 1's contract |

Downstream agents: read `soul.md`, then `MVP_LAYOUT.md`, then
`docs/releases/v0.2.0/VERSIONING.md`, then any agent reports that have landed in
`docs/releases/v0.2.0/agent-reports/`. Do not implement behavior that contradicts a
V2 or F requirement; if a conflict appears, stop and report it.

## Ground rules for the release

1. **Backward compatible.** A 0.1.x install must upgrade with zero data loss and no
   behavior change to its existing plan, history, or notifications (V2-16).
2. **No de-scoping by silence.** If an agent cannot deliver a V2 item, it must say so
   in its report; the changelog only claims what actually shipped.
3. **The F-contract survives.** F-01…F-16 remain binding as amended in `soul.md`.
4. **Tests before UI** for all money math, migration, and plan generation
   (`MVP_LAYOUT.md` §13 lists the required suites).
