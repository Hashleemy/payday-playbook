import Foundation
import SwiftUI

enum AppTab: Hashable {
    case today
    case calendar
    case debts
    case progress
}

/// Central navigation state, including deep links from notifications.
@MainActor
final class AppRouter: ObservableObject {
    @Published var selectedTab: AppTab = .today
    /// Plan item to open a check-in for, triggered by deep link or Today.
    @Published var pendingCheckInItemID: UUID?
    /// Debt plan letter to open, triggered by deep link.
    @Published var pendingDebtPlanID: String?
    @Published var showSettings = false

    func handleNotificationRoute(_ userInfo: [AnyHashable: Any]) {
        guard let route = userInfo[NotificationScheduler.routeKey] as? String else { return }
        let reference = userInfo[NotificationScheduler.referenceKey] as? String
        switch NotificationScheduler.Route(rawValue: route) {
        case .checkIn:
            selectedTab = .today
            if let reference, let id = UUID(uuidString: reference) {
                pendingCheckInItemID = id
            }
        case .cardDetail:
            selectedTab = .debts
            pendingDebtPlanID = reference
        case .today:
            selectedTab = .today
        case .progress, .milestone:
            selectedTab = .progress
        case nil:
            break
        }
    }
}
