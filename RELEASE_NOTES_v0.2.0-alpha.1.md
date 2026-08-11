# Payday Playbook — v0.2.0-alpha.1

**App version 0.2.0 · build 2 · persistence schema 2 · calculation version 2 · backup schema 2**
Prerelease for device testing. Not for general distribution — see *Before you trust this build*.

---

## What this release is

0.1.0 executed one person's debt plan. It was hard-wired to it: six credit cards keyed
"A"–"F", a fixed pair of checking accounts, a car payment and a train pass, and a schedule
that had been computed once and baked in.

0.2.0 makes the app work for whoever is holding the phone. You set it up with your own
accounts, your own debts, and your own paycheck, and the app generates your plan — using
the same avalanche method, the same protected-cash discipline, and the same
paycheck-by-paycheck honesty that the original plan had.

**If you were already using 0.1.x, nothing you have is disturbed.** Your plan, its 23
paydays, your ledger, your check-ins, and your reminders all survive exactly as they were.
You will not be asked to set the app up again.

---

## New

**Guided setup that survives interruption.** Eight steps: what you're working toward and how
hard you want to push, your checking accounts, your debts, your income, your recurring
bills, a preview of your reminders, then review and generate. Every step saves as you go —
if you're interrupted, force-quit, or just put the phone down for three days, you come back
to exactly where you were, with everything you'd already entered still there.

**Your accounts, by name and role.** Up to ten checking accounts, each named by you, each
marked as income, spending, or reserves. One is your default income account.

**Every kind of debt, not just credit cards.** Credit card, personal loan, car note, student
loan, medical debt, or other — each asking for what actually applies to it. Cards ask for a
limit and show your utilization; installment loans track original versus current principal.
If a debt might charge you for paying it off early and you're not sure, say so: the app will
route extra money elsewhere rather than risk a penalty, and ask you to confirm.

**A plan built from your numbers.** Minimums covered first and scheduled against their due
dates, your protected cash floor and recurring bills reserved, your personal allowance set
aside — and then every remaining dollar to your highest-rate debt, rolling straight to the
next one the moment it's cleared. Every paycheck reconciles to the cent.

**A plan screen that explains itself.** The order and why, projected payoff date, interest,
a paycheck-by-paycheck playbook, and — when your inputs support it — what you save versus
paying minimums only. Where the app can't honestly compute something, it says so instead of
guessing.

**Insights.** Interest saved, payoff-date movement, utilization warnings, bill-crunch
warnings, and how your allowance is actually going.

**A calendar for your plan.** Paydays, transfers, reserves, payments, due dates, milestones,
and what you actually recorded — each marked planned, actual, completed, needs-attention, or
reforecast, in words and icons, never colour alone.

**Due dates you control.** Any day 1–31, clamped sensibly in short months. Change one and
the calendar and your reminders update immediately, with no duplicates.

---

## Changed

- **A fresh install no longer arrives pre-loaded with someone else's plan.** It starts with
  setup. The original plan is still available as a clearly-labelled template if you
  specifically want to look at it.
- **Reminders are rescheduled by comparison, not by wiping and rebuilding.** Reminders that
  haven't changed are left alone; changed ones are replaced in place. Upgrading from 0.1.x
  cannot produce two of the same reminder.
- The app version is now 0.2.0. The `1.0` in earlier builds was an untouched Xcode default,
  not a claim that the app was finished.

## Fixed during integration

Three defects that only existed once the separate workstreams were combined:

- The plan shown on the Plan and Today screens is rebuilt from your saved inputs each time
  you look at it. That rebuild used a slightly different code path than the one that saved
  it, so in some cases — reversed twice-monthly pay dates, or a plan viewed some days after
  it was made — **the plan on screen could differ from the plan that was saved**. There is
  now one code path.
- A newly set-up user could see **$2,094.00 shown as their take-home pay** on Today,
  Settings, and the debt-free screen. That is the template user's paycheck; it was a
  fallback that should never have been reachable.
- The payday variance chart on Progress was blank for generated plans.

---

## Before you trust this build

**Local notifications have not been tested on a physical iPhone.** Everything about them is
verified in automated tests — the right reminders, the right times, stable identifiers, no
duplicates, and lock-screen copy that names no amounts — but those tests confirm what the
app *asks iOS for*, not what iOS actually delivers. Real delivery on a locked device,
provisional authorization, the system's 64-pending-request limit, lock-screen rendering,
crossing a real time-zone or daylight-saving boundary, and tapping a notification that
launches the app from cold all still need a device pass. `TESTING.md` lists them as items
1–7.

Other things worth knowing:

- Weekly and biweekly bills don't get a due-date marker or reminder — a day-of-the-month
  can't describe them. Their money is still reserved from every paycheck.
- Quarterly, half-yearly and yearly bills recur from the month you created them; you can't
  yet pin a specific first due date.
- If you change a due date, that item's markers disappear for months *before* the change.
  The app doesn't record what the old date was and won't invent one.
- Debts carried over from 0.1.x have no "original principal" — percent-paid is measured
  from the balance the plan started with, exactly as before. Setup will offer to fill it in.
- Interest is estimated simply: a 365-day year, accrued at each payday. It is not your
  card issuer's statement maths, and real interest will differ. Every plan says so on screen.
- At the very largest text sizes, the main action on Today needs a scroll to reach.

## Privacy, unchanged

Everything stays on your iPhone. No account, no sign-in, no telemetry, no network needed.
The app never asks for bank credentials, full card numbers, CVVs, or your SSN — the only
identifying thing it will store is the last four digits of a card, and only if you choose to
enter them. No financial value is written to system logs in a release build.
