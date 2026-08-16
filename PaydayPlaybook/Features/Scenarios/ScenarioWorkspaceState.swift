import Foundation
import SwiftData

/// The Payoff Scenarios calculator surface (V3-05/V3-06, §8.6).
///
/// Two things this type exists to guarantee:
///
/// 1. **The engine never runs in a view body.** Agent 3 measured three
///    scenarios plus one insight at over a second on an eight-debt plan, and a
///    SwiftUI body can evaluate many times per frame. Everything here is
///    computed once, off the body, and cached against the inputs it was
///    computed from.
/// 2. **Overrides never touch saved data.** The override panel edits a copy of
///    the snapshot. The user's income, cadence, and profile are read; nothing
///    is written until they explicitly apply a scenario.
struct ScenarioWorkspaceState {
    /// What the user may change without editing their saved setup (R-18).
    struct Overrides: Equatable {
        var takeHome: Decimal?
        var cadence: PayCadence?
        var effectiveDate: Date?

        var isActive: Bool {
            takeHome != nil || cadence != nil || effectiveDate != nil
        }

        /// One line naming what is being modelled differently, so a changed
        /// number on a card is never unexplained.
        func summary(baseCadence: PayCadence) -> String? {
            guard isActive else { return nil }
            var parts: [String] = []
            if let takeHome {
                parts.append("take-home \(MoneyFormat.string(takeHome))")
            }
            if let cadence, cadence != baseCadence {
                parts.append("paid \(cadence.displayName.lowercased())")
            }
            if let effectiveDate {
                parts.append("from \(DateFormat.medium(effectiveDate))")
            }
            return parts.isEmpty ? nil : "Modelling " + ListFormat.sentence(parts) + ". Your saved setup is unchanged."
        }
    }

    /// The saved inputs the calculator preloaded, before overrides.
    var baseInput: StoredPlanInput?
    var savedTakeHome: Decimal = .zero
    var savedCadence: PayCadence = .biweekly
    var overrides = Overrides()
    var results: [ScenarioResult] = []
    var definitions: [StoredScenarioDefinition] = []
    /// Set when the snapshot cannot reach the engine at all — a missing pay
    /// day, for instance, which is actionable rather than a card.
    var blockingError: String?

    var isReady: Bool { baseInput != nil && !results.isEmpty }

    func result(for kind: ScenarioKind) -> ScenarioResult? {
        results.first { $0.kind == kind }
    }

    func definition(for kind: ScenarioKind) -> StoredScenarioDefinition? {
        definitions.first { $0.kind == kind }
    }

    var balanced: ScenarioResult? { result(for: .balanced) }

    /// True when no scenario could be computed — the screen then leads with
    /// what it still needs rather than three empty cards.
    var allMissingInputs: Bool {
        !results.isEmpty && results.allSatisfy { !$0.isComputable }
    }

    /// Every distinct missing input across the three cards, de-duplicated by
    /// field so the "what I still need" list does not repeat itself.
    var distinctMissingInputs: [ScenarioMissingInput] {
        var seen = Set<String>()
        var ordered: [ScenarioMissingInput] = []
        for result in results {
            for missing in result.missingInputs {
                let key = "\(missing.field.rawValue)-\(missing.debtID?.uuidString ?? "")"
                if seen.insert(key).inserted { ordered.append(missing) }
            }
        }
        return ordered
    }
}

// MARK: - Loader

/// Builds the scenario definitions from the user's saved profile and runs the
/// calculator. Every constraint comes from the profile or from an explicit
/// override; nothing is invented (V3-06).
struct ScenarioWorkspaceLoader {
    let context: ModelContext
    let dateProvider: DateProviding
    let calculator: ScenarioCalculating

    init(
        context: ModelContext,
        dateProvider: DateProviding = SystemDateProvider(),
        calculator: ScenarioCalculating = ScenarioCalculationService()
    ) {
        self.context = context
        self.dateProvider = dateProvider
        self.calculator = calculator
    }

    /// Reads the saved inputs without running the engine — cheap enough for a
    /// first render, so the overrides panel can populate before results land.
    func preload() throws -> ScenarioWorkspaceState {
        var state = ScenarioWorkspaceState()
        let input = try PlanningInputBuilder(context: context).build(
            asOf: DateMath.startOfDay(dateProvider.now)
        )
        state.baseInput = input
        state.savedTakeHome = input.baseTakeHome
        state.savedCadence = input.cadence
        return state
    }

    /// Runs the three scenarios. Call from a `Task`, never from a body.
    func calculate(into state: inout ScenarioWorkspaceState) throws {
        guard var input = state.baseInput else { return }
        let profile = try context.fetch(FetchDescriptor<UserGoalProfile>()).first

        // R-18 overrides apply to a copy. `PlanningInputBuilder`'s output is a
        // value type, so the saved rows cannot be reached from here at all.
        if let cadence = state.overrides.cadence { input.cadence = cadence }
        if let takeHome = state.overrides.takeHome { input.baseTakeHome = takeHome }

        let effectiveDate = state.overrides.effectiveDate
            ?? DateMath.startOfDay(dateProvider.now)

        state.definitions = Self.definitions(profile: profile, effectiveDate: effectiveDate)
        do {
            state.results = try calculator.scenarios(from: input, definitions: state.definitions)
            state.blockingError = nil
        } catch {
            state.results = []
            state.blockingError = error.localizedDescription
        }
    }

    /// One definition per contracted scenario kind, in card order.
    ///
    /// Every value is the user's own or nil. A nil the scenario needs comes
    /// back as a named missing input from the calculator — this layer never
    /// substitutes a default to make a card appear.
    static func definitions(
        profile: UserGoalProfile?,
        effectiveDate: Date
    ) -> [StoredScenarioDefinition] {
        // Zero is how the profile spells "not stated" for these columns, so it
        // is mapped back to nil rather than passed on as a real constraint.
        func stated(_ value: Decimal?) -> Decimal? {
            guard let value, value > 0 else { return nil }
            return value
        }

        return ScenarioKind.allCases.map { kind in
            StoredScenarioDefinition(
                kind: kind,
                incomeOverride: nil,
                minimumProtectedCash: stated(profile?.minimumProtectedCash),
                preferredFloor: profile?.protectedFloor,
                preferredAllowance: profile?.allowanceCap,
                plannedSavingsPerPaycheck: stated(profile?.plannedSavingsPerPaycheck),
                additionalReserve: stated(profile?.additionalCushionReserve),
                extraPaymentCeiling: stated(profile?.extraPaymentCeiling),
                zeroAllowanceConfirmedAt: profile?.zeroAllowanceConfirmedAt,
                effectiveDate: effectiveDate
            )
        }
    }
}

// MARK: - Missing-input presentation

extension ScenarioMissingInput {
    /// Where the user goes to answer this, in the app's own navigation words.
    /// Nil when the field has no single screen that owns it.
    var destinationTitle: String? {
        switch field {
        case .minimumProtectedCash, .protectedCash, .preferredAllowance,
             .plannedSavings, .cushionConstraint, .zeroAllowanceConfirmation:
            return "Goal & guardrails"
        case .debts, .debtBalance, .debtAPR, .debtMinimum:
            return "Bills & debts"
        case .income, .payCadence, .nextPayday:
            return "Income"
        case .extraPaymentAmount, .extraPaymentTarget:
            return nil
        }
    }

    var symbolName: String {
        switch field {
        case .zeroAllowanceConfirmation: return "hand.raised"
        case .debts, .debtBalance, .debtAPR, .debtMinimum: return "creditcard"
        case .income, .payCadence, .nextPayday: return "dollarsign.circle"
        default: return "questionmark.circle"
        }
    }
}

extension PlanningNote {
    /// Warnings and assumptions arrive as sentences with a machine-readable
    /// code, so iconography is attached here rather than parsed out of prose.
    var symbolName: String {
        "info.circle"
    }
}
