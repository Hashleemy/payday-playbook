import Foundation

/// Canonical values of Original Plan v1 as specified in soul.md / MVP_LAYOUT.md.
/// The bundled OriginalPlanV1.json seed resource is validated against these
/// constants before insertion, and unit tests assert both stay in agreement.
enum PlanContract {
    static let planName = "Original Plan v1"
    static let schemaVersion = 1
    static let calculationVersion = 1

    static let startingDebtTotal = Decimal(string: "29681.61")!
    static let startingChecking1 = Decimal(string: "900.00")!
    static let protectedBuffer = Decimal(string: "1000.00")!
    static let allowanceCap = Decimal(string: "300.00")!
    static let firstCheckBufferAdd = Decimal(string: "100.00")!
    static let carReservePerCheck = Decimal(string: "335.08")!
    static let trainReservePerCheck = Decimal(string: "51.23")!
    static let totalFixedReserve = Decimal(string: "386.31")!
    static let firstIncome = Decimal(string: "2094.00")!
    static let raisedIncome = Decimal(string: "2190.00")!
    static let firstCheckCardBudget = Decimal(string: "1307.69")!
    static let standardCardBudget = Decimal(string: "1407.69")!
    static let raisedCardBudget = Decimal(string: "1503.69")!
    static let baselineModeledInterest = Decimal(string: "3461.16")!
    static let baselineNoSpendCeiling = Decimal(string: "7900.00")!
    static let payFrequencyDays = 14
    static let paydayCount = 23
    static let debtCount = 6
    static let minimumPaymentFloor = Decimal(string: "17.50")!
    static let minimumPaymentRate = Decimal(string: "0.005")!

    static let avalancheOrder = ["B", "D", "A", "F", "C", "E"]

    static var firstPayday: Date { DateMath.localDate(year: 2026, month: 8, day: 20) }
    static var secondPayday: Date { DateMath.localDate(year: 2026, month: 9, day: 3) }
    static var incomeRaiseDate: Date { DateMath.localDate(year: 2026, month: 12, day: 10) }
    static var baselinePayoffDate: Date { DateMath.localDate(year: 2027, month: 6, day: 24) }

    /// Baseline per-card payoff dates.
    static var baselinePayoffDates: [String: Date] {
        [
            "B": DateMath.localDate(year: 2026, month: 8, day: 20),
            "D": DateMath.localDate(year: 2026, month: 10, day: 15),
            "A": DateMath.localDate(year: 2026, month: 11, day: 26),
            "F": DateMath.localDate(year: 2027, month: 1, day: 7),
            "C": DateMath.localDate(year: 2027, month: 5, day: 13),
            "E": DateMath.localDate(year: 2027, month: 6, day: 24)
        ]
    }

    /// (planID, startingBalance, apr) in avalanche priority order.
    static let debtSeeds: [(planID: String, balance: Decimal, apr: Decimal)] = [
        ("B", Decimal(string: "1049.00")!, Decimal(string: "0.2999")!),
        ("D", Decimal(string: "4987.00")!, Decimal(string: "0.2899")!),
        ("A", Decimal(string: "3787.65")!, Decimal(string: "0.2724")!),
        ("F", Decimal(string: "3495.00")!, Decimal(string: "0.2649")!),
        ("C", Decimal(string: "11650.40")!, Decimal(string: "0.2449")!),
        ("E", Decimal(string: "4712.56")!, Decimal(string: "0.2199")!)
    ]
}
