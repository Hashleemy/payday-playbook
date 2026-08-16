import SwiftUI
import SwiftData

/// Resumable first-run setup (V2-01). One question at a time, every step
/// writing real rows as it goes, so an interruption at any point resumes
/// exactly where the user left off with nothing lost.
///
/// Step order follows the v0.2.0 onboarding mission: welcome → goal →
/// accounts → debts → income → obligations → reminders preview → review and
/// generate. (MVP_LAYOUT §4's table orders income/obligations/floor before
/// debts; the deviation is recorded in the Agent 4 report.)
struct OnboardingFlowView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var notificationScheduler: NotificationScheduler

    @State private var step: OnboardingStep = .welcome
    @State private var didResume = false
    @State private var loadedProgress = false
    @State private var stepError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if didResume {
                    ResumeBanner { didResume = false }
                }
                stepContent
            }
            .navigationTitle(step.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step.showsProgress {
                    ToolbarItem(placement: .principal) {
                        OnboardingProgressHeader(step: step)
                    }
                }
            }
        }
        .onAppear {
            guard !loadedProgress else { return }
            loadedProgress = true
            restoreProgress()
        }
        .alert(
            "Couldn't save that step",
            isPresented: Binding(get: { stepError != nil }, set: { if !$0 { stepError = nil } })
        ) {
            Button("OK", role: .cancel) { stepError = nil }
        } message: {
            Text(stepError ?? "")
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .none, .welcome:
            WelcomeStepView(onContinue: { advance(from: .welcome) })
        case .goals:
            GoalStepView(
                onContinue: { advance(from: .goals) },
                onBack: { step = .welcome }
            )
        case .accounts:
            AccountsStepView(
                onContinue: { advance(from: .accounts) },
                onBack: { step = .goals }
            )
        case .debts:
            DebtsStepView(
                onContinue: { advance(from: .debts) },
                onBack: { step = .accounts }
            )
        case .income:
            IncomeStepView(
                onContinue: { advance(from: .income) },
                onBack: { step = .debts }
            )
        case .obligations:
            ObligationsStepView(
                onContinue: { advance(from: .obligations) },
                onBack: { step = .income }
            )
        case .notifications:
            RemindersStepView(
                onContinue: { advance(from: .notifications) },
                onBack: { step = .obligations }
            )
        case .review, .finished:
            ReviewStepView(
                onBack: { step = .notifications },
                onFinish: finish
            )
        case .billsAndDebts:
            // Declared in the schema but not yet in `OnboardingStep.flowOrder`,
            // so nothing can route here until the combined step is built
            // (V3-01, onboarding owner). Falling back to the existing debts
            // step keeps the flow traversable if it ever is reached.
            DebtsStepView(
                onContinue: { advance(from: .debts) },
                onBack: { step = .accounts }
            )
        }
    }

    // MARK: - Progress

    private func restoreProgress() {
        do {
            let service = OnboardingProgressService(
                context: modelContext, dateProvider: appEnvironment.dateProvider
            )
            let resume = try service.resumeStep()
            step = resume == .none ? .welcome : resume
            // "Picking up where you left off" only when there is genuinely
            // something to pick up (§4.0).
            didResume = resume.sortIndex > OnboardingStep.welcome.sortIndex
        } catch {
            step = .welcome
        }
    }

    /// Records the completed step and moves on. The row write already
    /// happened inside the step view — this only advances position, so a
    /// crash between the two never loses an answer.
    private func advance(from completed: OnboardingStep) {
        didResume = false
        do {
            try OnboardingProgressService(
                context: modelContext, dateProvider: appEnvironment.dateProvider
            ).markStepCompleted(completed)
        } catch {
            stepError = error.localizedDescription
        }
        step = completed.next
    }

    // MARK: - Finish

    private func finish() {
        scheduleReminders()
    }

    private func scheduleReminders() {
        let context = modelContext
        let dateProvider = appEnvironment.dateProvider
        Task {
            await notificationScheduler.rescheduleAll(context: context, dateProvider: dateProvider)
        }
    }
}

// MARK: - Chrome

/// "Picking up where you left off" (§4.0). Dismissible, never blocking.
private struct ResumeBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.forward.circle")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Picking up where you left off.")
                .font(.footnote)
            Spacer(minLength: 8)
            Button("Dismiss", action: onDismiss)
                .font(.footnote)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding.resumeBanner")
    }
}

private struct OnboardingProgressHeader: View {
    let step: OnboardingStep

    var body: some View {
        VStack(spacing: 2) {
            Text(step.progressLabel)
                .font(.caption.weight(.medium))
            ProgressView(value: step.progressFraction)
                .frame(maxWidth: 160)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(step.progressLabel)
    }
}

/// Shared step chrome: scrolling content plus a pinned Back/Continue bar.
/// `Back` is always available after the first step and never destroys data.
struct OnboardingScaffold<Content: View>: View {
    let title: String
    var subtitle: String?
    var continueTitle = "Continue"
    var continueEnabled = true
    var continueIdentifier: String
    var onBack: (() -> Void)?
    let onContinue: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                content
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                if let onBack {
                    Button("Back", action: onBack)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("onboarding.back")
                }
                Button(continueTitle, action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(!continueEnabled)
                    .accessibilityIdentifier(continueIdentifier)
            }
            .padding()
            .background(.bar)
        }
    }
}

// MARK: - Step metadata

extension OnboardingStep {
    /// The steps the user actually sees, in order.
    static var userFacing: [OnboardingStep] {
        [.welcome, .goals, .accounts, .debts, .income, .obligations, .notifications, .review]
    }

    var displayIndex: Int? {
        Self.userFacing.firstIndex(of: self).map { $0 + 1 }
    }

    var showsProgress: Bool {
        self != .welcome && self != .none && displayIndex != nil
    }

    var progressLabel: String {
        guard let index = displayIndex else { return "Setup" }
        return "Step \(index) of \(Self.userFacing.count)"
    }

    var progressFraction: Double {
        guard let index = displayIndex else { return 1 }
        return Double(index) / Double(Self.userFacing.count)
    }

    var navigationTitle: String {
        switch self {
        case .none, .welcome: return ""
        case .goals: return "Your goal"
        case .accounts: return "Checking accounts"
        case .debts: return "Your debts"
        case .income: return "Income"
        case .obligations: return "Essential bills"
        case .notifications: return "Dates & reminders"
        case .review, .finished: return "Review"
        case .billsAndDebts: return "Bills & debts"
        }
    }
}
