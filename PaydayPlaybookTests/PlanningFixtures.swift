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
    static let trainObligationID = UUID(uuidString: "00000000-0000-0000-0001-000000000002")!

    /// Lem-equivalent onboarding inputs: the calc-v2 engine must reproduce
    /// the documented Original Plan v1 baseline from these raw values.
    /// The $100 first-check buffer is not an input — it falls out of the
    /// floor top-up ($900 starting balance → $1,000 protected floor).
    static func lemInput() -> PlanningInput {
        let seeds: [(String, String, String, Int)] = [
            ("B", "1049.00", "0.2999", 1),
            ("D", "4987.00", "0.2899", 2),
            ("A", "3787.65", "0.2724", 3),
            ("F", "3495.00", "0.2649", 4),
            ("C", "11650.40", "0.2449", 5),
            ("E", "4712.56", "0.2199", 6)
        ]
        return PlanningInput(
            asOf: TestSupport.date(2026, 8, 9),
            income: IncomeInput(
                cadence: .biweekly,
                firstPayday: TestSupport.date(2026, 8, 20),
                amounts: [
                    IncomeStep(effectiveDate: TestSupport.date(2026, 8, 20),
                                 amount: TestSupport.money("2094.00")),
                    IncomeStep(effectiveDate: TestSupport.date(2026, 12, 10),
                                 amount: TestSupport.money("2190.00"))
                ]
            ),
            spending: SpendingInput(
                startingBalance: TestSupport.money("900.00"),
                protectedFloor: TestSupport.money("1000.00"),
                allowancePerPaycheck: TestSupport.money("300.00")
            ),
            obligations: [
                ObligationInput(id: carObligationID, name: "Car",
                                amount: TestSupport.money("726.00"), cadence: .monthly, dueDay: nil),
                ObligationInput(id: trainObligationID, name: "Train pass",
                                amount: TestSupport.money("111.00"), cadence: .monthly, dueDay: nil)
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
        firstPayday: Date = TestSupport.date(2026, 8, 20)
    ) -> PlanningInput {
        PlanningInput(
            asOf: TestSupport.date(2026, 8, 9),
            income: IncomeInput(
                cadence: cadence,
                firstPayday: firstPayday,
                amounts: [IncomeStep(effectiveDate: firstPayday, amount: TestSupport.money(income))],
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
