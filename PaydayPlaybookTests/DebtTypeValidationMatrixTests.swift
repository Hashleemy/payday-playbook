import XCTest
import SwiftData
@testable import PaydayPlaybook

/// T-18 (V4-01): the §4.6 debt-type field-relevance matrix, held on every
/// surface at once. Three surfaces answer "what does this debt still need?" —
/// the editor rules (`DebtFormRules`), the Bills & Debts row warnings
/// (`BillsAndDebtsLoader.warnings`), and the review/checklist gap list
/// (`SetupCompletenessService`) — and they must agree exactly, all driven by
/// the one semantic source on `DebtType`.
///
/// All values are fictional (V3-12).
final class DebtTypeValidationMatrixTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        ModelContext(try TestSupport.makeContainer())
    }

    private var installmentTypes: [DebtType] {
        DebtType.allCases.filter { $0 != .creditCard }
    }

    /// A debt of the given type with every optional field left blank, saved
    /// the way the editors save (through the repository), so the fixture the
    /// three surfaces see is identical.
    @discardableResult
    private func insertBareDebt(
        _ type: DebtType,
        named name: String,
        context: ModelContext
    ) throws -> DebtAccount {
        try DebtRepository(context: context).create(
            type: type,
            displayName: name,
            currentBalance: TestSupport.money("1200.00"),
            apr: TestSupport.money("0.1999"),
            // Installment types cannot be saved without a minimum (A-06),
            // and that rule is not under test here.
            minimumAmount: type.requiresEnteredMinimum ? TestSupport.money("90.00") : nil,
            now: TestSupport.date(2054, 8, 1)
        )
    }

    // MARK: - Original principal (the reported defect)

    /// A credit card with every card-meaningful field completed and no
    /// original principal is a complete answer: no gap, no warning, no
    /// blocker — and the plan generates.
    func testCreditCardWithNoOriginalPrincipalPassesSetupValidation() throws {
        let context = try makeContext()
        try CashAccountRepository(context: context).create(
            name: "Everyday", currentBalance: TestSupport.money("900.00"),
            roles: [.income, .spending]
        )
        try GoalProfileRepository(context: context).save(
            goalText: nil, targetDebtFreeDate: nil, posture: .steady,
            protectedFloor: TestSupport.money("500.00"),
            allowanceCap: TestSupport.money("200.00")
        )
        try IncomeRepository(context: context).save(
            cadence: .biweekly, anchorPayday: TestSupport.date(2054, 9, 4),
            takeHome: TestSupport.money("1900.00"), monthlyDay: nil,
            semimonthlyFirstDay: nil, semimonthlySecondDay: nil,
            destinationAccountID: nil
        )
        let card = try DebtRepository(context: context).create(
            type: .creditCard, displayName: "Card Alpha",
            currentBalance: TestSupport.money("1450.00"),
            apr: TestSupport.money("0.2399"),
            minimumAmount: TestSupport.money("45.00"),
            originalPrincipal: nil,
            creditLimit: TestSupport.money("4000.00"),
            dueDayOfMonth: 12
        )

        let gaps = try SetupCompletenessService(context: context).gaps()
        XCTAssertTrue(
            gaps.filter { $0.subjectID == card.id }.isEmpty,
            "A fully answered card has nothing left to ask: \(gaps.map(\.title))"
        )
        XCTAssertEqual(BillsAndDebtsLoader.warnings(for: card), [])

        let plan = try PlanGenerationService.generate(
            context: context, asOf: TestSupport.date(2054, 8, 10)
        )
        XCTAssertFalse(plan.rows.paydays.isEmpty)
    }

    /// No surface — editor, chip, or gap list — mentions original principal
    /// for a card, even one missing everything optional.
    func testNoSurfaceAsksACardForOriginalPrincipal() throws {
        let context = try makeContext()
        let card = try insertBareDebt(.creditCard, named: "Card Beta", context: context)

        XCTAssertFalse(DebtFormRules(type: .creditCard).showsOriginalPrincipal)
        XCTAssertFalse(BillsAndDebtsLoader.warnings(for: card).contains("the original amount"))
        let gaps = try SetupCompletenessService(context: context).gaps()
        XCTAssertFalse(gaps.contains { $0.kind == .originalPrincipal })
        // The presentation predicate the Debts-tab editor gates on agrees.
        XCTAssertFalse(DebtType.creditCard.showsOriginalPrincipal)
    }

    /// Installment-style debts keep original principal as a helpful,
    /// never-blocking optional gap on all three surfaces.
    func testInstallmentTypesKeepTheOptionalOriginalPrincipalGap() throws {
        for type in installmentTypes {
            let context = try makeContext()
            let debt = try insertBareDebt(type, named: "Auto Loan", context: context)

            XCTAssertTrue(
                DebtFormRules(type: type).showsOriginalPrincipal,
                "\(type.rawValue) asks for original principal"
            )
            XCTAssertTrue(
                BillsAndDebtsLoader.warnings(for: debt).contains("the original amount"),
                "\(type.rawValue) row warns about the missing original amount"
            )
            let gap = try XCTUnwrap(
                try SetupCompletenessService(context: context).gaps()
                    .first { $0.kind == .originalPrincipal },
                "\(type.rawValue) is gap-listed on original principal"
            )
            XCTAssertEqual(gap.subjectID, debt.id)
            XCTAssertFalse(gap.isBlocker, "Original principal never blocks (§4.6)")

            // The editor's "Required" chip on loans is presentation-only:
            // model validation accepts a blank original principal.
            XCTAssertNoThrow(try ModelValidation.validateDebt(
                type: type, displayName: "Auto Loan",
                currentBalance: TestSupport.money("1200.00"),
                originalPrincipal: nil, apr: TestSupport.money("0.1999"),
                minimumAmount: TestSupport.money("90.00"),
                creditLimit: nil, dueDayOfMonth: nil, lastFour: nil
            ))
        }
    }

    /// A credit limit is a credit limit — it never satisfies, produces, or
    /// masquerades as an original-principal requirement.
    func testCreditLimitIsNotInterpretedAsOriginalPrincipal() throws {
        let context = try makeContext()
        // A card with a limit and no original principal: the limit gap
        // closes, and no original-principal gap opens in its place.
        let cardWithLimit = try DebtRepository(context: context).create(
            type: .creditCard, displayName: "Card Alpha",
            currentBalance: TestSupport.money("800.00"),
            apr: TestSupport.money("0.2199"),
            minimumAmount: nil,
            originalPrincipal: nil,
            creditLimit: TestSupport.money("2500.00"),
            now: TestSupport.date(2054, 8, 1)
        )
        // A card with neither: the one gap it gets is the credit limit.
        let cardWithout = try insertBareDebt(.creditCard, named: "Card Beta", context: context)

        let gaps = try SetupCompletenessService(context: context).gaps()
        XCTAssertFalse(gaps.contains { $0.kind == .originalPrincipal })
        XCTAssertFalse(gaps.contains { $0.kind == .creditLimit && $0.subjectID == cardWithLimit.id })
        XCTAssertTrue(gaps.contains { $0.kind == .creditLimit && $0.subjectID == cardWithout.id })

        // Utilization reads the limit, never the original principal: a card
        // carrying only an original principal still has unknown utilization.
        let stored = DebtAccount(
            planID: "T1", displayName: "Card Gamma",
            startingBalance: TestSupport.money("600.00"),
            apr: TestSupport.money("0.2099"), priority: 9,
            debtType: .creditCard,
            originalPrincipal: TestSupport.money("5000.00"), creditLimit: nil
        )
        XCTAssertNil(stored.utilization(currentBalance: stored.startingBalance))
    }

    // MARK: - Credit limit relevance

    func testCreditLimitIsOnlyEverAskedOfCards() throws {
        for type in installmentTypes {
            let context = try makeContext()
            let debt = try insertBareDebt(type, named: "Auto Loan", context: context)

            XCTAssertFalse(DebtFormRules(type: type).showsCreditLimit)
            XCTAssertFalse(BillsAndDebtsLoader.warnings(for: debt).contains("the credit limit"))
            XCTAssertFalse(
                try SetupCompletenessService(context: context).gaps()
                    .contains { $0.kind == .creditLimit }
            )
            // And storing one on a non-card is rejected at the model layer.
            XCTAssertThrowsError(try ModelValidation.validateDebt(
                type: type, displayName: "Auto Loan",
                currentBalance: TestSupport.money("1200.00"),
                originalPrincipal: nil, apr: TestSupport.money("0.1999"),
                minimumAmount: TestSupport.money("90.00"),
                creditLimit: TestSupport.money("3000.00"),
                dueDayOfMonth: nil, lastFour: nil
            )) { error in
                XCTAssertEqual(error as? ModelValidationError, .creditLimitOnNonCard(type))
            }
        }
    }

    func testMarkedUnknownLimitStopsEveryAsk() throws {
        let context = try makeContext()
        let card = try DebtRepository(context: context).create(
            type: .creditCard, displayName: "Card Alpha",
            currentBalance: TestSupport.money("700.00"),
            apr: TestSupport.money("0.2499"),
            minimumAmount: nil,
            creditLimitMarkedUnknown: true,
            now: TestSupport.date(2054, 8, 1)
        )
        XCTAssertFalse(BillsAndDebtsLoader.warnings(for: card).contains("the credit limit"))
        XCTAssertFalse(
            try SetupCompletenessService(context: context).gaps()
                .contains { $0.kind == .creditLimit }
        )
        XCTAssertNil(card.utilization(currentBalance: card.startingBalance))
    }

    // MARK: - The blocking set is unchanged

    /// Only missing installment minimums (A-06) and the structural blockers
    /// (no account, no income, no default income account, no profile) block
    /// generation. No per-debt optional field ever does.
    func testOnlyInstallmentMinimumsBlockAmongDebtFields() throws {
        for type in DebtType.allCases {
            let context = try makeContext()
            let debt = DebtAccount(
                planID: "T1", displayName: type == .creditCard ? "Card Alpha" : "Auto Loan",
                startingBalance: TestSupport.money("1500.00"),
                apr: TestSupport.money("0.1499"),
                minimumAmount: nil, priority: 1,
                debtType: type
            )
            context.insert(debt)
            try context.save()

            let debtBlockers = try SetupCompletenessService(context: context).gaps()
                .filter { $0.isBlocker && $0.subjectID == debt.id }
            if type.requiresEnteredMinimum {
                XCTAssertEqual(debtBlockers.map(\.kind), [.estimatedMinimum])
            } else {
                XCTAssertTrue(debtBlockers.isEmpty, "\(type.rawValue) has no per-debt blocker")
            }
        }
    }

    // MARK: - Three surfaces, one rule

    /// For every type and every per-debt concept, the chip warnings and the
    /// gap list assert the same set of missing fields on the same fixture.
    func testChipsAndGapListAgreeFieldByFieldOnEveryType() throws {
        for type in DebtType.allCases {
            let context = try makeContext()
            let debt = try insertBareDebt(type, named: "Debt Under Test", context: context)
            let warnings = BillsAndDebtsLoader.warnings(for: debt)
            let kinds = Set(
                try SetupCompletenessService(context: context).gaps()
                    .filter { $0.subjectID == debt.id }
                    .map(\.kind)
            )

            XCTAssertEqual(
                warnings.contains("the original amount"),
                kinds.contains(.originalPrincipal),
                "\(type.rawValue): original-principal surfaces disagree"
            )
            XCTAssertEqual(
                warnings.contains("the credit limit"),
                kinds.contains(.creditLimit),
                "\(type.rawValue): credit-limit surfaces disagree"
            )
            XCTAssertEqual(
                warnings.contains("its due day"),
                kinds.contains(.dueDay),
                "\(type.rawValue): due-day surfaces disagree"
            )
            XCTAssertEqual(
                warnings.contains("whether extra principal is allowed"),
                kinds.contains(.extraPrincipalEligibility),
                "\(type.rawValue): prepayment surfaces disagree"
            )
            // The editor's ask matches both: it shows the original-principal
            // field exactly when the concept exists for the type.
            XCTAssertEqual(
                DebtFormRules(type: type).showsOriginalPrincipal,
                type.usesOriginalPrincipal
            )
            XCTAssertEqual(DebtFormRules(type: type).showsCreditLimit, type.supportsCreditLimit)
        }
    }

    /// Due day is an optional gap for every type (§4.6): the editor chip
    /// says optional, and the gap never blocks.
    func testDueDayIsAnOptionalGapForEveryType() throws {
        for type in DebtType.allCases {
            XCTAssertEqual(DebtFormRules(type: type).dueDay, .optional)

            let context = try makeContext()
            let debt = try insertBareDebt(type, named: "Debt Under Test", context: context)
            let gap = try XCTUnwrap(
                try SetupCompletenessService(context: context).gaps()
                    .first { $0.kind == .dueDay && $0.subjectID == debt.id }
            )
            XCTAssertFalse(gap.isBlocker)
        }
    }
}
