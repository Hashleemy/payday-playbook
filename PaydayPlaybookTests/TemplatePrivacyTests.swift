import XCTest
import SwiftData
@testable import PaydayPlaybook

/// Original Plan v1 is one real person's finances. It is a development and
/// verification fixture; a distribution build must neither carry it nor offer
/// it. `EXCLUDED_SOURCE_FILE_NAMES` on the Release configuration keeps the
/// resource out of the bundle, and a Release build phase fails the build if
/// that ever regresses.
///
/// These tests cover what a build setting cannot: that the app behaves
/// correctly and safely in the resulting resource-less state.
@MainActor
final class TemplatePrivacyTests: XCTestCase {

    /// Stands in for a distribution bundle: the xctest bundle has never
    /// contained the template, so it is a faithful "resource is absent" case.
    private var bundleWithoutTemplate: Bundle { Bundle(for: TemplatePrivacyTests.self) }

    // MARK: - Availability is derived from the resource, not a flag

    func testTemplateIsAvailableInThisDevelopmentBuild() {
        XCTAssertTrue(
            TemplateCatalog.isAvailable(in: .main),
            "Development builds keep the template — the migration repair path and the seed tests need it."
        )
    }

    func testTemplateIsUnavailableWhenTheResourceIsAbsent() {
        XCTAssertFalse(TemplateCatalog.isAvailable(in: bundleWithoutTemplate))
    }

    /// The onboarding affordance is driven by the same derivation, so a build
    /// can never advertise a template it cannot produce.
    func testWelcomeAffordanceFollowsResourceAvailability() {
        let withTemplate = WelcomeStepView(
            onContinue: {}, onLoadTemplate: {},
            templateAvailable: TemplateCatalog.isAvailable(in: .main)
        )
        let withoutTemplate = WelcomeStepView(
            onContinue: {}, onLoadTemplate: {},
            templateAvailable: TemplateCatalog.isAvailable(in: bundleWithoutTemplate)
        )
        XCTAssertTrue(withTemplate.templateAvailable)
        XCTAssertFalse(withoutTemplate.templateAvailable)
    }

    // MARK: - The resource-less state is safe, not merely unsupported

    /// A Release build has no template. Anything that reaches the seeder there
    /// must fail cleanly and leave the store exactly as it found it — an empty
    /// store is recoverable, a half-written plan graph is not.
    func testSeedingWithoutTheTemplateFailsCleanlyAndWritesNothing() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)

        XCTAssertThrowsError(
            try PlanSeeder.seedIfNeeded(context: context, bundle: bundleWithoutTemplate)
        ) { error in
            XCTAssertEqual(error as? SeedPlanError, .resourceMissing)
        }

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DebtAccount>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PaydayPlanItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Milestone>()), 0)
        XCTAssertFalse(
            context.hasChanges,
            "A refused seed must leave no pending inserts behind for a later save to commit."
        )
    }

    /// A fresh install without the template still reaches onboarding — the
    /// missing resource must not be mistaken for a broken install or block
    /// setup, which is the only path to a plan in a distribution build.
    func testAFreshStoreWithoutTheTemplateStillRoutesToOnboarding() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)

        XCTAssertEqual(try MigrationService.detectInstallState(context: context), .freshInstall)
        let summary = try MigrationService.migrateIfNeeded(context: context)
        XCTAssertFalse(summary.didMigrate)

        // No AppSettings row means RootView's `onboardingComplete` is false.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AppSettings>()), 0)
    }
}
