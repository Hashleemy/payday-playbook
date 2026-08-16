import XCTest
@testable import PaydayPlaybook

/// Required mission test 18: property/invariant coverage over randomized but
/// fully deterministic inputs (seeded SplitMix64 — no flakiness).
final class AvalanchePropertyTests: XCTestCase {

    /// Deterministic PRNG so every run exercises identical inputs.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private func cents(_ range: ClosedRange<Int>, _ rng: inout SplitMix64) -> Decimal {
        Decimal(Int.random(in: range, using: &rng)) / 100
    }

    private func randomInput(iteration: Int, rng: inout SplitMix64) -> PlanningInput {
        let cadences: [PlanningPayCadence] = [
            .weekly, .biweekly,
            .semimonthly(firstDay: 1, secondDay: 15),
            .semimonthly(firstDay: 15, secondDay: 31),
            .monthly(day: [1, 15, 29, 30, 31].randomElement(using: &rng)!)
        ]
        let cadence = cadences.randomElement(using: &rng)!
        let debtCount = Int.random(in: 1...6, using: &rng)
        let types: [DebtType] = [.creditCard, .personalLoan, .autoLoan,
                                 .studentLoan, .medicalDebt, .other]
        let letters = ["A", "B", "C", "D", "E", "F"]
        let debts: [DebtInput] = (0..<debtCount).map { index in
            let type = types.randomElement(using: &rng)!
            let hasMinimum = type != .creditCard || Bool.random(using: &rng)
            let hasPromo = Bool.random(using: &rng) && Bool.random(using: &rng)
            let eligibility: PrepaymentEligibility =
                [.eligible, .eligible, .ineligible, .unknown].randomElement(using: &rng)!
            return DebtInput(
                id: PlanningFixtures.debtID(letters[index]),
                name: letters[index],
                debtType: type,
                balance: cents(10000...1_500_000, &rng),
                apr: Decimal(Int.random(in: 0...3500, using: &rng)) / 10000,
                promo: hasPromo ? PromoAPR(
                    apr: Decimal(Int.random(in: 0...500, using: &rng)) / 10000,
                    expirationDate: TestSupport.date(2026, 10, Int.random(in: 1...28, using: &rng))
                ) : nil,
                minimumPayment: hasMinimum ? cents(2000...40000, &rng) : nil,
                dueDay: Bool.random(using: &rng) ? Int.random(in: 1...31, using: &rng) : nil,
                creditLimit: type == .creditCard && Bool.random(using: &rng)
                    ? cents(0...2_000_000, &rng) : nil,
                prepayment: eligibility,
                createdOrder: index
            )
        }
        let obligationCount = Int.random(in: 0...3, using: &rng)
        let obligations: [ObligationInput] = (0..<obligationCount).map { index in
            ObligationInput(
                id: UUID(uuidString: "00000000-0000-0000-0002-00000000000\(index)")!,
                name: "Obligation \(index)",
                amount: cents(1000...80000, &rng),
                cadence: ObligationCadence.allCases.randomElement(using: &rng)!,
                dueDay: Bool.random(using: &rng) ? Int.random(in: 1...31, using: &rng) : nil
            )
        }
        var windfalls: [Windfall] = []
        if Bool.random(using: &rng) {
            windfalls.append(Windfall(
                date: TestSupport.date(2026, Int.random(in: 9...12, using: &rng), 1),
                amount: cents(5000...200_000, &rng)
            ))
        }
        return PlanningInput(
            asOf: TestSupport.date(2054, 8, 9),
            income: IncomeInput(
                cadence: cadence,
                firstPayday: TestSupport.date(2026, 8, Int.random(in: 10...28, using: &rng)),
                amounts: [
                    PlanningIncomeChange(effectiveDate: TestSupport.date(2054, 8, 1),
                                 amount: cents(60000...350_000, &rng)),
                    PlanningIncomeChange(effectiveDate: TestSupport.date(2055, 1, 1),
                                 amount: cents(60000...350_000, &rng))
                ],
                windfalls: windfalls
            ),
            spending: SpendingInput(
                startingBalance: cents(0...300_000, &rng),
                protectedFloor: cents(0...250_000, &rng),
                allowancePerPaycheck: cents(0...50000, &rng)
            ),
            obligations: obligations,
            debts: debts
        )
    }

    func testInvariantsOverRandomizedInputs() throws {
        var rng = SplitMix64(state: 0xDEB7F4EE)
        for iteration in 0..<25 {
            let input = randomInput(iteration: iteration, rng: &rng)
            let result = try AvalanchePlanEngine.generatePlan(input)
            let label = "iteration \(iteration)"
            let ineligibleIDs = Set(input.debts.filter { $0.prepayment != .eligible }.map(\.id))

            // Determinism: identical input → identical output.
            let again = try AvalanchePlanEngine.generatePlan(input)
            XCTAssertEqual(again, result, "\(label): engine must be deterministic")

            var previousBalances = Dictionary(
                uniqueKeysWithValues: input.debts.map { ($0.id, $0.balance.rounded2) })

            for check in result.paychecks {
                // Cash reconciliation to the cent, every paycheck.
                XCTAssertEqual(check.income + check.windfall,
                               check.keepInSpending + check.transferToReserves,
                               "\(label) check \(check.sequence): deposit split")
                let minimumsGap = check.shortfall?.minimumsGap ?? 0
                XCTAssertEqual(check.debtBudget + minimumsGap,
                               check.minimumsTotal + check.extraTotal + check.unassignedCash,
                               "\(label) check \(check.sequence): budget split")
                let paymentSum = check.payments.reduce(Decimal.zero) { $0 + $1.minimum + $1.extra }
                XCTAssertEqual(paymentSum, check.minimumsTotal + check.extraTotal,
                               "\(label) check \(check.sequence): payments vs totals")

                // Nothing negative, ever.
                XCTAssertGreaterThanOrEqual(check.allowanceReserved, 0, label)
                XCTAssertGreaterThanOrEqual(check.floorTopUp, 0, label)
                XCTAssertGreaterThanOrEqual(check.transferToReserves, 0, label)
                XCTAssertGreaterThanOrEqual(check.debtBudget, 0, label)
                XCTAssertGreaterThanOrEqual(check.unassignedCash, 0, label)
                XCTAssertGreaterThanOrEqual(check.minimumsTotal, 0, label)
                XCTAssertGreaterThanOrEqual(check.extraTotal, 0, label)

                for payment in check.payments {
                    XCTAssertGreaterThanOrEqual(payment.minimum, 0, label)
                    XCTAssertGreaterThanOrEqual(payment.extra, 0, label)
                    // No payment exceeds what the debt could owe: previous
                    // balance plus this period's total interest (loose but
                    // meaningful bound), with a cent of rounding slack.
                    let before = previousBalances[payment.debtID] ?? 0
                    XCTAssertLessThanOrEqual(
                        payment.minimum + payment.extra,
                        before + check.interestAccrued + Decimal(string: "0.02")!,
                        "\(label) check \(check.sequence): payment exceeds balance")
                    // Ineligible/unknown debts never receive extra principal.
                    if ineligibleIDs.contains(payment.debtID) {
                        XCTAssertEqual(payment.extra, 0,
                                       "\(label): ineligible debt received extra")
                    }
                }

                // No debt drops below zero.
                for balance in check.endingBalances {
                    XCTAssertGreaterThanOrEqual(balance.balance, 0,
                                                "\(label) check \(check.sequence): negative balance")
                    previousBalances[balance.debtID] = balance.balance
                }

                // Shortfalls are explicit when present, and the gap breakdown
                // accounts for every dollar with no phantom idle cash.
                if let shortfall = check.shortfall {
                    XCTAssertGreaterThanOrEqual(shortfall.gap, 0, label)
                    XCTAssertGreaterThanOrEqual(shortfall.allowanceReduced, 0, label)
                    XCTAssertGreaterThanOrEqual(shortfall.floorGap, 0, label)
                    XCTAssertGreaterThanOrEqual(shortfall.obligationGap, 0, label)
                    XCTAssertGreaterThanOrEqual(shortfall.minimumsGap, 0, label)
                    XCTAssertEqual(shortfall.floorGap + shortfall.obligationGap + shortfall.minimumsGap,
                                   shortfall.gap,
                                   "\(label) check \(check.sequence): gap breakdown")
                    XCTAssertEqual(check.extraTotal, 0,
                                   "\(label) check \(check.sequence): no extra on a short paycheck")
                    XCTAssertFalse(shortfall.explanation.isEmpty, label)
                }
            }

            // Terminal state is coherent.
            if let payoff = result.forecastPayoffDate {
                XCTAssertEqual(result.paychecks.last?.date, payoff, label)
                XCTAssertEqual(result.paychecks.last?.totalDebtAfter, 0, label)
                XCTAssertFalse(result.notPayableAsConfigured, label)
            } else if input.debts.contains(where: { $0.balance.rounded2 > 0 }) {
                XCTAssertTrue(result.notPayableAsConfigured, label)
            }

            // Event identifiers are unique (stable-identifier contract).
            let identifiers = result.events.map(\.identifier)
            XCTAssertEqual(identifiers.count, Set(identifiers).count,
                           "\(label): duplicate event identifiers")
        }
    }

    // Codable round-trip: the DTOs are the storage/UI contract and must
    // survive encoding without loss.
    func testPlanningResultCodableRoundTrip() throws {
        let result = try AvalanchePlanEngine.generatePlan(PlanningFixtures.baselineInput())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(result)
        let decoded = try decoder.decode(PlanningResult.self, from: data)
        XCTAssertEqual(decoded, result)

        let input = PlanningFixtures.baselineInput()
        let inputData = try encoder.encode(input)
        let decodedInput = try decoder.decode(PlanningInput.self, from: inputData)
        XCTAssertEqual(decodedInput, input)
    }
}
