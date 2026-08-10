import Foundation
import SwiftData

@Model
final class DebtAccount {
    var id: UUID
    /// Stable plan identifier from the seeded plan: "A" through "F".
    var planID: String
    var displayName: String
    /// Optional last four digits only. Full account numbers are never stored.
    var lastFour: String?
    var startingBalance: Decimal
    var apr: Decimal
    /// User-entered current minimum payment; nil means use the baseline estimate.
    var minimumAmount: Decimal?
    var dueDayOfMonth: Int?
    var priority: Int
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        planID: String,
        displayName: String,
        lastFour: String? = nil,
        startingBalance: Decimal,
        apr: Decimal,
        minimumAmount: Decimal? = nil,
        dueDayOfMonth: Int? = nil,
        priority: Int,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.planID = planID
        self.displayName = displayName
        self.lastFour = lastFour
        self.startingBalance = startingBalance
        self.apr = apr
        self.minimumAmount = minimumAmount
        self.dueDayOfMonth = dueDayOfMonth
        self.priority = priority
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
