import Foundation
import SwiftData

/// Pay cadence (V2-06). Day-of-month values are clamped per R-11, so a stored
/// 31 means "last day" in shorter months by construction.
enum PayCadence: String, Codable, CaseIterable, Identifiable {
    case weekly
    case biweekly
    case semimonthly
    case monthly

    var id: String { rawValue }

    /// R-03 paychecks per year.
    var paychecksPerYear: Int {
        switch self {
        case .weekly: return 52
        case .biweekly: return 26
        case .semimonthly: return 24
        case .monthly: return 12
        }
    }

    /// Fixed day gap for the interval-based cadences; nil for date-of-month ones.
    var fixedDayInterval: Int? {
        switch self {
        case .weekly: return 7
        case .biweekly: return 14
        case .semimonthly, .monthly: return nil
        }
    }

    var displayName: String {
        switch self {
        case .weekly: return "Weekly"
        case .biweekly: return "Every two weeks"
        case .semimonthly: return "Twice a month"
        case .monthly: return "Monthly"
        }
    }
}

/// The user's income setup (V2-06): cadence, anchor payday, destination
/// account, and base take-home. Future raises/cuts are `IncomeChange` rows.
/// `PlanVersion` freezes its own copy of this timeline at generation
/// (`IncomeRule` rows), so editing the live schedule never rewrites a plan.
@Model
final class IncomeSchedule {
    var id: UUID = UUID()
    var cadenceRaw: String = PayCadence.biweekly.rawValue
    /// The next (or first) payday the timeline is generated from.
    var anchorPayday: Date = Date()
    /// Day of month for `.monthly` (1–31, clamped per R-11).
    var monthlyDay: Int?
    /// The two days of month for `.semimonthly` (each 1–31, clamped per R-11).
    var semimonthlyFirstDay: Int?
    var semimonthlySecondDay: Int?
    /// Cash account that receives the paycheck; nil falls back to the
    /// default income account.
    var destinationAccountID: UUID?
    /// Take-home per paycheck before any effective-dated `IncomeChange`.
    var baseTakeHome: Decimal = Decimal.zero
    var isArchived: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var cadence: PayCadence {
        get { PayCadence(rawValue: cadenceRaw) ?? .biweekly }
        set { cadenceRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        cadence: PayCadence,
        anchorPayday: Date,
        monthlyDay: Int? = nil,
        semimonthlyFirstDay: Int? = nil,
        semimonthlySecondDay: Int? = nil,
        destinationAccountID: UUID? = nil,
        baseTakeHome: Decimal,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.cadenceRaw = cadence.rawValue
        self.anchorPayday = anchorPayday
        self.monthlyDay = monthlyDay
        self.semimonthlyFirstDay = semimonthlyFirstDay
        self.semimonthlySecondDay = semimonthlySecondDay
        self.destinationAccountID = destinationAccountID
        self.baseTakeHome = baseTakeHome
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A future-dated take-home change on an `IncomeSchedule` ("raises to $2,300
/// on 2027-01-15"). Effective-dated, first-class, editable in Settings.
@Model
final class IncomeChange {
    var id: UUID = UUID()
    var scheduleID: UUID = UUID()
    var effectiveDate: Date = Date()
    var newTakeHome: Decimal = Decimal.zero
    var note: String?
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        scheduleID: UUID,
        effectiveDate: Date,
        newTakeHome: Decimal,
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.scheduleID = scheduleID
        self.effectiveDate = effectiveDate
        self.newTakeHome = newTakeHome
        self.note = note
        self.createdAt = createdAt
    }
}
