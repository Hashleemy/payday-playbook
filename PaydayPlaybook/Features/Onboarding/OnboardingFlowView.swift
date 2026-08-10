import SwiftUI
import SwiftData

/// Four-screen onboarding: welcome, plan confirmation, card labels,
/// notifications. Seeding happens atomically; onboarding completes only
/// after the seed succeeds.
struct OnboardingFlowView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var notificationScheduler: NotificationScheduler

    enum Step {
        case welcome
        case confirmPlan
        case labelCards
        case notifications
    }

    @State private var step: Step = .welcome
    @State private var seedError: String?

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .welcome:
                    WelcomeStep {
                        step = .confirmPlan
                    }
                case .confirmPlan:
                    ConfirmPlanStep(seedError: $seedError) {
                        do {
                            try PlanSeeder.seedIfNeeded(context: modelContext)
                            seedError = nil
                            step = .labelCards
                        } catch {
                            seedError = error.localizedDescription
                        }
                    }
                case .labelCards:
                    LabelCardsStep {
                        step = .notifications
                    }
                case .notifications:
                    NotificationsStep {
                        finishOnboarding()
                    }
                }
            }
        }
    }

    private func finishOnboarding() {
        do {
            // Safety net: guarantee the seed exists even if the user somehow
            // skipped ahead; completion is only recorded after it succeeds.
            try PlanSeeder.seedIfNeeded(context: modelContext)
            let settings = try modelContext.fetch(FetchDescriptor<AppSettings>())
            guard let row = settings.first else { return }
            row.onboardingComplete = true
            try modelContext.save()
            _ = try? appEnvironment.reforecastService(context: modelContext)
                .reforecast(trigger: .initialSeed)
            Task {
                await notificationScheduler.rescheduleAll(
                    context: modelContext,
                    dateProvider: appEnvironment.dateProvider
                )
            }
        } catch {
            seedError = error.localizedDescription
            step = .confirmPlan
        }
    }
}

private struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "checklist")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 48)
                    .accessibilityHidden(true)
                Text("Payday Playbook")
                    .font(.largeTitle.bold())
                Text("Know today's play. Record what happened. See the finish line.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                Text("All of your financial data stays on this iPhone unless you export it yourself. No account, no bank linking, no internet required.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
        }
        .safeAreaInset(edge: .bottom) {
            Button("Load My Plan", action: onContinue)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding()
                .accessibilityIdentifier("onboarding.loadPlan")
        }
    }
}

private struct ConfirmPlanStep: View {
    @Binding var seedError: String?
    let onConfirm: () -> Void

    var body: some View {
        List {
            Section("Your starting position") {
                LabeledContent("Starting card debt") {
                    MoneyText(amount: PlanContract.startingDebtTotal, font: .body.weight(.semibold))
                }
                LabeledContent("Planned paychecks") { Text("\(PlanContract.paydayCount)") }
                LabeledContent("Baseline payoff") {
                    Text(DateMath.mediumString(PlanContract.baselinePayoffDate))
                }
                LabeledContent("Checking 1 cash today") {
                    MoneyText(amount: PlanContract.startingChecking1)
                }
                LabeledContent("Protected floor") {
                    MoneyText(amount: PlanContract.protectedBuffer)
                }
            }
            Section("Two accounts, one play") {
                Label("Checking 1 — flex cash: the protected $1,000 floor plus up to $300 allowance per check. Available, not assumed spent.", systemImage: "1.circle")
                Label("Checking 2 — bills and debt: car, train, minimums, and the avalanche payment. Nothing else comes out of it.", systemImage: "2.circle")
            }
            .font(.subheadline)
            if let seedError {
                Section {
                    Label(seedError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Original Plan v1")
        .safeAreaInset(edge: .bottom) {
            Button("Use Original Plan v1", action: onConfirm)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding()
                .accessibilityIdentifier("onboarding.usePlan")
        }
    }
}

private struct LabelCardsStep: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DebtAccount.priority) private var debts: [DebtAccount]
    let onContinue: () -> Void

    var body: some View {
        List {
            Section {
                Text("Add optional nicknames, due days, and current minimums. You can skip this — everything can be edited later in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(debts) { debt in
                DebtLabelRow(debt: debt)
            }
        }
        .navigationTitle("Label your cards")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button("Continue") {
                    try? modelContext.save()
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("onboarding.cardsContinue")
            }
            .padding()
        }
    }
}

private struct DebtLabelRow: View {
    @Bindable var debt: DebtAccount
    @State private var dueDayText = ""
    @State private var minimumText = ""

    var body: some View {
        Section("Card \(debt.planID) · \(MoneyFormat.string(debt.startingBalance)) · \(aprText)") {
            TextField("Nickname or issuer (optional)", text: $debt.displayName)
            TextField("Last four digits (optional)", text: Binding(
                get: { debt.lastFour ?? "" },
                set: { debt.lastFour = sanitizeLastFour($0) }
            ))
            .keyboardType(.numberPad)
            TextField("Statement due day 1–28 (optional)", text: $dueDayText)
                .keyboardType(.numberPad)
                .onChange(of: dueDayText) { _, newValue in
                    if let day = Int(newValue), (1...28).contains(day) {
                        debt.dueDayOfMonth = day
                    } else if newValue.isEmpty {
                        debt.dueDayOfMonth = nil
                    }
                }
            TextField("Current minimum (optional)", text: $minimumText)
                .keyboardType(.decimalPad)
                .onChange(of: minimumText) { _, newValue in
                    if let amount = MoneyFormat.parse(newValue), !amount.isNegative {
                        debt.minimumAmount = amount
                    } else if newValue.isEmpty {
                        debt.minimumAmount = nil
                    }
                }
        }
        .onAppear {
            dueDayText = debt.dueDayOfMonth.map(String.init) ?? ""
            minimumText = debt.minimumAmount.map(MoneyFormat.editingString) ?? ""
        }
    }

    private var aprText: String {
        let percent = (debt.apr * 100) as NSDecimalNumber
        return "\(percent)% APR"
    }

    private func sanitizeLastFour(_ input: String) -> String? {
        let digits = input.filter(\.isNumber)
        let trimmed = String(digits.prefix(4))
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct NotificationsStep: View {
    @EnvironmentObject private var notificationScheduler: NotificationScheduler
    let onFinish: () -> Void
    @State private var requesting = false

    var body: some View {
        List {
            Section("Stay on the plan") {
                Label("Payday morning: today's play at 8:00 AM", systemImage: "sun.max")
                Label("Payday evening: a nudge at 7:00 PM only if the check-in is unfinished", systemImage: "moon")
                Label("Card due dates: three days ahead and day-of at 9:00 AM", systemImage: "creditcard")
                Label("Weekly summary: Sundays at 6:00 PM", systemImage: "calendar")
            }
            .font(.subheadline)
            Section {
                Text("Notifications are optional and can be changed anytime in Settings. The app works fully without them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Reminders")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button {
                    requesting = true
                    Task {
                        _ = await notificationScheduler.requestAuthorization()
                        requesting = false
                        onFinish()
                    }
                } label: {
                    if requesting {
                        SwiftUI.ProgressView()
                    } else {
                        Text("Enable Reminders")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(requesting)
                .accessibilityIdentifier("onboarding.enableNotifications")

                Button("Not Now", action: onFinish)
                    .accessibilityIdentifier("onboarding.skipNotifications")
            }
            .padding()
        }
    }
}
