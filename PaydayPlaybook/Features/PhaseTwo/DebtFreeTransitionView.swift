import SwiftUI
import SwiftData

/// Debt-free confirmation, one-time celebration, and Phase II goal setup (F-16).
struct DebtFreeTransitionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var allSettings: [AppSettings]

    enum Stage {
        case confirm
        case celebrate
        case chooseGoal
    }

    @State private var stage: Stage = .confirm
    @State private var selectedGoal: PhaseTwoGoal = .emergencyFund
    @State private var targetAmount: Decimal?
    @State private var celebrationScale = 0.6

    private var releasedPerPaycheck: Decimal {
        // Cash freed per check once cards are gone: income − allowance − reserves.
        guard let plan = (try? PlanSeeder.currentPlan(context: modelContext)) ?? nil else {
            return PlanContract.raisedCardBudget
        }
        let income = (try? ReforecastService.currentIncome(
            context: modelContext,
            on: appEnvironment.dateProvider.now
        )) ?? PlanContract.raisedIncome
        return (income - plan.allowanceCap - plan.totalFixedReservePerCheck).rounded2
    }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .confirm: confirmStage
                case .celebrate: celebrateStage
                case .chooseGoal: goalStage
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                // Already confirmed: jump straight to goal adjustment; the
                // celebration only ever plays once.
                if let settings = allSettings.first, settings.debtFreeConfirmedAt != nil {
                    selectedGoal = settings.phaseTwoGoal ?? .emergencyFund
                    targetAmount = settings.phaseTwoTargetAmount
                    stage = .chooseGoal
                }
            }
        }
    }

    private var confirmStage: some View {
        List {
            Section {
                Text("Every card balance in the app reads $0.00. Confirm that your issuers agree — check each account one last time.")
                    .font(.subheadline)
            }
            Section {
                Button {
                    confirmDebtFree()
                } label: {
                    Text("Yes — I'm debt-free")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    dismiss()
                } label: {
                    Text("Not yet")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Confirm")
    }

    private var celebrateStage: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "party.popper.fill")
                .font(.system(size: 72))
                .foregroundStyle(.mint)
                .scaleEffect(reduceMotion ? 1 : celebrationScale)
                .animation(reduceMotion ? nil : .spring(duration: 0.6, bounce: 0.4), value: celebrationScale)
                .accessibilityHidden(true)
            Text("Debt-free!")
                .font(.largeTitle.bold())
            Text("\(MoneyFormat.string(PlanContract.startingDebtTotal)) of card debt is gone. Every history entry stays saved in the app.")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Text("About \(MoneyFormat.string(releasedPerPaycheck)) per paycheck is now released for what comes next.")
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button {
                stage = .chooseGoal
            } label: {
                Text("Choose the Next Goal")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
        .onAppear { celebrationScale = 1.0 }
    }

    private var goalStage: some View {
        List {
            Section("Phase II — pick one focus") {
                Picker("Goal", selection: $selectedGoal) {
                    ForEach(PhaseTwoGoal.allCases) { goal in
                        Text(goal.displayName).tag(goal)
                    }
                }
                .pickerStyle(.inline)
            }
            Section("Optional target") {
                MoneyField(label: "Target amount", value: $targetAmount)
                Text("Suggested allocation: direct the released \(MoneyFormat.string(releasedPerPaycheck)) per paycheck toward this goal. The app only tracks the goal — it never moves money and this is not investment advice.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button {
                    saveGoal()
                } label: {
                    Text("Start Phase II")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Next goal")
    }

    private func confirmDebtFree() {
        guard let settings = allSettings.first else { return }
        let now = appEnvironment.dateProvider.now
        settings.debtFreeConfirmedAt = now
        // Celebrate exactly once.
        if settings.debtFreeCelebrationShownAt == nil {
            settings.debtFreeCelebrationShownAt = now
            stage = .celebrate
        } else {
            stage = .chooseGoal
        }
        try? modelContext.save()
        try? appEnvironment.milestoneService(context: modelContext).refreshAchievements()
    }

    private func saveGoal() {
        guard let settings = allSettings.first else { return }
        settings.phaseTwoGoal = selectedGoal
        settings.phaseTwoTargetAmount = targetAmount
        try? modelContext.save()
        dismiss()
    }
}

/// Compact Phase II tracker card shown on Today once debt-free is confirmed.
struct PhaseTwoCard: View {
    let settings: AppSettings
    let releasedPerPaycheck: Decimal

    var body: some View {
        DashboardCard(title: "Phase II", systemImage: "flag.2.crossed") {
            VStack(alignment: .leading, spacing: 6) {
                if let goal = settings.phaseTwoGoal {
                    Text("Current goal: \(goal.displayName)")
                        .font(.subheadline.weight(.medium))
                    if let target = settings.phaseTwoTargetAmount {
                        Text("Target: \(MoneyFormat.string(target))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text("Released cash: about \(MoneyFormat.string(releasedPerPaycheck)) per paycheck.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Choose your next goal — emergency fund, car, retirement, Roth IRA, or investing.")
                        .font(.subheadline)
                }
            }
        }
    }
}
