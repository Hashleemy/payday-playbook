import Foundation
import SwiftData

@Model
final class PlanVersion {
    var id: UUID
    var name: String
    var createdAt: Date
    var isOriginalBaseline: Bool
    var isActive: Bool
    var firstPayday: Date
    var payFrequencyDays: Int
    var startingChecking1: Decimal
    var protectedBuffer: Decimal
    var allowanceCap: Decimal
    var firstCheckBufferAdd: Decimal
    var carReservePerCheck: Decimal
    var trainReservePerCheck: Decimal
    var calculationVersion: Int
    var timeZoneID: String
    /// Comma-separated debt plan IDs in avalanche priority order, e.g. "B,D,A,F,C,E".
    var avalancheOrderRaw: String
    var baselinePayoffDate: Date
    var baselineModeledInterest: Decimal
    var baselineNoSpendCeiling: Decimal
    /// V2-06. Migrated plans are biweekly (`payFrequencyDays` stays 14 and
    /// remains authoritative for calc-v1 plans).
    var payCadenceRaw: String = PayCadence.biweekly.rawValue
    /// Day of month for `.monthly` cadence (clamped per R-11).
    var monthlyPayDay: Int?
    /// The two days of month for `.semimonthly` cadence (clamped per R-11).
    var semimonthlyPayDay1: Int?
    var semimonthlyPayDay2: Int?
    /// Cash account that received income when this plan was generated.
    var incomeAccountID: UUID?
    /// True for plans generated from onboarding inputs (calc v2); false for
    /// the migrated/template Original Plan v1.
    var generatedFromProfile: Bool = false
    /// JSON-encoded `StoredPlanInput` snapshot captured at generation, so the
    /// plan is reproducible byte-for-byte. Nil on Original Plan v1 — it
    /// predates calc v2 and its stored schedule is the truth.
    var inputSnapshotData: Data?

    var payCadence: PayCadence {
        get { PayCadence(rawValue: payCadenceRaw) ?? .biweekly }
        set { payCadenceRaw = newValue.rawValue }
    }

    var avalancheOrder: [String] {
        get { avalancheOrderRaw.split(separator: ",").map(String.init) }
        set { avalancheOrderRaw = newValue.joined(separator: ",") }
    }

    var totalFixedReservePerCheck: Decimal {
        carReservePerCheck + trainReservePerCheck
    }

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        isOriginalBaseline: Bool,
        isActive: Bool,
        firstPayday: Date,
        payFrequencyDays: Int,
        startingChecking1: Decimal,
        protectedBuffer: Decimal,
        allowanceCap: Decimal,
        firstCheckBufferAdd: Decimal,
        carReservePerCheck: Decimal,
        trainReservePerCheck: Decimal,
        calculationVersion: Int,
        timeZoneID: String = TimeZone.current.identifier,
        avalancheOrderRaw: String,
        baselinePayoffDate: Date,
        baselineModeledInterest: Decimal,
        baselineNoSpendCeiling: Decimal
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.isOriginalBaseline = isOriginalBaseline
        self.isActive = isActive
        self.firstPayday = firstPayday
        self.payFrequencyDays = payFrequencyDays
        self.startingChecking1 = startingChecking1
        self.protectedBuffer = protectedBuffer
        self.allowanceCap = allowanceCap
        self.firstCheckBufferAdd = firstCheckBufferAdd
        self.carReservePerCheck = carReservePerCheck
        self.trainReservePerCheck = trainReservePerCheck
        self.calculationVersion = calculationVersion
        self.timeZoneID = timeZoneID
        self.avalancheOrderRaw = avalancheOrderRaw
        self.baselinePayoffDate = baselinePayoffDate
        self.baselineModeledInterest = baselineModeledInterest
        self.baselineNoSpendCeiling = baselineNoSpendCeiling
    }
}
