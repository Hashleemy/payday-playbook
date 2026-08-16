import XCTest
import UserNotifications
@testable import PaydayPlaybook

/// The device pass has to answer "did that edit leave a duplicate behind?", and
/// the lock screen cannot answer it — a stale trigger looks exactly like a
/// correct one until it fires on the wrong day. These cover the detector behind
/// the debug diagnostics screen, so a red row on the phone means something real
/// and a green one is worth believing.
final class NotificationDiagnosticsTests: XCTestCase {

    private func summary(
        _ identifier: String,
        title: String = "Payday check-in",
        body: String = "Your payday check-in is ready",
        fire: Date? = TestSupport.date(2054, 9, 1)
    ) -> PendingNotificationSummary {
        PendingNotificationSummary(identifier: identifier, title: title, body: body, fireDate: fire)
    }

    // MARK: - The upgrade failure mode

    /// The one the upgrade rehearsal is looking for: a 0.1.x letter-keyed
    /// request left pending beside its v2 replacement. Different identifiers,
    /// so the system replaces neither — the user gets both.
    func testLegacyIdentifierLeftBesideItsReplacementIsReported() {
        let debtID = UUID().uuidString
        let pending = [
            summary("due-soon-B-20540901", title: "A debt payment is due soon"),
            summary("debt-due-soon-\(debtID)-20540901", title: "A debt payment is due soon")
        ]

        let findings = NotificationDiagnostics.findings(for: pending)

        XCTAssertTrue(findings.contains(.legacyScheme(identifier: "due-soon-B-20540901")))
        XCTAssertTrue(
            findings.contains { if case .duplicateContent = $0 { return true } else { return false } },
            "Same words at the same moment under two identifiers is a duplicate the user will experience."
        )
    }

    /// `milestone-` is a 0.1.x prefix but also prefixes the current
    /// `milestone-approaching-`. The current family must not be flagged.
    func testCurrentMilestoneFamilyIsNotMistakenForTheLegacyPrefix() {
        let identifier = NotificationFamily.milestoneApproaching.identifier(entity: UUID().uuidString)

        XCTAssertFalse(NotificationDiagnostics.isLegacy(identifier))
        XCTAssertTrue(NotificationDiagnostics.isLegacy("milestone-3"))

        let findings = NotificationDiagnostics.findings(for: [summary(identifier)])
        XCTAssertFalse(findings.contains { $0.isProblem })
    }

    // MARK: - Quiet on a healthy schedule

    func testAHealthyScheduleProducesNoProblems() {
        let itemID = UUID().uuidString
        let debtID = UUID().uuidString
        let pending = [
            summary(
                NotificationFamily.paydayMorning.identifier(entity: itemID),
                title: "Payday", fire: TestSupport.date(2054, 9, 1)
            ),
            summary(
                NotificationFamily.paydayEvening.identifier(entity: itemID),
                title: "Check-in", fire: TestSupport.date(2054, 9, 2)
            ),
            summary(
                NotificationFamily.debtDueSoon.identifier(entity: debtID, occurrence: "20540905"),
                title: "A debt payment is due soon", fire: TestSupport.date(2054, 9, 5)
            )
        ]

        XCTAssertTrue(NotificationDiagnostics.findings(for: pending).allSatisfy { !$0.isProblem })
    }

    /// Two reminders can legitimately share wording — they must differ by
    /// moment, not by identifier alone, or the detector would cry wolf on every
    /// recurring family.
    func testSameCopyOnDifferentDaysIsNotADuplicate() {
        let debtID = UUID().uuidString
        let pending = [
            summary(
                NotificationFamily.debtDueSoon.identifier(entity: debtID, occurrence: "20540905"),
                fire: TestSupport.date(2054, 9, 5)
            ),
            summary(
                NotificationFamily.debtDueSoon.identifier(entity: debtID, occurrence: "20541005"),
                fire: TestSupport.date(2054, 10, 5)
            )
        ]

        XCTAssertTrue(NotificationDiagnostics.findings(for: pending).allSatisfy { !$0.isProblem })
    }

    // MARK: - Other apps' requests

    func testForeignRequestsAreReportedButNeverAsAProblem() {
        let findings = NotificationDiagnostics.findings(for: [summary("com.other.app.reminder")])

        XCTAssertEqual(findings, [.foreign(identifier: "com.other.app.reminder")])
        XCTAssertFalse(findings.contains { $0.isProblem })
    }

    // MARK: - Reading real requests

    /// The screen builds its summaries from `UNNotificationRequest`; that
    /// mapping is what runs on the phone, so it is worth pinning.
    func testSummaryReadsIdentifierCopyAndFireDateFromARealRequest() throws {
        let content = UNMutableNotificationContent()
        content.title = "Payday"
        content.body = "Your payday check-in is ready"
        let components = DateComponents(year: 2027, month: 3, day: 14, hour: 9, minute: 0)
        let request = UNNotificationRequest(
            identifier: NotificationFamily.paydayMorning.identifier(entity: "abc"),
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )

        let summary = PendingNotificationSummary(request: request)

        XCTAssertEqual(summary.identifier, "payday-morning-abc")
        XCTAssertEqual(summary.title, "Payday")
        XCTAssertEqual(summary.body, "Your payday check-in is ready")
        XCTAssertTrue(summary.isOurs)
        let fireDate = try XCTUnwrap(summary.fireDate)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: fireDate)
        XCTAssertEqual(parts.year, 2027)
        XCTAssertEqual(parts.month, 3)
        XCTAssertEqual(parts.day, 14)
        XCTAssertEqual(parts.hour, 9)
    }
}
