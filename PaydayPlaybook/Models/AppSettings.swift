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
