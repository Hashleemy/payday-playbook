import XCTest
@testable import PaydayPlaybook

/// F-11: notification payloads deep-link to the right destination.
final class AppRouterTests: XCTestCase {

    @MainActor
    func testCheckInRoute() {
        let router = AppRouter()
        let itemID = UUID()
        router.handleNotificationRoute([
            NotificationScheduler.routeKey: "checkin",
            NotificationScheduler.referenceKey: itemID.uuidString
        ])
        XCTAssertEqual(router.selectedTab, .today)
        XCTAssertEqual(router.pendingCheckInItemID, itemID)
    }

    @MainActor
    func testCardDetailRoute() {
        let router = AppRouter()
        router.handleNotificationRoute([
            NotificationScheduler.routeKey: "card",
            NotificationScheduler.referenceKey: "C"
        ])
        XCTAssertEqual(router.selectedTab, .debts)
        XCTAssertEqual(router.pendingDebtPlanID, "C")
    }

    @MainActor
    func testProgressAndMilestoneRoutes() {
        let router = AppRouter()
        router.handleNotificationRoute([NotificationScheduler.routeKey: "progress"])
        XCTAssertEqual(router.selectedTab, .progress)
        router.handleNotificationRoute([NotificationScheduler.routeKey: "milestone"])
        XCTAssertEqual(router.selectedTab, .progress)
    }

    @MainActor
    func testUnknownRouteIsIgnored() {
        let router = AppRouter()
        let originalTab = router.selectedTab
        router.handleNotificationRoute(["route": "bogus"])
        XCTAssertEqual(router.selectedTab, originalTab)
        router.handleNotificationRoute([:])
        XCTAssertEqual(router.selectedTab, originalTab)
    }
}
