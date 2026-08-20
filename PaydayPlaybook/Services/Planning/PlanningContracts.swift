import Foundation

// MARK: - Calculation versioning

/// Calculation behavior is versioned. Version 1 is the frozen legacy baseline
/// implemented by `DebtCalculationEngine`; it must keep reproducing its stored
/// schedule forever. Version 2 is the generalized avalanche generator in
/// `AvalanchePlanEngine` (calc rules R-01…R-16). Version 3 is the same engine
/// plus the scenario and extra-payment rules R-17…R-24. Version 4 adds the
/// Balanced quick-win promotion input (R-25…R-27). Dispatch on
/// `PlanningInput.calculationVersion`; never route version-1 plans through a
/// later allocator.
enum PlanCalculationVersion: Int, Codable, Equatable, Sendable {
    /// Frozen legacy behavior (`DebtCalculationEngine`).
    case v1LegacyBaseline = 1
    /// Generalized avalanche engine (this module).
    case v2Avalanche = 2
    /// Avalanche engine with scenario constraints and extra payments
    /// (R-17…R-24). Reduces to `.v2Avalanche` output exactly when the input
    /// carries no scenario and no extra payments (R-22).
    case v3Scenario = 3
    /// Scenario engine with the quick-win promotion input (R-25…R-27).
    /// Reduces to `.v3Scenario` output exactly when `quickWinPromotions` is
    /// empty; carrying promotions on an input stamped below this version is a
    /// validation error, never a silent ignore.
    case v4BalancedQuickWin = 4
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
    /// Calc v3 (R-17/R-18): the scenario constraints this projection runs
    /// under. Nil means the plain calc-v2 recommendation. The engine folds the
    /// constraints into income and spending during normalization, so there is
    /// exactly one interpretation of each scenario kind.
    var scenario: ScenarioInput?
    /// Calc v3 (R-20): one-time and recurring extra payments modeled on top of
    /// the plan. Empty means the plain calc-v2 recommendation.
    var extraPayments: [ExtraPaymentInput] = []

    private enum CodingKeys: String, CodingKey {
        case calculationVersion, asOf, income, spending, obligations, debts
        case scenario, extraPayments
    }
}

extension PlanningInput {
    /// Decoded tolerantly so calc-v2 payloads written before the scenario
    /// fields existed still round-trip (`extraPayments` defaults to empty).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        calculationVersion = try container.decodeIfPresent(
            PlanCalculationVersion.self, forKey: .calculationVersion) ?? .v2Avalanche
        asOf = try container.decode(Date.self, forKey: .asOf)
        income = try container.decode(IncomeInput.self, forKey: .income)
        spending = try container.decode(SpendingInput.self, forKey: .spending)
        obligations = try container.decode([ObligationInput].self, forKey: .obligations)
        debts = try container.decode([DebtInput].self, forKey: .debts)
        scenario = try container.decodeIfPresent(ScenarioInput.self, forKey: .scenario)
        extraPayments = try container.decodeIfPresent(
            [ExtraPaymentInput].self, forKey: .extraPayments) ?? []
    }
}

// MARK: - Scenario inputs (calc v3, R-17/R-18)

/// The three contracted scenarios (V3-05). The names are product-visible and
/// fixed: Fastest Safe, Balanced (Recommended), More Cushion.
enum ScenarioKind: String, Codable, Equatable, Sendable, CaseIterable {
    /// Preserve essential bills, required minimums, and the user's *minimum*
    /// protected cash; send the maximum approved surplus to eligible debt.
    case fastestSafe
    /// Preserve the user's *preferred* floor and allowance, essential bills,
    /// and planned savings, then avalanche the remainder. Recommended.
    case balanced
    /// Balanced plus a chosen additional cash reserve and/or a reduced
    /// extra-payment ceiling.
    case moreCushion
}

/// R-18 income override. Applied to a copy of the inputs; saved data is never
/// mutated. Income alone is never enough — a payoff estimate still needs the
/// full R-24 input set.
struct IncomeOverrideInput: Codable, Equatable, Sendable {
    var amount: Decimal
    var cadence: PlanningPayCadence
    /// Take-home steps to this amount on this date. When `cadence` differs
    /// from the saved cadence the payday timeline is rebased here, because a
    /// mid-plan cadence switch has no meaning against the old anchor.
    var effectiveDate: Date
}

/// Engine-side mirror of `StoredScenarioDefinition`. Converted only by
/// `PlanGenerationService.engineInput`.
///
/// Every field is the user's own value or nil; the engine never manufactures a
/// lifestyle assumption (V3-06). Which fields a given kind *requires* is
/// enforced by `ScenarioCalculationService`, which returns a named
/// missing-input result rather than guessing.
struct ScenarioInput: Codable, Equatable, Sendable {
    var kind: ScenarioKind
    var incomeOverride: IncomeOverrideInput?
    /// Fastest Safe: the least cash the user will hold in spending.
    var minimumProtectedCash: Decimal?
    /// Balanced / More Cushion: the user's preferred protected floor.
    var preferredFloor: Decimal?
    /// Balanced / More Cushion: the user's preferred per-paycheck allowance.
    var preferredAllowance: Decimal?
    /// Balanced / More Cushion: savings set aside each paycheck ahead of extra
    /// principal.
    var plannedSavingsPerPaycheck: Decimal?
    /// More Cushion: extra cash retained each paycheck on top of Balanced.
    var additionalReserve: Decimal?
    /// More Cushion: a cap on extra principal per paycheck. Money held back by
    /// the cap is retained as cash, not left unassigned.
    var extraPaymentCeiling: Decimal?
    /// When the user confirmed a $0 discretionary allowance. Fastest Safe is
    /// not computable without it — the engine never assumes it (R-17).
    var zeroAllowanceConfirmedAt: Date?
    /// When this scenario's schedule begins if it is ever applied (V3-15).
    /// Preview math is unaffected; applying is a separate, explicit step.
    var effectiveDate: Date
    /// Calc v4 (R-25): debts promoted ahead of the R-08 extra-principal attack
    /// order and the assembled payoff order, in list order, until retired.
    /// Only active, `.eligible` debts take effect; anything else is a no-op
    /// with a `.quickWinPromotionIneligible` warning. Minimums funding,
    /// reserves, floor, allowance, and shortfall math are untouched. Empty on
    /// every calc-v2/v3 input, and requires `.v4BalancedQuickWin` to carry.
    var quickWinPromotions: [UUID] = []

    /// The protected floor this scenario preserves. Nil leaves the saved floor
    /// in place.
    var resolvedProtectedFloor: Decimal? {
        switch kind {
        case .fastestSafe: return minimumProtectedCash
        case .balanced, .moreCushion: return preferredFloor
        }
    }

    /// The per-paycheck allowance this scenario preserves. Fastest Safe drives
    /// it to $0 — which is why it requires `zeroAllowanceConfirmedAt`.
    var resolvedAllowance: Decimal? {
        switch kind {
        case .fastestSafe: return 0
        case .balanced, .moreCushion: return preferredAllowance
        }
    }

    /// Cash set aside each paycheck after minimums and before extra principal.
    /// Fastest Safe retains nothing beyond the floor.
    var retainedPerPaycheck: Decimal {
        switch kind {
        case .fastestSafe:
            return 0
        case .balanced:
            return plannedSavingsPerPaycheck ?? 0
        case .moreCushion:
            return (plannedSavingsPerPaycheck ?? 0) + (additionalReserve ?? 0)
        }
    }

    /// Per-paycheck cap on extra principal; only More Cushion may impose one.
    var resolvedExtraPaymentCeiling: Decimal? {
        kind == .moreCushion ? extraPaymentCeiling : nil
    }
}

extension ScenarioInput {
    private enum CodingKeys: String, CodingKey {
        case kind, incomeOverride, minimumProtectedCash, preferredFloor, preferredAllowance
        case plannedSavingsPerPaycheck, additionalReserve, extraPaymentCeiling
        case zeroAllowanceConfirmedAt, effectiveDate, quickWinPromotions
    }

    /// Decoded tolerantly so calc-v3 payloads written before the promotion
    /// key existed still round-trip (`quickWinPromotions` defaults to empty).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(ScenarioKind.self, forKey: .kind)
        incomeOverride = try container.decodeIfPresent(IncomeOverrideInput.self, forKey: .incomeOverride)
        minimumProtectedCash = try container.decodeIfPresent(Decimal.self, forKey: .minimumProtectedCash)
        preferredFloor = try container.decodeIfPresent(Decimal.self, forKey: .preferredFloor)
        preferredAllowance = try container.decodeIfPresent(Decimal.self, forKey: .preferredAllowance)
        plannedSavingsPerPaycheck = try container.decodeIfPresent(Decimal.self, forKey: .plannedSavingsPerPaycheck)
        additionalReserve = try container.decodeIfPresent(Decimal.self, forKey: .additionalReserve)
        extraPaymentCeiling = try container.decodeIfPresent(Decimal.self, forKey: .extraPaymentCeiling)
        zeroAllowanceConfirmedAt = try container.decodeIfPresent(Date.self, forKey: .zeroAllowanceConfirmedAt)
        effectiveDate = try container.decode(Date.self, forKey: .effectiveDate)
        quickWinPromotions = try container.decodeIfPresent([UUID].self, forKey: .quickWinPromotions) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(incomeOverride, forKey: .incomeOverride)
        try container.encodeIfPresent(minimumProtectedCash, forKey: .minimumProtectedCash)
        try container.encodeIfPresent(preferredFloor, forKey: .preferredFloor)
        try container.encodeIfPresent(preferredAllowance, forKey: .preferredAllowance)
        try container.encodeIfPresent(plannedSavingsPerPaycheck, forKey: .plannedSavingsPerPaycheck)
        try container.encodeIfPresent(additionalReserve, forKey: .additionalReserve)
        try container.encodeIfPresent(extraPaymentCeiling, forKey: .extraPaymentCeiling)
        try container.encodeIfPresent(zeroAllowanceConfirmedAt, forKey: .zeroAllowanceConfirmedAt)
        try container.encode(effectiveDate, forKey: .effectiveDate)
        // Omitted when empty so a calc-v3 payload's bytes are unchanged.
        if !quickWinPromotions.isEmpty {
            try container.encode(quickWinPromotions, forKey: .quickWinPromotions)
        }
    }
}

// MARK: - Extra-payment inputs (calc v3, R-20)

enum ExtraPaymentKind: String, Codable, Equatable, Sendable {
    /// A single amount, applied on the first payday on or after its date.
    case oneTime
    /// The amount repeats on every payday from its effective date.
    case recurringPerPaycheck
    /// The amount repeats monthly on its effective date's day-of-month
    /// (clamped per R-11), applied on the first payday on or after each
    /// occurrence.
    case recurringMonthly
}

/// Engine-side mirror of `StoredExtraPayment`.
///
/// Modeled as money entering the single spending pool on its payday and then
/// flowing through the normal allocation order — the only placement that keeps
/// all four R-16 reconciliation identities true while `extraTotal` grows.
struct ExtraPaymentInput: Codable, Equatable, Sendable {
    var id: UUID
    var kind: ExtraPaymentKind
    var amount: Decimal
    var effectiveDate: Date
    /// Nil means the automatic avalanche target (R-08). A named debt receives
    /// the money first, subject to R-07 eligibility; anything it cannot absorb
    /// rolls to the avalanche order.
    var targetDebtID: UUID?
    /// Display/warning only. The engine keeps its single-pool model and never
    /// allocates per account (R-20/R-23).
    var sourceAccountID: UUID?
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
    /// Standard APR as a fraction (0.2799 = 29.99%).
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
    // Calc v3 (R-20)
    case extraPaymentApplied            // a modeled extra payment funded this payment
    case extraPaymentDirectedTarget     // the user named this debt for the extra
    // Calc v4 (R-25/R-27)
    case quickWinPromotion              // extra sent to a promoted quick-win debt
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
    // Calc v3 warnings (R-17…R-21)
    case extraPaymentTargetIneligible       // named target refuses extra principal
    case extraPaymentTargetUnknownBehavior  // named target's lender behavior unconfirmed
    case extraPaymentAfterPayoff            // the money lands after every debt is retired
    case extraPaymentPartiallyPlaced        // directed amount exceeded the target's balance
    case insufficientAvailableCash          // named source account cannot cover it
    case sourceAccountNotVerified           // per-account funds are outside the engine's model
    case aprMissingOrZero                   // no interest to save on this debt
    case protectedFloorAtRisk               // the modeled cash path sits under the floor
    case noBillsConfigured                  // the estimate assumes there are none
    case extraPaymentCeilingHeldBackCash    // ceiling retained cash instead of paying debt
    // Calc v3 assumptions (R-18…R-23)
    case revolvingNoPrincipalOnly           // cards have no lender-side principal-only option
    case installmentPrincipalOnlyEligible   // confirmed-eligible installment debt
    case incomeOverrideApplied              // take-home replaced from the override's date
    case incomeOverrideRebasesTimeline      // a cadence change restarts the payday timeline
    case scenarioCashRetainedPerPaycheck    // planned savings / cushion held each paycheck
    case extraPaymentsAreNewMoney           // modeled as arriving in the spending pool
    // Calc v4 (R-25…R-27)
    case quickWinSelected                   // Balanced promoted a quick-win debt
    case quickWinCostsMoreInterest          // the quick win adds estimated interest, stated
    case quickWinPromotionIneligible        // promoted debt inactive/ineligible — no-op
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
    /// User-assigned windfalls plus any calc-v3 extra payments landing here —
    /// both are money arriving in the pool on this payday.
    var windfall: Decimal
    /// The portion of `windfall` that came from modeled extra payments (R-20).
    /// Always 0 under calc v2.
    var extraPaymentInflow: Decimal = 0
    var allowanceReserved: Decimal
    var floorTopUp: Decimal
    /// Calc v3: planned savings, the More Cushion reserve, and any extra
    /// principal held back by the scenario's ceiling. Retained cash, so it is
    /// part of `keepInSpending` — which is what keeps identity 1 true while
    /// the debt budget shrinks by exactly this amount. Always 0 under calc v2.
    var scenarioCashRetained: Decimal = 0
    /// allowance + floor top-up + scenario cash retained: stays in the
    /// spending account.
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

// MARK: - Balanced selection rationale (calc v4, R-27)

/// Why Balanced chose the target it chose — machine-testable, engine-proven.
///
/// Every figure comes from two complete engine runs: the selected projection
/// and the pure-avalanche Balanced baseline (B0). Nothing here is estimated by
/// a side formula, and no saving is claimed unless both compared projections
/// finished (the R-16 precedent). `explanations` carries calm, quantified
/// sentences for the scenario card; the numeric fields are the single source
/// every surface derives its copy from — no view invents its own comparison.
struct BalancedSelectionRationale: Codable, Equatable, Sendable {
    enum Selection: String, Codable, Equatable, Sendable {
        /// No quick win passed the R-26 guardrails; B0 is Balanced — exactly
        /// the pre-v0.4.0 behavior.
        case avalanche
        /// A quick-win promotion won the R-26 lexicographic selection.
        case quickWin
    }

    var selection: Selection
    /// The promoted debt; nil when `selection == .avalanche`.
    var promotedDebtID: UUID?
    var promotedDebtName: String?
    /// R-25 candidates — debts whose full promotion simulation retired them
    /// within `balancedQuickWinHorizonPaychecks` — whether or not admissible.
    var candidatesConsidered: Int
    /// Selected-run estimated interest minus B0's. Positive means the quick
    /// win costs more; 0 for an avalanche selection.
    var interestDeltaVsAvalanche: Decimal
    /// Selected-run paycheck count minus B0's (≤ the G1 guardrail; 0 for an
    /// avalanche selection).
    var payoffDelayPaychecks: Int
    /// Days the first account payoff moved earlier versus B0; nil when B0 has
    /// no first payoff inside its projection or nothing was promoted.
    var firstPayoffAdvanceDays: Int?
    /// The minimum payment B0 still funds for the promoted debt in the first
    /// paycheck after the quick win retires it — the per-paycheck obligation
    /// the promotion releases. Nil when B0 funds none after that date (or for
    /// an avalanche selection).
    var releasedMinimumPerPaycheck: Decimal?
    /// Card-ready sentences; every number in them restates a field above.
    var explanations: [String]
}

// MARK: - Scenario results (calc v3, R-19/R-24)

/// A named input a scenario or insight needs before it can answer honestly.
/// The app shows these instead of inventing values (V3-06).
///
/// The vocabulary covers the whole R-24 input set so the missing-input UI has
/// one name per field, including fields this layer cannot raise itself: a
/// missing pay day is an actionable `GenerationError` thrown before any card
/// exists, and a balance or APR the user never entered is indistinguishable
/// from a real $0 at this boundary (it surfaces as `.aprMissingOrZero`
/// instead). Those cases are declared for the data layer, which can tell the
/// difference.
enum ScenarioInputField: String, Codable, Equatable, Sendable {
    case debts                      // no debts entered at all
    case debtBalance                // data layer only — see the note above
    case debtAPR                    // data layer only — see the note above
    case debtMinimum
    case income
    case payCadence                 // thrown as a GenerationError before a card exists
    case nextPayday                 // thrown as a GenerationError before a card exists
    case protectedCash              // the saved protected floor
    case minimumProtectedCash       // Fastest Safe
    case zeroAllowanceConfirmation  // Fastest Safe
    case preferredAllowance         // Balanced
    case plannedSavings             // Balanced
    case cushionConstraint          // More Cushion: reserve and/or ceiling
    case extraPaymentAmount
    case extraPaymentTarget
}

/// One missing input, named with copy that points at the screen that fixes it.
struct ScenarioMissingInput: Codable, Equatable, Sendable {
    var field: ScenarioInputField
    var message: String
    var debtID: UUID?

    init(field: ScenarioInputField, message: String, debtID: UUID? = nil) {
        self.field = field
        self.message = message
        self.debtID = debtID
    }
}

/// Estimated time to debt-free, expressed the three ways the card shows it.
struct ScenarioDuration: Codable, Equatable, Sendable {
    /// Calendar days from the plan's first payday to the payoff date.
    var days: Int
    /// Paychecks in the projection.
    var paychecks: Int
    /// Whole months in `days`, for the "about N months" headline.
    var months: Int
}

/// Interest and time against the Balanced scenario. Negative means this
/// scenario finishes sooner / costs less than Balanced.
struct ScenarioComparisonDelta: Codable, Equatable, Sendable {
    var interestDelta: Decimal
    /// Days later (positive) or earlier (negative) than Balanced.
    var timeDelta: Int
}

/// One scenario card (R-19). Wraps the full engine result so the calendar,
/// paycheck table, and warnings all come from the same projection — a preview
/// only; nothing here persists or activates itself (R-15/V3-15).
struct ScenarioResult: Codable, Equatable, Sendable {
    var kind: ScenarioKind
    /// The projection this card summarizes. Nil when `missingInputs` stopped
    /// the calculation — the honest answer is "here is what I still need".
    var plan: PlanningResult?

    var payoffDate: Date?
    var duration: ScenarioDuration?
    /// Sum of the input debt balances.
    var totalStartingPrincipal: Decimal
    /// Principal outstanding at the start of this projection.
    var totalCurrentPrincipal: Decimal
    /// Average per-paycheck money reaching debt (minimums + extra).
    var periodicDebtContribution: Decimal
    /// Average per-paycheck cash kept in spending (allowance, floor top-up,
    /// planned savings, cushion).
    var cashRetainedPerPaycheck: Decimal
    var estimatedTotalInterest: Decimal
    /// Principal + modeled interest actually paid across the projection.
    var totalPaid: Decimal
    /// The low point of the R-23 cash path — "minimum ending cash position".
    var minimumEndingCash: Decimal?
    var deltaVsBalanced: ScenarioComparisonDelta?
    var assumptions: [PlanningNote]
    var missingInputs: [ScenarioMissingInput]
    var warnings: [PlanningNote]
    /// True when the horizon cap was reached before payoff.
    var notPayableAsConfigured: Bool
    /// Calc v4 (R-27): the Balanced selection rationale. Nil for the other
    /// two kinds, for non-computable cards, and for definitions that arrived
    /// with a pinned promotion (regeneration never re-runs the selector).
    var balancedRationale: BalancedSelectionRationale? = nil

    /// False when missing inputs prevented an honest calculation.
    var isComputable: Bool { plan != nil }

    /// Calendar-ready actions for this preview (R-19); empty when not computable.
    var events: [PlanEvent] { plan?.events ?? [] }
}

// MARK: - Extra-payment insight (calc v3, R-20)

/// How one debt's payoff moved because of the modeled extra payment.
struct ExtraPaymentDownstreamChange: Codable, Equatable, Sendable {
    var debtID: UUID
    var name: String
    var payoffDateBefore: Date?
    var payoffDateAfter: Date?
    /// Days earlier (negative) or later (positive); nil when either side never
    /// finished inside the horizon.
    var daysChanged: Int?
    /// Position in `payoffOrder` before and after — an avalanche-order change.
    var payoffOrderBefore: Int
    var payoffOrderAfter: Int
}

/// "What if I pay extra?" answered against the same engine, to the cent.
/// A preview: it never persists or activates anything (V3-15).
struct ExtraPaymentInsight: Codable, Equatable, Sendable {
    var extraPaymentID: UUID
    var kind: ExtraPaymentKind
    var amount: Decimal
    var effectiveDate: Date
    /// The debt the money actually reached first. For an automatic target this
    /// is the avalanche pick; nil when nothing eligible could take it.
    var targetDebtID: UUID?
    /// True when the user did not name a target.
    var targetWasAutomatic: Bool

    var payoffDateBefore: Date?
    var payoffDateAfter: Date?
    /// Days pulled forward; nil unless both projections finished.
    var daysSaved: Int?
    /// Paychecks removed from the projection; nil unless both finished.
    var periodsSaved: Int?
    var interestBefore: Decimal
    var interestAfter: Decimal
    /// `interestBefore − interestAfter`; nil unless both projections finished,
    /// because an unfinished track has no comparable total.
    var interestSaved: Decimal?
    /// Principal + modeled interest paid with the extra payment in place.
    var totalPaid: Decimal
    var totalPaidBefore: Decimal
    /// Debt outstanding at the payday that applies the money, before minus
    /// after — the principal effect once modeled interest has accrued.
    var projectedPrincipalReduction: Decimal
    var downstreamChanges: [ExtraPaymentDownstreamChange]
    var missingInputs: [ScenarioMissingInput]
    var assumptions: [PlanningNote]
    var warnings: [PlanningNote]

    /// False when missing inputs prevented an honest calculation.
    var isComputable: Bool { missingInputs.isEmpty }
}
