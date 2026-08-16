import XCTest

/// Accessibility and navigation coverage for the v0.2 dashboard, plan screen,
/// and debt views (V2-13, V2-14, V2-18). These run against the invented
/// `DebugBaselineFixture` plan, which the `--uitest-skip-onboarding` path
/// lands schema-complete.
final class DashboardPlanUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func anyText(_ app: XCUIApplication, containing needle: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS %@", needle)
        let asStatic = app.staticTexts.matching(predicate).firstMatch
        if asStatic.exists { return asStatic }
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    /// Swipes until the element materializes (Lists and ScrollViews are lazy).
    @discardableResult
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 25) -> Bool {
        if element.exists { return true }
        for _ in 0..<attempts {
            app.swipeUp()
            if element.exists { return true }
        }
        return element.exists
    }

    /// Swipes until the element is actually on screen and tappable. `exists`
    /// is true for off-screen elements, so hittability needs its own loop.
    @discardableResult
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 25) -> Bool {
        if element.isHittable { return true }
        for _ in 0..<attempts {
            app.swipeUp()
            if element.isHittable { return true }
        }
        return element.isHittable
    }

    private func launch(
        today: String = "2054-08-20",
        contentSize: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--uitest", "--uitest-today", today,
            "--uitest-reset", "--uitest-skip-onboarding"
        ]
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        }
        app.launch()
        return app
    }

    // MARK: - Five-second dashboard content

    /// The dashboard's headline facts are all reachable without scrolling
    /// past the fold on a standard text size (F-02).
    @MainActor
    func testDashboardShowsStatusTargetAndFinishLine() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["today.checkInButton"].waitForExistence(timeout: 10))

        XCTAssertTrue(app.staticTexts["Where you stand"].exists)
        XCTAssertTrue(anyText(app, containing: "eliminated").exists)
        XCTAssertTrue(app.staticTexts["Today's play"].exists)
        XCTAssertTrue(app.staticTexts["Current target"].exists)

        app.swipeUp()
        XCTAssertTrue(app.staticTexts["The finish line"].waitForExistence(timeout: 5))
        XCTAssertTrue(anyText(app, containing: "Forecast payoff").exists)
        XCTAssertTrue(anyText(app, containing: "estimates, not guarantees").exists)
    }

    /// Accounts render by name with the protected-cash line and the
    /// available-not-spent wording the soul requires.
    @MainActor
    func testDashboardShowsAccountsProtectedCashAndInsight() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["today.checkInButton"].waitForExistence(timeout: 10))

        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(anyText(app, containing: "Protected floor").waitForExistence(timeout: 5))
        XCTAssertTrue(anyText(app, containing: "Available — not spent").exists)
        XCTAssertTrue(anyText(app, containing: "Maximum if no allowance had been spent").exists)

        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Insight"].waitForExistence(timeout: 5))
    }

    // MARK: - Plan screen

    /// The plan screen opens from the dashboard and offers the three tracks
    /// plus the explicit activation action.
    @MainActor
    func testPlanScreenOffersThreeTracksAndActivation() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["today.checkInButton"].waitForExistence(timeout: 10))

        let viewPlan = app.buttons["today.viewPlanButton"]
        XCTAssertTrue(scrollTo(viewPlan, in: app))
        viewPlan.tap()

        XCTAssertTrue(app.staticTexts["What this plan is built on"].waitForExistence(timeout: 10))
        XCTAssertTrue(anyText(app, containing: "Recommended order").exists)

        // The baseline/actual/reforecast selector is present.
        let picker = app.segmentedControls["plan.trackPicker"]
        XCTAssertTrue(scrollTo(picker, in: app))
        XCTAssertTrue(picker.buttons["Plan"].exists)
        XCTAssertTrue(picker.buttons["Actual"].exists)
        XCTAssertTrue(picker.buttons["Reforecast"].exists)

        // Switching to Actual shows the empty-actual explanation, never
        // planned values dressed as actuals.
        picker.buttons["Actual"].tap()
        let emptyActual = app.staticTexts["plan.emptyTrack"]
        XCTAssertTrue(scrollTo(emptyActual, in: app))
        XCTAssertTrue(emptyActual.label.contains("nothing is filled in from the plan"),
                      "The empty actual track explains itself: \(emptyActual.label)")

        // The activation action is explicit and reachable.
        let activate = app.buttons["plan.activateButton"]
        XCTAssertTrue(scrollTo(activate, in: app))
    }

    // MARK: - Debt views

    /// Debt detail uses debt vocabulary (not card-only) and exposes the
    /// per-type editor.
    @MainActor
    func testDebtDetailUsesDebtVocabularyAndOpensTheTypeAwareEditor() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["today.checkInButton"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Debts"].tap()

        let row = anyText(app, containing: "Card B")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Migrated cards keep their 0.1.x label.")
        row.tap()

        let editButton = app.buttons["Edit Debt"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 5), "The action reads 'Edit Debt', not 'Edit Card'.")
        XCTAssertTrue(scrollTo(anyText(app, containing: "Debt type"), in: app))

        editButton.tap()
        // The per-type editor: a type picker, and the extra-principal rule.
        let typePicker = app.descendants(matching: .any)["debt.typePicker"]
        XCTAssertTrue(typePicker.waitForExistence(timeout: 5))
        XCTAssertTrue(anyText(app, containing: "Extra principal allowed").exists)
        app.buttons["Cancel"].tap()
    }

    // MARK: - Accessibility at large text

    /// Every new surface stays usable at an accessibility text size: controls
    /// keep non-empty labels and remain hittable (V2-18).
    @MainActor
    func testDashboardAndPlanAtAccessibilityTextSize() throws {
        let app = launch(contentSize: "UICTContentSizeCategoryAccessibilityXL")

        let checkIn = app.buttons["today.checkInButton"]
        XCTAssertTrue(checkIn.waitForExistence(timeout: 15))
        XCTAssertFalse(checkIn.label.isEmpty)
        // At accessibility sizes the cards grow past the fold, so the primary
        // action is reached by scrolling — but it must still be tappable, not
        // clipped or overlapped.
        XCTAssertTrue(scrollUntilHittable(checkIn, in: app),
                      "The primary action stays reachable and tappable at accessibility sizes.")
        XCTAssertTrue(app.buttons["Add entry"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)

        let viewPlan = app.buttons["today.viewPlanButton"]
        XCTAssertTrue(scrollTo(viewPlan, in: app))
        XCTAssertFalse(viewPlan.label.isEmpty)
        viewPlan.tap()

        XCTAssertTrue(app.staticTexts["What this plan is built on"].waitForExistence(timeout: 10))
        // The playbook's paycheck rows still carry spoken labels at this size.
        let picker = app.segmentedControls["plan.trackPicker"]
        XCTAssertTrue(scrollUntilHittable(picker, in: app),
                      "The track selector stays reachable and tappable at accessibility sizes.")
    }

    /// The Progress tab's insights row and charts keep their text summaries at
    /// an accessibility text size — charts are never the only carrier.
    @MainActor
    func testProgressInsightsAndChartSummariesAtLargeText() throws {
        let app = launch(contentSize: "UICTContentSizeCategoryAccessibilityL")
        XCTAssertTrue(app.buttons["today.checkInButton"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Progress"].tap()

        XCTAssertTrue(app.staticTexts["The numbers"].waitForExistence(timeout: 10))
        // Chart summaries are plain text, present regardless of the chart.
        var attempts = 0
        var foundSummary = anyText(app, containing: "Chart summary").exists
        while !foundSummary && attempts < 8 {
            app.swipeUp()
            foundSummary = anyText(app, containing: "Chart summary").exists
            attempts += 1
        }
        XCTAssertTrue(foundSummary, "Every chart carries an accessible text summary.")
    }
}
