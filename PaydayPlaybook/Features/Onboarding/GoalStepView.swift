import SwiftUI
import SwiftData

/// Step 2 — goal, payoff posture, protected cash floor, and allowance cap
/// (§4.2/§4.6; V2-02, V2-08, V2-09). Also where the app explains, once and
/// plainly, why it recommends the avalanche order.
struct GoalStepView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appEnvironment: AppEnvironment

    let onContinue: () -> Void
    let onBack: () -> Void

    @State private var goalText = ""
    @State private var hasTargetDate = false
    @State private var targetDate = Date()
    @State private var posture: PayoffPosture = .steady
    @State private var protectedFloor: Decimal?
    @State private var allowanceCap: Decimal?
    /// Suggestions only overwrite fields the user hasn't set themselves.
    @State private var floorTouched = false
    @State private var allowanceTouched = false
    /// The last programmatically applied suggestions. `onChange` fires for
    /// those writes too (a render pass after `applySuggestions` returns), so
    /// "did the user touch this?" is decided by comparing the new value
    /// against the suggestion just applied — not by the change event alone.
    /// Without this, the first suggestion marked both fields touched and
    /// every later posture switch left stale defaults on screen (V4-02).
    @State private var suggestedFloor: Decimal?
    @State private var suggestedAllowance: Decimal?
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        OnboardingScaffold(
            title: "What are you working toward?",
            subtitle: "This shapes the words the app uses and a few starting suggestions. It never changes the math.",
            continueEnabled: isValid,
            continueIdentifier: "onboarding.goalContinue",
            onBack: onBack,
            onContinue: save
        ) {
            SetupField(
                title: "Your goal",
                requirement: .optional,
                help: "Something to see on the dashboard — \"debt-free before the wedding\"."
            ) {
                TextField("Optional", text: $goalText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("goal.text")
            }

            SetupField(
                title: "Target debt-free date",
                requirement: .optional,
                help: "If you have a date in mind, the app shows how far off the plan is. It never speeds up the plan on its own."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Set a target date", isOn: $hasTargetDate)
                        .frame(minHeight: 44)
                    if hasTargetDate {
                        DatePicker(
                            "Target date",
                            selection: $targetDate,
                            in: Date()...,
                            displayedComponents: .date
                        )
                        .frame(minHeight: 44)
                    }
                }
            }

            postureSection

            avalancheExplainer

            SetupMoneyField(
                title: "Protected cash floor",
                value: $protectedFloor,
                requirement: .required,
                help: "The app will never plan your spending account below this. It tops the floor back up before sending anything extra to debt.",
                error: floorError,
                fieldIdentifier: "goal.floor"
            )
            .onChange(of: protectedFloor) { _, newValue in
                if newValue != suggestedFloor { floorTouched = true }
            }

            SetupMoneyField(
                title: "Allowance per paycheck",
                value: $allowanceCap,
                requirement: .required,
                help: "This is available, not spent. We'll never count it as spent unless you tell us.",
                error: allowanceError,
                fieldIdentifier: "goal.allowance"
            )
            .onChange(of: allowanceCap) { _, newValue in
                if newValue != suggestedAllowance { allowanceTouched = true }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            load()
        }
    }

    private var postureSection: some View {
        SetupField(
            title: "How hard do you want to push?",
            requirement: .required,
            help: "This picks your starting floor and allowance, and the tone of the app's copy. You can change both numbers below."
        ) {
            VStack(spacing: 8) {
                ForEach(PayoffPosture.allCases) { option in
                    Button {
                        posture = option
                        applySuggestions(for: option)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: posture == option ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.displayName)
                                    .font(.body.weight(.medium))
                                Text(Self.postureDetail(option))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(option.displayName). \(Self.postureDetail(option))")
                    .accessibilityAddTraits(posture == option ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("goal.posture.\(option.rawValue)")
                }
            }
        }
    }

    private var avalancheExplainer: some View {
        SetupExplainer(
            text: "Your plan pays every minimum first, then sends everything left to the debt with the highest interest rate — the avalanche order. Of the common approaches, it costs the least interest and gets you out fastest.",
            systemImage: "arrow.down.right.circle"
        )
    }

    static func postureDetail(_ posture: PayoffPosture) -> String {
        switch posture {
        case .fullThrottle: return "Every spare dollar attacks debt. Smaller cushion, faster finish."
        case .steady: return "Strong payments with breathing room. A balanced starting point."
        case .cushionFirst: return "Build the cash floor first, then push hard on debt."
        }
    }

    /// R-14 posture suggestion table — editable defaults, never enforced.
    static func suggestedDefaults(for posture: PayoffPosture) -> (floor: Decimal, allowance: Decimal) {
        switch posture {
        case .fullThrottle: return (Decimal(string: "500.00")!, Decimal(string: "150.00")!)
        case .steady: return (Decimal(string: "1000.00")!, Decimal(string: "300.00")!)
        case .cushionFirst: return (Decimal(string: "2000.00")!, Decimal(string: "300.00")!)
        }
    }

    /// Applies the R-14 suggestions to fields the user hasn't typed into —
    /// a suggestion never overwrites a number the user entered themselves,
    /// and switching posture keeps updating untouched fields.
    private func applySuggestions(for posture: PayoffPosture) {
        let suggestion = Self.suggestedDefaults(for: posture)
        if !floorTouched {
            suggestedFloor = suggestion.floor
            protectedFloor = suggestion.floor
        }
        if !allowanceTouched {
            suggestedAllowance = suggestion.allowance
            allowanceCap = suggestion.allowance
        }
    }

    // MARK: - Validation

    private var floorError: String? {
        guard let protectedFloor else { return nil }
        return protectedFloor < 0 ? "The floor can't be negative." : nil
    }

    private var allowanceError: String? {
        guard let allowanceCap else { return nil }
        return allowanceCap < 0 ? "The allowance can't be negative." : nil
    }

    private var isValid: Bool {
        guard let protectedFloor, let allowanceCap else { return false }
        return protectedFloor >= 0 && allowanceCap >= 0
    }

    // MARK: - Persistence

    private func load() {
        guard let profile = try? GoalProfileRepository(context: modelContext)
            .profile(now: appEnvironment.dateProvider.now) else { return }
        goalText = profile.goalText ?? ""
        hasTargetDate = profile.targetDebtFreeDate != nil
        targetDate = profile.targetDebtFreeDate ?? appEnvironment.dateProvider.now
        posture = profile.posture
        // A saved profile has real values; a fresh one starts from the
        // posture suggestion so the field is never blank-and-required.
        if profile.onboardingCompletedAt != nil || profile.updatedAt != profile.createdAt {
            protectedFloor = profile.protectedFloor
            allowanceCap = profile.allowanceCap
            floorTouched = true
            allowanceTouched = true
        } else {
            applySuggestions(for: posture)
        }
    }

    private func save() {
        do {
            try GoalProfileRepository(context: modelContext).save(
                goalText: goalText,
                targetDebtFreeDate: hasTargetDate ? targetDate : nil,
                posture: posture,
                protectedFloor: protectedFloor ?? .zero,
                allowanceCap: allowanceCap ?? .zero,
                now: appEnvironment.dateProvider.now
            )
            error = nil
            onContinue()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
