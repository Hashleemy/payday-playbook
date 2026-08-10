import Foundation
import SwiftData

enum CheckInStatus: String, Codable, CaseIterable {
    case draft
    case completed
    case needsAttention
}

@Model
final class PaydayCheckIn {
    var id: UUID
    var paydayPlanItemID: UUID
    var statusRaw: String
    var actualIncome: Decimal?
    var outsideFundsUsed: Decimal?
    var actualC1Kept: Decimal?
    var actualC1Balance: Decimal?
    var actualAllowanceSpent: Decimal?
    var actualC2Transfer: Decimal?
    var actualCarReserve: Decimal?
    var actualTrainReserve: Decimal?
    var unallocatedAmount: Decimal?
    var note: String?
    /// Required explanation when a mathematically unreconciled check is marked complete.
    var reconciliationException: String?
    /// Last step the user was on, for resuming drafts (1-5).
    var currentStep: Int
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    var status: CheckInStatus {
        get { CheckInStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        paydayPlanItemID: UUID,
        status: CheckInStatus = .draft,
        currentStep: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.paydayPlanItemID = paydayPlanItemID
        self.statusRaw = status.rawValue
        self.currentStep = currentStep
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Actual payment amounts per card captured inside a payday check-in draft.
/// Ledger entries are only created when the check-in is completed.
@Model
final class CheckInCardPayment {
    var id: UUID
    var checkInID: UUID
    var debtPlanID: String
    var amount: Decimal
    /// Post-payment balance the user optionally reported during reconcile.
    var reportedBalanceAfter: Decimal?

    init(
        id: UUID = UUID(),
        checkInID: UUID,
        debtPlanID: String,
        amount: Decimal,
        reportedBalanceAfter: Decimal? = nil
    ) {
        self.id = id
        self.checkInID = checkInID
        self.debtPlanID = debtPlanID
        self.amount = amount
        self.reportedBalanceAfter = reportedBalanceAfter
    }
}
