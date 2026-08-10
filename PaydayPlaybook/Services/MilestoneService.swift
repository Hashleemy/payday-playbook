import Foundation
import SwiftData

/// Marks milestones achieved from actual balances and keeps forecast dates
/// in sync with the latest reforecast. Baseline dates never change.
struct MilestoneService {
    let context: ModelContext
    let dateProvider: DateProviding

    init(context: ModelContext, dateProvider: DateProviding) {
        self.context = context
        self.dateProvider = dateProvider
    }

    func refreshAchievements() throws {
        let balanceService = AccountBalanceService(context: context, dateProvider: dateProvider)
        let balances = try balanceService.debtBalances()
        let milestones = try context.fetch(FetchDescriptor<Milestone>())
        let today = DateMath.startOfDay(dateProvider.now)

        let startingTotal = balances.reduce(Decimal.zero) { $0 + $1.debt.startingBalance }
        let currentTotal = balances.reduce(Decimal.zero) { $0 + $1.balance }
        let eliminated = startingTotal - currentTotal

        var changed = false
        for milestone in milestones {
            switch milestone.type {
            case .cardPaidOff:
                if milestone.achievedDate == nil,
                   let cardID = milestone.relatedDebtPlanID,
                   let balance = balances.first(where: { $0.debt.planID == cardID }),
                   balance.isPaidOff {
                    milestone.achievedDate = today
                    changed = true
                }
            case .amountEliminated:
                if milestone.achievedDate == nil,
                   let threshold = milestone.thresholdAmount,
                   eliminated >= threshold {
                    milestone.achievedDate = today
                    changed = true
                }
            case .debtFree:
                if milestone.achievedDate == nil, currentTotal.isZeroMoney {
                    milestone.achievedDate = today
                    changed = true
                }
            }
        }

        if let forecast = try ReforecastService(context: context, dateProvider: dateProvider).latestForecast() {
            let perCard = Dictionary(
                uniqueKeysWithValues: forecast.perCardPayoffDates.map { ($0.debtPlanID, $0.payoffDate) }
            )
            for milestone in milestones {
                switch milestone.type {
                case .cardPaidOff:
                    if let cardID = milestone.relatedDebtPlanID, let date = perCard[cardID],
                       milestone.forecastDate != date {
                        milestone.forecastDate = date
                        changed = true
                    }
                case .debtFree:
                    if let payoff = forecast.projectedPayoffDate, milestone.forecastDate != payoff {
                        milestone.forecastDate = payoff
                        changed = true
                    }
                case .amountEliminated:
                    break
                }
            }
        }

        if changed {
            try context.save()
        }
    }

    /// All actual debt is gone (rounded to cents).
    func isDebtFree() throws -> Bool {
        let balanceService = AccountBalanceService(context: context, dateProvider: dateProvider)
        return try balanceService.totalActualDebt().isZeroMoney
    }
}
