import Foundation
import SwiftData

enum MilestoneKind: String, Codable, CaseIterable {
    case cardPaidOff
    case amountEliminated
    case debtFree
}

@Model
final class Milestone {
    var id: UUID
    var typeRaw: String
    var title: String
    /// Dollar threshold for amount-eliminated milestones.
    var thresholdAmount: Decimal?
    var relatedDebtPlanID: String?
    var baselineDate: Date?
    var forecastDate: Date?
    var achievedDate: Date?

    var type: MilestoneKind {
        get { MilestoneKind(rawValue: typeRaw) ?? .cardPaidOff }
        set { typeRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        type: MilestoneKind,
        title: String,
        thresholdAmount: Decimal? = nil,
        relatedDebtPlanID: String? = nil,
        baselineDate: Date? = nil,
        forecastDate: Date? = nil,
        achievedDate: Date? = nil
    ) {
        self.id = id
        self.typeRaw = type.rawValue
        self.title = title
        self.thresholdAmount = thresholdAmount
        self.relatedDebtPlanID = relatedDebtPlanID
        self.baselineDate = baselineDate
        self.forecastDate = forecastDate
        self.achievedDate = achievedDate
    }
}
