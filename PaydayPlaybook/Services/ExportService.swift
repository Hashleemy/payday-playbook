import Foundation
import SwiftData

/// Versioned JSON backup/restore and CSV exports. Every export and import is
/// user-initiated; nothing leaves the device otherwise.
struct ExportService {
    static let backupSchemaVersion = 1

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
        }
        struct IncomeRuleDTO: Codable {
            var id: UUID, planVersionID: UUID, effectiveDate: Date, netPaycheckAmount: String
        }
        struct DebtDTO: Codable {
            var id: UUID, planID: String, displayName: String, lastFour: String?
            var startingBalance: String, apr: String, minimumAmount: String?
            var dueDayOfMonth: Int?, priority: Int, isArchived: Bool
            var createdAt: Date, updatedAt: Date
        }
        struct PaydayPlanItemDTO: Codable {
            var id: UUID, planVersionID: UUID, sequenceNumber: Int, date: Date
            var plannedIncome: String, plannedC1Keep: String, plannedBufferAdd: String
            var plannedAllowance: String, plannedC2Transfer: String
            var plannedCarReserve: String, plannedTrainReserve: String, plannedCardBudget: String
            var plannedTargetDebtID: String, plannedDebtAfter: String, plannedC1NoSpendCeiling: String
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
        }
        struct SnapshotDTO: Codable {
            var id: UUID, debtAccountID: UUID?, debtPlanID: String?, cashAccountRaw: String?
            var effectiveDate: Date, amount: String, sourceTypeRaw: String
            var note: String?, isAuthoritative: Bool, createdAt: Date
            var correctsSnapshotID: UUID?, auditNote: String?
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
    }

    enum ExportError: LocalizedError {
        case unsupportedSchema(Int)
        case decimalParse(String)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version):
                return "This backup uses schema version \(version), which this app version cannot restore."
            case .decimalParse(let raw):
                return "The backup contains an invalid amount: \(raw)"
            case .encodingFailed:
                return "The backup could not be written."
            }
        }
    }

    private static func money(_ value: Decimal) -> String { "\(value)" }
    private static func money(_ value: Decimal?) -> String? { value.map { "\($0)" } }

    private static func decimal(_ raw: String) throws -> Decimal {
        guard let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else {
            throw ExportError.decimalParse(raw)
        }
        return value
    }

    private static func decimal(_ raw: String?) throws -> Decimal? {
        guard let raw else { return nil }
        return try decimal(raw)
    }

    // MARK: - Export

    static func buildBackup(context: ModelContext) throws -> Backup {
        let plans = try context.fetch(FetchDescriptor<PlanVersion>())
        let rules = try context.fetch(FetchDescriptor<IncomeRule>())
        let debts = try context.fetch(FetchDescriptor<DebtAccount>())
        let items = try context.fetch(FetchDescriptor<PaydayPlanItem>())
        let planned = try context.fetch(FetchDescriptor<PlannedCardBalance>())
        let checkIns = try context.fetch(FetchDescriptor<PaydayCheckIn>())
        let payments = try context.fetch(FetchDescriptor<CheckInCardPayment>())
        let entries = try context.fetch(FetchDescriptor<LedgerEntry>())
        let snapshots = try context.fetch(FetchDescriptor<BalanceSnapshot>())
        let forecasts = try context.fetch(FetchDescriptor<ForecastSnapshot>())
        let preferences = try context.fetch(FetchDescriptor<NotificationPreference>())
        let milestones = try context.fetch(FetchDescriptor<Milestone>())
        let settings = try context.fetch(FetchDescriptor<AppSettings>())

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
                    baselineNoSpendCeiling: money($0.baselineNoSpendCeiling)
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
                      createdAt: $0.createdAt, updatedAt: $0.updatedAt)
            },
            paydayPlanItems: items.map {
                .init(id: $0.id, planVersionID: $0.planVersionID, sequenceNumber: $0.sequenceNumber,
                      date: $0.date, plannedIncome: money($0.plannedIncome),
                      plannedC1Keep: money($0.plannedC1Keep), plannedBufferAdd: money($0.plannedBufferAdd),
                      plannedAllowance: money($0.plannedAllowance), plannedC2Transfer: money($0.plannedC2Transfer),
                      plannedCarReserve: money($0.plannedCarReserve), plannedTrainReserve: money($0.plannedTrainReserve),
                      plannedCardBudget: money($0.plannedCardBudget), plannedTargetDebtID: $0.plannedTargetDebtID,
                      plannedDebtAfter: money($0.plannedDebtAfter), plannedC1NoSpendCeiling: money($0.plannedC1NoSpendCeiling))
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
                      isCorrection: $0.isCorrection, correctsEntryID: $0.correctsEntryID, auditNote: $0.auditNote)
            },
            balanceSnapshots: snapshots.map {
                .init(id: $0.id, debtAccountID: $0.debtAccountID, debtPlanID: $0.debtPlanID,
                      cashAccountRaw: $0.cashAccountRaw, effectiveDate: $0.effectiveDate,
                      amount: money($0.amount), sourceTypeRaw: $0.sourceTypeRaw, note: $0.note,
                      isAuthoritative: $0.isAuthoritative, createdAt: $0.createdAt,
                      correctsSnapshotID: $0.correctsSnapshotID, auditNote: $0.auditNote)
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
                      seedSchemaVersion: $0.seedSchemaVersion, createdAt: $0.createdAt)
            }
        )
    }

    static func exportJSON(context: ModelContext, to directory: URL? = nil) throws -> URL {
        let backup = try buildBackup(context: context)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup)
        let stamp = fileTimestamp()
        let url = (directory ?? FileManager.default.temporaryDirectory)
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

    static func readBackup(from data: Data) throws -> Backup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(Backup.self, from: data)
        guard backup.schemaVersion == backupSchemaVersion else {
            throw ExportError.unsupportedSchema(backup.schemaVersion)
        }
        return backup
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
    static func restore(_ backup: Backup, context: ModelContext) throws {
        let objects = try buildObjects(from: backup)
        try deleteAll(context: context)
        for object in objects { context.insert(object) }
        try context.save()
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
            objects.append(DebtAccount(
                id: dto.id, planID: dto.planID, displayName: dto.displayName,
                lastFour: dto.lastFour, startingBalance: try decimal(dto.startingBalance),
                apr: try decimal(dto.apr), minimumAmount: try decimal(dto.minimumAmount),
                dueDayOfMonth: dto.dueDayOfMonth, priority: dto.priority,
                isArchived: dto.isArchived, createdAt: dto.createdAt, updatedAt: dto.updatedAt
            ))
        }
        for dto in backup.paydayPlanItems {
            objects.append(PaydayPlanItem(
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
            ))
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
            objects.append(settings)
        }

        return objects
    }

    static func deleteAll(context: ModelContext) throws {
        try context.delete(model: PlannedCardBalance.self)
        try context.delete(model: PaydayPlanItem.self)
        try context.delete(model: IncomeRule.self)
        try context.delete(model: CheckInCardPayment.self)
        try context.delete(model: PaydayCheckIn.self)
        try context.delete(model: LedgerEntry.self)
        try context.delete(model: BalanceSnapshot.self)
        try context.delete(model: ForecastSnapshot.self)
        try context.delete(model: NotificationPreference.self)
        try context.delete(model: Milestone.self)
        try context.delete(model: DebtAccount.self)
        try context.delete(model: PlanVersion.self)
        try context.delete(model: AppSettings.self)
        try context.save()
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
        var rows = ["planID,displayName,startingBalance,apr,minimum,dueDay,priority,archived"]
        for debt in debts {
            rows.append([
                debt.planID,
                csvEscape(debt.displayName),
                csvMoney(debt.startingBalance),
                "\(debt.apr)",
                debt.minimumAmount.map(csvMoney) ?? "",
                debt.dueDayOfMonth.map(String.init) ?? "",
                "\(debt.priority)",
                debt.isArchived ? "true" : "false"
            ].joined(separator: ","))
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
        let dir = directory ?? FileManager.default.temporaryDirectory
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
