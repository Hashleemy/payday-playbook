import Foundation

// MARK: - Calculation versioning

/// Calculation behavior is versioned. Version 1 is the frozen legacy baseline
/// implemented by `DebtCalculationEngine` (biweekly, seeded Original Plan v1);
/// it must keep reproducing the documented Aug 20 2026 – Jun 24 2027 result
/// forever. Version 2 is the generalized avalanche generator in
/// `AvalanchePlanEngine` (calc rules R-01…R-16). Dispatch on
/// `PlanningInput.calculationVersion`; never route version-1 plans through the
/// version-2 allocator.
enum PlanCalculationVersion: Int, Codable, Equatable, Sendable {
    /// Frozen legacy behavior (`DebtCalculationEngine`); Original Plan v1.
    case v1LegacyBaseline = 1
    /// Generalized avalanche engine (this module).
    case v2Avalanche = 2
}

// MARK: - Input DTOs

/// Everything the plan generator needs, decoupled from SwiftData and SwiftUI.
/// All dates are expected as local start-of-day; all money is `Decimal`.
struct PlanningInput: Codable, Equatable, Sendable {
    var calculationVersion: PlanCalculationVersion = .v2Avalanche
    /// The date the plan is generated (start of day). Only used for labeling
    /// and validation; allocation starts at the first payday.
    var asOf: Date
    var income: IncomeInput
    var spending: SpendingInput
    var obligations: [ObligationInput]
    var debts: [DebtInput]
}

/// Pay cadence for payday timeline generation (R-01, R-03).
/// Days of month are 1…31; a day beyond a month's length clamps to the last
/// valid day (R-11), so "last day of month" is expressed as day 31.
enum PlanningPayCadence: Codable, Equatable, Sendable {
    case weekly
    case biweekly
    /// Two paydays per month on the given days (e.g. 1 and 15, or 15 and 31
    /// for "15th and last day"). `firstDay < secondDay` required.
    case semimonthly(firstDay: Int, secondDay: Int)
    case monthly(day: Int)

    /// R-03: paychecks per year, used by obligation smoothing.
    var paychecksPerYear: Int {
        switch self {
        case .weekly: return 52
        case .biweekly: return 26
        case .semimonthly: return 24
        case .monthly: return 12
        }
    }
}

struct IncomeInput: Codable, Equatable, Sendable {
    var cadence: PlanningPayCadence
    /// The next payday; the anchor the timeline is generated from. For
    /// semimonthly/monthly cadences its day must match a configured day
    /// (after clamping).
    var firstPayday: Date
    /// Take-home amounts by effective date, ascending. The first entry's
    /// amount applies from the first payday even if its effective date is
    /// later (a plan cannot have zero income).
    var amounts: [PlanningIncomeChange]
    /// One-time extra money the user has explicitly assigned to the plan.
    /// Each windfall lands on the first payday on/after its date and flows
    /// through the normal allocation order. Windfalls are never inferred.
    var windfalls: [Windfall] = []
}

// `PlanningIncomeChange` (effective-dated take-home step) is declared in
// Services/PlanningDTO.swift and shared with the persistence layer.

struct Windfall: Codable, Equatable, Sendable {
    var date: Date
    var amount: Decimal
}

/// The spending account and the user's cash policy.
struct SpendingInput: Codable, Equatable, Sendable {
    /// Spending-account balance at plan start.
    var startingBalance: Decimal
    /// Protected cash floor — the plan never schedules the spending account
    /// below this under the no-spend assumption, topping it up before any
    /// extra principal (R-05 step 2).
    var protectedFloor: Decimal
    /// Per-paycheck personal allowance, reserved as available-not-spent.
    var allowancePerPaycheck: Decimal
}

// `ObligationCadence` (R-04 occurrences per year) is declared in
// Models/RecurringObligation.swift and shared with the model layer.

struct ObligationInput: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var amount: Decimal
    var cadence: ObligationCadence
    /// Optional day-of-month, clamped per R-11; calendar/event display only —
    /// reserving is smoothed per paycheck regardless of due day.
    var dueDay: Int?
}

// `DebtType` (six kinds, V2-04) is declared in Models/DebtAccount.swift and
// shared with the model layer.

/// Whether extra principal may be sent to this debt beyond its minimum.
/// `unknown` is treated as `ineligible` (never risk a prepayment penalty) and
/// produces a setup warning asking the user to confirm (R-07).
enum PrepaymentEligibility: String, Codable, Equatable, Sendable {
    case eligible, ineligible, unknown
}

struct PromoAPR: Codable, Equatable, Sendable {
    /// Promotional rate in force strictly before `expirationDate`.
    var apr: Decimal
    /// First date the standard APR applies again.
    var expirationDate: Date
}

struct DebtInput: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var debtType: DebtType
    /// Current balance / remaining principal.
    var balance: Decimal
    /// Standard APR as a fraction (0.2999 = 29.99%).
    var apr: Decimal
    /// Optional promotional APR with expiration; effective APR switches to
    /// the standard rate on the expiration date.
    var promo: PromoAPR?
    /// Authoritative when set. Interpreted as the amount due per due-date
    /// cycle when `dueDay` is set, otherwise per paycheck. Cards may leave it
    /// nil (estimated per R-06); installment types must supply it or the plan
    /// carries a missing-input warning.
    var minimumPayment: Decimal?
    /// Statement due day-of-month 1…31, clamped per R-11. When set, the
    /// minimum is funded from the last payday on or before each due date.
    /// When nil, the minimum is reserved every paycheck.
    var dueDay: Int?
    /// Cards only; utilization = balance ÷ limit, display/insight only.
    var creditLimit: Decimal?
    var prepayment: PrepaymentEligibility = .eligible
    /// Stable creation order; final tie-break for deterministic priority.
    var createdOrder: Int

    /// Effective APR on a given date: promo rate while the date is strictly
    /// before the promo expiration, standard APR afterwards.
    func effectiveAPR(on date: Date) -> Decimal {
        if let promo, date < promo.expirationDate { return promo.apr }
        return apr
    }
}

// MARK: - Reforecast input

/// An authoritative actual balance for one debt. Controls the forecast from
/// its effective date forward; never rewrites the original plan.
struct BalanceAuthority: Codable, Equatable, Sendable {
    var debtID: UUID
    var balance: Decimal
    var effectiveDate: Date
}

/// Actual-state overlay for reforecasting. The original `PlanningInput` stays
/// untouched; this describes what is true *now*.
struct ActualState: Codable, Equatable, Sendable {
    /// "Today" for the reforecast; projection starts at the first payday
    /// after this date.
    var asOf: Date
    /// Latest authoritative balance per debt. Debts without an entry keep
    /// their `PlanningInput` balance (with interest estimated from plan
    /// start; a warning notes the stale input). If a debt appears more than
    /// once, the entry with the latest effective date wins (ties: the later
    /// entry in the array).
    var balances: [BalanceAuthority]
    /// Actual spending-account balance, when known; nil keeps the no-spend
    /// planned path.
    var spendingBalance: Decimal?
}

// MARK: - Result DTOs

enum PlanKind: String, Codable, Equatable, Sendable {
    /// The immutable recommendation generated from onboarding inputs.
    case plan
    /// A projection from authoritative actual state. Never replaces `plan`.
    case reforecast
    /// The minimums-only comparison track.
    case minimumOnly
}

/// Machine-readable reasons attached to recommendations and movements.
enum ReasonCode: String, Codable, Equatable, Sendable {
    case avalancheHighestEffectiveAPR   // extra principal target choice
    case minimumDueByDate               // minimum funded ahead of a due date
    case minimumPerPaycheck             // minimum reserved every paycheck (no due day)
    case estimatedMinimum               // card minimum estimated per R-06
    case rolloverAfterPayoff            // freed capacity moved on in the same paycheck
    case promoRateActive
    case promoRateExpired               // priority changed after promo end
    case zeroAPRLast                    // 0% debts sort behind interest-bearing ones
    case prepaymentIneligible           // minimums only (R-07)
    case prepaymentUnknown              // treated as ineligible until confirmed
    case allowanceReserved
    case floorTopUp
    case obligationReserve
    case shortfallReducedExtra          // R-09 step 1
    case shortfallReducedAllowance      // R-09 step 2
    case shortfallNeedsAttention        // R-09 step 3, exact gap reported
    case unassignedCash                 // money with no eligible destination
    case debtPaidOff
    case windfallApplied
    case authoritativeBalance           // reforecast starts from a snapshot
}

/// Warning / assumption note codes.
enum PlanningNoteCode: String, Codable, Equatable, Sendable {
    // Missing / unsafe input warnings
    case installmentMinimumMissing      // installment debt without an entered minimum
    case prepaymentEligibilityUnknown   // extra principal withheld until confirmed
    case prepaymentProhibited
    case creditLimitMissing             // utilization unavailable
    case creditLimitZero
    case dueDayClamped
    case dueDateBeforeFirstPayday       // an occurrence falls before plan start
    case minimumOnlyUnavailable         // comparison withheld — inputs insufficient
    case minimumOnlyNeverFinishes       // minimums alone never retire the debt
    case horizonCapReached              // not payable as configured (R-01 cap)
    case noEligibleExtraTarget          // every debt ineligible; extra cash unassigned
    case shortfallOutsideFunds          // paycheck needs outside cash (R-09 gap)
    case staleBalanceInput              // reforecast debt without an authoritative snapshot
    // Assumption / confidence notes
    case estimateOnly                   // issuer interest & posting dates will differ
    case paymentsPostOnPayday           // payments modeled as posting on the funding payday
    case promoNotProrated               // effective APR applied per whole accrual period
    case year365                        // interest uses a 365-day year, including leap years
    case utilizationDisplayOnly
}

struct PlanningNote: Codable, Equatable, Sendable {
    var code: PlanningNoteCode
    var message: String
    var debtID: UUID?

    init(code: PlanningNoteCode, message: String, debtID: UUID? = nil) {
        self.code = code
        self.message = message
        self.debtID = debtID
    }
}

/// One debt's payment inside a paycheck.
struct PlannedPayment: Codable, Equatable, Sendable {
    var debtID: UUID
    var minimum: Decimal
    var extra: Decimal
    /// The due date this minimum funds, when driven by a due day.
    var fundsDueDate: Date?
    var reasons: [ReasonCode]

    var total: Decimal { minimum + extra }
}

struct ObligationReserve: Codable, Equatable, Sendable {
    var obligationID: UUID
    var amount: Decimal
}

struct DebtBalancePoint: Codable, Equatable, Sendable {
    var debtID: UUID
    var balance: Decimal
}

/// R-09 explicit shortfall — never silent negative cash.
struct PaycheckShortfall: Codable, Equatable, Sendable {
    /// Exact outside cash needed after extra→0 and allowance→0.
    /// Always `floorGap + obligationGap + minimumsGap`.
    var gap: Decimal
    /// How much of the allowance was given up (R-09 step 2).
    var allowanceReduced: Decimal
    /// Portion of `gap` covering the unfunded floor top-up.
    var floorGap: Decimal
    /// Portion of `gap` covering unfunded obligation reserves.
    var obligationGap: Decimal
    /// Portion of `gap` covering minimum payments (`gap − floorGap −
    /// obligationGap`).
    var minimumsGap: Decimal
    var explanation: String
}

/// One payday's full play: deposits, reserves, transfers, minimums, extra,
/// and ending balances. All amounts are rounded to cents and reconcile:
/// `income + windfall == keepInSpending + transferToReserves`, and
/// `debtBudget + (shortfall?.minimumsGap ?? 0) == minimumsTotal + extraTotal + unassignedCash`
/// (only the minimums portion of a shortfall gap flows through the debt
/// budget; the floor and obligation portions never touch it).
struct PaycheckPlan: Codable, Equatable, Sendable {
    var sequence: Int
    var date: Date
    /// Days of interest accrued in this period.
    var accrualDays: Int
    var income: Decimal
    var windfall: Decimal
    var allowanceReserved: Decimal
    var floorTopUp: Decimal
    /// allowance + floor top-up: stays in the spending account.
    var keepInSpending: Decimal
    /// income + windfall − keep: moves to the reserves account.
    var transferToReserves: Decimal
    var obligationReserves: [ObligationReserve]
    var obligationReserveTotal: Decimal
    /// Cash available to debts after allowance, floor, and obligations.
    var debtBudget: Decimal
    var payments: [PlannedPayment]
    var minimumsTotal: Decimal
    var extraTotal: Decimal
    /// The debt that received extra principal first this paycheck.
    var targetDebtID: UUID?
    var interestAccrued: Decimal
    var endingBalances: [DebtBalancePoint]
    /// Full-precision total rounded once (may differ from the sum of the
    /// per-debt rounded balances by stray cents; this is the true total).
    var totalDebtAfter: Decimal
    /// Debt-budget money with no eligible destination this paycheck; it stays
    /// in reserves and is flagged, never silently lost.
    var unassignedCash: Decimal
    /// Spending-account balance after this paycheck under the no-spend
    /// assumption (the "no-spend ceiling").
    var spendingCeilingAfter: Decimal
    var shortfall: PaycheckShortfall?
    /// One-line explanations for this paycheck's movements.
    var movements: [String]
}

struct DebtPlanSummary: Codable, Equatable, Sendable {
    var debtID: UUID
    var name: String
    var debtType: DebtType
    var startingBalance: Decimal
    var apr: Decimal
    var payoffDate: Date?
    var totalPaid: Decimal
    var interestPaid: Decimal
    var receivesExtraPrincipal: Bool
}

enum UtilizationLevel: String, Codable, Equatable, Sendable {
    case unknown    // missing or zero limit
    case ok         // < 30%
    case elevated   // ≥ 30% (R-12 informational)
    case critical   // ≥ 90% (R-12 needs attention)
}

struct CreditUtilization: Codable, Equatable, Sendable {
    var debtID: UUID
    var balance: Decimal
    var creditLimit: Decimal?
    /// balance ÷ limit rounded to 4 places; nil when the limit is missing or
    /// zero (never divides by zero).
    var utilization: Decimal?
    var level: UtilizationLevel
}

/// Minimums-only comparison. Only claims savings when both projections
/// actually finished; otherwise the optional fields stay nil and a note
/// explains why.
struct MinimumOnlyComparison: Codable, Equatable, Sendable {
    var payoffDate: Date?
    var paycheckCount: Int
    var totalInterest: Decimal
    /// Recommended-plan interest subtracted from minimum-only interest;
    /// nil unless both tracks completed inside the horizon.
    var interestSaved: Decimal?
    /// Days earlier the recommended plan finishes; nil unless both finished.
    var daysSaved: Int?
    /// True when minimums alone never retire the debt within the horizon.
    var unfinished: Bool
}

enum PlanEventKind: String, Codable, Equatable, Sendable {
    case payday                 // deposit + allocation play
    case minimumDue             // a debt's statement due date
    case obligationDue          // an obligation's due date
    case plannedPayment         // payment posting on a payday
    case debtPayoff             // a debt reaches $0.00
    case planComplete           // all debts retired
    case shortfallAlert         // R-09 needs-attention paycheck
}

/// Calendar-ready plan event with a stable identifier so schedulers can
/// replace rather than duplicate.
struct PlanEvent: Codable, Equatable, Sendable {
    /// Stable within a plan: "<kind>-<sequence-or-date>-<entity>".
    var identifier: String
    var date: Date
    var kind: PlanEventKind
    var debtID: UUID?
    var obligationID: UUID?
    var amount: Decimal?
    var title: String
    var reasons: [ReasonCode]
}

/// The full generated plan. Deterministic: identical `PlanningInput` always
/// produces an identical `PlanningResult`.
struct PlanningResult: Codable, Equatable, Sendable {
    var calculationVersion: PlanCalculationVersion
    var kind: PlanKind
    var generatedAsOf: Date

    // Principal
    /// Sum of the `PlanningInput` debt balances.
    var totalStartingPrincipal: Decimal
    /// Principal outstanding at the start of this projection: equals
    /// `totalStartingPrincipal` for a fresh plan; the sum of authoritative
    /// balances for a reforecast.
    var totalRemainingPrincipal: Decimal

    // Recommendation
    /// Debts in recommended payoff order (projected payoff sequence; unpaid
    /// debts follow in priority order).
    var payoffOrder: [UUID]
    /// First debt that receives extra principal; nil when nothing is
    /// eligible or everything is already paid.
    var currentTargetDebtID: UUID?
    /// Concise explanations of why this order/target was chosen.
    var recommendationReasons: [ReasonCode]
    var recommendationExplanations: [String]

    // Schedule
    var paychecks: [PaycheckPlan]
    var paycheckCount: Int
    var forecastPayoffDate: Date?
    var debtSummaries: [DebtPlanSummary]

    // Interest
    var estimatedTotalInterest: Decimal
    /// Interest still ahead as of generation (equals the total for a fresh
    /// plan; smaller for reforecasts that start mid-plan).
    var estimatedRemainingInterest: Decimal

    // Insight inputs
    var minimumOnlyComparison: MinimumOnlyComparison?
    var utilization: [CreditUtilization]
    /// The no-spend ceiling path, one point per paycheck.
    var cashBufferPath: [Decimal]
    /// True when any paycheck left eligible-debt money unassigned.
    var hasUnassignedCash: Bool

    // Calendar
    var events: [PlanEvent]

    // Trust
    var warnings: [PlanningNote]
    var assumptions: [PlanningNote]
    /// True when the horizon cap was hit before payoff (R-01: "not payable
    /// as configured").
    var notPayableAsConfigured: Bool
}
