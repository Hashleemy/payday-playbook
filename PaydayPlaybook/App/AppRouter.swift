import Foundation
import SwiftUI

enum AppTab: Hashable {
    case today
    case calendar
    /// The v0.3.0 Checking Accounts workspace (V3-02). Placed between Calendar
    /// and Debts so the tab order reads money-in → money-out.
    case accounts
    case debts
    case progress
}

/// Central navigation state, including deep links from notifications.
///
/// Routes carry entity identity (a plan-item `UUID`, a debt plan ID, a
/// milestone `UUID`) rather than positions, so a tap still lands correctly
/// after the plan has been edited. Targets that no longer exist fall back to
/// the closest sensible screen instead of dead-ending (V2-11).
@MainActor
final class AppRouter: ObservableObject {
    @Published var selectedTab: AppTab = .today
    /// Plan item to open a check-in for, triggered by deep link or Today.
    @Published var pendingCheckInItemID: UUID?
    /// Debt to open by entity, triggered by deep link. Preferred over the
    /// plan letter: letters are reusable slots, so a reminder delivered
    /// before a delete-and-re-add could otherwise open the wrong debt.
    @Published var pendingDebtID: UUID?
    /// Debt plan letter to open. Still populated for reminders scheduled by
    /// 0.1.x/0.2.x, which carried only the letter, and for links that never
    /// had a `UUID` (a plan item's avalanche target).
    @Published var pendingDebtPlanID: String?
    /// Obligation to highlight, triggered by a bill-due deep link.
    @Published var pendingObligationID: UUID?
    /// Milestone to reveal on Progress, triggered by deep link.
    @Published var pendingMilestoneID: UUID?
    @Published var showSettings = false

    func handleNotificationRoute(_ userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo[NotificationScheduler.routeKey] as? String,
              let route = NotificationRoute.parse(raw) else { return }
        let reference = userInfo[NotificationScheduler.referenceKey] as? String
        switch route {
        case .checkIn:
            selectedTab = .today
            // A reference that no longer resolves still lands on Today,
            // where the next open payday is the first thing on screen.
            if let reference, let id = UUID(uuidString: reference) {
                pendingCheckInItemID = id
            }
        case .debt:
            selectedTab = .debts
            // v0.3.0 reminders carry the debt's UUID; anything else is a
            // pre-upgrade plan letter and still resolves the old way.
            if let reference, let id = UUID(uuidString: reference) {
                pendingDebtID = id
            } else {
                pendingDebtPlanID = reference
            }
        case .obligation:
            // The calendar is where a bill's due date lives, alongside the
            // rest of that day's play; it selects the obligation's next
            // occurrence.
            selectedTab = .calendar
            if let reference, let id = UUID(uuidString: reference) {
                pendingObligationID = id
            }
        case .today:
            selectedTab = .today
        case .milestone:
            selectedTab = .progress
            if let reference, let id = UUID(uuidString: reference) {
                pendingMilestoneID = id
            }
        case .progress:
            selectedTab = .progress
        }
    }
}
