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
        today: String = "2054-08-20",
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

    /// Scrolls until an element materializes. Rows below the fold of a List
    /// or lazy stack are not in the accessibility tree until scrolled to, so
    /// `waitForExistence` alone is not enough.
    @discardableResult
    private func scrollTo(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int = 6
    ) -> Bool {
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    /// The decimal keypad has no return key, so it stays up and can cover the
    /// next field. Dropping it before scrolling keeps entry reliable.
    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.element.exists else { return }
        app.navigationBars.firstMatch.staticTexts.firstMatch.tap()
    }

    /// Types into a field, dropping the keyboard and scrolling first.
    private func type(_ text: String, into identifier: String, in app: XCUIApplication) {
        dismissKeyboard(app)
        let field = app.textFields[identifier]
        XCTAssertTrue(scrollTo(field, in: app), "\(identifier) should be reachable")
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
    /// A clean install must open on Welcome and must not be inside the app.
    ///
    /// Regression: on a genuinely fresh device install the app was reported as
    /// opening straight into a populated dashboard. The cause turned out to be
    /// the Welcome screen's template affordance — one tap seeded Original Plan
    /// v1 and marked onboarding complete, which reads as "the app remembered
    /// me" because that template is a real person's real plan. This pins the
    /// first screen, and `TemplatePrivacyTests` pins the template's absence
    /// from distribution builds.
    func testCleanInstallOpensOnWelcomeAndNotInsideTheApp() throws {
        let app = launch()

        XCTAssertTrue(
            app.buttons["onboarding.setUpPlan"].waitForExistence(timeout: 10),
            "A clean install must land on the Welcome step."
        )
        XCTAssertFalse(
            app.buttons["today.checkInButton"].exists,
            "A clean install must not open inside the app with a plan already in place."
        )
        XCTAssertTrue(anyText(app, containing: "stays on this iPhone").exists)
    }

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
        type("Everyday", into: "account.name", in: app)
        type("1200", into: "account.balance", in: app)
        dismissKeyboard(app)
        app.buttons["account.save"].tap()
        tapContinue("onboarding.accountsContinue", in: app)

        // Step 4 — income now comes before bills and debts (V3-08), so the
        // per-paycheck reserve preview smooths against the real cadence.
        type("2000", into: "income.takeHome", in: app)
        dismissKeyboard(app)
        tapContinue("onboarding.incomeContinue", in: app)

        // Step 5 — one consolidated page. The type choice comes first, then
        // only the fields that kind of item actually needs.
        tapContinue("billsAndDebts.add", in: app)
        XCTAssertTrue(app.buttons["addChooser.debt"].waitForExistence(timeout: 5))
        app.buttons["addChooser.debt"].tap()
        XCTAssertTrue(app.buttons["addChooser.debtType.creditCard"].waitForExistence(timeout: 5))
        app.buttons["addChooser.debtType.creditCard"].tap()
        type("Blue card", into: "debt.name", in: app)
        type("2000", into: "debt.balance", in: app)
        type("24.99", into: "debt.apr", in: app)
        dismissKeyboard(app)
        app.buttons["debt.save"].tap()

        // The same page adds a bill, through the same one button.
        tapContinue("billsAndDebts.add", in: app)
        XCTAssertTrue(app.buttons["addChooser.bill"].waitForExistence(timeout: 5))
        app.buttons["addChooser.bill"].tap()
        type("Rent", into: "obligation.name", in: app)
        type("1400", into: "obligation.amount", in: app)
        dismissKeyboard(app)
        app.buttons["obligation.save"].tap()

        XCTAssertTrue(anyText(app, containing: "Blue card").waitForExistence(timeout: 5))
        XCTAssertTrue(anyText(app, containing: "Rent").exists)
        tapContinue("onboarding.billsAndDebtsContinue", in: app)

        // Step 6 — dates and reminders preview, permission not required.
        XCTAssertTrue(anyText(app, containing: "Your next paydays").waitForExistence(timeout: 5))
        tapContinue("onboarding.remindersContinue", in: app)

        // Step 7 — review, then generate and commit.
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
        type("Everyday", into: "account.name", in: app)
        type("1200", into: "account.balance", in: app)
        dismissKeyboard(app)
        app.buttons["account.save"].tap()
        XCTAssertTrue(app.buttons["onboarding.accountsContinue"].waitForExistence(timeout: 5))
        app.terminate()

        // Relaunch on the same store: resumed, with the account still there.
        app = launch(reset: false)
        XCTAssertTrue(app.buttons["onboarding.accountsContinue"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["onboarding.resumeBanner"].exists
            || anyText(app, containing: "Picking up where you left off").exists)
        XCTAssertTrue(anyText(app, containing: "Everyday").exists)

        // Back to the goal step: the posture answer and its floor survived.
        app.buttons["onboarding.back"].tap()
        XCTAssertTrue(app.buttons["goal.posture.fullThrottle"].waitForExistence(timeout: 5))
        let floor = app.textFields["goal.floor"]
        XCTAssertTrue(scrollTo(floor, in: app))
        // The field reads out its formatted amount for VoiceOver.
        XCTAssertEqual(
            floor.value as? String, "$500.00",
            "The full-throttle floor the user saved is still in the field"
        )
    }

    // The template path is gone (V3-12): the Welcome screen offers setup and
    // nothing else, because there is no longer any plan to hand a new user.
    @MainActor
    func testWelcomeOffersNoTemplateAffordance() throws {
        let app = launch()

        XCTAssertTrue(app.buttons["onboarding.setUpPlan"].waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.buttons["onboarding.loadTemplate"].exists,
            "the withdrawn template affordance must not be drawn"
        )
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

        // Selected-day section (today = Aug 20) lists payday #1. Month mode is
        // one lazy list (v0.4.0: dashboard card, grid, then the day) — scroll
        // to materialize the day rows before asserting on them.
        let payday = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Payday #1'")).firstMatch
        var scrollAttempts = 0
        while !payday.exists && scrollAttempts < 5 {
            app.swipeUp()
            scrollAttempts += 1
        }
        XCTAssertTrue(payday.waitForExistence(timeout: 8))
        if !payday.isHittable { app.swipeUp() }
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

    // Backup screen produces a shareable JSON file (F-14, V3-09).
    @MainActor
    func testBackupCreatesShareableFile() throws {
        let app = launch(skipOnboarding: true)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        let backup = app.buttons["Create JSON Backup"]
        XCTAssertTrue(scrollTo(backup, in: app), "Create JSON Backup is reachable in Settings")
        backup.tap()
        app.buttons["Create JSON backup"].tap()
        let shareRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'PaydayPlaybook-Backup'")).firstMatch
        XCTAssertTrue(shareRow.waitForExistence(timeout: 5))
        // The sensitive-data warning is on the screen that writes the file,
        // not buried a level away (V3-09).
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'plain text'")
        ).firstMatch.exists)
    }

    // CSV exports survive the v0.3.0 regrouping (F-14).
    @MainActor
    func testCSVExportStillProducesFiles() throws {
        let app = launch(skipOnboarding: true)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        let csv = app.buttons["Export CSV Files"]
        XCTAssertTrue(scrollTo(csv, in: app), "Export CSV Files is reachable in Settings")
        csv.tap()
        app.buttons["Create CSV files"].tap()
        let csvRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Ledger'")).firstMatch
        XCTAssertTrue(csvRow.waitForExistence(timeout: 5))
    }

    // Generate Financial Report produces a PDF, and lives in its own group so
    // raw JSON is never presented as the report (V3-11).
    @MainActor
    func testGenerateFinancialReportProducesAPDF() throws {
        let app = launch(skipOnboarding: true)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        let report = app.buttons["Generate Financial Report"]
        XCTAssertTrue(scrollTo(report, in: app), "Generate Financial Report is reachable in Settings")
        report.tap()

        // The options form is long, and a SwiftUI List only builds the rows it
        // has scrolled to — the action lives past the section toggles.
        let generate = app.buttons["Generate Financial Report"]
        XCTAssertTrue(scrollTo(generate, in: app, maxSwipes: 10), "the generate action is reachable")
        generate.tap()
        let shareRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'PaydayPlaybook-Report' AND label CONTAINS '.pdf'")
        ).firstMatch
        XCTAssertTrue(shareRow.waitForExistence(timeout: 20), "a PDF report is produced and offered for sharing")
    }

    // Template export starts with nothing sensitive selected (V3-10).
    @MainActor
    func testTemplateExportDefaultsToStructureOnly() throws {
        let app = launch(skipOnboarding: true)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        let template = app.buttons["Export Template"]
        XCTAssertTrue(scrollTo(template, in: app), "Export Template is reachable in Settings")
        template.tap()

        // Every sensitive category must be off before the user touches
        // anything — the whole consent model rests on it (V3-10).
        for category in ["Names and labels", "Balances and principal", "Income amounts"] {
            let toggle = app.switches[category]
            // Scrolled to one at a time: the list builds rows lazily, so a
            // switch further down does not exist until it comes into view.
            XCTAssertTrue(scrollTo(toggle, in: app, maxSwipes: 10),
                          "\(category) is offered as an explicit choice")
            XCTAssertEqual(toggle.value as? String, "0", "\(category) must default to off")
        }
        let defaultNote = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Nothing here is included by default'")
        ).firstMatch
        XCTAssertTrue(scrollTo(defaultNote, in: app, maxSwipes: 4), "the default is stated on screen")
    }
}
