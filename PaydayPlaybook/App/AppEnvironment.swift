import Foundation
import SwiftData
import UserNotifications

/// Composition root for services shared across the app.
@MainActor
final class AppEnvironment: ObservableObject {
    let dateProvider: DateProviding
    let notificationScheduler: NotificationScheduler

    /// `dateProvider` defaults to the launch-argument-aware factory; tests
    /// inject a fixed provider so dashboard content is deterministic.
    init(dateProvider: DateProviding? = nil) {
        self.dateProvider = dateProvider ?? DateProviderFactory.make()
        self.notificationScheduler = NotificationScheduler()
    }

    func balanceService(context: ModelContext) -> AccountBalanceService {
        AccountBalanceService(context: context, dateProvider: dateProvider)
    }

    func reforecastService(context: ModelContext) -> ReforecastService {
        ReforecastService(context: context, dateProvider: dateProvider)
    }

    func milestoneService(context: ModelContext) -> MilestoneService {
        MilestoneService(context: context, dateProvider: dateProvider)
    }

    func calendarService(context: ModelContext) -> CalendarEventService {
        CalendarEventService(context: context, dateProvider: dateProvider)
    }

    func debtAllocationService(context: ModelContext) -> DebtAllocationService {
        DebtAllocationService(context: context, dateProvider: dateProvider)
    }
}

/// Routes notification taps into the router. Taps that arrive before the UI
/// has registered a handler (cold launch) are buffered and delivered once the
/// handler is set.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onRoute: (([AnyHashable: Any]) -> Void)? {
        didSet {
            if let onRoute, let pending {
                self.pending = nil
                onRoute(pending)
            }
        }
    }
    private var pending: [AnyHashable: Any]?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let onRoute = self.onRoute {
                onRoute(userInfo)
            } else {
                self.pending = userInfo
            }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
