import SwiftUI
import SwiftData

/// Onboarding step 5 — the consolidated Bills & Debts page (V3-08, §4.5).
///
/// Replaces the separate debts and obligations steps with the *same* page the
/// Settings screen shows. Nothing here writes on continue: each editor saves
/// its own row as the user finishes it, which is what makes the step resumable
/// and makes duplicates structurally impossible — an interrupted setup
/// re-reads the store and simply finds the rows already there.
struct BillsAndDebtsStepView: View {
    let onContinue: () -> Void
    let onBack: () -> Void

    @Query private var obligations: [RecurringObligation]
    @Query private var debts: [DebtAccount]

    private var hasAnything: Bool {
        obligations.contains { !$0.isArchived } || debts.contains { !$0.isArchived }
    }

    var body: some View {
        OnboardingScaffold(
            title: "What has to get paid?",
            subtitle: "Your bills and your debts, in one list. Estimates are fine — you can correct anything later, and the plan says which numbers it had to guess.",
            // Having neither is a real answer, and the button says so rather
            // than making the user wonder whether they missed something.
            continueTitle: hasAnything ? "Continue" : "I have none of these",
            continueIdentifier: "onboarding.billsAndDebtsContinue",
            onBack: onBack,
            onContinue: onContinue
        ) {
            BillsAndDebtsView(showsHeading: false, showsReview: true)
        }
    }
}
