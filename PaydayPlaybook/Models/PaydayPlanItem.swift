import Foundation
import SwiftData

@Model
final class PaydayPlanItem {
    var id: UUID
    var planVersionID: UUID
    var sequenceNumber: Int
    var date: Date
    var plannedIncome: Decimal
    var plannedC1Keep: Decimal
    var plannedBufferAdd: Decimal
    var plannedAllowance: Decimal
    var plannedC2Transfer: Decimal
    var plannedCarReserve: Decimal
    var plannedTrainReserve: Decimal
    var plannedCardBudget: Decimal
    /// Plan letter of the avalanche target for this check, e.g. "B".
    var plannedTargetDebtID: String
    var plannedDebtAfter: Decimal
    var plannedC1NoSpendCeiling: Decimal
    /// R-09: exact gap when floor + obligations + minimums exceed take-home.
    /// Nil means the paycheck is fully funded. Never set on migrated items.
    var shortfallAmount: Decimal?

    /// R-09 "needs attention" flag for calendar/dashboard rendering.
    var needsAttention: Bool { shortfallAmount != nil }

    init(
        id: UUID = UUID(),
        planVersionID: UUID,
        sequenceNumber: Int,
        date: Date,
        plannedIncome: Decimal,
        plannedC1Keep: Decimal,
        plannedBufferAdd: Decimal,
        plannedAllowance: Decimal,
        plannedC2Transfer: Decimal,
        plannedCarReserve: Decimal,
        plannedTrainReserve: Decimal,
        plannedCardBudget: Decimal,
        plannedTargetDebtID: String,
        plannedDebtAfter: Decimal,
        plannedC1NoSpendCeiling: Decimal
    ) {
        self.id = id
        self.planVersionID = planVersionID
        self.sequenceNumber = sequenceNumber
        self.date = date
        self.plannedIncome = plannedIncome
        self.plannedC1Keep = plannedC1Keep
        self.plannedBufferAdd = plannedBufferAdd
        self.plannedAllowance = plannedAllowance
        self.plannedC2Transfer = plannedC2Transfer
        self.plannedCarReserve = plannedCarReserve
        self.plannedTrainReserve = plannedTrainReserve
        self.plannedCardBudget = plannedCardBudget
        self.plannedTargetDebtID = plannedTargetDebtID
        self.plannedDebtAfter = plannedDebtAfter
        self.plannedC1NoSpendCeiling = plannedC1NoSpendCeiling
    }
}

/// Planned per-card balance after a given payday (related rows, per MVP layout §5).
@Model
final class PlannedCardBalance {
    var id: UUID
    var paydayPlanItemID: UUID
    var debtPlanID: String
    var balanceAfter: Decimal

    init(id: UUID = UUID(), paydayPlanItemID: UUID, debtPlanID: String, balanceAfter: Decimal) {
        self.id = id
        self.paydayPlanItemID = paydayPlanItemID
        self.debtPlanID = debtPlanID
        self.balanceAfter = balanceAfter
    }
}
