import Foundation
import SwiftData

enum NotificationKind: String, Codable, CaseIterable, Identifiable {
    case paydayMorning
    case paydayEveningIncomplete
    case cardDueSoon
    case cardDueToday
    case weeklySummary
    case milestoneApproaching
    case obligationDueSoon
    case obligationDueToday

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paydayMorning: return "Payday play"
        case .paydayEveningIncomplete: return "Incomplete payday reminder"
        case .cardDueSoon: return "Debt due soon"
        case .cardDueToday: return "Debt due today"
        case .weeklySummary: return "Weekly summary"
        case .milestoneApproaching: return "Milestone approaching"
        case .obligationDueSoon: return "Obligation due soon"
        case .obligationDueToday: return "Obligation due today"
        }
    }
}

@Model
final class NotificationPreference {
    var id: UUID
    var typeRaw: String
    var enabled: Bool
    var hour: Int
    var minute: Int
    /// Days of advance notice (card-due-soon), or paydays of notice (milestones).
    var leadDays: Int
    /// When false, notification content stays generic on the lock screen.
    var detailedLockScreenContent: Bool

    var type: NotificationKind {
        get { NotificationKind(rawValue: typeRaw) ?? .paydayMorning }
        set { typeRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        type: NotificationKind,
        enabled: Bool,
        hour: Int,
        minute: Int = 0,
        leadDays: Int = 0,
        detailedLockScreenContent: Bool = false
    ) {
        self.id = id
        self.typeRaw = type.rawValue
        self.enabled = enabled
        self.hour = hour
        self.minute = minute
        self.leadDays = leadDays
        self.detailedLockScreenContent = detailedLockScreenContent
    }

    static func seedDefaults() -> [NotificationPreference] {
        [
            NotificationPreference(type: .paydayMorning, enabled: true, hour: 8),
            NotificationPreference(type: .paydayEveningIncomplete, enabled: true, hour: 19),
            NotificationPreference(type: .cardDueSoon, enabled: true, hour: 9, leadDays: 3),
            NotificationPreference(type: .cardDueToday, enabled: true, hour: 9),
            NotificationPreference(type: .weeklySummary, enabled: true, hour: 18),
            NotificationPreference(type: .milestoneApproaching, enabled: true, hour: 9, leadDays: 1),
            NotificationPreference(type: .obligationDueSoon, enabled: true, hour: 9, leadDays: 3),
            NotificationPreference(type: .obligationDueToday, enabled: true, hour: 9)
        ]
    }

    /// Default rows for kinds missing from an existing store — added by the
    /// schema-2 upgrade without touching any existing preference row.
    static func missingDefaults(existing: [NotificationPreference]) -> [NotificationPreference] {
        let present = Set(existing.map(\.typeRaw))
        return seedDefaults().filter { !present.contains($0.typeRaw) }
    }
}
