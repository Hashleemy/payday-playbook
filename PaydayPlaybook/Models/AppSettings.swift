import Foundation
import SwiftData

enum PhaseTwoGoal: String, Codable, CaseIterable, Identifiable {
    case emergencyFund
    case carPrincipal
    case retirement
    case rothIRA
    case taxableInvesting

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .emergencyFund: return "Larger emergency fund"
        case .carPrincipal: return "Car principal"
        case .retirement: return "Retirement"
        case .rothIRA: return "Roth IRA"
        case .taxableInvesting: return "Taxable investing"
        }
    }
}

/// Single-row application settings record.
@Model
final class AppSettings {
    var id: UUID
    var onboardingComplete: Bool
    var appLockEnabled: Bool
    /// Set exactly once when the debt-free celebration has been shown.
    var debtFreeCelebrationShownAt: Date?
    var debtFreeConfirmedAt: Date?
    var phaseTwoGoalRaw: String?
    var phaseTwoTargetAmount: Decimal?
    var phaseTwoNote: String?
    var seedSchemaVersion: Int
    var createdAt: Date
    /// Set once by the schema 1→2 migration; nil on native v2 installs.
    var migratedAt: Date?
    /// Human-readable audit note recorded by the migration (MVP_LAYOUT §7.8).
    var migrationAuditNote: String?

    var phaseTwoGoal: PhaseTwoGoal? {
        get { phaseTwoGoalRaw.flatMap(PhaseTwoGoal.init(rawValue:)) }
        set { phaseTwoGoalRaw = newValue?.rawValue }
    }

    init(
        id: UUID = UUID(),
        onboardingComplete: Bool = false,
        appLockEnabled: Bool = false,
        seedSchemaVersion: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.onboardingComplete = onboardingComplete
        self.appLockEnabled = appLockEnabled
        self.seedSchemaVersion = seedSchemaVersion
        self.createdAt = createdAt
    }
}
