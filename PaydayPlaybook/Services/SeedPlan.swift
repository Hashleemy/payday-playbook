import Foundation

/// Decoded representation of the bundled OriginalPlanV1.json seed resource.
/// Amounts are strings in the JSON and parsed with `Decimal(string:)` so no
/// binary floating-point ever touches a monetary value.
struct SeedPlan: Decodable {
    struct SeedIncomeRule: Decodable {
        let effectiveDate: String
        let amount: String
    }

    struct SeedDebt: Decodable {
        let planID: String
        let priority: Int
        let startingBalance: String
        let apr: String
        let baselinePayoff: String
    }

    struct SeedPayday: Decodable {
        let seq: Int
        let date: String
        let income: String
        let c1Keep: String
        let bufferAdd: String
        let allowance: String
        let c2Transfer: String
        let carReserve: String
        let trainReserve: String
        let cardBudget: String
        let target: String
        let debtAfter: String
        let noSpendCeiling: String
        let perCard: [String: String]
    }

    struct SeedAmountMilestone: Decodable {
        let threshold: String
        let date: String
    }

    let schemaVersion: Int
    let planName: String
    let firstPayday: String
    let payFrequencyDays: Int
    let startingChecking1: String
    let protectedBuffer: String
    let allowanceCap: String
    let firstCheckBufferAdd: String
    let carReservePerCheck: String
    let trainReservePerCheck: String
    let baselinePayoffDate: String
    let baselineModeledInterest: String
    let baselineNoSpendCeiling: String
    let startingDebtTotal: String
    let avalancheOrder: [String]
    let incomeRules: [SeedIncomeRule]
    let debts: [SeedDebt]
    let paydays: [SeedPayday]
    let amountMilestones: [SeedAmountMilestone]
}

enum SeedPlanError: LocalizedError, Equatable {
    case resourceMissing
    case decodingFailed(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing:
            return "OriginalPlanV1.json is missing from the app bundle."
        case .decodingFailed(let detail):
            return "The seeded plan could not be read: \(detail)"
        case .validationFailed(let detail):
            return "The seeded plan failed validation: \(detail)"
        }
    }
}

enum SeedPlanLoader {
    static func decimal(_ raw: String, field: String) throws -> Decimal {
        guard let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else {
            throw SeedPlanError.decodingFailed("\(field) is not a decimal: \(raw)")
        }
        return value
    }

    static func date(_ raw: String, field: String) throws -> Date {
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else {
            throw SeedPlanError.decodingFailed("\(field) is not a date: \(raw)")
        }
        return DateMath.localDate(year: parts[0], month: parts[1], day: parts[2])
    }

    static func load(bundle: Bundle = .main) throws -> SeedPlan {
        guard let url = bundle.url(forResource: "OriginalPlanV1", withExtension: "json") else {
            throw SeedPlanError.resourceMissing
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SeedPlanError.decodingFailed(error.localizedDescription)
        }
        let seed: SeedPlan
        do {
            seed = try JSONDecoder().decode(SeedPlan.self, from: data)
        } catch {
            throw SeedPlanError.decodingFailed(String(describing: error))
        }
        try validate(seed)
        return seed
    }

    /// Validates the bundled resource against the canonical plan contract so
    /// accidental edits to the JSON are caught before anything is inserted.
    static func validate(_ seed: SeedPlan) throws {
        guard seed.schemaVersion == PlanContract.schemaVersion else {
            throw SeedPlanError.validationFailed("Unsupported schema version \(seed.schemaVersion)")
        }
        guard seed.paydays.count == PlanContract.paydayCount else {
            throw SeedPlanError.validationFailed("Expected \(PlanContract.paydayCount) paydays, found \(seed.paydays.count)")
        }
        guard seed.debts.count == PlanContract.debtCount else {
            throw SeedPlanError.validationFailed("Expected \(PlanContract.debtCount) debts, found \(seed.debts.count)")
        }
        guard seed.avalancheOrder == PlanContract.avalancheOrder else {
            throw SeedPlanError.validationFailed("Avalanche order mismatch: \(seed.avalancheOrder)")
        }

        let debtTotal = try seed.debts.reduce(Decimal.zero) { total, debt in
            try total + decimal(debt.startingBalance, field: "debt \(debt.planID)")
        }
        guard debtTotal == PlanContract.startingDebtTotal else {
            throw SeedPlanError.validationFailed("Starting debt total \(debtTotal) != \(PlanContract.startingDebtTotal)")
        }

        guard try date(seed.firstPayday, field: "firstPayday") == PlanContract.firstPayday else {
            throw SeedPlanError.validationFailed("First payday mismatch: \(seed.firstPayday)")
        }
        guard try date(seed.baselinePayoffDate, field: "baselinePayoffDate") == PlanContract.baselinePayoffDate else {
            throw SeedPlanError.validationFailed("Baseline payoff mismatch: \(seed.baselinePayoffDate)")
        }
        guard try decimal(seed.baselineNoSpendCeiling, field: "ceiling") == PlanContract.baselineNoSpendCeiling else {
            throw SeedPlanError.validationFailed("No-spend ceiling mismatch")
        }
        guard try decimal(seed.baselineModeledInterest, field: "interest") == PlanContract.baselineModeledInterest else {
            throw SeedPlanError.validationFailed("Modeled interest mismatch")
        }

        // Paydays must be sequential, 14 days apart, and internally consistent.
        var previousDate: Date?
        for payday in seed.paydays {
            let paydayDate = try date(payday.date, field: "payday \(payday.seq)")
            if let previous = previousDate {
                let gap = DateMath.days(from: previous, to: paydayDate)
                guard gap == seed.payFrequencyDays else {
                    throw SeedPlanError.validationFailed("Payday \(payday.seq) is \(gap) days after the prior payday")
                }
            }
            previousDate = paydayDate

            let income = try decimal(payday.income, field: "income \(payday.seq)")
            let keep = try decimal(payday.c1Keep, field: "c1Keep \(payday.seq)")
            let transfer = try decimal(payday.c2Transfer, field: "c2Transfer \(payday.seq)")
            guard keep + transfer == income else {
                throw SeedPlanError.validationFailed("Payday \(payday.seq): keep + transfer != income")
            }
            guard payday.perCard.count == PlanContract.debtCount else {
                throw SeedPlanError.validationFailed("Payday \(payday.seq): per-card balances incomplete")
            }
        }

        guard let last = seed.paydays.last,
              try date(last.date, field: "last payday") == PlanContract.baselinePayoffDate,
              try decimal(last.debtAfter, field: "last debtAfter") == 0 else {
            throw SeedPlanError.validationFailed("Final payday must land on the baseline payoff date with zero debt")
        }
    }
}
