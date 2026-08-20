import XCTest
import SwiftData
@testable import PaydayPlaybook

/// The scenario UI layer (V3-05/V3-06/V3-15): what the calculator preloads,
/// how overrides are applied, how missing inputs are presented, and the
/// guarantee that nothing persists until the user confirms.
///
/// Every value here is invented (V3-12).
final class ScenarioSurfaceTests: XCTestCase {

    // MARK: - Fixture

    /// A small, complete setup: one account, one income schedule, one debt,
    /// one bill, and a profile carrying the scenario constraints.
    private func makeSetup(
        plannedSavings: String? = "200.00",
        minimumProtectedCash: String? = "800.00",
        additionalCushion: String? = "150.00",
        extraCeiling: String? = "400.00",
        zeroAllowanceConfirmed: Bool = true
    ) throws -> ModelContext {
        let context = ModelContext(try TestSupport.makeContainer())
        let now = TestSupport.fixedToday.now

        try CashAccountRepository(context: context).create(
            name: "Everyday", currentBalance: TestSupport.money("2400.00"),
            roles: [.income, .spending], now: now
        )
        try IncomeRepository(context: context).save(
            cadence: .biweekly,
            anchorPayday: TestSupport.date(2054, 8, 20),
            takeHome: TestSupport.money("2400.00"),
            monthlyDay: nil,
            semimonthlyFirstDay: nil,
            semimonthlySecondDay: nil,
            destinationAccountID: nil,
            now: now
        )
        try DebtRepository(context: context).create(
            type: .creditCard, displayName: "Blue card",
            currentBalance: TestSupport.money("4200.00"),
            apr: TestSupport.money("0.2199"),
            minimumAmount: TestSupport.money("95.00"),
            dueDayOfMonth: 12, now: now
        )
        try ObligationRepository(context: context).create(
            name: "Rent", amount: TestSupport.money("1400.00"),
            cadence: .monthly, dueDay: 1, now: now
        )
        try GoalProfileRepository(context: context).save(
            goalText: "Clear the card",
            targetDebtFreeDate: nil,
            posture: .steady,
            protectedFloor: TestSupport.money("1000.00"),
            allowanceCap: TestSupport.money("250.00")
        )

        let profile = try XCTUnwrap(
            try context.fetch(FetchDescriptor<UserGoalProfile>()).first
        )
        profile.plannedSavingsPerPaycheck = plannedSavings.map(TestSupport.money) ?? .zero
        profile.minimumProtectedCash = minimumProtectedCash.map(TestSupport.money) ?? .zero
        profile.additionalCushionReserve = additionalCushion.map(TestSupport.money) ?? .zero
        profile.extraPaymentCeiling = extraCeiling.map(TestSupport.money) ?? .zero
        profile.zeroAllowanceConfirmedAt = zeroAllowanceConfirmed ? now : nil
        try context.save()

        return context
    }

    private func loadWorkspace(_ context: ModelContext) throws -> ScenarioWorkspaceState {
        let loader = ScenarioWorkspaceLoader(context: context, dateProvider: TestSupport.fixedToday)
        var state = try loader.preload()
        try loader.calculate(into: &state)
        return state
    }

    // MARK: - Preload

    func testCalculatorPreloadsTheSavedInputs() throws {
        let context = try makeSetup()
        let state = try ScenarioWorkspaceLoader(
            context: context, dateProvider: TestSupport.fixedToday
        ).preload()

        XCTAssertNotNil(state.baseInput)
        XCTAssertEqual(state.savedTakeHome, TestSupport.money("2400.00"))
        XCTAssertEqual(state.savedCadence, .biweekly)
        XCTAssertFalse(state.overrides.isActive)
    }

    func testExactlyThreeCardsInContractOrderWithBalancedRecommended() throws {
        let state = try loadWorkspace(try makeSetup())

        XCTAssertEqual(state.results.map(\.kind), [.fastestSafe, .balanced, .moreCushion])
        XCTAssertEqual(
            ScenarioKind.allCases.filter(\.isRecommended), [.balanced],
            "Balanced is the only recommended card (R-17)"
        )
    }

    // MARK: - Constraints come only from the user (V3-06)

    /// Zero is how the profile spells "never stated" for these columns. Passing
    /// it on as a real constraint would let a scenario compute from a number
    /// the user never gave.
    func testUnstatedConstraintsBecomeNilRatherThanZero() throws {
        let profile = UserGoalProfile(
            protectedFloor: TestSupport.money("1000.00"),
            allowanceCap: TestSupport.money("250.00")
        )
        let definitions = ScenarioDefinitionBuilder.definitions(
            profile: profile, effectiveDate: TestSupport.fixedToday.now
        )

        for definition in definitions {
            XCTAssertNil(definition.plannedSavingsPerPaycheck)
            XCTAssertNil(definition.minimumProtectedCash)
            XCTAssertNil(definition.additionalReserve)
            XCTAssertNil(definition.extraPaymentCeiling)
        }
        // Nil here is not "unstated" — §6 reads a nil floor or allowance as
        // "keep the ones already in the plan snapshot", which the input builder
        // fills from this same profile. Naming them again would give one number
        // two sources that could drift apart.
        XCTAssertNil(definitions.first?.preferredFloor)
        XCTAssertNil(definitions.first?.preferredAllowance)
    }

    func testNoProfileMeansEveryConstraintIsNil() {
        let definitions = ScenarioDefinitionBuilder.definitions(
            profile: nil, effectiveDate: TestSupport.fixedToday.now
        )
        XCTAssertEqual(definitions.count, 3)
        for definition in definitions {
            XCTAssertNil(definition.preferredFloor)
            XCTAssertNil(definition.preferredAllowance)
            XCTAssertNil(definition.zeroAllowanceConfirmedAt)
        }
    }

    /// Fastest Safe drives the allowance to $0, so it needs the user to have
    /// said that is acceptable. Silence is not consent.
    func testFastestSafeWithoutTheZeroAllowanceConfirmationIsAMissingInputCard() throws {
        let state = try loadWorkspace(try makeSetup(zeroAllowanceConfirmed: false))
        let fastest = try XCTUnwrap(state.result(for: .fastestSafe))

        XCTAssertFalse(fastest.isComputable)
        XCTAssertNil(fastest.plan)
        XCTAssertTrue(fastest.missingInputs.contains { $0.field == .zeroAllowanceConfirmation })
        XCTAssertTrue(
            state.result(for: .balanced)?.isComputable == true,
            "One card missing an input must not stop the others"
        )
    }

    func testBalancedWithoutPlannedSavingsIsAMissingInputCard() throws {
        let state = try loadWorkspace(try makeSetup(plannedSavings: nil))
        let balanced = try XCTUnwrap(state.result(for: .balanced))

        XCTAssertFalse(balanced.isComputable)
        XCTAssertTrue(balanced.missingInputs.contains { $0.field == .plannedSavings })
    }

    /// The panel lists each field once, however many cards are waiting on it.
    func testMissingInputsAreDeduplicatedAcrossCards() throws {
        let state = try loadWorkspace(try makeSetup(plannedSavings: nil))
        let fields = state.distinctMissingInputs.map(\.field)

        XCTAssertEqual(
            Set(fields).count, fields.count,
            "Every field appears at most once in the combined list"
        )
        XCTAssertTrue(fields.contains(.plannedSavings))
    }

    /// Every missing input the calculator can raise points at a screen, so the
    /// panel is never a dead end.
    func testEveryMissingInputNamesWhereToAnswerIt() throws {
        let state = try loadWorkspace(
            try makeSetup(
                plannedSavings: nil, minimumProtectedCash: nil,
                additionalCushion: nil, extraCeiling: nil,
                zeroAllowanceConfirmed: false
            )
        )
        XCTAssertFalse(state.distinctMissingInputs.isEmpty)
        for missing in state.distinctMissingInputs {
            XCTAssertNotNil(
                missing.destinationTitle,
                "\(missing.field.rawValue) has no destination"
            )
            XCTAssertFalse(missing.message.isEmpty)
        }
    }

    // MARK: - Overrides (R-18)

    func testOverridesApplyToACopyAndNeverTouchSavedData() throws {
        let context = try makeSetup()
        let loader = ScenarioWorkspaceLoader(context: context, dateProvider: TestSupport.fixedToday)
        var state = try loader.preload()

        state.overrides.takeHome = TestSupport.money("3000.00")
        state.overrides.cadence = .weekly
        try loader.calculate(into: &state)

        let schedule = try XCTUnwrap(try IncomeRepository(context: context).activeSchedule())
        XCTAssertEqual(
            schedule.baseTakeHome, TestSupport.money("2400.00"),
            "The saved take-home is untouched"
        )
        XCTAssertEqual(schedule.cadence, .biweekly, "The saved cadence is untouched")
        XCTAssertEqual(
            state.baseInput?.baseTakeHome, TestSupport.money("2400.00"),
            "The preloaded snapshot still holds the saved figures"
        )
    }

    func testAHigherOverriddenIncomeShortensTheBalancedPayoff() throws {
        let context = try makeSetup()
        let loader = ScenarioWorkspaceLoader(context: context, dateProvider: TestSupport.fixedToday)

        var saved = try loader.preload()
        try loader.calculate(into: &saved)
        let savedPayoff = try XCTUnwrap(saved.result(for: .balanced)?.payoffDate)

        var raised = try loader.preload()
        raised.overrides.takeHome = TestSupport.money("3200.00")
        try loader.calculate(into: &raised)
        let raisedPayoff = try XCTUnwrap(raised.result(for: .balanced)?.payoffDate)

        XCTAssertLessThan(raisedPayoff, savedPayoff)
    }

    func testOverrideSummaryNamesWhatChangedAndSaysSavedDataIsSafe() {
        var overrides = ScenarioWorkspaceState.Overrides()
        XCTAssertNil(overrides.summary(baseCadence: .biweekly), "No overrides, nothing to explain")

        overrides.takeHome = TestSupport.money("3000.00")
        overrides.cadence = .weekly
        let summary = try? XCTUnwrap(overrides.summary(baseCadence: .biweekly))
        let text = try? XCTUnwrap(summary)
        XCTAssertTrue(text?.contains("take-home") == true)
        XCTAssertTrue(text?.contains("weekly") == true)
        XCTAssertTrue(text?.contains("saved setup is unchanged") == true)
    }

    // MARK: - Previews never persist (R-15/V3-15)

    func testCalculatingScenariosPersistsNothing() throws {
        let context = try makeSetup()
        let plansBefore = try context.fetchCount(FetchDescriptor<PlanVersion>())
        let itemsBefore = try context.fetchCount(FetchDescriptor<PaydayPlanItem>())
        let ledgerBefore = try context.fetchCount(FetchDescriptor<LedgerEntry>())

        _ = try loadWorkspace(context)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), plansBefore)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PaydayPlanItem>()), itemsBefore)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), ledgerBefore)
    }

    func testExtraPaymentInsightPersistsNothing() throws {
        let context = try makeSetup()
        let debt = try XCTUnwrap(try DebtRepository(context: context).activeDebts().first)
        let plansBefore = try context.fetchCount(FetchDescriptor<PlanVersion>())
        let ledgerBefore = try context.fetchCount(FetchDescriptor<LedgerEntry>())

        let input = try PlanningInputBuilder(context: context).build(
            asOf: DateMath.startOfDay(TestSupport.fixedToday.now)
        )
        let insight = try ExtraPaymentInsightService().insight(
            from: input,
            extra: StoredExtraPayment(
                id: UUID(), kind: .oneTime, amount: TestSupport.money("500.00"),
                effectiveDate: TestSupport.date(2054, 9, 1),
                targetDebtID: debt.id, sourceAccountID: nil
            )
        )

        XCTAssertTrue(insight.isComputable)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), plansBefore)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), ledgerBefore)
    }

    // MARK: - Applying (V3-15)

    func testApplySummaryDescribesTheChangeWithoutMakingIt() throws {
        let context = try makeSetup()
        let state = try loadWorkspace(context)
        let result = try XCTUnwrap(state.result(for: .balanced))
        let definition = try XCTUnwrap(state.definition(for: .balanced))

        let summary = try ScenarioPlanActivationService(
            context: context, dateProvider: TestSupport.fixedToday
        ).summary(for: result, definition: definition)

        XCTAssertEqual(summary.planName, "Plan v1")
        XCTAssertEqual(summary.scenarioName, "Balanced")
        XCTAssertEqual(summary.effectiveDate, definition.effectiveDate)
        XCTAssertNil(summary.replacesPlanNamed, "There is no active plan yet")
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<PlanVersion>()), 0,
            "Asking what would happen must not make it happen"
        )
    }

    func testApplyingCreatesAFutureEffectiveCalcV4PlanStampedAsAScenario() throws {
        let context = try makeSetup()
        let state = try loadWorkspace(context)
        let result = try XCTUnwrap(state.result(for: .moreCushion))
        let definition = try XCTUnwrap(state.definition(for: .moreCushion))
        let input = try XCTUnwrap(state.baseInput)

        let plan = try ScenarioPlanActivationService(
            context: context, dateProvider: TestSupport.fixedToday
        ).apply(result: result, definition: definition, baseInput: input)

        XCTAssertTrue(plan.isActive)
        XCTAssertEqual(plan.scenarioKind, .scenario)
        XCTAssertEqual(plan.effectiveDate, definition.effectiveDate)
        XCTAssertEqual(plan.calculationVersion, PlanCalculationVersion.v4BalancedQuickWin.rawValue)

        // The stored snapshot is the scenario's own input, so regenerating the
        // plan reproduces what the user actually saw.
        let stored = try GeneratedPlanService.storedInput(for: plan)
        XCTAssertEqual(stored.scenario?.kind, .moreCushion)
        XCTAssertEqual(stored.calculationVersion, PlanCalculationVersion.v4BalancedQuickWin.rawValue)
    }

    /// V3-15: the previous plan and all history remain intact.
    func testApplyingLeavesTheEarlierPlanAndItsHistoryIntact() throws {
        let context = try makeSetup()
        let state = try loadWorkspace(context)
        let input = try XCTUnwrap(state.baseInput)

        // First plan: Balanced.
        let first = try ScenarioPlanActivationService(
            context: context, dateProvider: TestSupport.fixedToday
        ).apply(
            result: try XCTUnwrap(state.result(for: .balanced)),
            definition: try XCTUnwrap(state.definition(for: .balanced)),
            baseInput: input
        )
        let firstID = first.id
        let firstName = first.name
        let firstPayoff = first.baselinePayoffDate
        let firstItemCount = try context.fetch(
            FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == firstID })
        ).count
        XCTAssertGreaterThan(firstItemCount, 0)

        // Then the user changes their mind and applies Fastest Safe.
        let second = try ScenarioPlanActivationService(
            context: context, dateProvider: TestSupport.fixedToday
        ).apply(
            result: try XCTUnwrap(state.result(for: .fastestSafe)),
            definition: try XCTUnwrap(state.definition(for: .fastestSafe)),
            baseInput: input
        )

        XCTAssertNotEqual(second.id, first.id)
        XCTAssertTrue(second.isActive)
        XCTAssertFalse(first.isActive, "Only the active flag yields")
        XCTAssertEqual(first.name, firstName)
        XCTAssertEqual(first.baselinePayoffDate, firstPayoff, "The earlier plan's figures are untouched")
        XCTAssertEqual(
            try context.fetch(
                FetchDescriptor<PaydayPlanItem>(predicate: #Predicate { $0.planVersionID == firstID })
            ).count,
            firstItemCount,
            "The earlier plan keeps every payday row"
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), 2)
    }

    func testApplyingAScenarioThatIsNotComputableIsRefused() throws {
        let context = try makeSetup(zeroAllowanceConfirmed: false)
        let state = try loadWorkspace(context)
        let result = try XCTUnwrap(state.result(for: .fastestSafe))
        let definition = try XCTUnwrap(state.definition(for: .fastestSafe))
        let input = try XCTUnwrap(state.baseInput)

        XCTAssertThrowsError(
            try ScenarioPlanActivationService(
                context: context, dateProvider: TestSupport.fixedToday
            ).apply(result: result, definition: definition, baseInput: input)
        ) { error in
            XCTAssertEqual(
                error as? ScenarioPlanActivationService.ActivationError,
                .scenarioNotComputable
            )
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), 0)
    }

    // MARK: - Copy

    func testEveryScenarioKindHasANameAndAPlainSummaryLine() {
        for kind in ScenarioKind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty)
            XCTAssertFalse(kind.summaryLine.isEmpty)
            XCTAssertFalse(kind.symbolName.isEmpty)
        }
    }

    /// No scenario copy shames the user for the trade they pick.
    func testScenarioCopyCarriesNoShameLanguage() {
        let banned = ["should", "must", "irresponsible", "too much", "waste", "bad choice"]
        for kind in ScenarioKind.allCases {
            for phrase in banned {
                XCTAssertFalse(
                    kind.summaryLine.lowercased().contains(phrase),
                    "\"\(phrase)\" appeared in \(kind.displayName): \(kind.summaryLine)"
                )
            }
        }
    }
}
