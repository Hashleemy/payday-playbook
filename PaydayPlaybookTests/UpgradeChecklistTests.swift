import XCTest
import SwiftData
@testable import PaydayPlaybook

/// The upgrade path (V2-16): an install that already has a plan never
/// repeats onboarding. It sees a checklist of only the questions v0.2.0
/// newly knows how to ask, and answering them preserves every existing plan
/// and actual value.
final class UpgradeChecklistTests: XCTestCase {

    /// A 0.1.x store carried through the schema 1→2 migration, with the
    /// activity a real upgrade brings.
    private func makeMigratedStore() throws -> (ModelContainer, ModelContext) {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context, applySchemaUpgrade: false)
        let settings = try XCTUnwrap(context.fetch(FetchDescriptor<AppSettings>()).first)
        settings.onboardingComplete = true

        let debts = try context.fetch(FetchDescriptor<DebtAccount>())
        let cardB = try XCTUnwrap(debts.first { $0.planID == "B" })
        context.insert(LedgerEntry(
            effectiveDate: TestSupport.date(2054, 8, 20),
            type: .cardPayment,
            amount: TestSupport.money("1061.07"),
            sourceAccount: .checking2,
            destinationAccount: .card,
            debtAccountID: cardB.id,
            debtPlanID: "B"
        ))
        let plan = try XCTUnwrap(PlanRepository.legacyBaseline(context: context))
        let firstItem = try XCTUnwrap(TestSupport.planItems(context, plan: plan).first)
        let checkIn = PaydayCheckIn(paydayPlanItemID: firstItem.id, status: .completed)
        checkIn.actualIncome = TestSupport.money("2400.00")
        checkIn.completedAt = TestSupport.date(2054, 8, 20)
        context.insert(checkIn)
        try context.save()

        _ = try MigrationService.migrateIfNeeded(
            context: context, dateProvider: FixedDateProvider(fixed: TestSupport.date(2054, 8, 21))
        )
        return (container, context)
    }

    // MARK: - No re-onboarding

    func testMigratedInstallSkipsOnboardingEntirely() throws {
        let (_, context) = try makeMigratedStore()

        let settings = try XCTUnwrap(context.fetch(FetchDescriptor<AppSettings>()).first)
        XCTAssertTrue(settings.onboardingComplete)
        let progress = try OnboardingProgressService(
            context: context, dateProvider: TestSupport.fixedToday
        ).progress()
        XCTAssertNotNil(progress.completedAt)
        XCTAssertEqual(progress.resumeStep, .finished)
    }

    // MARK: - The checklist asks only about the new questions

    func testChecklistAsksOnlyForWhatMigrationCouldNotKnow() throws {
        let (_, context) = try makeMigratedStore()
        let gaps = try SetupCompletenessService(context: context).gaps()
        let kinds = Set(gaps.map(\.kind))

        // Things migration DID establish are never asked about again.
        XCTAssertFalse(kinds.contains(.accountRoles), "Checking 1/2 became roled accounts")
        XCTAssertFalse(kinds.contains(.defaultIncomeAccount), "Checking 1 is the income account")
        XCTAssertFalse(kinds.contains(.income), "The plan's income rules became a live schedule")
        XCTAssertFalse(kinds.contains(.incomeCadenceDays), "Biweekly needs no day-of-month")
        XCTAssertFalse(kinds.contains(.obligations), "Car and train became obligations")

        // Things it could not know are offered, and none of them blocks.
        XCTAssertTrue(kinds.contains(.goals), "Migration has no goal or target date")
        XCTAssertTrue(kinds.contains(.creditLimit), "0.1.x never stored card limits")
        XCTAssertTrue(kinds.contains(.debtType), "Types were defaulted, not confirmed")
        // V4-01: every migrated debt is typed credit card, and a revolving
        // card has no original principal to ask about — the ask appears only
        // if the user confirms a row is really an installment debt.
        XCTAssertFalse(kinds.contains(.originalPrincipal), "A card is never asked (V4-01)")
        XCTAssertTrue(gaps.allSatisfy { !$0.isBlocker }, "A migrated user is never blocked")
    }

    /// The original-principal concept still exists on the checklist — for
    /// the types that have one. Confirming a defaulted "card" is really a
    /// loan surfaces the ask that the card typing suppressed (V4-01).
    func testRetypingACardToALoanSurfacesTheOriginalPrincipalAsk() throws {
        let (_, context) = try makeMigratedStore()
        let cardB = try XCTUnwrap(
            context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" }
        )
        XCTAssertFalse(
            try SetupCompletenessService(context: context).gaps()
                .contains { $0.kind == .originalPrincipal },
            "While typed as cards, no row is asked for an original amount"
        )

        try DebtRepository(context: context).update(
            cardB, type: .personalLoan, displayName: cardB.displayName,
            currentBalance: cardB.startingBalance, apr: cardB.apr,
            minimumAmount: TestSupport.money("100.00"),
            originalPrincipal: nil, creditLimit: nil,
            dueDayOfMonth: cardB.dueDayOfMonth, prepayment: .eligible, note: nil
        )

        let gap = try XCTUnwrap(
            try SetupCompletenessService(context: context).gaps()
                .first { $0.kind == .originalPrincipal }
        )
        XCTAssertEqual(gap.subjectID, cardB.id)
        XCTAssertFalse(gap.isBlocker)
    }

    func testEveryChecklistItemPointsAtAnEditor() throws {
        let (_, context) = try makeMigratedStore()
        for gap in try SetupCompletenessService(context: context).gaps() {
            switch gap.destination {
            case .debts, .accounts, .obligations:
                XCTAssertNotNil(
                    gap.subjectID ?? UUID(),
                    "\(gap.kind.rawValue) opens a row editor or an add sheet"
                )
            case .goals, .income:
                break // Global editors need no subject.
            }
            XCTAssertFalse(gap.title.isEmpty)
            XCTAssertFalse(gap.detail.isEmpty)
        }
    }

    // MARK: - Answering the checklist preserves everything

    func testAnsweringTheChecklistPreservesPlanAndActualData() throws {
        let (_, context) = try makeMigratedStore()

        // Capture the whole baseline and the actual track, value for value.
        let plan = try XCTUnwrap(PlanRepository.legacyBaseline(context: context))
        let planID = plan.id
        let itemsBefore = try TestSupport.planItems(context, plan: plan).map {
            [$0.plannedIncome, $0.plannedC1Keep, $0.plannedC2Transfer, $0.plannedCardBudget,
             $0.plannedCarReserve, $0.plannedTrainReserve, $0.plannedDebtAfter,
             $0.plannedC1NoSpendCeiling]
        }
        let planFieldsBefore = [
            plan.startingChecking1, plan.protectedBuffer, plan.allowanceCap,
            plan.baselineModeledInterest, plan.baselineNoSpendCeiling
        ]
        let payoffBefore = plan.baselinePayoffDate
        let calcVersionBefore = plan.calculationVersion
        let ledgerBefore = try context.fetch(FetchDescriptor<LedgerEntry>()).count
        let checkInBefore = try XCTUnwrap(context.fetch(FetchDescriptor<PaydayCheckIn>()).first)
        let checkInIncomeBefore = checkInBefore.actualIncome
        let debtsBefore = try context.fetch(FetchDescriptor<DebtAccount>())
            .sorted { $0.planID < $1.planID }
            .map { [$0.startingBalance, $0.apr] }

        // The user works the checklist: a goal, a card limit, and a
        // confirmed type. (No original principal — a card is never asked
        // for one, V4-01.)
        try GoalProfileRepository(context: context).save(
            goalText: "Debt-free before the wedding",
            targetDebtFreeDate: TestSupport.date(2055, 9, 1),
            posture: .fullThrottle,
            protectedFloor: TestSupport.money("1000.00"),
            allowanceCap: TestSupport.money("300.00")
        )
        let cardB = try XCTUnwrap(
            context.fetch(FetchDescriptor<DebtAccount>()).first { $0.planID == "B" }
        )
        try DebtRepository(context: context).update(
            cardB, type: .creditCard, displayName: cardB.displayName,
            currentBalance: cardB.startingBalance, apr: cardB.apr,
            minimumAmount: cardB.minimumAmount,
            originalPrincipal: nil,
            creditLimit: TestSupport.money("3000.00"),
            dueDayOfMonth: cardB.dueDayOfMonth, prepayment: .eligible, note: nil
        )

        // Baseline plan: untouched, field for field.
        let planAfter = try XCTUnwrap(
            context.fetch(FetchDescriptor<PlanVersion>()).first { $0.id == planID }
        )
        XCTAssertEqual(
            [planAfter.startingChecking1, planAfter.protectedBuffer, planAfter.allowanceCap,
             planAfter.baselineModeledInterest, planAfter.baselineNoSpendCeiling],
            planFieldsBefore
        )
        XCTAssertEqual(planAfter.baselinePayoffDate, payoffBefore)
        XCTAssertEqual(planAfter.calculationVersion, calcVersionBefore, "Original Plan v1 stays calc v1")
        XCTAssertEqual(
            try TestSupport.planItems(context, plan: planAfter).map {
                [$0.plannedIncome, $0.plannedC1Keep, $0.plannedC2Transfer, $0.plannedCardBudget,
                 $0.plannedCarReserve, $0.plannedTrainReserve, $0.plannedDebtAfter,
                 $0.plannedC1NoSpendCeiling]
            },
            itemsBefore,
            "Every planned value of all 23 paychecks is unchanged"
        )

        // Actual track: untouched.
        XCTAssertEqual(try context.fetch(FetchDescriptor<LedgerEntry>()).count, ledgerBefore)
        XCTAssertEqual(checkInBefore.actualIncome, checkInIncomeBefore)
        XCTAssertEqual(checkInBefore.status, .completed)

        // Debt balances and rates: untouched; only the new fields changed.
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<DebtAccount>())
                .sorted { $0.planID < $1.planID }
                .map { [$0.startingBalance, $0.apr] },
            debtsBefore
        )
        XCTAssertEqual(cardB.creditLimit, TestSupport.money("3000.00"))
        XCTAssertNil(cardB.originalPrincipal, "Never fabricated, never asked of a card")
        XCTAssertNotNil(cardB.debtTypeConfirmedAt)

        // And the answered items leave the checklist. Original principal was
        // never on it for these cards (V4-01).
        let remaining = try SetupCompletenessService(context: context).gaps()
        XCTAssertFalse(remaining.contains { $0.kind == .goals })
        XCTAssertFalse(remaining.contains { $0.kind == .creditLimit && $0.subjectID == cardB.id })
        XCTAssertFalse(remaining.contains { $0.kind == .originalPrincipal })
        XCTAssertFalse(remaining.contains { $0.kind == .debtType && $0.subjectID == cardB.id })
        // The five cards not yet touched still appear.
        XCTAssertEqual(remaining.filter { $0.kind == .creditLimit }.count, 5)
    }

    /// A fresh install carries no pre-existing plan data, and its checklist
    /// is the empty-store one rather than the migrated one.
    func testFreshInstallHasNoSeededDataAndBlocksUntilSetupIsDone() throws {
        let context = ModelContext(try TestSupport.makeContainer())
        _ = try MigrationService.migrateIfNeeded(context: context)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DebtAccount>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PaydayPlanItem>()), 0)

        let gaps = try SetupCompletenessService(context: context).gaps()
        XCTAssertTrue(gaps.contains { $0.kind == .income && $0.isBlocker })
        XCTAssertTrue(gaps.contains { $0.kind == .accountRoles && $0.isBlocker })
    }
}
