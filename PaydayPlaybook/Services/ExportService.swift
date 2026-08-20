import Foundation
import SwiftData

/// Versioned JSON backup/restore and CSV exports. Every export and import is
/// user-initiated; nothing leaves the device otherwise.
struct ExportService {
    /// Writes version 4; imports 1, 2, 3, and 4. Importing an older file runs
    /// the same logical migrations as an app upgrade (MVP_LAYOUT §2/§7, V2-18).
    ///
    /// Version 3 was the first to be wrapped in a `PortableDocument` envelope
    /// (V3-09). Versions 1 and 2 are bare `Backup` objects with no envelope,
    /// which is how a reader tells them apart without guessing.
    ///
    /// Version 4 is a *semantic* bump (V4-03, VERSIONING.md §5): the envelope
    /// shape and the store schema are unchanged, but a 0.4.0 backup can carry
    /// plans stamped calculation version 4, which an older reader cannot
    /// faithfully re-dispatch — so it must refuse the document by name rather
    /// than guess. The persistence schema stays 3; restore keys its migration
    /// steps on that axis, not on this one.
    static let backupSchemaVersion = 4
    static let importableSchemaVersions = 1...4

    // MARK: - Backup document

    struct Backup: Codable {
        struct PlanVersionDTO: Codable {
            var id: UUID, name: String, createdAt: Date
            var isOriginalBaseline: Bool, isActive: Bool
            var firstPayday: Date, payFrequencyDays: Int
            var startingChecking1: String, protectedBuffer: String, allowanceCap: String
            var firstCheckBufferAdd: String, carReservePerCheck: String, trainReservePerCheck: String
            var calculationVersion: Int, timeZoneID: String, avalancheOrderRaw: String
            var baselinePayoffDate: Date, baselineModeledInterest: String, baselineNoSpendCeiling: String
            // Schema 2 (optional so version-1 files still decode).
            var payCadenceRaw: String?
            var monthlyPayDay: Int?, semimonthlyPayDay1: Int?, semimonthlyPayDay2: Int?
            var incomeAccountID: UUID?, generatedFromProfile: Bool?, inputSnapshotData: Data?
            // Schema 3 (V3-15). `inputSnapshotData` needs no new key: the
            // extended `StoredPlanInput` encodes its scenario and extras
            // inside the same blob, and v2 snapshots still decode.
            var scenarioKindRaw: String?, effectiveDate: Date?
        }
        struct IncomeRuleDTO: Codable {
            var id: UUID, planVersionID: UUID, effectiveDate: Date, netPaycheckAmount: String
        }
        struct DebtDTO: Codable {
            var id: UUID, planID: String, displayName: String, lastFour: String?
            var startingBalance: String, apr: String, minimumAmount: String?
            var dueDayOfMonth: Int?, priority: Int, isArchived: Bool
            var createdAt: Date, updatedAt: Date
            // Schema 2 (optional so version-1 files still decode).
            var debtTypeRaw: String?, originalPrincipal: String?
            var creditLimit: String?, isExtraPrincipalEligible: Bool?
            var prepaymentRaw: String?, setupNote: String?
            var debtTypeConfirmedAt: Date?, creditLimitMarkedUnknown: Bool?
        }
        struct PaydayPlanItemDTO: Codable {
            var id: UUID, planVersionID: UUID, sequenceNumber: Int, date: Date
            var plannedIncome: String, plannedC1Keep: String, plannedBufferAdd: String
            var plannedAllowance: String, plannedC2Transfer: String
            var plannedCarReserve: String, plannedTrainReserve: String, plannedCardBudget: String
            var plannedTargetDebtID: String, plannedDebtAfter: String, plannedC1NoSpendCeiling: String
            // Schema 2 (optional so version-1 files still decode).
            var shortfallAmount: String?
        }
        struct PlannedCardBalanceDTO: Codable {
            var id: UUID, paydayPlanItemID: UUID, debtPlanID: String, balanceAfter: String
        }
        struct CheckInDTO: Codable {
            var id: UUID, paydayPlanItemID: UUID, statusRaw: String
            var actualIncome: String?, outsideFundsUsed: String?
            var actualC1Kept: String?, actualC1Balance: String?, actualAllowanceSpent: String?
            var actualC2Transfer: String?, actualCarReserve: String?, actualTrainReserve: String?
            var unallocatedAmount: String?, note: String?, reconciliationException: String?
            var currentStep: Int, completedAt: Date?, createdAt: Date, updatedAt: Date
        }
        struct CheckInCardPaymentDTO: Codable {
            var id: UUID, checkInID: UUID, debtPlanID: String, amount: String
            var reportedBalanceAfter: String?
        }
        struct LedgerEntryDTO: Codable {
            var id: UUID, effectiveDate: Date, createdAt: Date, updatedAt: Date
            var typeRaw: String, amount: String
            var sourceAccountRaw: String?, destinationAccountRaw: String?
            var debtAccountID: UUID?, debtPlanID: String?, paydayCheckInID: UUID?
            var note: String?, isCorrection: Bool, correctsEntryID: UUID?, auditNote: String?
            // Schema 2 (optional so version-1 files still decode).
            var sourceAccountID: UUID?, destinationAccountID: UUID?
            // Schema 3 (V3-02/V3-03). Nil is meaningful — "written before
            // provenance existed" — so it is never backfilled on import.
            var provenanceRaw: String?
        }
        struct SnapshotDTO: Codable {
            var id: UUID, debtAccountID: UUID?, debtPlanID: String?, cashAccountRaw: String?
            var effectiveDate: Date, amount: String, sourceTypeRaw: String
            var note: String?, isAuthoritative: Bool, createdAt: Date
            var correctsSnapshotID: UUID?, auditNote: String?
            // Schema 2 (optional so version-1 files still decode).
            var cashAccountID: UUID?
        }
        struct ForecastDTO: Codable {
            var id: UUID, calculatedAt: Date, sourcePlanVersionID: UUID, triggerTypeRaw: String
            var projectedPayoffDate: Date?, remainingPaychecks: Int
            var estimatedRemainingInterest: String, perCardPayoffData: Data, summaryExplanation: String
        }
        struct NotificationPreferenceDTO: Codable {
            var id: UUID, typeRaw: String, enabled: Bool, hour: Int, minute: Int
            var leadDays: Int, detailedLockScreenContent: Bool
        }
        struct MilestoneDTO: Codable {
            var id: UUID, typeRaw: String, title: String, thresholdAmount: String?
            var relatedDebtPlanID: String?, baselineDate: Date?, forecastDate: Date?, achievedDate: Date?
        }
        struct AppSettingsDTO: Codable {
            var id: UUID, onboardingComplete: Bool, appLockEnabled: Bool
            var debtFreeCelebrationShownAt: Date?, debtFreeConfirmedAt: Date?
            var phaseTwoGoalRaw: String?, phaseTwoTargetAmount: String?, phaseTwoNote: String?
            var seedSchemaVersion: Int, createdAt: Date
            // Schema 2 (optional so version-1 files still decode).
            var migratedAt: Date?, migrationAuditNote: String?
        }
        struct CashAccountDTO: Codable {
            var id: UUID, name: String, currentBalance: String, rolesRaw: String
            var isDefaultIncome: Bool, sortOrder: Int, isArchived: Bool
            var legacyKindRaw: String?, createdAt: Date, updatedAt: Date
            // Schema 3 (V3-02).
            var protectedAmount: String?, balanceAsOf: Date?
        }
        struct ObligationDTO: Codable {
            var id: UUID, name: String, amount: String, cadenceRaw: String
            var dueDay: Int?, accountID: UUID?, isArchived: Bool
            var legacyKey: String?, createdAt: Date, updatedAt: Date
            var isEssential: Bool?
        }
        struct UserGoalProfileDTO: Codable {
            var id: UUID, goalText: String?, targetDebtFreeDate: Date?, postureRaw: String
            var protectedFloor: String, allowanceCap: String
            var onboardingCompletedAt: Date?, createdAt: Date, updatedAt: Date
            // Schema 3 scenario constraints (V3-05/V3-06). Optional so v1/v2
            // files decode; each defaults to zero, which the scenario layer
            // reads as "the user has not stated this yet".
            var minimumProtectedCash: String?, plannedSavingsPerPaycheck: String?
            var additionalCushionReserve: String?, extraPaymentCeiling: String?
            var zeroAllowanceConfirmedAt: Date?
        }
        struct OnboardingProgressDTO: Codable {
            var id: UUID, lastCompletedStepRaw: String
            var startedAt: Date, updatedAt: Date, completedAt: Date?
        }
        struct IncomeScheduleDTO: Codable {
            var id: UUID, cadenceRaw: String, anchorPayday: Date
            var monthlyDay: Int?, semimonthlyFirstDay: Int?, semimonthlySecondDay: Int?
            var destinationAccountID: UUID?, baseTakeHome: String, isArchived: Bool
            var createdAt: Date, updatedAt: Date
        }
        struct IncomeChangeDTO: Codable {
            var id: UUID, scheduleID: UUID, effectiveDate: Date
            var newTakeHome: String, note: String?, createdAt: Date
        }
        struct PlannedObligationReserveDTO: Codable {
            var id: UUID, paydayPlanItemID: UUID, obligationID: UUID, amount: String
        }

        var schemaVersion: Int
        var exportedAt: Date
        var appVersion: String
        var planVersions: [PlanVersionDTO]
        var incomeRules: [IncomeRuleDTO]
        var debts: [DebtDTO]
        var paydayPlanItems: [PaydayPlanItemDTO]
        var plannedCardBalances: [PlannedCardBalanceDTO]
        var checkIns: [CheckInDTO]
        var checkInCardPayments: [CheckInCardPaymentDTO]
        var ledgerEntries: [LedgerEntryDTO]
        var balanceSnapshots: [SnapshotDTO]
        var forecastSnapshots: [ForecastDTO]
        var notificationPreferences: [NotificationPreferenceDTO]
        var milestones: [MilestoneDTO]
        var appSettings: [AppSettingsDTO]
        // Schema 2 collections (optional so version-1 files still decode).
        var cashAccounts: [CashAccountDTO]?
        var obligations: [ObligationDTO]?
        var userGoalProfiles: [UserGoalProfileDTO]?
        var onboardingProgress: [OnboardingProgressDTO]?
        var incomeSchedules: [IncomeScheduleDTO]?
        var incomeChanges: [IncomeChangeDTO]?
        var plannedObligationReserves: [PlannedObligationReserveDTO]?
    }

    enum ExportError: LocalizedError, Equatable {
        case unsupportedSchema(Int)
        /// An amount in this collection could not be parsed. It names the
        /// collection and never the value: error text reaches screenshots and
        /// bug reports, and the old `decimalParse(raw)` case echoed a balance
        /// straight into one (V3-13).
        case amountUnreadable(collection: String)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version):
                return "This backup uses schema version \(version), which this app version cannot restore."
            case .amountUnreadable(let collection):
                return "An amount in this backup's \(collection) section isn't a readable number."
            case .encodingFailed:
                return "The backup could not be written."
            }
        }
    }

    private static func money(_ value: Decimal) -> String { "\(value)" }
    private static func money(_ value: Decimal?) -> String? { value.map { "\($0)" } }

    /// Parses a stored money string.
    ///
    /// This is the backstop, not the diagnostic: `BackupValidator` walks every
    /// collection's money fields before restore begins and reports the exact
    /// collection and field. By the time row construction runs, an unreadable
    /// amount has already been rejected — so this case only fires for a caller
    /// that skipped validation, and says so generically rather than echoing
    /// the value.
    static func decimalOrThrow(_ raw: String) throws -> Decimal {
        guard let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else {
            throw ExportError.amountUnreadable(collection: "records")
        }
        return value
    }

    private static func decimal(_ raw: String) throws -> Decimal {
        try decimalOrThrow(raw)
    }

    private static func decimal(_ raw: String?) throws -> Decimal? {
        guard let raw else { return nil }
        return try decimal(raw)
    }

    /// Whether a stored money string is parseable, for the validation pass.
    static func isReadableAmount(_ raw: String?) -> Bool {
        guard let raw else { return true }
        return Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) != nil
    }

    /// Whether a stored money string names an amount greater than zero. Nil
    /// and zero are both "not stated" — the template layer treats them the
    /// same, because neither is a number a user gave.
    static func isPositiveAmount(_ raw: String?) -> Bool {
        guard let raw, let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else {
            return false
        }
        return value > 0
    }

    // MARK: - Export

    /// Fetches a collection in a stable order.
    ///
    /// `FetchDescriptor` with no sort returns rows in whatever order the store
    /// happens to hold them, which differs between a store the user built up
    /// and the same data after a restore. Exporting unordered arrays made two
    /// exports of identical data differ, so a user diffing yesterday's backup
    /// against today's saw churn that meant nothing. Sorting by `id` costs
    /// nothing and makes an export a function of its data.
    private static func ordered<T: PersistentModel>(
        _ type: T.Type,
        _ context: ModelContext,
        by id: KeyPath<T, UUID>
    ) throws -> [T] {
        try context.fetch(FetchDescriptor<T>())
            .sorted { $0[keyPath: id].uuidString < $1[keyPath: id].uuidString }
    }

    static func buildBackup(context: ModelContext) throws -> Backup {
        let plans = try ordered(PlanVersion.self, context, by: \.id)
        let rules = try ordered(IncomeRule.self, context, by: \.id)
        let debts = try ordered(DebtAccount.self, context, by: \.id)
        let items = try ordered(PaydayPlanItem.self, context, by: \.id)
        let planned = try ordered(PlannedCardBalance.self, context, by: \.id)
        let checkIns = try ordered(PaydayCheckIn.self, context, by: \.id)
        let payments = try ordered(CheckInCardPayment.self, context, by: \.id)
        let entries = try ordered(LedgerEntry.self, context, by: \.id)
        let snapshots = try ordered(BalanceSnapshot.self, context, by: \.id)
        let forecasts = try ordered(ForecastSnapshot.self, context, by: \.id)
        let preferences = try ordered(NotificationPreference.self, context, by: \.id)
        let milestones = try ordered(Milestone.self, context, by: \.id)
        let settings = try ordered(AppSettings.self, context, by: \.id)
        let cashAccounts = try ordered(CashAccount.self, context, by: \.id)
        let obligations = try ordered(RecurringObligation.self, context, by: \.id)
        let profiles = try ordered(UserGoalProfile.self, context, by: \.id)
        let onboarding = try ordered(OnboardingProgress.self, context, by: \.id)
        let incomeSchedules = try ordered(IncomeSchedule.self, context, by: \.id)
        let incomeChanges = try ordered(IncomeChange.self, context, by: \.id)
        let obligationReserves = try ordered(PlannedObligationReserve.self, context, by: \.id)

        return Backup(
            schemaVersion: backupSchemaVersion,
            exportedAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            planVersions: plans.map {
                .init(
                    id: $0.id, name: $0.name, createdAt: $0.createdAt,
                    isOriginalBaseline: $0.isOriginalBaseline, isActive: $0.isActive,
                    firstPayday: $0.firstPayday, payFrequencyDays: $0.payFrequencyDays,
                    startingChecking1: money($0.startingChecking1),
                    protectedBuffer: money($0.protectedBuffer),
                    allowanceCap: money($0.allowanceCap),
                    firstCheckBufferAdd: money($0.firstCheckBufferAdd),
                    carReservePerCheck: money($0.carReservePerCheck),
                    trainReservePerCheck: money($0.trainReservePerCheck),
                    calculationVersion: $0.calculationVersion, timeZoneID: $0.timeZoneID,
                    avalancheOrderRaw: $0.avalancheOrderRaw,
                    baselinePayoffDate: $0.baselinePayoffDate,
                    baselineModeledInterest: money($0.baselineModeledInterest),
                    baselineNoSpendCeiling: money($0.baselineNoSpendCeiling),
                    payCadenceRaw: $0.payCadenceRaw,
                    monthlyPayDay: $0.monthlyPayDay,
                    semimonthlyPayDay1: $0.semimonthlyPayDay1,
                    semimonthlyPayDay2: $0.semimonthlyPayDay2,
                    incomeAccountID: $0.incomeAccountID,
                    generatedFromProfile: $0.generatedFromProfile,
                    inputSnapshotData: $0.inputSnapshotData,
                    scenarioKindRaw: $0.scenarioKindRaw,
                    effectiveDate: $0.effectiveDate
                )
            },
            incomeRules: rules.map {
                .init(id: $0.id, planVersionID: $0.planVersionID, effectiveDate: $0.effectiveDate,
                      netPaycheckAmount: money($0.netPaycheckAmount))
            },
            debts: debts.map {
                .init(id: $0.id, planID: $0.planID, displayName: $0.displayName, lastFour: $0.lastFour,
                      startingBalance: money($0.startingBalance), apr: money($0.apr),
                      minimumAmount: money($0.minimumAmount), dueDayOfMonth: $0.dueDayOfMonth,
                      priority: $0.priority, isArchived: $0.isArchived,
                      createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                      debtTypeRaw: $0.debtTypeRaw, originalPrincipal: money($0.originalPrincipal),
                      creditLimit: money($0.creditLimit),
                      isExtraPrincipalEligible: $0.isExtraPrincipalEligible,
                      prepaymentRaw: $0.prepaymentRaw, setupNote: $0.setupNote,
                      debtTypeConfirmedAt: $0.debtTypeConfirmedAt,
                      creditLimitMarkedUnknown: $0.creditLimitMarkedUnknown)
            },
            paydayPlanItems: items.map {
                .init(id: $0.id, planVersionID: $0.planVersionID, sequenceNumber: $0.sequenceNumber,
                      date: $0.date, plannedIncome: money($0.plannedIncome),
                      plannedC1Keep: money($0.plannedC1Keep), plannedBufferAdd: money($0.plannedBufferAdd),
                      plannedAllowance: money($0.plannedAllowance), plannedC2Transfer: money($0.plannedC2Transfer),
                      plannedCarReserve: money($0.plannedCarReserve), plannedTrainReserve: money($0.plannedTrainReserve),
                      plannedCardBudget: money($0.plannedCardBudget), plannedTargetDebtID: $0.plannedTargetDebtID,
                      plannedDebtAfter: money($0.plannedDebtAfter), plannedC1NoSpendCeiling: money($0.plannedC1NoSpendCeiling),
                      shortfallAmount: money($0.shortfallAmount))
            },
            plannedCardBalances: planned.map {
                .init(id: $0.id, paydayPlanItemID: $0.paydayPlanItemID, debtPlanID: $0.debtPlanID,
                      balanceAfter: money($0.balanceAfter))
            },
            checkIns: checkIns.map {
                .init(id: $0.id, paydayPlanItemID: $0.paydayPlanItemID, statusRaw: $0.statusRaw,
                      actualIncome: money($0.actualIncome), outsideFundsUsed: money($0.outsideFundsUsed),
                      actualC1Kept: money($0.actualC1Kept), actualC1Balance: money($0.actualC1Balance),
                      actualAllowanceSpent: money($0.actualAllowanceSpent), actualC2Transfer: money($0.actualC2Transfer),
                      actualCarReserve: money($0.actualCarReserve), actualTrainReserve: money($0.actualTrainReserve),
                      unallocatedAmount: money($0.unallocatedAmount), note: $0.note,
                      reconciliationException: $0.reconciliationException, currentStep: $0.currentStep,
                      completedAt: $0.completedAt, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
            },
            checkInCardPayments: payments.map {
                .init(id: $0.id, checkInID: $0.checkInID, debtPlanID: $0.debtPlanID,
                      amount: money($0.amount), reportedBalanceAfter: money($0.reportedBalanceAfter))
            },
            ledgerEntries: entries.map {
                .init(id: $0.id, effectiveDate: $0.effectiveDate, createdAt: $0.createdAt,
                      updatedAt: $0.updatedAt, typeRaw: $0.typeRaw, amount: money($0.amount),
                      sourceAccountRaw: $0.sourceAccountRaw, destinationAccountRaw: $0.destinationAccountRaw,
                      debtAccountID: $0.debtAccountID, debtPlanID: $0.debtPlanID,
                      paydayCheckInID: $0.paydayCheckInID, note: $0.note,
                      isCorrection: $0.isCorrection, correctsEntryID: $0.correctsEntryID, auditNote: $0.auditNote,
                      sourceAccountID: $0.sourceAccountID, destinationAccountID: $0.destinationAccountID,
                      provenanceRaw: $0.provenanceRaw)
            },
            balanceSnapshots: snapshots.map {
                .init(id: $0.id, debtAccountID: $0.debtAccountID, debtPlanID: $0.debtPlanID,
                      cashAccountRaw: $0.cashAccountRaw, effectiveDate: $0.effectiveDate,
                      amount: money($0.amount), sourceTypeRaw: $0.sourceTypeRaw, note: $0.note,
                      isAuthoritative: $0.isAuthoritative, createdAt: $0.createdAt,
                      correctsSnapshotID: $0.correctsSnapshotID, auditNote: $0.auditNote,
                      cashAccountID: $0.cashAccountID)
            },
            forecastSnapshots: forecasts.map {
                .init(id: $0.id, calculatedAt: $0.calculatedAt, sourcePlanVersionID: $0.sourcePlanVersionID,
                      triggerTypeRaw: $0.triggerTypeRaw, projectedPayoffDate: $0.projectedPayoffDate,
                      remainingPaychecks: $0.remainingPaychecks,
                      estimatedRemainingInterest: money($0.estimatedRemainingInterest),
                      perCardPayoffData: $0.perCardPayoffData, summaryExplanation: $0.summaryExplanation)
            },
            notificationPreferences: preferences.map {
                .init(id: $0.id, typeRaw: $0.typeRaw, enabled: $0.enabled, hour: $0.hour,
                      minute: $0.minute, leadDays: $0.leadDays,
                      detailedLockScreenContent: $0.detailedLockScreenContent)
            },
            milestones: milestones.map {
                .init(id: $0.id, typeRaw: $0.typeRaw, title: $0.title,
                      thresholdAmount: money($0.thresholdAmount), relatedDebtPlanID: $0.relatedDebtPlanID,
                      baselineDate: $0.baselineDate, forecastDate: $0.forecastDate, achievedDate: $0.achievedDate)
            },
            appSettings: settings.map {
                .init(id: $0.id, onboardingComplete: $0.onboardingComplete, appLockEnabled: $0.appLockEnabled,
                      debtFreeCelebrationShownAt: $0.debtFreeCelebrationShownAt,
                      debtFreeConfirmedAt: $0.debtFreeConfirmedAt, phaseTwoGoalRaw: $0.phaseTwoGoalRaw,
                      phaseTwoTargetAmount: money($0.phaseTwoTargetAmount), phaseTwoNote: $0.phaseTwoNote,
                      seedSchemaVersion: $0.seedSchemaVersion, createdAt: $0.createdAt,
                      migratedAt: $0.migratedAt, migrationAuditNote: $0.migrationAuditNote)
            },
            cashAccounts: cashAccounts.map {
                .init(id: $0.id, name: $0.name, currentBalance: money($0.currentBalance),
                      rolesRaw: $0.rolesRaw, isDefaultIncome: $0.isDefaultIncome,
                      sortOrder: $0.sortOrder, isArchived: $0.isArchived,
                      legacyKindRaw: $0.legacyKindRaw, createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                      protectedAmount: money($0.protectedAmount), balanceAsOf: $0.balanceAsOf)
            },
            obligations: obligations.map {
                .init(id: $0.id, name: $0.name, amount: money($0.amount), cadenceRaw: $0.cadenceRaw,
                      dueDay: $0.dueDay, accountID: $0.accountID, isArchived: $0.isArchived,
                      legacyKey: $0.legacyKey, createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                      isEssential: $0.isEssential)
            },
            userGoalProfiles: profiles.map {
                .init(id: $0.id, goalText: $0.goalText, targetDebtFreeDate: $0.targetDebtFreeDate,
                      postureRaw: $0.postureRaw, protectedFloor: money($0.protectedFloor),
                      allowanceCap: money($0.allowanceCap),
                      onboardingCompletedAt: $0.onboardingCompletedAt,
                      createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                      minimumProtectedCash: money($0.minimumProtectedCash),
                      plannedSavingsPerPaycheck: money($0.plannedSavingsPerPaycheck),
                      additionalCushionReserve: money($0.additionalCushionReserve),
                      extraPaymentCeiling: money($0.extraPaymentCeiling),
                      zeroAllowanceConfirmedAt: $0.zeroAllowanceConfirmedAt)
            },
            onboardingProgress: onboarding.map {
                .init(id: $0.id, lastCompletedStepRaw: $0.lastCompletedStepRaw,
                      startedAt: $0.startedAt, updatedAt: $0.updatedAt, completedAt: $0.completedAt)
            },
            incomeSchedules: incomeSchedules.map {
                .init(id: $0.id, cadenceRaw: $0.cadenceRaw, anchorPayday: $0.anchorPayday,
                      monthlyDay: $0.monthlyDay, semimonthlyFirstDay: $0.semimonthlyFirstDay,
                      semimonthlySecondDay: $0.semimonthlySecondDay,
                      destinationAccountID: $0.destinationAccountID,
                      baseTakeHome: money($0.baseTakeHome), isArchived: $0.isArchived,
                      createdAt: $0.createdAt, updatedAt: $0.updatedAt)
            },
            incomeChanges: incomeChanges.map {
                .init(id: $0.id, scheduleID: $0.scheduleID, effectiveDate: $0.effectiveDate,
                      newTakeHome: money($0.newTakeHome), note: $0.note, createdAt: $0.createdAt)
            },
            plannedObligationReserves: obligationReserves.map {
                .init(id: $0.id, paydayPlanItemID: $0.paydayPlanItemID,
                      obligationID: $0.obligationID, amount: money($0.amount))
            }
        )
    }

    /// Wraps a payload in the schema-3 envelope (V3-09).
    static func document(for backup: Backup) -> PortableDocument<Backup> {
        PortableDocument(
            documentKind: .fullBackup,
            schemaVersion: backup.schemaVersion,
            appVersion: backup.appVersion,
            calculationVersion: PlanContract.currentCalculationVersion,
            exportedAt: backup.exportedAt,
            integrity: integrity(of: backup),
            payload: backup
        )
    }

    /// Row counts per collection, re-derived on import to detect truncation.
    /// Structural only — how many rows, never what is in them.
    static func integrity(of backup: Backup) -> PortableIntegrity {
        PortableIntegrity(recordCounts: [
            "planVersions": backup.planVersions.count,
            "incomeRules": backup.incomeRules.count,
            "debts": backup.debts.count,
            "paydayPlanItems": backup.paydayPlanItems.count,
            "plannedCardBalances": backup.plannedCardBalances.count,
            "checkIns": backup.checkIns.count,
            "checkInCardPayments": backup.checkInCardPayments.count,
            "ledgerEntries": backup.ledgerEntries.count,
            "balanceSnapshots": backup.balanceSnapshots.count,
            "forecastSnapshots": backup.forecastSnapshots.count,
            "notificationPreferences": backup.notificationPreferences.count,
            "milestones": backup.milestones.count,
            "appSettings": backup.appSettings.count,
            "cashAccounts": (backup.cashAccounts ?? []).count,
            "obligations": (backup.obligations ?? []).count,
            "userGoalProfiles": (backup.userGoalProfiles ?? []).count,
            "onboardingProgress": (backup.onboardingProgress ?? []).count,
            "incomeSchedules": (backup.incomeSchedules ?? []).count,
            "incomeChanges": (backup.incomeChanges ?? []).count,
            "plannedObligationReserves": (backup.plannedObligationReserves ?? []).count
        ])
    }

    static func encodeBackup(_ backup: Backup) throws -> Data {
        try PortableCoding.encoder().encode(document(for: backup))
    }

    static func exportJSON(context: ModelContext, to directory: URL? = nil) throws -> URL {
        let data = try encodeBackup(try buildBackup(context: context))
        let stamp = fileTimestamp()
        let url = (directory ?? PortableFileStore.backupsDirectory())
            .appendingPathComponent("PaydayPlaybook-Backup-\(stamp).json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    // MARK: - Restore

    struct RestoreSummary {
        let schemaVersion: Int
        let exportedAt: Date
        let planVersions: Int
        let debts: Int
        let paydays: Int
        let checkIns: Int
        let ledgerEntries: Int
        let balanceSnapshots: Int
    }

    /// Decodes a backup file of any supported export schema.
    ///
    /// Schema 3 arrives inside a `PortableDocument`; schemas 1 and 2 are bare
    /// `Backup` objects written before the envelope existed. The probe routes
    /// between them so neither shape has to be guessed at, and a template file
    /// is rejected by name rather than failing somewhere inside the payload.
    ///
    /// Structural checks only — `BackupValidator` owns limits, relationships,
    /// duplicate IDs, and amount readability.
    static func readBackup(from data: Data) throws -> Backup {
        let decoder = PortableCoding.decoder()
        let probe = try PortableDocumentProbe.probe(data, decoder: decoder)

        if let kind = probe.documentKind, kind != .fullBackup {
            throw PortabilityError.wrongDocumentKind(expected: .fullBackup, found: kind)
        }
        guard importableSchemaVersions.contains(probe.schemaVersion) else {
            throw PortabilityError.unsupportedSchema(
                found: probe.schemaVersion,
                lowest: importableSchemaVersions.lowerBound,
                highest: importableSchemaVersions.upperBound
            )
        }

        guard probe.documentKind != nil else {
            // Export schema 1 or 2: the file *is* the payload.
            return try decodeLegacyBackup(data, decoder: decoder)
        }

        let document: PortableDocument<Backup>
        do {
            document = try decoder.decode(PortableDocument<Backup>.self, from: data)
        } catch let error as DecodingError {
            throw PortabilityError.malformed(Self.fieldPath(error))
        }
        guard document.schemaVersion == document.payload.schemaVersion else {
            throw PortabilityError.schemaVersionMismatch(
                envelope: document.schemaVersion,
                payload: document.payload.schemaVersion
            )
        }
        let derived = integrity(of: document.payload)
        if let (collection, declared, found) = document.integrity.disagreements(with: derived).first {
            throw PortabilityError.integrityMismatch(
                collection: collection, declared: declared, found: found
            )
        }
        return document.payload
    }

    private static func decodeLegacyBackup(_ data: Data, decoder: JSONDecoder) throws -> Backup {
        do {
            return try decoder.decode(Backup.self, from: data)
        } catch let error as DecodingError {
            throw PortabilityError.malformed(Self.fieldPath(error))
        }
    }

    /// The coding path a decoding failure occurred at — a field name, never
    /// the field's contents (V3-13).
    static func fieldPath(_ error: DecodingError) -> String {
        let context: DecodingError.Context
        switch error {
        case .typeMismatch(_, let value), .valueNotFound(_, let value),
             .keyNotFound(_, let value), .dataCorrupted(let value):
            context = value
        @unknown default:
            return "document"
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? "document" : path
    }

    static func summarize(_ backup: Backup) -> RestoreSummary {
        RestoreSummary(
            schemaVersion: backup.schemaVersion,
            exportedAt: backup.exportedAt,
            planVersions: backup.planVersions.count,
            debts: backup.debts.count,
            paydays: backup.paydayPlanItems.count,
            checkIns: backup.checkIns.count,
            ledgerEntries: backup.ledgerEntries.count,
            balanceSnapshots: backup.balanceSnapshots.count
        )
    }

    /// Replaces the entire store with the backup contents. Callers must write
    /// a rollback backup first and get explicit user confirmation. All backup
    /// rows are parsed and constructed BEFORE anything is deleted, so a
    /// malformed backup aborts without touching existing data.
    ///
    /// An older backup is brought up to the current schema by the same logical
    /// migrations an app upgrade runs, inside the same save; if any of them
    /// fails, the whole restore rolls back — never a partial write.
    static func restore(_ backup: Backup, context: ModelContext) throws {
        let objects = try buildObjects(from: backup)
        do {
            try deleteAllWithoutSaving(context: context)
            for object in objects { context.insert(object) }
            // Migration steps key on the *persistence* schema the file's rows
            // were written under, not on the export-envelope version: export
            // schemas 3 and 4 both carry schema-3 rows (the 4 bump is
            // semantic — calc-v4 plans — per VERSIONING.md §5). Keying on
            // `backupSchemaVersion` here would re-run the schema-3 upgrade on
            // an already-schema-3 restore, re-copying the profile floor onto
            // an account whose protected amount the user has since zeroed and
            // forcing `onboardingComplete` — both value mutations.
            if backup.schemaVersion < PlanContract.currentSchemaVersion {
                // Every step the backup predates, in order. Restoring a v1
                // document must land on the current schema, not part-way:
                // a store stamped behind the app is indistinguishable from a
                // legacy install and would be migrated again next launch.
                if backup.schemaVersion < 2 {
                    try MigrationService.applyLogicalUpgrade(context: context)
                }
                try MigrationService.applySchema3Upgrade(context: context)
                try MigrationService.stamp(context: context, from: backup.schemaVersion)
                // A restored store holds a complete plan; the flags must
                // agree so the restored user is never re-onboarded (§7.7).
                if let settings = try context.fetch(FetchDescriptor<AppSettings>()).first {
                    settings.onboardingComplete = true
                }
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func buildObjects(from backup: Backup) throws -> [any PersistentModel] {
        var objects: [any PersistentModel] = []

        for dto in backup.planVersions {
            let plan = PlanVersion(
                id: dto.id, name: dto.name, createdAt: dto.createdAt,
                isOriginalBaseline: dto.isOriginalBaseline, isActive: dto.isActive,
                firstPayday: dto.firstPayday, payFrequencyDays: dto.payFrequencyDays,
                startingChecking1: try decimal(dto.startingChecking1),
                protectedBuffer: try decimal(dto.protectedBuffer),
                allowanceCap: try decimal(dto.allowanceCap),
                firstCheckBufferAdd: try decimal(dto.firstCheckBufferAdd),
                carReservePerCheck: try decimal(dto.carReservePerCheck),
                trainReservePerCheck: try decimal(dto.trainReservePerCheck),
                calculationVersion: dto.calculationVersion,
                timeZoneID: dto.timeZoneID,
                avalancheOrderRaw: dto.avalancheOrderRaw,
                baselinePayoffDate: dto.baselinePayoffDate,
                baselineModeledInterest: try decimal(dto.baselineModeledInterest),
                baselineNoSpendCeiling: try decimal(dto.baselineNoSpendCeiling)
            )
            if let cadence = dto.payCadenceRaw { plan.payCadenceRaw = cadence }
            plan.monthlyPayDay = dto.monthlyPayDay
            plan.semimonthlyPayDay1 = dto.semimonthlyPayDay1
            plan.semimonthlyPayDay2 = dto.semimonthlyPayDay2
            plan.incomeAccountID = dto.incomeAccountID
            plan.generatedFromProfile = dto.generatedFromProfile ?? false
            plan.inputSnapshotData = dto.inputSnapshotData
            plan.scenarioKindRaw = dto.scenarioKindRaw
            plan.effectiveDate = dto.effectiveDate
            objects.append(plan)
        }
        for dto in backup.incomeRules {
            objects.append(IncomeRule(
                id: dto.id, planVersionID: dto.planVersionID,
                effectiveDate: dto.effectiveDate,
                netPaycheckAmount: try decimal(dto.netPaycheckAmount)
            ))
        }
        for dto in backup.debts {
            let debt = DebtAccount(
                id: dto.id, planID: dto.planID, displayName: dto.displayName,
                lastFour: dto.lastFour, startingBalance: try decimal(dto.startingBalance),
                apr: try decimal(dto.apr), minimumAmount: try decimal(dto.minimumAmount),
                dueDayOfMonth: dto.dueDayOfMonth, priority: dto.priority,
                isArchived: dto.isArchived, createdAt: dto.createdAt, updatedAt: dto.updatedAt,
                debtType: dto.debtTypeRaw.flatMap(DebtType.init(rawValue:)) ?? .creditCard,
                originalPrincipal: try decimal(dto.originalPrincipal),
                creditLimit: try decimal(dto.creditLimit),
                isExtraPrincipalEligible: dto.isExtraPrincipalEligible ?? true
            )
            // Restored verbatim: the tri-state raw stays nil on version-1
            // files so `prepayment` keeps falling back to the boolean.
            debt.prepaymentRaw = dto.prepaymentRaw
            debt.setupNote = dto.setupNote
            debt.debtTypeConfirmedAt = dto.debtTypeConfirmedAt
            debt.creditLimitMarkedUnknown = dto.creditLimitMarkedUnknown ?? false
            objects.append(debt)
        }
        for dto in backup.paydayPlanItems {
            let item = PaydayPlanItem(
                id: dto.id, planVersionID: dto.planVersionID, sequenceNumber: dto.sequenceNumber,
                date: dto.date, plannedIncome: try decimal(dto.plannedIncome),
                plannedC1Keep: try decimal(dto.plannedC1Keep),
                plannedBufferAdd: try decimal(dto.plannedBufferAdd),
                plannedAllowance: try decimal(dto.plannedAllowance),
                plannedC2Transfer: try decimal(dto.plannedC2Transfer),
                plannedCarReserve: try decimal(dto.plannedCarReserve),
                plannedTrainReserve: try decimal(dto.plannedTrainReserve),
                plannedCardBudget: try decimal(dto.plannedCardBudget),
                plannedTargetDebtID: dto.plannedTargetDebtID,
                plannedDebtAfter: try decimal(dto.plannedDebtAfter),
                plannedC1NoSpendCeiling: try decimal(dto.plannedC1NoSpendCeiling)
            )
            item.shortfallAmount = try decimal(dto.shortfallAmount)
            objects.append(item)
        }
        for dto in backup.plannedCardBalances {
            objects.append(PlannedCardBalance(
                id: dto.id, paydayPlanItemID: dto.paydayPlanItemID,
                debtPlanID: dto.debtPlanID, balanceAfter: try decimal(dto.balanceAfter)
            ))
        }
        for dto in backup.checkIns {
            let checkIn = PaydayCheckIn(
                id: dto.id, paydayPlanItemID: dto.paydayPlanItemID,
                status: CheckInStatus(rawValue: dto.statusRaw) ?? .draft,
                currentStep: dto.currentStep, createdAt: dto.createdAt, updatedAt: dto.updatedAt
            )
            checkIn.actualIncome = try decimal(dto.actualIncome)
            checkIn.outsideFundsUsed = try decimal(dto.outsideFundsUsed)
            checkIn.actualC1Kept = try decimal(dto.actualC1Kept)
            checkIn.actualC1Balance = try decimal(dto.actualC1Balance)
            checkIn.actualAllowanceSpent = try decimal(dto.actualAllowanceSpent)
            checkIn.actualC2Transfer = try decimal(dto.actualC2Transfer)
            checkIn.actualCarReserve = try decimal(dto.actualCarReserve)
            checkIn.actualTrainReserve = try decimal(dto.actualTrainReserve)
            checkIn.unallocatedAmount = try decimal(dto.unallocatedAmount)
            checkIn.note = dto.note
            checkIn.reconciliationException = dto.reconciliationException
            checkIn.completedAt = dto.completedAt
            objects.append(checkIn)
        }
        for dto in backup.checkInCardPayments {
            objects.append(CheckInCardPayment(
                id: dto.id, checkInID: dto.checkInID, debtPlanID: dto.debtPlanID,
                amount: try decimal(dto.amount),
                reportedBalanceAfter: try decimal(dto.reportedBalanceAfter)
            ))
        }
        for dto in backup.ledgerEntries {
            let entry = LedgerEntry(
                id: dto.id, effectiveDate: dto.effectiveDate, createdAt: dto.createdAt,
                updatedAt: dto.updatedAt,
                type: LedgerEntryType(rawValue: dto.typeRaw) ?? .correction,
                amount: try decimal(dto.amount),
                debtAccountID: dto.debtAccountID, debtPlanID: dto.debtPlanID,
                paydayCheckInID: dto.paydayCheckInID, note: dto.note,
                isCorrection: dto.isCorrection, correctsEntryID: dto.correctsEntryID,
                auditNote: dto.auditNote
            )
            entry.sourceAccountRaw = dto.sourceAccountRaw
            entry.destinationAccountRaw = dto.destinationAccountRaw
            entry.sourceAccountID = dto.sourceAccountID
            entry.destinationAccountID = dto.destinationAccountID
            // Copied verbatim, nil included: a nil provenance records that the
            // row predates the field, which is a fact, not a gap to fill.
            entry.provenanceRaw = dto.provenanceRaw
            objects.append(entry)
        }
        for dto in backup.balanceSnapshots {
            let snapshot = BalanceSnapshot(
                id: dto.id, debtAccountID: dto.debtAccountID, debtPlanID: dto.debtPlanID,
                effectiveDate: dto.effectiveDate, amount: try decimal(dto.amount),
                sourceType: SnapshotSourceType(rawValue: dto.sourceTypeRaw) ?? .userEntry,
                note: dto.note, isAuthoritative: dto.isAuthoritative, createdAt: dto.createdAt,
                correctsSnapshotID: dto.correctsSnapshotID, auditNote: dto.auditNote
            )
            snapshot.cashAccountRaw = dto.cashAccountRaw
            snapshot.cashAccountID = dto.cashAccountID
            objects.append(snapshot)
        }
        for dto in backup.forecastSnapshots {
            let forecast = ForecastSnapshot(
                id: dto.id, calculatedAt: dto.calculatedAt,
                sourcePlanVersionID: dto.sourcePlanVersionID,
                triggerType: ForecastTrigger(rawValue: dto.triggerTypeRaw) ?? .manual,
                projectedPayoffDate: dto.projectedPayoffDate,
                remainingPaychecks: dto.remainingPaychecks,
                estimatedRemainingInterest: try decimal(dto.estimatedRemainingInterest),
                perCardPayoffDates: [],
                summaryExplanation: dto.summaryExplanation
            )
            forecast.perCardPayoffData = dto.perCardPayoffData
            objects.append(forecast)
        }
        for dto in backup.notificationPreferences {
            objects.append(NotificationPreference(
                id: dto.id, type: NotificationKind(rawValue: dto.typeRaw) ?? .paydayMorning,
                enabled: dto.enabled, hour: dto.hour, minute: dto.minute,
                leadDays: dto.leadDays, detailedLockScreenContent: dto.detailedLockScreenContent
            ))
        }
        for dto in backup.milestones {
            objects.append(Milestone(
                id: dto.id, type: MilestoneKind(rawValue: dto.typeRaw) ?? .cardPaidOff,
                title: dto.title, thresholdAmount: try decimal(dto.thresholdAmount),
                relatedDebtPlanID: dto.relatedDebtPlanID, baselineDate: dto.baselineDate,
                forecastDate: dto.forecastDate, achievedDate: dto.achievedDate
            ))
        }
        for dto in backup.appSettings {
            let settings = AppSettings(
                id: dto.id, onboardingComplete: dto.onboardingComplete,
                appLockEnabled: dto.appLockEnabled,
                seedSchemaVersion: dto.seedSchemaVersion, createdAt: dto.createdAt
            )
            settings.debtFreeCelebrationShownAt = dto.debtFreeCelebrationShownAt
            settings.debtFreeConfirmedAt = dto.debtFreeConfirmedAt
            settings.phaseTwoGoalRaw = dto.phaseTwoGoalRaw
            settings.phaseTwoTargetAmount = try decimal(dto.phaseTwoTargetAmount)
            settings.phaseTwoNote = dto.phaseTwoNote
            settings.migratedAt = dto.migratedAt
            settings.migrationAuditNote = dto.migrationAuditNote
            objects.append(settings)
        }
        for dto in backup.cashAccounts ?? [] {
            let account = CashAccount(
                id: dto.id, name: dto.name,
                currentBalance: try decimal(dto.currentBalance),
                roles: [], isDefaultIncome: dto.isDefaultIncome,
                sortOrder: dto.sortOrder, isArchived: dto.isArchived,
                createdAt: dto.createdAt, updatedAt: dto.updatedAt
            )
            account.rolesRaw = dto.rolesRaw
            account.legacyKindRaw = dto.legacyKindRaw
            account.protectedAmount = try decimal(dto.protectedAmount) ?? .zero
            account.balanceAsOf = dto.balanceAsOf
            objects.append(account)
        }
        for dto in backup.obligations ?? [] {
            let obligation = RecurringObligation(
                id: dto.id, name: dto.name, amount: try decimal(dto.amount),
                cadence: ObligationCadence(rawValue: dto.cadenceRaw) ?? .monthly,
                dueDay: dto.dueDay, accountID: dto.accountID, isArchived: dto.isArchived,
                legacyKey: dto.legacyKey, createdAt: dto.createdAt, updatedAt: dto.updatedAt
            )
            obligation.cadenceRaw = dto.cadenceRaw
            obligation.isEssential = dto.isEssential ?? true
            objects.append(obligation)
        }
        for dto in backup.userGoalProfiles ?? [] {
            let profile = UserGoalProfile(
                id: dto.id, goalText: dto.goalText, targetDebtFreeDate: dto.targetDebtFreeDate,
                posture: PayoffPosture(rawValue: dto.postureRaw) ?? .steady,
                protectedFloor: try decimal(dto.protectedFloor),
                allowanceCap: try decimal(dto.allowanceCap),
                onboardingCompletedAt: dto.onboardingCompletedAt,
                createdAt: dto.createdAt, updatedAt: dto.updatedAt
            )
            profile.postureRaw = dto.postureRaw
            profile.minimumProtectedCash = try decimal(dto.minimumProtectedCash) ?? .zero
            profile.plannedSavingsPerPaycheck = try decimal(dto.plannedSavingsPerPaycheck) ?? .zero
            profile.additionalCushionReserve = try decimal(dto.additionalCushionReserve) ?? .zero
            profile.extraPaymentCeiling = try decimal(dto.extraPaymentCeiling) ?? .zero
            profile.zeroAllowanceConfirmedAt = dto.zeroAllowanceConfirmedAt
            objects.append(profile)
        }
        for dto in backup.onboardingProgress ?? [] {
            let progress = OnboardingProgress(
                id: dto.id, startedAt: dto.startedAt,
                updatedAt: dto.updatedAt, completedAt: dto.completedAt
            )
            progress.lastCompletedStepRaw = dto.lastCompletedStepRaw
            objects.append(progress)
        }
        for dto in backup.incomeSchedules ?? [] {
            let schedule = IncomeSchedule(
                id: dto.id, cadence: PayCadence(rawValue: dto.cadenceRaw) ?? .biweekly,
                anchorPayday: dto.anchorPayday, monthlyDay: dto.monthlyDay,
                semimonthlyFirstDay: dto.semimonthlyFirstDay,
                semimonthlySecondDay: dto.semimonthlySecondDay,
                destinationAccountID: dto.destinationAccountID,
                baseTakeHome: try decimal(dto.baseTakeHome), isArchived: dto.isArchived,
                createdAt: dto.createdAt, updatedAt: dto.updatedAt
            )
            schedule.cadenceRaw = dto.cadenceRaw
            objects.append(schedule)
        }
        for dto in backup.incomeChanges ?? [] {
            objects.append(IncomeChange(
                id: dto.id, scheduleID: dto.scheduleID, effectiveDate: dto.effectiveDate,
                newTakeHome: try decimal(dto.newTakeHome), note: dto.note, createdAt: dto.createdAt
            ))
        }
        for dto in backup.plannedObligationReserves ?? [] {
            objects.append(PlannedObligationReserve(
                id: dto.id, paydayPlanItemID: dto.paydayPlanItemID,
                obligationID: dto.obligationID, amount: try decimal(dto.amount)
            ))
        }

        return objects
    }

    static func deleteAll(context: ModelContext) throws {
        try deleteAllWithoutSaving(context: context)
        try context.save()
    }

    /// Deletion without a save so `restore` stays one transaction: parse →
    /// delete → insert → (migrate) → single save, rolled back atomically.
    /// Rows are deleted individually THROUGH the context — the batch
    /// `context.delete(model:)` API works at the store level and a later
    /// `rollback()` cannot bring those rows back, which would turn a failed
    /// restore into data loss.
    private static func deleteAllWithoutSaving(context: ModelContext) throws {
        func deleteRows<T: PersistentModel>(_ type: T.Type) throws {
            for row in try context.fetch(FetchDescriptor<T>()) {
                context.delete(row)
            }
        }
        try deleteRows(PlannedObligationReserve.self)
        try deleteRows(PlannedCardBalance.self)
        try deleteRows(PaydayPlanItem.self)
        try deleteRows(IncomeRule.self)
        try deleteRows(CheckInCardPayment.self)
        try deleteRows(PaydayCheckIn.self)
        try deleteRows(LedgerEntry.self)
        try deleteRows(BalanceSnapshot.self)
        try deleteRows(ForecastSnapshot.self)
        try deleteRows(NotificationPreference.self)
        try deleteRows(Milestone.self)
        try deleteRows(DebtAccount.self)
        try deleteRows(IncomeChange.self)
        try deleteRows(IncomeSchedule.self)
        try deleteRows(RecurringObligation.self)
        try deleteRows(CashAccount.self)
        try deleteRows(UserGoalProfile.self)
        try deleteRows(OnboardingProgress.self)
        try deleteRows(PlanVersion.self)
        try deleteRows(AppSettings.self)
    }

    // MARK: - CSV

    static func csvEscape(_ field: String) -> String {
        var field = field
        // Neutralize spreadsheet formula interpretation of exported free text.
        if let first = field.first, "=+-@".contains(first) {
            field = "'" + field
        }
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    private static let csvDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Plain two-decimal money for CSV cells (no symbol, no grouping).
    private static let csvMoneyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    static func csvMoney(_ value: Decimal) -> String {
        csvMoneyFormatter.string(from: value.rounded2 as NSDecimalNumber) ?? "\(value.rounded2)"
    }

    private static func csvDate(_ date: Date?) -> String {
        date.map { csvDateFormatter.string(from: $0) } ?? ""
    }

    static func ledgerCSV(context: ModelContext) throws -> String {
        let entries = try context.fetch(FetchDescriptor<LedgerEntry>())
            .sorted { $0.effectiveDate < $1.effectiveDate }
        var rows = ["date,type,amount,source,destination,card,note,isCorrection,auditNote"]
        for entry in entries {
            rows.append([
                csvDate(entry.effectiveDate),
                entry.type.rawValue,
                csvMoney(entry.amount),
                entry.sourceAccountRaw ?? "",
                entry.destinationAccountRaw ?? "",
                entry.debtPlanID ?? "",
                csvEscape(entry.note ?? ""),
                entry.isCorrection ? "true" : "false",
                csvEscape(entry.auditNote ?? "")
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    static func snapshotsCSV(context: ModelContext) throws -> String {
        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
            .sorted { $0.effectiveDate < $1.effectiveDate }
        var rows = ["effectiveDate,account,card,amount,sourceType,isAuthoritative,note"]
        for snapshot in snapshots {
            rows.append([
                csvDate(snapshot.effectiveDate),
                snapshot.cashAccountRaw ?? "debt",
                snapshot.debtPlanID ?? "",
                csvMoney(snapshot.amount),
                snapshot.sourceTypeRaw,
                snapshot.isAuthoritative ? "true" : "false",
                csvEscape(snapshot.note ?? "")
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    static func debtsCSV(context: ModelContext) throws -> String {
        let debts = try context.fetch(FetchDescriptor<DebtAccount>())
            .sorted { $0.priority < $1.priority }
        // Columns are append-only (V2-18): existing names and order intact,
        // schema-2 columns added at the end.
        var rows = ["planID,displayName,startingBalance,apr,minimum,dueDay,priority,archived,type,originalPrincipal,creditLimit,extraPrincipalEligible,prepayment,note"]
        for debt in debts {
            // Built in two halves: one 14-element literal of mixed optionals
            // and maps pushes the type-checker past its budget.
            var columns: [String] = [
                debt.planID,
                csvEscape(debt.displayName),
                csvMoney(debt.startingBalance),
                "\(debt.apr)",
                debt.minimumAmount.map(csvMoney) ?? "",
                debt.dueDayOfMonth.map(String.init) ?? "",
                "\(debt.priority)"
            ]
            columns.append(debt.isArchived ? "true" : "false")
            columns.append(debt.debtTypeRaw)
            columns.append(debt.originalPrincipal.map(csvMoney) ?? "")
            columns.append(debt.creditLimit.map(csvMoney) ?? "")
            columns.append(debt.isExtraPrincipalEligible ? "true" : "false")
            columns.append(debt.prepayment.rawValue)
            columns.append(debt.setupNote.map(csvEscape) ?? "")
            rows.append(columns.joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    static func checkInsCSV(context: ModelContext) throws -> String {
        let checkIns = try context.fetch(FetchDescriptor<PaydayCheckIn>())
        let items = try context.fetch(FetchDescriptor<PaydayPlanItem>())
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let sorted = checkIns.sorted {
            (itemsByID[$0.paydayPlanItemID]?.sequenceNumber ?? 0) < (itemsByID[$1.paydayPlanItemID]?.sequenceNumber ?? 0)
        }
        var rows = ["payday,date,status,actualIncome,outsideFunds,c1Kept,c1Balance,allowanceSpent,c2Transfer,carReserve,trainReserve,unallocated,completedAt,exception"]
        for checkIn in sorted {
            let item = itemsByID[checkIn.paydayPlanItemID]
            func cell(_ value: Decimal?) -> String { value.map(csvMoney) ?? "" }
            rows.append([
                item.map { "\($0.sequenceNumber)" } ?? "",
                csvDate(item?.date),
                checkIn.statusRaw,
                cell(checkIn.actualIncome),
                cell(checkIn.outsideFundsUsed),
                cell(checkIn.actualC1Kept),
                cell(checkIn.actualC1Balance),
                cell(checkIn.actualAllowanceSpent),
                cell(checkIn.actualC2Transfer),
                cell(checkIn.actualCarReserve),
                cell(checkIn.actualTrainReserve),
                cell(checkIn.unallocatedAmount),
                csvDate(checkIn.completedAt),
                csvEscape(checkIn.reconciliationException ?? "")
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    static func exportCSVs(context: ModelContext, to directory: URL? = nil) throws -> [URL] {
        let stamp = fileTimestamp()
        let dir = directory ?? PortableFileStore.csvDirectory()
        let files: [(String, String)] = [
            ("PaydayPlaybook-Ledger-\(stamp).csv", try ledgerCSV(context: context)),
            ("PaydayPlaybook-Balances-\(stamp).csv", try snapshotsCSV(context: context)),
            ("PaydayPlaybook-Debts-\(stamp).csv", try debtsCSV(context: context)),
            ("PaydayPlaybook-CheckIns-\(stamp).csv", try checkInsCSV(context: context))
        ]
        var urls: [URL] = []
        for (name, contents) in files {
            let url = dir.appendingPathComponent(name)
            try contents.data(using: .utf8)?.write(to: url, options: [.atomic, .completeFileProtection])
            urls.append(url)
        }
        return urls
    }

    private static func fileTimestamp() -> String {
        PortableFileStore.timestamp()
    }
}
