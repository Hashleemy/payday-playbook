import Foundation
@testable import PaydayPlaybook

/// Shared builders for calc-v2 planning tests. Fixed UUIDs keep every test
/// deterministic and let assertions reference debts by plan letter.
enum PlanningFixtures {

    static func debtID(_ letter: String) -> UUID {
        let hex = String(letter.unicodeScalars.first!.value, radix: 16, uppercase: true)
        let suffix = String(repeating: "0", count: 12 - hex.count) + hex
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }

    static let carObligationID = UUID(uuidString: "00000000-0000-0000-0001-000000000001")!
    static let transitObligationID = UUID(uuidString: "00000000-0000-0000-0001-000000000002")!

    /// Onboarding inputs equivalent to `DebugBaselineFixture`, so a calc-v2
    /// plan generated from them is directly comparable to the calc-v1
    /// projection of the same numbers.
    ///
    /// These values are invented. The suite previously used one real person's
    /// finances here, which meant a parity test could not be read or changed
    /// without handling their actual balances; the parity property being
    /// checked never depended on whose numbers they were.
    static func baselineInput() -> PlanningInput {
        let seeds: [(String, String, String, Int)] = [
            ("A", "5700.00", "0.2600", 1),
            ("B", "5850.00", "0.2300", 2),
            ("C", "6500.00", "0.2000", 3),
            ("D", "5700.00", "0.1700", 4),
            ("E", "6150.00", "0.1400", 5),
            ("F", "6500.00", "0.1100", 6)
        ]
        return PlanningInput(
            asOf: TestSupport.date(2054, 8, 10),
            income: IncomeInput(
                cadence: .biweekly,
                firstPayday: TestSupport.date(2054, 8, 20),
                amounts: [
                    PlanningIncomeChange(effectiveDate: TestSupport.date(2054, 8, 20),
                                 amount: TestSupport.money("2400.00")),
                    PlanningIncomeChange(effectiveDate: TestSupport.date(2054, 12, 10),
                                 amount: TestSupport.money("2500.00"))
                ]
            ),
            spending: SpendingInput(
                startingBalance: TestSupport.money("1500.00"),
                protectedFloor: TestSupport.money("1500.00"),
                allowancePerPaycheck: TestSupport.money("300.00")
            ),
            obligations: [
                ObligationInput(id: carObligationID, name: "Car",
                                amount: TestSupport.money("700.00"), cadence: .monthly, dueDay: nil),
                ObligationInput(id: transitObligationID, name: "Transit pass",
                                amount: TestSupport.money("150.00"), cadence: .monthly, dueDay: nil)
            ],
            debts: seeds.map { letter, balance, apr, order in
                DebtInput(
                    id: debtID(letter),
                    name: letter,
                    debtType: .creditCard,
                    balance: TestSupport.money(balance),
                    apr: TestSupport.money(apr),
                    promo: nil,
                    minimumPayment: nil,
                    dueDay: nil,
                    creditLimit: nil,
                    prepayment: .eligible,
                    createdOrder: order
                )
            }
        )
    }

    /// The calc-v1 projection of the same invented inputs, for parity checks.
    static func baselineLegacyProjection() -> DebtCalculationEngine.ProjectionResult {
        let input = baselineInput()
        let reserves = DebugBaselineFixture.carReservePerCheck
            + DebugBaselineFixture.transitReservePerCheck
        let dates = (0..<40).map {
            DateMath.addingDays(PlanContract.payFrequencyDays * $0, to: DebugBaselineFixture.firstPayday)
        }
        let paydays = dates.enumerated().map { offset, date -> DebtCalculationEngine.EnginePayday in
            let sequence = offset + 1
            let income = sequence >= DebugBaselineFixture.raiseAtSequence
                ? DebugBaselineFixture.raisedIncome
                : DebugBaselineFixture.firstIncome
            let budget = (income - DebugBaselineFixture.allowancePerCheck - reserves).rounded2
            return DebtCalculationEngine.EnginePayday(
                sequence: sequence, date: date, cardBudget: budget
            )
        }
        let debts = input.debts.map {
            DebtCalculationEngine.EngineDebt(planID: $0.name, apr: $0.apr, balance: $0.balance)
        }
        return DebtCalculationEngine.project(debts: debts, paydays: paydays)
    }

    /// A small generic input for behavior tests: biweekly $2,000 take-home,
    /// $500 floor already met, $200 allowance, no obligations by default.
    static func simpleInput(
        debts: [DebtInput],
        allowance: String = "200.00",
        floor: String = "500.00",
        startingBalance: String = "500.00",
        income: String = "2000.00",
        obligations: [ObligationInput] = [],
        windfalls: [Windfall] = [],
        cadence: PlanningPayCadence = .biweekly,
        firstPayday: Date = TestSupport.date(2054, 8, 20)
    ) -> PlanningInput {
        PlanningInput(
            asOf: TestSupport.date(2054, 8, 9),
            income: IncomeInput(
                cadence: cadence,
                firstPayday: firstPayday,
                amounts: [PlanningIncomeChange(effectiveDate: firstPayday, amount: TestSupport.money(income))],
                windfalls: windfalls
            ),
            spending: SpendingInput(
                startingBalance: TestSupport.money(startingBalance),
                protectedFloor: TestSupport.money(floor),
                allowancePerPaycheck: TestSupport.money(allowance)
            ),
            obligations: obligations,
            debts: debts
        )
    }

    static func card(
        _ letter: String,
        balance: String,
        apr: String,
        minimum: String? = nil,
        dueDay: Int? = nil,
        limit: String? = nil,
        promo: PromoAPR? = nil,
        prepayment: PrepaymentEligibility = .eligible,
        order: Int = 0
    ) -> DebtInput {
        DebtInput(
            id: debtID(letter),
            name: letter,
            debtType: .creditCard,
            balance: TestSupport.money(balance),
            apr: TestSupport.money(apr),
            promo: promo,
            minimumPayment: minimum.map(TestSupport.money),
            dueDay: dueDay,
            creditLimit: limit.map(TestSupport.money),
            prepayment: prepayment,
            createdOrder: order
        )
    }

    static func loan(
        _ letter: String,
        type: DebtType = .personalLoan,
        balance: String,
        apr: String,
        minimum: String? = nil,
        dueDay: Int? = nil,
        prepayment: PrepaymentEligibility = .eligible,
        order: Int = 0
    ) -> DebtInput {
        DebtInput(
            id: debtID(letter),
            name: letter,
            debtType: type,
            balance: TestSupport.money(balance),
            apr: TestSupport.money(apr),
            promo: nil,
            minimumPayment: minimum.map(TestSupport.money),
            dueDay: dueDay,
            creditLimit: nil,
            prepayment: prepayment,
            createdOrder: order
        )
    }

    /// Asserts nothing; returns the target (first extra recipient) sequence
    /// for each paycheck for order assertions.
    static func targets(_ result: PlanningResult) -> [UUID?] {
        result.paychecks.map(\.targetDebtID)
    }
}
