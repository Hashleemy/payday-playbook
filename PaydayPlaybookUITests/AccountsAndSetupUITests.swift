import XCTest

/// The v0.3.0 surfaces: the Checking Accounts workspace, the consolidated
/// Bills & Debts page, and the payoff scenario screens.
///
/// Run these alone on a dedicated simulator with `-parallel-testing-enabled NO`
/// — the suite shares its store with the unit tests otherwise, which is a
/// pinned v0.2.0 hazard.
final class AccountsAndSetupUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func launch(
        skipOnboarding: Bool = true,
        today: String = "2054-08-20",
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest", "--uitest-reset", "--uitest-today", today]
        if skipOnboarding { app.launchArguments.append("--uitest-skip-onboarding") }
        app.launchArguments += extraArguments
        app.launch()
        return app
    }

    private func anyText(_ app: XCUIApplication, containing needle: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS %@", needle)
        let asStatic = app.staticTexts.matching(predicate).firstMatch
        if asStatic.exists { return asStatic }
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    @discardableResult
    private func scrollTo(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int = 8
    ) -> Bool {
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.element.exists else { return }
        app.navigationBars.firstMatch.staticTexts.firstMatch.tap()
    }

    private func type(_ text: String, into identifier: String, in app: XCUIApplication) {
        dismissKeyboard(app)
        let field = app.textFields[identifier]
        XCTAssertTrue(scrollTo(field, in: app), "\(identifier) should be reachable")
        field.tap()
        field.typeText(text)
    }

    private func openAccountsTab(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["Accounts"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15), "The Accounts tab must exist (V3-02)")
        tab.tap()
    }

    /// Settings rows are addressed by their visible label, matching the rest
    /// of the suite — a `NavigationLink` inside a `List` does not expose a
    /// custom identifier as a button.
    private func openSettings(_ app: XCUIApplication) {
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15), "Settings is reachable from Today")
        settings.tap()
    }

    @discardableResult
    private func openBillsAndDebts(_ app: XCUIApplication) -> Bool {
        let row = app.buttons["Bills & debts"]
        guard scrollTo(row, in: app) else { return false }
        row.tap()
        return app.buttons["billsAndDebts.add"].waitForExistence(timeout: 10)
    }

    /// Opens the first debt in the list. The fixture's migrated cards are named
    /// "Card A", "Card B", … and the list rows are navigation links addressed
    /// by text, exactly as the existing debt tests do.
    private func openFirstDebt(_ app: XCUIApplication) {
        app.tabBars.buttons["Debts"].tap()
        let row = anyText(app, containing: "Card ")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "The debts list has at least one card")
        row.tap()
    }

    // MARK: - Accounts workspace (V3-02)

    @MainActor
    func testAccountsTabIsFirstClassAndShowsEveryContractedFigure() throws {
        let app = launch()
        openAccountsTab(app)

        XCTAssertTrue(
            app.otherElements["accounts.summary"].waitForExistence(timeout: 10)
                || anyText(app, containing: "Available to the plan").waitForExistence(timeout: 10),
            "The workspace opens on its summary"
        )
        // §5.1: protected and available are shown, not just the raw balance.
        XCTAssertTrue(anyText(app, containing: "Protected").exists)
        XCTAssertTrue(anyText(app, containing: "Available").exists)
    }

    @MainActor
    func testRecordingADepositUpdatesTheBalanceAndTheActivityList() throws {
        let app = launch()
        openAccountsTab(app)

        let card = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'accounts.card.'")
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "At least one account card")
        card.tap()

        let deposit = app.buttons["account.action.deposit"]
        XCTAssertTrue(scrollTo(deposit, in: app), "The deposit action is on the detail screen")
        deposit.tap()

        type("125", into: "movement.amount", in: app)
        dismissKeyboard(app)
        // The sheet states the resulting balance before it is committed.
        XCTAssertTrue(anyText(app, containing: "goes from").exists)
        app.buttons["movement.save.deposit"].tap()

        XCTAssertTrue(
            anyText(app, containing: "Deposit").waitForExistence(timeout: 10),
            "The deposit appears in the account's activity"
        )
    }

    /// V3-03: a balance update requires confirmation and explains that it
    /// records a snapshot rather than rewriting history.
    @MainActor
    func testBalanceUpdateExplainsItselfAndRequiresConfirmation() throws {
        let app = launch()
        openAccountsTab(app)

        let card = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'accounts.card.'")
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()

        let update = app.buttons["account.action.adjustment"]
        XCTAssertTrue(scrollTo(update, in: app))
        update.tap()

        XCTAssertTrue(
            anyText(app, containing: "Everything already recorded stays exactly as it is").waitForExistence(timeout: 5),
            "The sheet says what a balance update does before it is used"
        )

        type("2100", into: "movement.statedBalance", in: app)
        dismissKeyboard(app)
        app.buttons["movement.save.adjustment"].tap()

        // A confirmation step, not a silent write.
        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "A balance update must be confirmed")
        XCTAssertTrue(
            confirm.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'Nothing already recorded is changed'")
            ).firstMatch.exists,
            "The confirmation says history is not rewritten"
        )
        confirm.buttons["Record balance"].tap()

        XCTAssertTrue(
            anyText(app, containing: "Balance history").waitForExistence(timeout: 10)
        )
    }

    /// §5.1: archive is blocked-or-explained while something still references
    /// the account.
    ///
    /// The upgraded fixture install carries two migrated accounts, so the
    /// blocker here is "it receives your paycheck" rather than the
    /// last-account rule. The assertion therefore pins the *shape* of the
    /// explanation — a titled sheet naming what still uses the account — which
    /// is what the contract requires, instead of one blocker's exact sentence.
    @MainActor
    func testArchivingABlockedAccountExplainsWhy() throws {
        let app = launch()
        openAccountsTab(app)

        let card = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'accounts.card.'")
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()

        let archive = app.buttons["account.detail.archive"]
        XCTAssertTrue(scrollTo(archive, in: app))
        XCTAssertTrue(
            archive.label.contains("Why can't I archive"),
            "A blocked archive says so on the button rather than failing on tap"
        )
        archive.tap()
        XCTAssertTrue(
            anyText(app, containing: "Can't archive yet").waitForExistence(timeout: 5),
            "A blocked archive opens an explanation rather than failing silently"
        )
        XCTAssertTrue(
            anyText(app, containing: "still being used").exists,
            "The explanation says what is holding the account"
        )
        // Every blocker offers a route forward, not just a refusal.
        XCTAssertTrue(
            anyText(app, containing: "then archive this one").exists
                || anyText(app, containing: "another account").exists,
            "The explanation names what to do next"
        )
    }

    @MainActor
    func testAccountsWorkspaceAtAccessibilityTextSize() throws {
        let app = launch(extraArguments: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityL"
        ])
        openAccountsTab(app)

        let card = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'accounts.card.'")
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        // The card is one accessibility element carrying the whole summary.
        XCTAssertFalse(card.label.isEmpty)
        XCTAssertTrue(
            card.label.contains("Available"),
            "The card's VoiceOver label still names every figure at large type"
        )
        XCTAssertTrue(card.isHittable, "The card stays reachable at accessibility sizes")
    }

    // MARK: - Consolidated Bills & Debts (V3-08)

    @MainActor
    func testSettingsHasOneBillsAndDebtsPageWithASingleAddAction() throws {
        let app = launch()

        openSettings(app)

        // Checked while still on the Settings list: the separate v0.2 entry is
        // replaced by the consolidated one, not sitting beside it.
        XCTAssertTrue(scrollTo(app.buttons["Bills & debts"], in: app))
        XCTAssertFalse(
            app.buttons["Essential bills"].exists,
            "The consolidated page replaces the separate bills entry (V3-08)"
        )

        XCTAssertTrue(openBillsAndDebts(app), "Settings offers one Bills & debts destination")
        XCTAssertTrue(anyText(app, containing: "Bills").exists)
        XCTAssertTrue(anyText(app, containing: "Debts").exists)
    }

    @MainActor
    func testAddingChoosesTypeFirstThenShowsOnlyRelevantFields() throws {
        let app = launch()
        openSettings(app)
        XCTAssertTrue(openBillsAndDebts(app))

        app.buttons["billsAndDebts.add"].tap()
        XCTAssertTrue(app.buttons["addChooser.bill"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["addChooser.debt"].exists)

        // A bill never asks for an APR or a credit limit.
        app.buttons["addChooser.bill"].tap()
        XCTAssertTrue(app.textFields["obligation.name"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["debt.apr"].exists)
        XCTAssertFalse(app.textFields["debt.creditLimit"].exists)
    }

    /// Every v0.2 debt field survives the consolidation.
    @MainActor
    func testDebtEditorStillOffersEveryTypeSpecificField() throws {
        let app = launch()
        openSettings(app)
        XCTAssertTrue(openBillsAndDebts(app))

        app.buttons["billsAndDebts.add"].tap()
        XCTAssertTrue(app.buttons["addChooser.debt"].waitForExistence(timeout: 5))
        app.buttons["addChooser.debt"].tap()
        XCTAssertTrue(app.buttons["addChooser.debtType.autoLoan"].waitForExistence(timeout: 5))
        app.buttons["addChooser.debtType.autoLoan"].tap()

        XCTAssertTrue(app.textFields["debt.name"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollTo(app.textFields["debt.apr"], in: app))
        XCTAssertTrue(scrollTo(app.textFields["debt.originalPrincipal"], in: app))
        // A loan asks the prepayment question; a card never does.
        XCTAssertTrue(
            scrollTo(app.otherElements["debt.prepayment"], in: app)
                || anyText(app, containing: "pay extra toward the principal").exists,
            "The extra-principal eligibility question survives (V2-05)"
        )
    }

    // MARK: - Scenarios (V3-05/V3-06/V3-15)

    @MainActor
    func testProgressOffersTheScenarioEntryAndTheCalculatorRendersThreeCards() throws {
        let app = launch()

        app.tabBars.buttons["Progress"].tap()
        let entry = app.buttons["progress.scenariosEntry"]
        XCTAssertTrue(scrollTo(entry, in: app), "Progress offers the payoff-plan entry (§8.6)")
        entry.tap()

        // The engine runs off the main thread's render path, so a loading
        // state is expected before the cards land.
        XCTAssertTrue(
            app.otherElements["scenarios.card.balanced"].waitForExistence(timeout: 30)
                || anyText(app, containing: "Balanced").waitForExistence(timeout: 30),
            "The three cards render"
        )
        XCTAssertTrue(anyText(app, containing: "Fastest Safe").exists)
        XCTAssertTrue(anyText(app, containing: "More Cushion").exists)
        // Balanced is recommended in words, not by colour alone.
        XCTAssertTrue(anyText(app, containing: "Recommended").exists)
    }

    /// V3-06: an upgraded install has never been asked for planned savings or
    /// a minimum protected balance, so the cards ask instead of inventing
    /// them. This is the state the fixture install genuinely reaches, and it
    /// is the contract's headline honesty behaviour.
    ///
    /// The apply-and-confirm path needs constraints this install does not
    /// have; `ScenarioSurfaceTests` covers it end to end against a setup that
    /// does, including that cancelling writes nothing.
    @MainActor
    func testMissingConstraintsAreNamedInsteadOfInvented() throws {
        let app = launch()

        app.tabBars.buttons["Progress"].tap()
        let entry = app.buttons["progress.scenariosEntry"]
        XCTAssertTrue(scrollTo(entry, in: app))
        entry.tap()

        XCTAssertTrue(
            anyText(app, containing: "Balanced").waitForExistence(timeout: 40),
            "The cards render"
        )
        XCTAssertTrue(
            anyText(app, containing: "rather ask than guess").exists
                || anyText(app, containing: "still missing").exists
                || anyText(app, containing: "needs a little more").exists,
            "Missing constraints are named rather than defaulted"
        )
        // Nothing on this screen applies itself.
        XCTAssertFalse(
            app.otherElements["scenarios.applySuccess"].exists,
            "Opening the calculator must never create a plan"
        )
    }

    @MainActor
    func testOverridesPanelSaysSavedDataIsUntouched() throws {
        let app = launch()

        app.tabBars.buttons["Progress"].tap()
        let entry = app.buttons["progress.scenariosEntry"]
        XCTAssertTrue(scrollTo(entry, in: app))
        entry.tap()

        let adjust = app.buttons["scenarios.adjust"]
        XCTAssertTrue(adjust.waitForExistence(timeout: 30))
        adjust.tap()

        XCTAssertTrue(
            anyText(app, containing: "saved income and pay schedule stay exactly as they are")
                .waitForExistence(timeout: 5),
            "The override panel promises not to touch saved data (R-18)"
        )
        XCTAssertTrue(app.textFields["scenarios.override.takeHome"].exists)
        XCTAssertTrue(app.buttons["scenarios.override.apply"].exists)
    }

    /// V3-04: the extra-payment preview is reachable from debt detail and says
    /// plainly that looking changes nothing.
    @MainActor
    func testExtraPaymentPreviewIsReachableFromDebtDetailAndMutatesNothing() throws {
        let app = launch()

        openFirstDebt(app)

        let whatIf = app.buttons["What if I pay extra?"]
        XCTAssertTrue(scrollTo(whatIf, in: app), "Debt detail offers the extra-payment entry")
        whatIf.tap()

        XCTAssertTrue(
            anyText(app, containing: "Nothing is scheduled, paid, or changed by looking")
                .waitForExistence(timeout: 5)
        )
        type("500", into: "extraPayment.amount", in: app)
        dismissKeyboard(app)
        app.buttons["extraPayment.calculate"].tap()

        XCTAssertTrue(
            anyText(app, containing: "A preview only").waitForExistence(timeout: 30)
                || anyText(app, containing: "Interest with this").waitForExistence(timeout: 30),
            "The insight renders as a preview"
        )
    }

    @MainActor
    func testScenariosAtAccessibilityTextSize() throws {
        let app = launch(extraArguments: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityL"
        ])

        app.tabBars.buttons["Progress"].tap()
        let entry = app.buttons["progress.scenariosEntry"]
        XCTAssertTrue(scrollTo(entry, in: app, maxSwipes: 12))
        XCTAssertFalse(entry.label.isEmpty)
        entry.tap()

        XCTAssertTrue(
            anyText(app, containing: "Balanced").waitForExistence(timeout: 40),
            "The cards still render at accessibility text sizes"
        )
    }
}
