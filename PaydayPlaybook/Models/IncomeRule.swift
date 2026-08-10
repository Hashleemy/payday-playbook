import Foundation
import SwiftData

@Model
final class IncomeRule {
    var id: UUID
    var planVersionID: UUID
    var effectiveDate: Date
    var netPaycheckAmount: Decimal

    init(id: UUID = UUID(), planVersionID: UUID, effectiveDate: Date, netPaycheckAmount: Decimal) {
        self.id = id
        self.planVersionID = planVersionID
        self.effectiveDate = effectiveDate
        self.netPaycheckAmount = netPaycheckAmount
    }
}
