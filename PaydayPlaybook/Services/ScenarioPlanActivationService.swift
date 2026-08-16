import Foundation
import SwiftData

/// Turns a previewed scenario into a real, future-effective plan version
/// (V3-15). This is the *only* place a scenario is allowed to become a plan;
/// `ScenarioCalculationService` and `ExtraPaymentInsightService` never persist
/// anything, by contract.
///
/// Three properties the release contract asks for, and how each is met:
///
/// - **The previous plan and all history remain intact.** `PlanPersister`
///   inserts a brand-new `PlanVersion` graph and only flips the old version's
///   `isActive` flag; no earlier row is edited or deleted.
/// - **Nothing happens without confirmation.** This service is called from the
///   confirmation step, never from a card tap — applying is a decision, and the
///   engine layer deliberately cannot make it.
/// - **A scenario-born plan says so.** The new row carries
///   `scenarioKind = .scenario` and the scenario's `effectiveDate`, so a later
///   reader can tell a modelled future from the plan the user chose to follow.
struct ScenarioPlanActivationService {
    let context: ModelContext
    let dateProvider: DateProviding

    init(context: ModelContext, dateProvider: DateProviding = SystemDateProvider()) {
        self.context = context
        self.dateProvider = dateProvider
    }

    enum ActivationError: LocalizedError, Equatable {
        case scenarioNotComputable

        var errorDescription: String? {
            switch self {
            case .scenarioNotComputable:
                return "This scenario is still missing information, so there's nothing to apply yet."
            }
        }
    }

    /// What the confirmation step restates before anything is written.
    struct ApplySummary: Equatable {
        var planName: String
        var scenarioName: String
        var effectiveDate: Date
        var payoffDate: Date?
        var estimatedInterest: Decimal
        var replacesPlanNamed: String?
        var calculationVersion: Int
    }

    /// The summary for a scenario, computed without writing anything. Safe to
    /// call from a confirmation sheet.
    func summary(
        for result: ScenarioResult,
        definition: StoredScenarioDefinition
    ) throws -> ApplySummary {
        ApplySummary(
            planName: try GeneratedPlanService.nextPlanName(context: context),
            scenarioName: result.kind.displayName,
            effectiveDate: definition.effectiveDate,
            payoffDate: result.payoffDate,
            estimatedInterest: result.estimatedTotalInterest,
            replacesPlanNamed: try context.fetch(FetchDescriptor<PlanVersion>())
                .first(where: \.isActive)?.name,
            calculationVersion: result.plan?.calculationVersion.rawValue
                ?? PlanCalculationVersion.v3Scenario.rawValue
        )
    }

    /// Persists the scenario as a new active plan version.
    ///
    /// The snapshot stored on the row is the *scenario's own* input — the one
    /// the projection was actually computed from, carrying its constraints and
    /// calc-v3 stamp. Storing the baseline input instead would produce a plan
    /// that regenerates into something the user never saw.
    @discardableResult
    func apply(
        result: ScenarioResult,
        definition: StoredScenarioDefinition,
        baseInput: StoredPlanInput
    ) throws -> PlanVersion {
        guard let projection = result.plan else { throw ActivationError.scenarioNotComputable }

        var snapshot = baseInput
        snapshot.calculationVersion = PlanCalculationVersion.v3Scenario.rawValue
        snapshot.scenario = definition

        let now = dateProvider.now
        let name = try GeneratedPlanService.nextPlanName(context: context)
        let hasAnyPlan = try context.fetchCount(FetchDescriptor<PlanVersion>()) > 0

        let plan = try PlanPersister(context: context).insertPlanGraph(
            named: name,
            input: snapshot,
            result: GeneratedPlanService.storedResult(from: projection, input: snapshot),
            // A scenario is never an install's immutable baseline: the
            // baseline is what the user started from, and only the very first
            // plan of an install can be that.
            isOriginalBaseline: !hasAnyPlan,
            now: now
        )
        plan.scenarioKind = .scenario
        plan.effectiveDate = definition.effectiveDate
        try context.save()
        return plan
    }
}

// MARK: - Presentation vocabulary

extension ScenarioKind {
    /// The one place the three cards are named. The scenario screens, the
    /// comparison view and the generated PDF report all read it, so a printout
    /// and the screen it was generated from agree word for word.
    var displayName: String {
        switch self {
        case .fastestSafe: return "Fastest Safe"
        case .balanced: return "Balanced"
        case .moreCushion: return "More Cushion"
        }
    }

    /// One sentence describing the trade the scenario makes. Descriptive, not
    /// a nudge: none of the three is presented as the "right" answer beyond
    /// Balanced's contracted recommendation badge.
    var summaryLine: String {
        switch self {
        case .fastestSafe:
            return "Everything above your protected cash goes to debt. Fastest payoff, no discretionary allowance."
        case .balanced:
            return "Keeps your allowance and planned savings, and sends the rest to debt."
        case .moreCushion:
            return "Holds back extra cash on top of your savings, so debt takes longer but your buffer is larger."
        }
    }

    var symbolName: String {
        switch self {
        case .fastestSafe: return "hare"
        case .balanced: return "scalemass"
        case .moreCushion: return "shield.lefthalf.filled"
        }
    }

    /// R-17's contracted recommendation. Visual only — nothing auto-applies.
    var isRecommended: Bool { self == .balanced }
}
