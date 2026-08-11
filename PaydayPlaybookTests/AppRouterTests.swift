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

    // MARK: - v0.2.0 routes

    @MainActor
    func testEveryScheduledFamilyRoutesSomewhereUseful() {
        // One case per notification family the scheduler can produce, so a
        // new family cannot ship without a destination.
        let itemID = UUID()
        let milestoneID = UUID()
        let obligationID = UUID()
        let cases: [(NotificationRoute, String, AppTab)] = [
            (.checkIn, itemID.uuidString, .today),          // payday morning + evening
            (.debt, "C", .debts),                           // debt due soon + due today
            (.obligation, obligationID.uuidString, .today), // obligation due soon + today
            (.milestone, milestoneID.uuidString, .progress),
            (.progress, "", .progress),                     // weekly summary
            (.today, "", .today)
        ]
        for (route, reference, expectedTab) in cases {
            let router = AppRouter()
            router.selectedTab = .calendar
            router.handleNotificationRoute([
                NotificationScheduler.routeKey: route.rawValue,
                NotificationScheduler.referenceKey: reference
            ])
            XCTAssertEqual(router.selectedTab, expectedTab, "route \(route.rawValue) landed on the wrong tab")
        }
    }

    @MainActor
    func testObligationAndMilestoneRoutesCarryTheirEntity() {
        let router = AppRouter()
        let obligationID = UUID()
        router.handleNotificationRoute([
            NotificationScheduler.routeKey: "obligation",
            NotificationScheduler.referenceKey: obligationID.uuidString
        ])
        XCTAssertEqual(router.pendingObligationID, obligationID)

        let milestoneID = UUID()
        router.handleNotificationRoute([
            NotificationScheduler.routeKey: "milestone",
            NotificationScheduler.referenceKey: milestoneID.uuidString
        ])
        XCTAssertEqual(router.pendingMilestoneID, milestoneID)
    }

    @MainActor
    func testLegacyCardRouteStillResolvesAfterUpgrade() {
        // Reminders scheduled by 0.1.x carry route "card"; a tap on one that
        // survives the upgrade must still open Debts.
        XCTAssertEqual(NotificationRoute.parse("card"), .debt)
        let router = AppRouter()
        router.handleNotificationRoute([
            NotificationScheduler.routeKey: "card",
            NotificationScheduler.referenceKey: "B"
        ])
        XCTAssertEqual(router.selectedTab, .debts)
        XCTAssertEqual(router.pendingDebtPlanID, "B")
    }

    @MainActor
    func testDeletedOrUnparsableReferenceStillLandsOnTheRightTab() {
        // A deep link whose entity is gone must not dead-end: the tab still
        // changes and the screen shows its own current state.
        let router = AppRouter()
        router.handleNotificationRoute([
            NotificationScheduler.routeKey: "checkin",
            NotificationScheduler.referenceKey: "not-a-uuid"
        ])
        XCTAssertEqual(router.selectedTab, .today)
        XCTAssertNil(router.pendingCheckInItemID)

        router.handleNotificationRoute([
            NotificationScheduler.routeKey: "milestone",
            NotificationScheduler.referenceKey: ""
        ])
        XCTAssertEqual(router.selectedTab, .progress)
        XCTAssertNil(router.pendingMilestoneID)
    }
}
