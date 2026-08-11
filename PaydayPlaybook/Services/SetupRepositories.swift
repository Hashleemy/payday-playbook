import Foundation
import SwiftData

/// Data access for the rows onboarding creates, beside Agent 2's
/// `CashAccountRepository`. Each repository validates through
/// `ModelValidation` before writing, so an invalid row can never persist —
/// screens surface the thrown message inline without losing the user's input.
///
/// Every mutation saves immediately: onboarding is resumable by construction
/// because each step writes real rows as it goes (V2-01), never a draft blob.

// MARK: - Debts (V2-04, V2-05)

struct DebtRepository {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func activeDebts() throws -> [DebtAccount] {
        try context.fetch(FetchDescriptor<DebtAccount>(predicate: #Predicate { !$0.isArchived }))
            .sorted { ($0.priority, $0.createdAt) < ($1.priority, $1.createdAt) }
    }

    /// Next free plan identifier. Onboarding-created debts are "D1", "D2", …;
    /// the migrated/template plan owns the letters "A"–"F", so the two never
    /// collide on a store that later loads the template.
    func nextPlanID() throws -> String {
        let used = Set(try context.fetch(FetchDescriptor<DebtAccount>()).map(\.planID))
        var index = 1
        while used.contains("D\(index)") { index += 1 }
        return "D\(index)"
    }

    @discardableResult
    func create(
        type: DebtType,
        displayName: String,
        currentBalance: Decimal,
        apr: Decimal,
        minimumAmount: Decimal?,
        originalPrincipal: Decimal? = nil,
        creditLimit: Decimal? = nil,
        dueDayOfMonth: Int? = nil,
        prepayment: PrepaymentEligibility = .eligible,
        note: String? = nil,
        creditLimitMarkedUnknown: Bool = false,
        now: Date = Date()
    ) throws -> DebtAccount {
        try ModelValidation.validateDebt(
            type: type, displayName: displayName, currentBalance: currentBalance,
            originalPrincipal: originalPrincipal, apr: apr, minimumAmount: minimumAmount,
            creditLimit: creditLimit, dueDayOfMonth: dueDayOfMonth, lastFour: nil
        )
        let nextPriority = (try context.fetch(FetchDescriptor<DebtAccount>()).map(\.priority).max() ?? 0) + 1
        let debt = DebtAccount(
            planID: try nextPlanID(),
            displayName: displayName,
            startingBalance: currentBalance,
            apr: apr,
            minimumAmount: minimumAmount,
            dueDayOfMonth: dueDayOfMonth,
            priority: nextPriority,
            createdAt: now,
            updatedAt: now,
            debtType: type,
            originalPrincipal: originalPrincipal,
            creditLimit: creditLimit
        )
        debt.prepayment = prepayment
        debt.setupNote = note
        debt.creditLimitMarkedUnknown = creditLimitMarkedUnknown
        // The user just chose this type from the picker.
        debt.debtTypeConfirmedAt = now
        context.insert(debt)
        try context.save()
        return debt
    }

    func update(
        _ debt: DebtAccount,
        type: DebtType,
        displayName: String,
        currentBalance: Decimal,
        apr: Decimal,
        minimumAmount: Decimal?,
        originalPrincipal: Decimal?,
        creditLimit: Decimal?,
        dueDayOfMonth: Int?,
        prepayment: PrepaymentEligibility,
        note: String?,
        creditLimitMarkedUnknown: Bool = false,
        isArchived: Bool? = nil,
        now: Date = Date()
    ) throws {
        try ModelValidation.validateDebt(
            type: type, displayName: displayName, currentBalance: currentBalance,
            originalPrincipal: originalPrincipal, apr: apr, minimumAmount: minimumAmount,
            creditLimit: creditLimit, dueDayOfMonth: dueDayOfMonth, lastFour: debt.lastFour
        )
        debt.debtType = type
        debt.displayName = displayName
        debt.startingBalance = currentBalance
        debt.apr = apr
        debt.minimumAmount = minimumAmount
        debt.originalPrincipal = originalPrincipal
        debt.creditLimit = creditLimit
        debt.dueDayOfMonth = dueDayOfMonth
        debt.prepayment = prepayment
        debt.setupNote = note
        debt.creditLimitMarkedUnknown = creditLimitMarkedUnknown
        debt.debtTypeConfirmedAt = debt.debtTypeConfirmedAt ?? now
        if let isArchived { debt.isArchived = isArchived }
        debt.updatedAt = now
        try context.save()
    }

    /// Removes a debt outright. Onboarding only — once a plan exists the
    /// debt carries history and must be archived instead (§4.8).
    func delete(_ debt: DebtAccount) throws {
        context.delete(debt)
        try context.save()
    }

    func archive(_ debt: DebtAccount, now: Date = Date()) throws {
        debt.isArchived = true
        debt.updatedAt = now
        try context.save()
    }
}

// MARK: - Essential obligations (V2-07)

struct ObligationRepository {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func activeObligations() throws -> [RecurringObligation] {
        try context.fetch(FetchDescriptor<RecurringObligation>(predicate: #Predicate { !$0.isArchived }))
            .sorted { ($0.createdAt, $0.name) < ($1.createdAt, $1.name) }
    }

    @discardableResult
    func create(
        name: String,
        amount: Decimal,
        cadence: ObligationCadence,
        dueDay: Int? = nil,
        accountID: UUID? = nil,
        isEssential: Bool = true,
        now: Date = Date()
    ) throws -> RecurringObligation {
        try ModelValidation.validateObligation(name: name, amount: amount, dueDay: dueDay)
        let obligation = RecurringObligation(
            name: name, amount: amount, cadence: cadence, dueDay: dueDay,
            accountID: accountID, createdAt: now, updatedAt: now
        )
        obligation.isEssential = isEssential
        context.insert(obligation)
        try context.save()
        return obligation
    }

    func update(
        _ obligation: RecurringObligation,
        name: String,
        amount: Decimal,
        cadence: ObligationCadence,
        dueDay: Int?,
        accountID: UUID?,
        isEssential: Bool,
        now: Date = Date()
    ) throws {
        try ModelValidation.validateObligation(name: name, amount: amount, dueDay: dueDay)
        obligation.name = name
        obligation.amount = amount
        obligation.cadence = cadence
        obligation.dueDay = dueDay
        obligation.accountID = accountID
        obligation.isEssential = isEssential
        obligation.updatedAt = now
        try context.save()
    }

    func delete(_ obligation: RecurringObligation) throws {
        context.delete(obligation)
        try context.save()
    }

    func archive(_ obligation: RecurringObligation, now: Date = Date()) throws {
        obligation.isArchived = true
        obligation.updatedAt = now
        try context.save()
    }
}

// MARK: - Income (V2-06)

struct IncomeRepository {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func activeSchedule() throws -> IncomeSchedule? {
        try context.fetch(FetchDescriptor<IncomeSchedule>(predicate: #Predicate { !$0.isArchived })).first
    }

    func changes(for schedule: IncomeSchedule) throws -> [IncomeChange] {
        let scheduleID = schedule.id
        return try context.fetch(
            FetchDescriptor<IncomeChange>(predicate: #Predicate { $0.scheduleID == scheduleID })
        ).sorted { $0.effectiveDate < $1.effectiveDate }
    }

    /// Creates or updates the single live income schedule. Onboarding revisits
    /// this step freely, so saving twice must edit rather than accumulate.
    @discardableResult
    func save(
        cadence: PayCadence,
        anchorPayday: Date,
        takeHome: Decimal,
        monthlyDay: Int?,
        semimonthlyFirstDay: Int?,
        semimonthlySecondDay: Int?,
        destinationAccountID: UUID?,
        now: Date = Date()
    ) throws -> IncomeSchedule {
        try ModelValidation.validateIncomeSchedule(
            cadence: cadence, takeHome: takeHome, monthlyDay: monthlyDay,
            semimonthlyFirstDay: semimonthlyFirstDay,
            semimonthlySecondDay: semimonthlySecondDay
        )
        if cadence == .semimonthly, semimonthlyFirstDay == semimonthlySecondDay {
            throw ModelValidationError.duplicateSemimonthlyDays
        }
        let schedule = try activeSchedule() ?? {
            let fresh = IncomeSchedule(
                cadence: cadence, anchorPayday: anchorPayday,
                baseTakeHome: takeHome, createdAt: now, updatedAt: now
            )
            context.insert(fresh)
            return fresh
        }()
        schedule.cadence = cadence
        schedule.anchorPayday = DateMath.startOfDay(anchorPayday)
        schedule.baseTakeHome = takeHome
        schedule.monthlyDay = cadence == .monthly ? monthlyDay : nil
        schedule.semimonthlyFirstDay = cadence == .semimonthly ? semimonthlyFirstDay : nil
        schedule.semimonthlySecondDay = cadence == .semimonthly ? semimonthlySecondDay : nil
        schedule.destinationAccountID = destinationAccountID
        schedule.updatedAt = now
        try context.save()
        return schedule
    }

    @discardableResult
    func addChange(
        to schedule: IncomeSchedule,
        effectiveDate: Date,
        newTakeHome: Decimal,
        note: String? = nil,
        now: Date = Date()
    ) throws -> IncomeChange {
        guard newTakeHome > 0 else {
            throw ModelValidationError.zeroOrNegativeAmount(field: "The new take-home amount")
        }
        let change = IncomeChange(
            scheduleID: schedule.id,
            effectiveDate: DateMath.startOfDay(effectiveDate),
            newTakeHome: newTakeHome,
            note: note,
            createdAt: now
        )
        context.insert(change)
        try context.save()
        return change
    }

    func delete(_ change: IncomeChange) throws {
        context.delete(change)
        try context.save()
    }
}

// MARK: - Goal profile (V2-02, V2-08, V2-09)

struct GoalProfileRepository {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// The single profile row, created on first access.
    @discardableResult
    func profile(now: Date = Date()) throws -> UserGoalProfile {
        if let existing = try context.fetch(FetchDescriptor<UserGoalProfile>()).first {
            return existing
        }
        let fresh = UserGoalProfile(createdAt: now, updatedAt: now)
        context.insert(fresh)
        try context.save()
        return fresh
    }

    func save(
        goalText: String?,
        targetDebtFreeDate: Date?,
        posture: PayoffPosture,
        protectedFloor: Decimal,
        allowanceCap: Decimal,
        now: Date = Date()
    ) throws {
        guard protectedFloor >= 0 else {
            throw ModelValidationError.negativeAmount(field: "The protected floor")
        }
        guard allowanceCap >= 0 else {
            throw ModelValidationError.negativeAmount(field: "The allowance")
        }
        let row = try profile(now: now)
        let trimmed = goalText?.trimmingCharacters(in: .whitespacesAndNewlines)
        row.goalText = (trimmed?.isEmpty ?? true) ? nil : trimmed
        row.targetDebtFreeDate = targetDebtFreeDate.map(DateMath.startOfDay)
        row.posture = posture
        row.protectedFloor = protectedFloor
        row.allowanceCap = allowanceCap
        row.updatedAt = now
        try context.save()
    }
}
