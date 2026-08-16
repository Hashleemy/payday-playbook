import XCTest
@testable import PaydayPlaybook

/// Builders for the calc-v3 scenario and extra-payment suites.
///
/// Every value here is invented. No real person's balances, income, account
/// names, or dates appear in this file or in any test that uses it (V3-12).
enum ScenarioFixtures {

    // MARK: - Stable identifiers

    static func debtID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0003-%012d", index))!
    }

    static let billID = UUID(uuidString: "00000000-0000-0000-0004-000000000001")!
    static let secondBillID = UUID(uuidString: "00000000-0000-0000-0004-000000000002")!
    static let sourceAccountID = UUID(uuidString: "00000000-0000-0000-0005-000000000001")!

    static func extraPaymentID(_ index: Int = 1) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0006-%012d", index))!
    }

    // MARK: - Dates

    /// A fixed, fictional timeline so no assertion depends on the wall clock.
    static let asOf = TestSupport.date(2027, 3, 1)
    static let firstPayday = TestSupport.date(2027, 3, 12)

    // MARK: - Builders

    static func debt(
        _ index: Int,
        name: String,
        type: DebtType = .creditCard,
        balance: String,
        apr: String,
        minimum: String? = nil,
        dueDay: Int? = nil,
        limit: String? = nil,
        prepayment: PrepaymentEligibility = .eligible
    ) -> PlanningDebt {
        PlanningDebt(
            id: debtID(index),
            displayID: "D\(index)",
            name: name,
            debtType: type,
            currentBalance: TestSupport.money(balance),
            apr: TestSupport.money(apr),
            minimumAmount: minimum.map(TestSupport.money),
            isExtraPrincipalEligible: prepayment == .eligible,
            creditLimit: limit.map(TestSupport.money),
            dueDayOfMonth: dueDay,
            originalPrincipal: nil,
            prepayment: prepayment
        )
    }

    static func bill(
        _ id: UUID = billID,
        name: String = "Studio rent share",
        amount: String = "900.00",
        cadence: ObligationCadence = .monthly,
        dueDay: Int? = 1
    ) -> PlanningObligation {
        PlanningObligation(
            id: id, name: name, amount: TestSupport.money(amount),
            cadence: cadence, dueDay: dueDay
        )
    }

    /// Three fictional debts across two debt types: one high-APR card, one
    /// smaller card, and an installment loan with an entered payment.
    static func standardDebts() -> [PlanningDebt] {
        [
            debt(1, name: "Aurora Card", balance: "2400.00", apr: "0.2450", dueDay: 14, limit: "5000.00"),
            debt(2, name: "Beacon Card", balance: "900.00", apr: "0.1899", dueDay: 22, limit: "2000.00"),
            debt(3, name: "Comet Auto Loan", type: .autoLoan, balance: "4800.00",
                 apr: "0.0699", minimum: "220.00", dueDay: 5)
        ]
    }

    static func snapshot(
        calculationVersion: Int = 2,
        cadence: PayCadence = .biweekly,
        monthlyPayDay: Int? = nil,
        semimonthlyPayDay1: Int? = nil,
        semimonthlyPayDay2: Int? = nil,
        nextPayday: Date = firstPayday,
        takeHome: String = "2400.00",
        incomeChanges: [PlanningIncomeChange] = [],
        startingBalance: String = "1200.00",
        protectedFloor: String = "1000.00",
        allowanceCap: String = "250.00",
        obligations: [PlanningObligation]? = nil,
        debts: [PlanningDebt]? = nil,
        scenario: StoredScenarioDefinition? = nil,
        extraPayments: [StoredExtraPayment] = []
    ) -> StoredPlanInput {
        StoredPlanInput(
            calculationVersion: calculationVersion,
            cadence: cadence,
            monthlyPayDay: monthlyPayDay,
            semimonthlyPayDay1: semimonthlyPayDay1,
            semimonthlyPayDay2: semimonthlyPayDay2,
            nextPayday: nextPayday,
            baseTakeHome: TestSupport.money(takeHome),
            incomeChanges: incomeChanges,
            spendingStartingBalance: TestSupport.money(startingBalance),
            protectedFloor: TestSupport.money(protectedFloor),
            allowanceCap: TestSupport.money(allowanceCap),
            firstCheckBufferAdd: .zero,
            obligations: obligations ?? [bill()],
            debts: debts ?? standardDebts(),
            paycheckCap: StoredPlanInput.defaultPaycheckCap,
            timeZoneID: TimeZone.current.identifier,
            asOf: asOf,
            scenario: scenario,
            extraPayments: extraPayments
        )
    }

    // MARK: - Scenario definitions

    /// A fully-answered definition for each kind; individual tests null out one
    /// field at a time to exercise the missing-input contract (T-8).
    static func definition(
        _ kind: ScenarioKind,
        incomeOverride: StoredIncomeOverride? = nil,
        minimumProtectedCash: String? = "400.00",
        preferredFloor: String? = "1000.00",
        preferredAllowance: String? = "250.00",
        plannedSavings: String? = "100.00",
        additionalReserve: String? = "150.00",
        extraPaymentCeiling: String? = nil,
        zeroAllowanceConfirmed: Bool = true,
        effectiveDate: Date = firstPayday
    ) -> StoredScenarioDefinition {
        StoredScenarioDefinition(
            kind: kind,
            incomeOverride: incomeOverride,
            minimumProtectedCash: minimumProtectedCash.map(TestSupport.money),
            preferredFloor: preferredFloor.map(TestSupport.money),
            preferredAllowance: preferredAllowance.map(TestSupport.money),
            plannedSavingsPerPaycheck: plannedSavings.map(TestSupport.money),
            additionalReserve: additionalReserve.map(TestSupport.money),
            extraPaymentCeiling: extraPaymentCeiling.map(TestSupport.money),
            zeroAllowanceConfirmedAt: zeroAllowanceConfirmed ? TestSupport.date(2027, 2, 20) : nil,
            effectiveDate: effectiveDate
        )
    }

    /// The three cards, in contract order.
    static func allDefinitions() -> [StoredScenarioDefinition] {
        [definition(.fastestSafe), definition(.balanced), definition(.moreCushion)]
    }

    static func extraPayment(
        _ index: Int = 1,
        kind: ExtraPaymentKind = .oneTime,
        amount: String = "500.00",
        effectiveDate: Date = firstPayday,
        targetDebtID: UUID? = nil,
        sourceAccountID: UUID? = nil
    ) -> StoredExtraPayment {
        StoredExtraPayment(
            id: extraPaymentID(index),
            kind: kind,
            amount: TestSupport.money(amount),
            effectiveDate: effectiveDate,
            targetDebtID: targetDebtID,
            sourceAccountID: sourceAccountID
        )
    }

    // MARK: - R-16 reconciliation (must hold on every calc-v3 result)

    /// Asserts the four contracted identities plus the calc-v3 extension that
    /// retained scenario cash is part of `keepInSpending`. A single failing
    /// paycheck is reported with its sequence number so the row is findable.
    static func assertReconciles(
        _ result: PlanningResult,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for paycheck in result.paychecks {
            let where_ = "\(label) paycheck \(paycheck.sequence)"

            XCTAssertEqual(
                paycheck.income + paycheck.windfall,
                paycheck.keepInSpending + paycheck.transferToReserves,
                "\(where_): income + windfall != keep + transfer", file: file, line: line
            )
            XCTAssertEqual(
                paycheck.debtBudget + (paycheck.shortfall?.minimumsGap ?? 0),
                paycheck.minimumsTotal + paycheck.extraTotal + paycheck.unassignedCash,
                "\(where_): debt budget + minimums gap != minimums + extra + unassigned",
                file: file, line: line
            )
            XCTAssertEqual(
                paycheck.payments.reduce(Decimal.zero) { $0 + $1.minimum + $1.extra },
                paycheck.minimumsTotal + paycheck.extraTotal,
                "\(where_): per-debt payments != minimums + extra", file: file, line: line
            )
            if let shortfall = paycheck.shortfall {
                XCTAssertEqual(
                    shortfall.gap,
                    shortfall.floorGap + shortfall.obligationGap + shortfall.minimumsGap,
                    "\(where_): shortfall gap != floor + obligation + minimums gaps",
                    file: file, line: line
                )
            }
            XCTAssertEqual(
                paycheck.keepInSpending,
                paycheck.allowanceReserved + paycheck.floorTopUp + paycheck.scenarioCashRetained,
                "\(where_): keep != allowance + floor top-up + retained", file: file, line: line
            )
            XCTAssertGreaterThanOrEqual(
                paycheck.windfall, paycheck.extraPaymentInflow,
                "\(where_): extra-payment inflow exceeds the deposit it rides in",
                file: file, line: line
            )
            // Every emitted amount is whole cents.
            for amount in [paycheck.keepInSpending, paycheck.transferToReserves,
                           paycheck.minimumsTotal, paycheck.extraTotal,
                           paycheck.unassignedCash, paycheck.scenarioCashRetained] {
                XCTAssertEqual(amount, amount.rounded2,
                               "\(where_): \(amount) is not whole cents", file: file, line: line)
            }
        }
    }
}
