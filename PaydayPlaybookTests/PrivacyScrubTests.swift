import XCTest
import SwiftData
@testable import PaydayPlaybook

/// T-2 / T-15 (V3-12): the app carries no personal financial data.
///
/// Replaces `PlanSeederTests` and `TemplatePrivacyTests`, which existed to
/// prove the bundled template behaved safely. There is no template now, so
/// these assert the stronger property: it is gone, in every configuration,
/// and a fresh install produces nothing but what the user enters.
final class PrivacyScrubTests: XCTestCase {

    // MARK: - T-2: a fresh install receives no plan

    func testFreshInstallStoresNothingUntilTheUserEntersIt() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)

        XCTAssertEqual(try MigrationService.detectInstallState(context: context), .freshInstall)
        let summary = try MigrationService.migrateIfNeeded(
            context: context, dateProvider: TestSupport.fixedToday
        )
        XCTAssertFalse(summary.didMigrate)

        // Every model that could carry money is empty.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DebtAccount>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CashAccount>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecurringObligation>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PaydayPlanItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BalanceSnapshot>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Milestone>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<IncomeSchedule>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserGoalProfile>()), 0)

        // No AppSettings row means RootView routes to onboarding.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AppSettings>()), 0)
    }

    // MARK: - T-15: no bundled personal resource, in any configuration

    /// The withdrawn template shipped as a bundle resource. Neither the app
    /// bundle nor the test bundle may contain it — or anything resembling a
    /// bundled plan — under Debug or Release.
    func testNoBundledPlanResourceExists() {
        let withdrawn = ["OriginalPlanV1", "OriginalPlan", "SeedPlan", "PlanSeed", "Template"]
        for bundle in [Bundle.main, Bundle(for: PrivacyScrubTests.self)] {
            for name in withdrawn {
                XCTAssertNil(
                    bundle.url(forResource: name, withExtension: "json"),
                    "\(name).json must not be bundled in \(bundle.bundleURL.lastPathComponent)"
                )
            }
        }
    }

    /// `PlanContract` is the file that used to hold the founding user's plan.
    /// What remains must be version stamps and estimator constants only —
    /// nothing that describes a person's finances.
    func testPlanContractCarriesOnlyGenericConstants() {
        // Version stamps.
        XCTAssertEqual(PlanContract.schemaVersion, 1)
        XCTAssertEqual(PlanContract.calculationVersion, 1)
        XCTAssertEqual(PlanContract.currentSchemaVersion, 3)
        XCTAssertEqual(PlanContract.currentCalculationVersion, 4)
        XCTAssertEqual(PlanContract.minimumModernCalculationVersion, 2)

        // The R-06 estimator, which is a published rule, not anyone's balance.
        XCTAssertEqual(PlanContract.minimumPaymentFloor, TestSupport.money("17.50"))
        XCTAssertEqual(PlanContract.minimumPaymentRate, TestSupport.money("0.005"))
        XCTAssertEqual(PlanContract.payFrequencyDays, 14)

        // The R-25/R-26 quick-win policy: named, tunable modeling constants
        // (A-12) — product policy, definitionally not personal data.
        XCTAssertEqual(PlanContract.balancedQuickWinHorizonPaychecks, 3)
        XCTAssertEqual(PlanContract.balancedQuickWinMaxDelayPaychecks, 1)
        XCTAssertEqual(PlanContract.balancedQuickWinMaxExtraInterestRate, TestSupport.money("0.01"))
        XCTAssertEqual(PlanContract.balancedQuickWinMaxExtraInterestCap, TestSupport.money("50"))

        // Lookup keys, not user data.
        XCTAssertEqual(PlanContract.planName, "Original Plan v1")
        XCTAssertEqual(PlanContract.generatedPlanName, "Plan v1")
    }

    /// The development fixture must be self-evidently synthetic: round
    /// balances, and a first payday far enough out that it cannot be mistaken
    /// for a record of something that happened.
    func testDevelopmentFixtureIsObviouslySynthetic() {
        for card in DebugBaselineFixture.cards {
            let balance = Decimal(string: card.balance)!
            XCTAssertEqual(balance, (balance / 100).rounded2 * 100,
                           "fixture balances are round hundreds, never lifelike")
        }
        XCTAssertGreaterThan(
            DebugBaselineFixture.firstPayday,
            DateMath.localDate(year: 2050, month: 1, day: 1),
            "the fixture's schedule is plainly in the future"
        )
    }

    // MARK: - Privacy-safe diagnostics (V3-13)

    /// Notification identifiers key on entities and dates, never on money.
    func testNotificationIdentifiersCarryNoAmounts() {
        let entity = UUID().uuidString
        for family in NotificationFamily.allCases {
            let identifier = family.identifier(entity: entity)
            XCTAssertTrue(NotificationFamily.owns(identifier))
            // A currency separator in an identifier would mean an amount is
            // being written into a key that ends up in system logs.
            XCTAssertFalse(identifier.contains("$"), "identifier must not carry an amount")
            XCTAssertFalse(identifier.contains("."), "identifier must not carry a decimal amount")
        }
    }
}
