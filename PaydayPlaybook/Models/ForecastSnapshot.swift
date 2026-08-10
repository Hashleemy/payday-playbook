import Foundation
import SwiftData

enum ForecastTrigger: String, Codable, CaseIterable {
    case initialSeed
    case paydayCompleted
    case balanceSnapshot
    case aprChange
    case paycheckChange
    case extraPayment
    case planEdit
    case manual
}

struct PerCardPayoff: Codable, Equatable {
    var debtPlanID: String
    var payoffDate: Date
}

@Model
final class ForecastSnapshot {
    var calculatedAt: Date
    var id: UUID
    var sourcePlanVersionID: UUID
    var triggerTypeRaw: String
    var projectedPayoffDate: Date?
    var remainingPaychecks: Int
    var estimatedRemainingInterest: Decimal
    /// JSON-encoded [PerCardPayoff].
    var perCardPayoffData: Data
    var summaryExplanation: String

    var triggerType: ForecastTrigger {
        get { ForecastTrigger(rawValue: triggerTypeRaw) ?? .manual }
        set { triggerTypeRaw = newValue.rawValue }
    }

    var perCardPayoffDates: [PerCardPayoff] {
        get { (try? JSONDecoder().decode([PerCardPayoff].self, from: perCardPayoffData)) ?? [] }
        set { perCardPayoffData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    init(
        id: UUID = UUID(),
        calculatedAt: Date = Date(),
        sourcePlanVersionID: UUID,
        triggerType: ForecastTrigger,
        projectedPayoffDate: Date?,
        remainingPaychecks: Int,
        estimatedRemainingInterest: Decimal,
        perCardPayoffDates: [PerCardPayoff],
        summaryExplanation: String
    ) {
        self.id = id
        self.calculatedAt = calculatedAt
        self.sourcePlanVersionID = sourcePlanVersionID
        self.triggerTypeRaw = triggerType.rawValue
        self.projectedPayoffDate = projectedPayoffDate
        self.remainingPaychecks = remainingPaychecks
        self.estimatedRemainingInterest = estimatedRemainingInterest
        self.perCardPayoffData = (try? JSONEncoder().encode(perCardPayoffDates)) ?? Data()
        self.summaryExplanation = summaryExplanation
    }
}
