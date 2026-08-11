import Foundation

// MARK: - Shared planning contract (Agent 2 ↔ Agent 3 boundary)
//
// `PlanInputSnapshot` and `PlanResultSnapshot` are the storage-independent DTOs the
// calc-v2 generator consumes and produces. Foundation only — the calculation
// engine must never import SwiftData or touch a ModelContext. The data layer
// builds `PlanInputSnapshot` from models (`PlanningInputBuilder`), persists a
// `PlanResultSnapshot` as an immutable `PlanVersion` graph (`PlanPersister`), and
// stores the encoded input on `PlanVersion.inputSnapshotData` so every
// generated plan is reproducible.
//
// All money crosses this boundary as `Decimal`, and is JSON-encoded as a
// string (never a binary floating-point number) via the coding helpers below.

// MARK: Money-safe coding helpers

extension KeyedEncodingContainer {
    mutating func encodeMoney(_ value: Decimal, forKey key: Key) throws {
        try encode("\(value)", forKey: key)
    }

    mutating func encodeMoneyIfPresent(_ value: Decimal?, forKey key: Key) throws {
        guard let value else { return }
        try encodeMoney(value, forKey: key)
    }
}

extension KeyedDecodingContainer {
    func money(forKey key: Key) throws -> Decimal {
        let raw = try decode(String.self, forKey: key)
        guard let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self, debugDescription: "Not a decimal: \(raw)"
            )
        }
        return value
    }

    func moneyIfPresent(forKey key: Key) throws -> Decimal? {
        guard contains(key), try decodeNil(forKey: key) == false else { return nil }
        return try money(forKey: key)
    }
}

// MARK: - PlanInputSnapshot

/// A future take-home change, effective on its date (V2-06).
struct PlanningIncomeChange: Equatable {
    var effectiveDate: Date
    var amount: Decimal
}

/// An essential obligation as the generator sees it (V2-07).
struct PlanningObligation: Equatable {
    var id: UUID
    var name: String
    var amount: Decimal
    var cadence: ObligationCadence
    var dueDay: Int?
}

/// A debt as the generator sees it (V2-04/V2-05). Array order is creation
/// order — the final R-08 tie-break. `displayID` is the stable per-plan
/// identifier used in schedules ("A"–"F" for Lem, or a generated key).
struct PlanningDebt: Equatable {
    var id: UUID
    var displayID: String
    var name: String
    var debtType: DebtType
    var currentBalance: Decimal
    var apr: Decimal
    /// User-entered minimum; nil lets credit cards use the R-06 estimator.
    /// Installment types are validated to always carry one.
    var minimumAmount: Decimal?
    var isExtraPrincipalEligible: Bool
    var creditLimit: Decimal?
    var dueDayOfMonth: Int?
    var originalPrincipal: Decimal?
    /// Tri-state prepayment eligibility (V2-05). Nil (older snapshots) falls
    /// back to `isExtraPrincipalEligible`; `.unknown` withholds extra
    /// principal with a confirm-me warning instead of risking a penalty.
    var prepayment: PrepaymentEligibility? = nil

    /// The value the engine allocates on.
    var effectivePrepayment: PrepaymentEligibility {
        prepayment ?? (isExtraPrincipalEligible ? .eligible : .ineligible)
    }
}

/// Everything the calc-v2 generator needs, captured at generation time.
struct PlanInputSnapshot: Equatable {
    var calculationVersion: Int
    var cadence: PayCadence
    /// Day of month for `.monthly`; both days for `.semimonthly` (R-11 clamped).
    var monthlyPayDay: Int?
    var semimonthlyPayDay1: Int?
    var semimonthlyPayDay2: Int?
    /// First payday to generate from.
    var nextPayday: Date
    var baseTakeHome: Decimal
    var incomeChanges: [PlanningIncomeChange]
    /// Spending account state and guardrails (V2-03, V2-08, V2-09).
    var spendingStartingBalance: Decimal
    var protectedFloor: Decimal
    var allowanceCap: Decimal
    /// One-time first-check buffer addition (Lem-equivalence; 0 otherwise).
    var firstCheckBufferAdd: Decimal
    var obligations: [PlanningObligation]
    var debts: [PlanningDebt]
    /// R-01 generation cap (A-05). Hitting it flags the result, never loops.
    var paycheckCap: Int
    var timeZoneID: String
    /// Start-of-day generation date, stored so a regeneration reproduces the
    /// engine call (and its `generatedAsOf` label) exactly. Nil on snapshots
    /// written before this field existed; callers then supply their own.
    var asOf: Date? = nil

    static let defaultPaycheckCap = 600
}

// MARK: - PlanResultSnapshot

/// A per-paycheck obligation reserve line (frozen R-04 output).
struct PlanningObligationReserve: Equatable {
    var obligationID: UUID
    var amount: Decimal
}

/// One generated paycheck of the plan (R-05/R-10 outputs).
struct PlanningPayday: Equatable {
    var sequence: Int
    var date: Date
    var income: Decimal
    var keepInSpending: Decimal
    var transferToReserves: Decimal
    var allowance: Decimal
    var floorTopUp: Decimal
    var obligationReserves: [PlanningObligationReserve]
    var debtBudget: Decimal
    /// displayID of the avalanche target; nil when nothing was attacked.
    var targetDebtID: String?
    /// displayID → planned balance after this check.
    var perDebtBalancesAfter: [String: Decimal]
    var totalDebtAfter: Decimal
    var noSpendCeiling: Decimal
    /// R-09: exact gap when the paycheck can't cover floor + obligations +
    /// minimums. Nil when fully funded.
    var shortfallAmount: Decimal?
}

struct PlanningDebtPayoff: Equatable {
    var debtID: String
    var payoffDate: Date
}

/// The generated plan. Persisting this (with its input) creates an immutable
/// baseline `PlanVersion`; the result itself never mutates.
struct PlanResultSnapshot: Equatable {
    var calculationVersion: Int
    var paydays: [PlanningPayday]
    var payoffDate: Date?
    var totalEstimatedInterest: Decimal
    var paycheckCount: Int
    var debtPayoffs: [PlanningDebtPayoff]
    /// True when the R-01 cap was hit: "not payable as configured".
    var cappedAtPaycheckLimit: Bool
}

// MARK: - Obligation smoothing (R-04)

/// The one smoothing rule shared by generator, migration check, and the live
/// per-paycheck preview in onboarding: `round2(amount × occurrencesPerYear ÷
/// paychecksPerYear)`. Reproduces Lem's $726 → $335.08 and $111 → $51.23.
enum ObligationMath {
    static func perPaycheckReserve(
        amount: Decimal,
        cadence: ObligationCadence,
        paychecksPerYear: Int
    ) -> Decimal {
        guard paychecksPerYear > 0 else { return .zero }
        let annualized = amount * Decimal(cadence.occurrencesPerYear)
        return (annualized / Decimal(paychecksPerYear)).rounded2
    }
}

// MARK: - Codable (money as strings)

extension PlanningIncomeChange: Codable {
    private enum CodingKeys: String, CodingKey { case effectiveDate, amount }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        effectiveDate = try container.decode(Date.self, forKey: .effectiveDate)
        amount = try container.money(forKey: .amount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(effectiveDate, forKey: .effectiveDate)
        try container.encodeMoney(amount, forKey: .amount)
    }
}

extension PlanningObligation: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, amount, cadence, dueDay }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        amount = try container.money(forKey: .amount)
        cadence = try container.decode(ObligationCadence.self, forKey: .cadence)
        dueDay = try container.decodeIfPresent(Int.self, forKey: .dueDay)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeMoney(amount, forKey: .amount)
        try container.encode(cadence, forKey: .cadence)
        try container.encodeIfPresent(dueDay, forKey: .dueDay)
    }
}

extension PlanningDebt: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, displayID, name, debtType, currentBalance, apr, minimumAmount
        case isExtraPrincipalEligible, creditLimit, dueDayOfMonth, originalPrincipal
        case prepayment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayID = try container.decode(String.self, forKey: .displayID)
        name = try container.decode(String.self, forKey: .name)
        debtType = try container.decode(DebtType.self, forKey: .debtType)
        currentBalance = try container.money(forKey: .currentBalance)
        apr = try container.money(forKey: .apr)
        minimumAmount = try container.moneyIfPresent(forKey: .minimumAmount)
        isExtraPrincipalEligible = try container.decode(Bool.self, forKey: .isExtraPrincipalEligible)
        creditLimit = try container.moneyIfPresent(forKey: .creditLimit)
        dueDayOfMonth = try container.decodeIfPresent(Int.self, forKey: .dueDayOfMonth)
        originalPrincipal = try container.moneyIfPresent(forKey: .originalPrincipal)
        prepayment = try container.decodeIfPresent(PrepaymentEligibility.self, forKey: .prepayment)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayID, forKey: .displayID)
        try container.encode(name, forKey: .name)
        try container.encode(debtType, forKey: .debtType)
        try container.encodeMoney(currentBalance, forKey: .currentBalance)
        try container.encodeMoney(apr, forKey: .apr)
        try container.encodeMoneyIfPresent(minimumAmount, forKey: .minimumAmount)
        try container.encode(isExtraPrincipalEligible, forKey: .isExtraPrincipalEligible)
        try container.encodeMoneyIfPresent(creditLimit, forKey: .creditLimit)
        try container.encodeIfPresent(dueDayOfMonth, forKey: .dueDayOfMonth)
        try container.encodeMoneyIfPresent(originalPrincipal, forKey: .originalPrincipal)
        try container.encodeIfPresent(prepayment, forKey: .prepayment)
    }
}

extension PlanInputSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case calculationVersion, cadence, monthlyPayDay, semimonthlyPayDay1, semimonthlyPayDay2
        case nextPayday, baseTakeHome, incomeChanges
        case spendingStartingBalance, protectedFloor, allowanceCap, firstCheckBufferAdd
        case obligations, debts, paycheckCap, timeZoneID, asOf
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        calculationVersion = try container.decode(Int.self, forKey: .calculationVersion)
        cadence = try container.decode(PayCadence.self, forKey: .cadence)
        monthlyPayDay = try container.decodeIfPresent(Int.self, forKey: .monthlyPayDay)
        semimonthlyPayDay1 = try container.decodeIfPresent(Int.self, forKey: .semimonthlyPayDay1)
        semimonthlyPayDay2 = try container.decodeIfPresent(Int.self, forKey: .semimonthlyPayDay2)
        nextPayday = try container.decode(Date.self, forKey: .nextPayday)
        baseTakeHome = try container.money(forKey: .baseTakeHome)
        incomeChanges = try container.decode([PlanningIncomeChange].self, forKey: .incomeChanges)
        spendingStartingBalance = try container.money(forKey: .spendingStartingBalance)
        protectedFloor = try container.money(forKey: .protectedFloor)
        allowanceCap = try container.money(forKey: .allowanceCap)
        firstCheckBufferAdd = try container.money(forKey: .firstCheckBufferAdd)
        obligations = try container.decode([PlanningObligation].self, forKey: .obligations)
        debts = try container.decode([PlanningDebt].self, forKey: .debts)
        paycheckCap = try container.decode(Int.self, forKey: .paycheckCap)
        timeZoneID = try container.decode(String.self, forKey: .timeZoneID)
        asOf = try container.decodeIfPresent(Date.self, forKey: .asOf)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(calculationVersion, forKey: .calculationVersion)
        try container.encode(cadence, forKey: .cadence)
        try container.encodeIfPresent(monthlyPayDay, forKey: .monthlyPayDay)
        try container.encodeIfPresent(semimonthlyPayDay1, forKey: .semimonthlyPayDay1)
        try container.encodeIfPresent(semimonthlyPayDay2, forKey: .semimonthlyPayDay2)
        try container.encode(nextPayday, forKey: .nextPayday)
        try container.encodeMoney(baseTakeHome, forKey: .baseTakeHome)
        try container.encode(incomeChanges, forKey: .incomeChanges)
        try container.encodeMoney(spendingStartingBalance, forKey: .spendingStartingBalance)
        try container.encodeMoney(protectedFloor, forKey: .protectedFloor)
        try container.encodeMoney(allowanceCap, forKey: .allowanceCap)
        try container.encodeMoney(firstCheckBufferAdd, forKey: .firstCheckBufferAdd)
        try container.encode(obligations, forKey: .obligations)
        try container.encode(debts, forKey: .debts)
        try container.encode(paycheckCap, forKey: .paycheckCap)
        try container.encode(timeZoneID, forKey: .timeZoneID)
        try container.encodeIfPresent(asOf, forKey: .asOf)
    }
}

extension PlanningObligationReserve: Codable {
    private enum CodingKeys: String, CodingKey { case obligationID, amount }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        obligationID = try container.decode(UUID.self, forKey: .obligationID)
        amount = try container.money(forKey: .amount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(obligationID, forKey: .obligationID)
        try container.encodeMoney(amount, forKey: .amount)
    }
}

extension PlanningPayday: Codable {
    private enum CodingKeys: String, CodingKey {
        case sequence, date, income, keepInSpending, transferToReserves
        case allowance, floorTopUp, obligationReserves, debtBudget
        case targetDebtID, perDebtBalancesAfter, totalDebtAfter, noSpendCeiling, shortfallAmount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(Int.self, forKey: .sequence)
        date = try container.decode(Date.self, forKey: .date)
        income = try container.money(forKey: .income)
        keepInSpending = try container.money(forKey: .keepInSpending)
        transferToReserves = try container.money(forKey: .transferToReserves)
        allowance = try container.money(forKey: .allowance)
        floorTopUp = try container.money(forKey: .floorTopUp)
        obligationReserves = try container.decode([PlanningObligationReserve].self, forKey: .obligationReserves)
        debtBudget = try container.money(forKey: .debtBudget)
        targetDebtID = try container.decodeIfPresent(String.self, forKey: .targetDebtID)
        let rawBalances = try container.decode([String: String].self, forKey: .perDebtBalancesAfter)
        perDebtBalancesAfter = try rawBalances.mapValues { raw in
            guard let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .perDebtBalancesAfter, in: container,
                    debugDescription: "Not a decimal: \(raw)"
                )
            }
            return value
        }
        totalDebtAfter = try container.money(forKey: .totalDebtAfter)
        noSpendCeiling = try container.money(forKey: .noSpendCeiling)
        shortfallAmount = try container.moneyIfPresent(forKey: .shortfallAmount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(date, forKey: .date)
        try container.encodeMoney(income, forKey: .income)
        try container.encodeMoney(keepInSpending, forKey: .keepInSpending)
        try container.encodeMoney(transferToReserves, forKey: .transferToReserves)
        try container.encodeMoney(allowance, forKey: .allowance)
        try container.encodeMoney(floorTopUp, forKey: .floorTopUp)
        try container.encode(obligationReserves, forKey: .obligationReserves)
        try container.encodeMoney(debtBudget, forKey: .debtBudget)
        try container.encodeIfPresent(targetDebtID, forKey: .targetDebtID)
        try container.encode(perDebtBalancesAfter.mapValues { "\($0)" }, forKey: .perDebtBalancesAfter)
        try container.encodeMoney(totalDebtAfter, forKey: .totalDebtAfter)
        try container.encodeMoney(noSpendCeiling, forKey: .noSpendCeiling)
        try container.encodeMoneyIfPresent(shortfallAmount, forKey: .shortfallAmount)
    }
}

extension PlanningDebtPayoff: Codable {
    private enum CodingKeys: String, CodingKey { case debtID, payoffDate }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        debtID = try container.decode(String.self, forKey: .debtID)
        payoffDate = try container.decode(Date.self, forKey: .payoffDate)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(debtID, forKey: .debtID)
        try container.encode(payoffDate, forKey: .payoffDate)
    }
}

extension PlanResultSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case calculationVersion, paydays, payoffDate, totalEstimatedInterest
        case paycheckCount, debtPayoffs, cappedAtPaycheckLimit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        calculationVersion = try container.decode(Int.self, forKey: .calculationVersion)
        paydays = try container.decode([PlanningPayday].self, forKey: .paydays)
        payoffDate = try container.decodeIfPresent(Date.self, forKey: .payoffDate)
        totalEstimatedInterest = try container.money(forKey: .totalEstimatedInterest)
        paycheckCount = try container.decode(Int.self, forKey: .paycheckCount)
        debtPayoffs = try container.decode([PlanningDebtPayoff].self, forKey: .debtPayoffs)
        cappedAtPaycheckLimit = try container.decode(Bool.self, forKey: .cappedAtPaycheckLimit)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(calculationVersion, forKey: .calculationVersion)
        try container.encode(paydays, forKey: .paydays)
        try container.encodeIfPresent(payoffDate, forKey: .payoffDate)
        try container.encodeMoney(totalEstimatedInterest, forKey: .totalEstimatedInterest)
        try container.encode(paycheckCount, forKey: .paycheckCount)
        try container.encode(debtPayoffs, forKey: .debtPayoffs)
        try container.encode(cappedAtPaycheckLimit, forKey: .cappedAtPaycheckLimit)
    }
}

// MARK: - Stable snapshot coding

/// Canonical encoder/decoder for `PlanVersion.inputSnapshotData` — sorted
/// keys and ISO-8601 dates so identical inputs produce identical bytes.
enum PlanningSnapshotCoder {
    static func encode(_ input: PlanInputSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(input)
    }

    static func decode(_ data: Data) throws -> PlanInputSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PlanInputSnapshot.self, from: data)
    }
}
