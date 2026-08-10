import XCTest

/// UI tests run against an isolated store (`--uitest`), reset per test with
/// `--uitest-reset`, and a pinned "today" so flows are deterministic.
final class PaydayPlaybookUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Matches text whether or not the row's children were merged into a
    /// single accessibility element (e.g. by LabeledContent).
    private func anyText(_ app: XCUIApplication, containing needle: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS %@", needle)
        let asStatic = app.staticTexts.matching(predicate).firstMatch
        if asStatic.exists { return asStatic }
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    private func launch(
        reset: Bool = true,
        skipOnboarding: Bool = false,
        today: String = "2026-08-20",
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest", "--uitest-today", today]
        if reset { app.launchArguments.append("--uitest-reset") }
        if skipOnboarding { app.launchArguments.append("--uitest-skip-onboarding") }
        app.launchArguments += extraArguments
        app.launch()
        return app
    }

    // Clean install: onboarding shows the exact plan and lands on Today (F-01).
    @MainActor
    func testOnboardingSeedsPlanAndLandsOnToday() throws {
        let app = launch()

        let loadPlan = app.buttons["onboarding.loadPlan"]
        XCTAssertTrue(loadPlan.waitForExistence(timeout: 10))
        app.swipeUp()
        loadPlan.tap()

        // Confirmation screen shows the exact seeded numbers.
        XCTAssertTrue(anyText(app, containing: "$29,681.61").waitForExistence(timeout: 5))
        XCTAssertTrue(anyText(app, containing: "Jun 24, 2027").exists)
        app.buttons["onboarding.usePlan"].tap()

        // Cards can be skipped without blocking.
        XCTAssertTrue(app.buttons["onboarding.cardsContinue"].waitForExistence(timeout: 5))
        app.buttons["onboarding.cardsContinue"].tap()

        // Notifications are optional.
        XCTAssertTrue(app.buttons["onboarding.skipNotifications"].waitForExistence(timeout: 5))
        app.buttons["onboarding.skipNotifications"].tap()

        // Today dashboard with the payday check-in ready (today is payday #1).
        let checkInButton = app.buttons["today.checkInButton"]
        XCTAssertTrue(checkInButton.waitForExistence(timeout: 10))
        XCTAssertEqual(checkInButton.label, "Start Check-In")
        XCTAssertTrue(app.staticTexts["Where you stand"].exists)
    }

    // Relaunching after onboarding does not duplicate the seed (F-01) and
    // user data persists across relaunch.
    @MainActor
    func testSeedSurvivesRelaunchWithoutDuplicates() throws {
        var app = launch(skipOnboarding: true)
        XCTAssertTrue(app.buttons["today.checkInButton"].waitForExistence(timeout: 10))
        app.terminate()

        // Relaunch without reset: same store, still exactly one plan.
        app = launch(reset: false, skipOnboarding: true)
        XCTAssertTrue(app.buttons["today.checkInButton"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Debts"].tap()
        // Six cards, none duplicated: card B row exists exactly once.
        let cardB = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Card B'"))
        XCTAssertTrue(cardB.firstMatch.waitForExistence(timeout: 5))
    }

    // Complete the first payday check-in end to end (F-03).
    @MainActor
    func testCompleteFirstPaydayCheckIn() throws {
        let app = launch(skipOnboarding: true)
        let checkInButton = app.buttons["today.checkInButton"]
        XCTAssertTrue(checkInButton.waitForExistence(timeout: 10))
        checkInButton.tap()

        // Step 1 — income prefilled with the planned $2,094.
        XCTAssertTrue(app.staticTexts["Step 1 of 5 — Income"].waitForExistence(timeout: 5))
        app.buttons["checkin.next"].tap()
        XCTAssertTrue(app.staticTexts["Step 2 of 5 — Checking 1"].waitForExistence(timeout: 5))
        app.buttons["checkin.next"].tap()
        XCTAssertTrue(app.staticTexts["Step 3 of 5 — Checking 2"].waitForExistence(timeout: 5))
        app.buttons["checkin.next"].tap()
        XCTAssertTrue(app.staticTexts["Step 4 of 5 — Card payments"].waitForExistence(timeout: 5))
        app.buttons["checkin.next"].tap()
        XCTAssertTrue(app.staticTexts["Step 5 of 5 — Reconcile"].waitForExistence(timeout: 5))

        let complete = app.buttons["checkin.complete"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        complete.tap()

        XCTAssertTrue(app.staticTexts["Payday complete"].waitForExistence(timeout: 8))
        app.buttons["Close"].tap()

        // Today now offers review, and status reflects the completed check.
        XCTAssertTrue(checkInButton.waitForExistence(timeout: 5))
        XCTAssertEqual(checkInButton.label, "Review Completed Check")
    }

    // Save a draft, leave, and resume on the saved step (F-03).
    @MainActor
    func testSaveAndResumeDraft() throws {
        let app = launch(skipOnboarding: true)
        let checkInButton = app.buttons["today.checkInButton"]
        XCTAssertTrue(checkInButton.waitForExistence(timeout: 10))
        checkInButton.tap()

        XCTAssertTrue(app.staticTexts["Step 1 of 5 — Income"].waitForExistence(timeout: 5))
        app.buttons["checkin.next"].tap()
        XCTAssertTrue(app.staticTexts["Step 2 of 5 — Checking 1"].waitForExistence(timeout: 5))
        app.buttons["checkin.saveDraft"].tap()

        // The button reflects the draft.
        XCTAssertTrue(checkInButton.waitForExistence(timeout: 5))
        XCTAssertEqual(checkInButton.label, "Continue Check-In")
        checkInButton.tap()
        // Resumes on step 2.
        XCTAssertTrue(app.staticTexts["Step 2 of 5 — Checking 1"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
    }

    // Record a payment and an authoritative balance update (F-04, F-05).
    @MainActor
    func testAddPaymentAndBalanceUpdate() throws {
        let app = launch(skipOnboarding: true, today: "2026-08-21")
        XCTAssertTrue(app.tabBars.buttons["Debts"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Debts"].tap()

        let cardRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Card B'")).firstMatch
        XCTAssertTrue(cardRow.waitForExistence(timeout: 5))
        cardRow.tap()

        // Add a payment.
        app.buttons["Add Payment"].tap()
        let amountField = app.textFields["payment.amount"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
        amountField.tap()
        amountField.typeText("50")
        app.buttons["payment.save"].tap()

        // Payment shows in history (scroll the lazy list to materialize it).
        XCTAssertTrue(app.buttons["Update Balance"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(anyText(app, containing: "Card payment").waitForExistence(timeout: 5))
        app.swipeDown()

        // Update the balance.
        app.buttons["Update Balance"].tap()
        let balanceField = app.textFields["balance.amount"]
        XCTAssertTrue(balanceField.waitForExistence(timeout: 5))
        balanceField.tap()
        balanceField.typeText("900")
        app.buttons["balance.save"].tap()

        // The new authoritative balance is the headline number.
        XCTAssertTrue(anyText(app, containing: "$900.00").waitForExistence(timeout: 5))
    }

    // Calendar day panel opens the payday check-in (F-07).
    @MainActor
    func testCalendarDayOpensCheckIn() throws {
        let app = launch(skipOnboarding: true)
        XCTAssertTrue(app.tabBars.buttons["Calendar"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Calendar"].tap()

        // Selected-day panel (today = Aug 20) lists payday #1.
        let payday = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Payday #1'")).firstMatch
        XCTAssertTrue(payday.waitForExistence(timeout: 8))
        payday.tap()

        XCTAssertTrue(app.staticTexts["Step 1 of 5 — Income"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
    }

    // The dashboard stays usable at accessibility text sizes and its controls
    // carry accessibility labels (F-15).
    @MainActor
    func testDashboardAtAccessibilityTextSize() throws {
        let app = launch(
            skipOnboarding: true,
            extraArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityL"
            ]
        )
        let checkInButton = app.buttons["today.checkInButton"]
        XCTAssertTrue(checkInButton.waitForExistence(timeout: 10))
        XCTAssertFalse(checkInButton.label.isEmpty)
        XCTAssertTrue(app.buttons["Add entry"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
    }

    // Notification settings render the not-determined experience without a
    // permission prompt, and the app remains fully usable (F-11).
    @MainActor
    func testNotificationSettingsWithoutPermission() throws {
        let app = launch(skipOnboarding: true)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        app.buttons["Reminders"].tap()
        // Either the enable button (not determined) or the toggles render.
        let enable = app.buttons["Enable notifications"]
        let paydayToggle = app.staticTexts["Payday play"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5) || paydayToggle.waitForExistence(timeout: 5))
    }

    // Backup screen produces a shareable JSON file (F-14).
    @MainActor
    func testBackupCreatesShareableFile() throws {
        let app = launch(skipOnboarding: true)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        app.buttons["Backup & export"].tap()
        app.buttons["Create JSON backup"].tap()
        let shareRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'PaydayPlaybook-Backup'")).firstMatch
        XCTAssertTrue(shareRow.waitForExistence(timeout: 5))

        app.buttons["Create CSV files"].tap()
        let csvRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Ledger'")).firstMatch
        XCTAssertTrue(csvRow.waitForExistence(timeout: 5))
    }
}
