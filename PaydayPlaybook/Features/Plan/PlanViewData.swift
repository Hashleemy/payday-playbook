import Foundation
import SwiftData

/// Which of the three truths the plan screen is showing (soul §2, R-15).
/// The selector switches the *view*, never the stored data: baseline rows are
/// immutable, actual rows come only from user entries, and a reforecast is a
/// fresh estimate that is never written over either.
enum PlanTrack: String, CaseIterable, Identifiable {
    case baseline
    case actual
    case reforecast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .baseline: return "Plan"
        case .actual: return "Actual"
        case .reforecast: return "Reforecast"
        }
    }

    var explanation: String {
        switch self {
        case .baseline:
            return "What this plan version expected when it was generated. It never changes."
        case .actual:
            return "What you recorded as actually happening. Only your entries appear here."
        case .reforecast:
            return "What's now expected, starting from your confirmed balances. The plan above stays as written."
        }
    }
}

/// One paycheck row of the playbook, from whichever track is selected.
struct PlanPaycheckRow: Identifiable {
    let id: UUID
    let sequence: Int
    let date: Date
    let income: Decimal
    let keepInSpending: Decimal
    let transferToReserves: Decimal
    let allowance: Decimal
    let floorTopUp: Decimal
    let obligationReserves: [(name: String, amount: Decimal)]
    let obligationReserveTotal: Decimal
    let minimumsTotal: Decimal?
    let extraTotal: Decimal?
    let debtBudget: Decimal
    let targetLabel: String?
    let debtAfter: Decimal
    let endingCash: Decimal
    let shortfall: Decimal?
    /// Ready-to-read movement sentences (calc-v2 engine output).
    let movements: [String]
    /// True when this row is the actual record rather than a plan row.
    let isActualRecord: Bool
}

/// A debt as the plan screen shows it, in recommended payoff order.
struct PlanDebtRow: Identifiable {
    let id: UUID
    let planID: String
    let name: String
    let debtType: DebtType
    let apr: Decimal
    let currentBalance: Decimal
    let originalPrincipal: Decimal?
    let creditLimit: Decimal?
    let utilization: Decimal?
    let minimum: Decimal?
    let dueDay: Int?
    let priority: Int
    let payoffDate: Date?
    let receivesExtraPrincipal: Bool
}

/// A what-if scenario: the same inputs with one guardrail changed. Display
/// only — running one never touches the active plan (soul hard boundary).
struct PlanScenario: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let payoffDate: Date?
    let totalInterest: Decimal
    /// Days later (positive) or earlier (negative) than the active plan.
    let dayDelta: Int?
    let interestDelta: Decimal
}

/// Everything the Generated Plan screen renders, assembled once per load.
struct PlanViewData {
    var plan: PlanVersion?
    var planName: String = ""
    var calculationVersion: Int = 1
    var isBaseline: Bool = false
    var isActive: Bool = false
    var generatedFromProfile: Bool = false
    var generatedAt: Date?

    // Inputs and assumptions
    var cadenceText: String = ""
    var firstPaydayText: String = ""
    var takeHomeText: String = ""
    var incomeChangeLines: [String] = []
    var protectedFloor: Decimal = .zero
    var allowanceCap: Decimal = .zero
    var obligationLines: [(name: String, amount: Decimal, cadence: String, perPaycheck: Decimal)] = []
    var accountLines: [(name: String, roles: String, balance: Decimal)] = []
    var assumptionLines: [String] = []
    var warningLines: [String] = []
    /// Set when inputs are missing or a snapshot can't be read. Numbers are
    /// withheld rather than guessed.
    var lowConfidenceNote: String?

    // Recommendation
    var debtRows: [PlanDebtRow] = []
    var avalancheExplanation: String = ""
    var totalPrincipalNow: Decimal = .zero
    var totalStartingPrincipal: Decimal = .zero
    var totalOriginalPrincipal: Decimal?

    // Outcome
    var payoffDate: Date?
    var paycheckCount: Int = 0
    var totalEstimatedInterest: Decimal = .zero
    /// Nil when the engine withholds the minimums-only comparison; the note
    /// says why (never a guessed comparison).
    var minimumOnlyInterest: Decimal?
    var minimumOnlyPayoffDate: Date?
    var minimumOnlyUnavailableReason: String?
    var minimumOnlyNeverFinishes: Bool = false
    var interestSaved: Decimal?
    var daysSaved: Int?

    // Playbook
    var baselineRows: [PlanPaycheckRow] = []
    var actualRows: [PlanPaycheckRow] = []
    var reforecastRows: [PlanPaycheckRow] = []
    var reforecastPayoffDate: Date?
    var reforecastInterest: Decimal?
    var reforecastUnavailableReason: String?

    // Scenarios
    var scenarios: [PlanScenario] = []
    var scenarioNote: String?

    var hasPlan: Bool { plan != nil }

    func rows(for track: PlanTrack) -> [PlanPaycheckRow] {
        switch track {
        case .baseline: return baselineRows
        case .actual: return actualRows
        case .reforecast: return reforecastRows
        }
    }
}
