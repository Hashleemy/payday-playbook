import Foundation
import SwiftData

/// Per-paycheck obligation reserve frozen into a plan item at generation
/// (MVP_LAYOUT §6). Replaces the fixed car/train pair for generated plans;
/// migration adds equivalent rows next to the untouched legacy values on
/// Original Plan v1 items.
@Model
final class PlannedObligationReserve {
    var id: UUID = UUID()
    var paydayPlanItemID: UUID = UUID()
    var obligationID: UUID = UUID()
    var amount: Decimal = Decimal.zero

    init(
        id: UUID = UUID(),
        paydayPlanItemID: UUID,
        obligationID: UUID,
        amount: Decimal
    ) {
        self.id = id
        self.paydayPlanItemID = paydayPlanItemID
        self.obligationID = obligationID
        self.amount = amount
    }
}
