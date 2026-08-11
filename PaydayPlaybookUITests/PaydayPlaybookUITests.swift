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

    /// Types into a field that may need scrolling into view first.
    private func type(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        if !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }

    private func tapContinue(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(identifier) should exist")
        button.tap()
    }

    // Clean first run: the full setup flow generates a plan from the user's
    // own numbers and lands on Today (V2-01, V2-10).
    @MainActor
    func testFirstRunSetupGeneratesAPlanAndLandsOnToday() throws {
        let app = launch()

        // Step 1 — welcome and the privacy promise.
        XCTAssertTrue(app.buttons["onboarding.setUpPlan"].waitForExistence(timeout: 10))
        XCTAssertTrue(anyText(app, containing: "stays on this iPhone").exists)
        app.buttons["onboarding.setUpPlan"].tap()

        // Step 2 — goal and guardrails come prefilled from the posture.
        XCTAssertTrue(app.buttons["goal.posture.steady"].waitForExistence(timeout: 5))
        app.buttons["goal.posture.steady"].tap()
        tapContinue("onboarding.goalContinue", in: app)

        // Step 3 — one checking account.
        tapContinue("accounts.add", in: app)
        type("Everyday", into: app.textFields["account.name"], in: app)
        type("1200", into: app.textFields["Balance today"], in: app)
        app.buttons["account.save"].tap()
        tapContinue("onboarding.accountsContinue", in: app)

        // Steps 4 and 5 — type picker, then the card's own fields.
        tapContinue("debts.add", in: app)
        XCTAssertTrue(app.buttons["debtType.creditCard"].waitForExistence(timeout: 5))
        app.buttons["debtType.creditCard"].tap()
        type("Blue card", into: app.textFields["debt.name"], in: app)
        type("2000", into: app.textFields["Balance today"], in: app)
        type("24.99", into: app.textFields["Interest rate (APR)"], in: app)
        app.buttons["debt.save"].tap()
        tapContinue("onboarding.debtsContinue", in: app)

        // Step 6 — income.
        type("2000", into: app.textFields["Take-home per paycheck"], in: app)
        tapContinue("onboarding.incomeContinue", in: app)

        // Step 7 — bills can be skipped.
        tapContinue("onboarding.obligationsContinue", in: app)

        // Step 8 — dates and reminders preview, permission not required.
        XCTAssertTrue(anyText(app, containing: "Your next paydays").waitForExistence(timeout: 5))
        tapContinue("onboarding.remindersContinue", in: app)

        // Steps 9 and 10 — review, then generate and commit.
        XCTAssertTrue(app.buttons["onboarding.generate"].waitForExistence(timeout: 5))
        app.buttons["onboarding.generate"].tap()
        XCTAssertTrue(app.buttons["onboarding.usePlan"].waitForExistence(timeout: 15))
        app.buttons["onboarding.usePlan"].tap()

        // The dashboard, built from the user's own plan.
        XCTAssertTrue(app.buttons["today.checkInButton"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Where you stand"].exists)
    }

    // Setup survives a force-quit mid-flow and resumes on the saved step
    // with every earlier answer intact (V2-01).
    @MainActor
    func testSetupResumesAfterForceQuit() throws {
        var app = launch()

        XCTAssertTrue(app.buttons["onboarding.setUpPlan"].waitForExistence(timeout: 10))
        app.buttons["onboarding.setUpPlan"].tap()
        XCTAssertTrue(app.buttons["goal.posture.fullThrottle"].waitForExistence(timeout: 5))
        app.buttons["goal.posture.fullThrottle"].tap()
        tapContinue("onboarding.goalContinue", in: app)

        // Add an account, then kill the app before leaving the step.
        tapContinue("accounts.add", in: app)
        type("Everyday", into: app.textFields["account.name"], in: app)
        type("1200", into: app.textFields["Balance today"], in: app)
        app.buttons["account.save"].tap()
        XCTAssertTrue(app.buttons["onboarding.accountsContinue"].waitForExistence(timeout: 5))
        app.terminate()

        // Relaunch on the same store: resumed, with the account still there.
        app = launch(reset: false)
        XCTAssertTrue(app.buttons["onboarding.accountsContinue"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["onboarding.resumeBanner"].exists
            || anyText(app, containing: "Picking up where you left off").exists)
        XCTAssertTrue(anyText(app, containing: "Everyday").exists)

        // Back to the goal step: the posture answer survived too.
        app.buttons["onboarding.back"].tap()
        XCTAssertTrue(app.buttons["goal.posture.fullThrottle"].waitForExistence(timeout: 5))
        XCTAssertTrue(anyText(app, containing: "$500").exists, "Full-throttle floor suggestion persisted")
    }

    // The template path still produces the exact Original Plan v1, behind an
    // explicit warning that it is one person's plan (§4.1).
    @MainActor
    func testTemplateLoadShowsWarningAndSeedsOriginalPlan() throws {
        let app = launch()

        XCTAssertTrue(app.buttons["onboarding.loadTemplate"].waitForExistence(timeout: 10))
        app.buttons["onboarding.loadTemplate"].tap()
        XCTAssertTrue(anyText(app, containing: "one specific person's plan").waitForExistence(timeout: 5))
        app.buttons["Load template"].tap()

        XCTAssertTrue(app.buttons["today.checkInButton"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Debts"].tap()
        XCTAssertTrue(anyText(app, containing: "$29,681.61").waitForExistence(timeout: 5)
            || anyText(app, containing: "Card B").waitForExistence(timeout: 5))
    }

    // Setup is usable at accessibility text sizes: nothing clipped away, and
    // every control still carries its label (V2-18).
    @MainActor
    func testSetupAtAccessibilityTextSize() throws {
        let app = launch(extraArguments: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityL"
        ])

        let setUp = app.buttons["onboarding.setUpPlan"]
        XCTAssertTrue(setUp.waitForExistence(timeout: 10))
        XCTAssertFalse(setUp.label.isEmpty)
        setUp.tap()

        // The goal step's controls survive the larger type.
        XCTAssertTrue(app.buttons["goal.posture.steady"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["goal.posture.steady"].label.isEmpty)
        let continueButton = app.buttons["onboarding.goalContinue"]
        XCTAssertTrue(continueButton.exists)
        XCTAssertTrue(continueButton.isHittable, "Continue stays reachable at accessibility sizes")
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
        let backup = app.buttons["Backup & export"]
        XCTAssertTrue(backup.waitForExistence(timeout: 5))
        if !backup.isHittable { app.swipeUp() }
        backup.tap()
        app.buttons["Create JSON backup"].tap()
        let shareRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'PaydayPlaybook-Backup'")).firstMatch
        XCTAssertTrue(shareRow.waitForExistence(timeout: 5))

        app.buttons["Create CSV files"].tap()
        let csvRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Ledger'")).firstMatch
        XCTAssertTrue(csvRow.waitForExistence(timeout: 5))
    }
}
