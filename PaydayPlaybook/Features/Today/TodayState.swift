import Foundation
import SwiftData

/// Assembled state for the five-second dashboard (F-02, V2-13).
///
/// Works for every plan kind: the migrated/template Original Plan v1 (calc
/// v1, stored rows + `ForecastSnapshot`s) and generated plans (calc v2,
/// stored rows + deterministic regeneration from the input snapshot).
/// Planned, actual, and reforecast values stay separate throughout (R-15).
struct TodayState {
    /// The plan whose schedule the dashboard renders: the active version
    /// when it owns payday rows, else the baseline it derives from.
    var plan: PlanVersion?
    var planItems: [PaydayPlanItem] = []
    var currentItem: PaydayPlanItem?      // payday on/before today without completion
    var nextItem: PaydayPlanItem?         // next payday strictly after today
    var currentCheckIn: PaydayCheckIn?

    // Principal
    var totalDebt: Decimal = .zero
    var startingPrincipal: Decimal = .zero
    var plannedDebtToday: Decimal = .zero
    var percentEliminated: Decimal = .zero

    // Status / target
    var statusKind: StatusBadge.Kind = .onTrack
    var targetDebt: AccountBalanceService.DebtBalance?
    /// One sentence on why the target is first (avalanche reasoning).
    var targetReason: String?
    var debtBalances: [AccountBalanceService.DebtBalance] = []

    // Forecast (best current estimate — never overwrites the plan)
    var forecast: ForecastSnapshot?
    var forecastPayoffDate: Date?
    var paychecksRemaining: Int?
    var estimatedRemainingInterest: Decimal?
    /// Estimated interest saved versus minimums only; nil when the engine
    /// withholds the comparison (insufficient inputs / unfinished track).
    var interestSaved: Decimal?

    // Accounts (V2-03/V2-13)
    var spendingAccount: AccountBalanceService.NamedAccountState?
    var reservesAccount: AccountBalanceService.NamedAccountState?
    var otherAccounts: [AccountBalanceService.NamedAccountState] = []
    var checking1: AccountBalanceService.Checking1State?
    var checking2: AccountBalanceService.Checking2State?
    /// Planned per-paycheck reserve per obligation for the displayed payday.
    var reserveLines: [(id: UUID, name: String, amount: Decimal)] = []

    // Copy
    var goalText: String?
    /// One short, neutral insight or warning (V2-14 tone rules).
    var insightLine: String?
    /// Calm calculation warning (corrupt snapshot, not-payable flag). Never
    /// replaced by placeholder numbers.
    var calculationWarning: String?

    var isDebtFree = false
    /// False when onboarding finished but no plan exists (recovery state).
    var hasPlan = false

    @MainActor
    static func load(context: ModelContext, environment: AppEnvironment) -> TodayState {
        var state = TodayState()
        do {
            let today = DateMath.startOfDay(environment.dateProvider.now)
            let plans = try context.fetch(FetchDescriptor<PlanVersion>())
            let baseline = try PlanRepository.legacyBaseline(context: context)
            let active = plans.first(where: \.isActive)

            func items(for plan: PlanVersion) throws -> [PaydayPlanItem] {
                let planID = plan.id
                return try context.fetch(
                    FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == planID })
                ).sorted { $0.sequenceNumber < $1.sequenceNumber }
            }

            // Schedule source: active plan when it owns payday rows;
            // 0.1.x settings-only versions fall back to the baseline schedule.
            var plan = active ?? baseline
            var planItems = try plan.map(items(for:)) ?? []
            if planItems.isEmpty, let baseline, plan?.id != baseline.id {
                plan = baseline
                planItems = try items(for: baseline)
            }
            guard let plan, !planItems.isEmpty else {
                state.hasPlan = false
                return state
            }
            state.hasPlan = true
            state.plan = plan
            state.planItems = planItems

            let checkIns = try context.fetch(FetchDescriptor<PaydayCheckIn>())
            let checkInsByItem = Dictionary(grouping: checkIns, by: \.paydayPlanItemID)

            let pastItems = planItems.filter { DateMath.startOfDay($0.date) <= today }
            let openPast = pastItems.filter { item in
                let status = checkInsByItem[item.id]?.first?.status
                return status != .completed && status != .needsAttention
            }
            // Earliest open payday first so missed check-ins stay reachable.
            state.currentItem = openPast.first ?? pastItems.last
            state.nextItem = planItems.first { DateMath.startOfDay($0.date) > today }
            if let current = state.currentItem {
                state.currentCheckIn = checkInsByItem[current.id]?.first
            }

            let balanceService = environment.balanceService(context: context)
            let balances = try balanceService.debtBalances()
            state.debtBalances = balances
            state.totalDebt = balances.reduce(Decimal.zero) { $0 + $1.balance }.rounded2
            let startingTotal = balances.reduce(Decimal.zero) { $0 + $1.debt.startingBalance }
            state.startingPrincipal = startingTotal.rounded2
            if startingTotal > 0 {
                state.percentEliminated = ((startingTotal - state.totalDebt) / startingTotal * 100).rounded2
            }
            state.isDebtFree = state.totalDebt.isZeroMoney && !balances.isEmpty

            let plannedToday = pastItems.last?.plannedDebtAfter ?? startingTotal
            state.plannedDebtToday = plannedToday
            let variance = (plannedToday - state.totalDebt).rounded2
            if state.currentCheckIn?.status == .needsAttention {
                state.statusKind = .needsAttention
            } else if variance >= Decimal(string: "0.01")! {
                state.statusKind = .ahead(variance)
            } else if variance <= Decimal(string: "-0.01")! {
                state.statusKind = .behind(-variance)
            } else {
                state.statusKind = .onTrack
            }

            state.targetDebt = balances.first { !$0.isPaidOff }

            // Forecast + interest, dispatched on the plan's calculation stamp.
            state.forecast = try environment.reforecastService(context: context).latestForecast()
            if plan.calculationVersion >= PlanContract.minimumModernCalculationVersion {
                loadCalcV2Forecast(into: &state, plan: plan, context: context, environment: environment)
            } else {
                state.forecastPayoffDate = state.forecast?.projectedPayoffDate ?? plan.baselinePayoffDate
                state.paychecksRemaining = state.forecast?.remainingPaychecks
                state.estimatedRemainingInterest = state.forecast?.estimatedRemainingInterest
                state.interestSaved = nil // minimums-only comparison needs calc v2
            }
            if state.targetReason == nil, let target = state.targetDebt {
                state.targetReason = "Highest APR of your active debts (\(DebtFormat.aprText(target.debt.apr))) — extra dollars here save the most interest."
            }

            // Accounts by role (V2-03). Legacy stores keep the derived
            // Checking 1/2 states; named accounts wrap them for display.
            state.checking1 = try balanceService.checking1State(plan: plan, planItems: planItems)
            state.checking2 = try balanceService.checking2State()
            let named = try balanceService.namedAccountStates(plan: plan, planItems: planItems)
            if !named.isEmpty {
                let spending = named.first { $0.account.roles.contains(.spending) }
                let reserves = named.first { $0.account.roles.contains(.reserves) && $0.account.id != spending?.account.id }
                state.spendingAccount = spending
                state.reservesAccount = reserves
                state.otherAccounts = named.filter {
                    $0.account.id != spending?.account.id && $0.account.id != reserves?.account.id
                }
            }

            // Planned obligation reserves for the displayed payday (V2-07).
            if let displayItem = state.currentItem ?? state.nextItem {
                let itemID = displayItem.id
                let reserveRows = try context.fetch(
                    FetchDescriptor<PlannedObligationReserve>(predicate: #Predicate { $0.paydayPlanItemID == itemID })
                )
                let obligations = try context.fetch(FetchDescriptor<RecurringObligation>())
                let names = Dictionary(uniqueKeysWithValues: obligations.map { ($0.id, $0.name) })
                state.reserveLines = reserveRows
                    .map { (id: $0.obligationID, name: names[$0.obligationID] ?? "Obligation", amount: $0.amount) }
                    .sorted { $0.name < $1.name }
            }

            state.goalText = try context.fetch(FetchDescriptor<UserGoalProfile>()).first?.goalText

            state.insightLine = insight(for: state, environment: environment)
        } catch {
            // Leave partial state; the dashboard renders what it can and
            // never fabricates a number for a section that failed to load.
        }
        return state
    }

    /// Calc-v2 forecast values, read from the plan's own stored rows and a
    /// display-only engine reforecast. A corrupt snapshot degrades to the
    /// stored baseline values with a calm warning — never placeholder math.
    @MainActor
    private static func loadCalcV2Forecast(
        into state: inout TodayState,
        plan: PlanVersion,
        context: ModelContext,
        environment: AppEnvironment
    ) {
        state.forecastPayoffDate = plan.baselinePayoffDate
        let service = GeneratedPlanService(context: context, dateProvider: environment.dateProvider)
        do {
            let baseline = try service.baselineResult(for: plan)
            state.interestSaved = baseline?.minimumOnlyComparison?.interestSaved
            state.estimatedRemainingInterest = baseline?.estimatedRemainingInterest
            if let reforecast = try service.reforecastResult(for: plan) {
                state.forecastPayoffDate = reforecast.forecastPayoffDate
                state.paychecksRemaining = reforecast.paycheckCount
                state.estimatedRemainingInterest = reforecast.estimatedRemainingInterest
                if reforecast.notPayableAsConfigured {
                    state.calculationWarning = "As configured, the current budget doesn't retire every debt inside the projection horizon. The plan stays as written — consider revisiting the inputs."
                }
                if state.forecastPayoffDate == nil && !reforecast.notPayableAsConfigured {
                    state.forecastPayoffDate = plan.baselinePayoffDate
                }
            }
            if let explanation = baseline?.recommendationExplanations.first {
                state.targetReason = explanation
            }
        } catch let error as GeneratedPlanService.ServiceError {
            state.calculationWarning = error.errorDescription
        } catch {
            state.calculationWarning = "The forecast couldn't be updated. Your plan and history are unchanged."
        }
    }

    /// One short, neutral line (V2-14 tone): most useful first, never shaming.
    private static func insight(for state: TodayState, environment: AppEnvironment) -> String {
        // 1. A payday that needs outside funds (R-09).
        if let item = ([state.currentItem, state.nextItem].compactMap { $0 }).first(where: { $0.shortfallAmount != nil }),
           let gap = item.shortfallAmount {
            return "Payday #\(item.sequenceNumber) needs about \(MoneyFormat.string(gap)) from outside funds. Minimums stay covered in the plan."
        }
        // 2. Critical utilization (R-12) — the canonical threshold, so this
        // line can never fire at a level the badge would not (V4-04).
        if let critical = state.debtBalances.first(where: { balance in
            guard let utilization = balance.debt.utilization(currentBalance: balance.balance) else { return false }
            return utilization >= UtilizationMath.attentionThreshold
        }) {
            return "\(critical.debt.displayName) is using over 90% of its limit — needs attention."
        }
        // 3. Behind plan — stated plainly, no blame.
        if case .behind(let amount) = state.statusKind {
            return "About \(MoneyFormat.string(amount)) behind the plan right now. The next payday play closes the gap."
        }
        // 4. Interest saved (estimate-honest, only when the engine supports it).
        if let saved = state.interestSaved, saved > 0 {
            return "Following this plan is estimated to save about \(MoneyFormat.string(saved)) in interest versus paying minimums only."
        }
        // 5. Ahead of plan.
        if case .ahead(let amount) = state.statusKind, amount >= 1 {
            return "You're about \(MoneyFormat.string(amount)) ahead of the plan. Keep the same play."
        }
        // 6. Quiet default.
        return "On track. Nothing needs your attention today."
    }
}
