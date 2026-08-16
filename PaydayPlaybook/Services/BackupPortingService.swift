import Foundation
import SwiftData

/// Full JSON backup and restore (V3-09), implementing `BackupPorting`.
///
/// The restore is a three-step transaction — **stage, preview, commit** —
/// because "replace everything I own" deserves a step where the user can see
/// what they are about to get and back out for free:
///
///     stage(data:)   parse + validate, touching nothing        → RestorePreview
///     (user reviews counts and categories; details on request)
///     commit(_:)     safety backup, then one atomic replace    → RestoreOutcome
///
/// Cancelling is not an operation: staging writes nothing, so abandoning a
/// preview leaves the store bit-for-bit as it was. Committing delegates to
/// `ExportService.restore`, which parses every row *before* deleting anything
/// and rolls the whole context back on any failure.
protocol BackupPorting {
    func exportBackup() throws -> URL
    func stage(data: Data) throws -> RestorePreview
    @discardableResult
    func commit(_ preview: RestorePreview, createSafetyBackup: Bool) throws -> RestoreOutcome
}

// MARK: - Preview

/// What a user sees before authorizing a restore: **how many** records of
/// **what kinds**, never how much money (V3-09, V3-13).
///
/// The staged payload is held privately. A view cannot reach a balance by
/// accident — it has to call `revealDetails()`, which exists precisely so that
/// showing real values is a deliberate, auditable act rather than a default.
struct RestorePreview {
    struct Count: Identifiable, Equatable {
        var label: String
        var count: Int
        var id: String { label }
    }

    var documentKind: PortableDocumentKind
    var schemaVersion: Int
    /// Version of the app that wrote the file; nil on schema 1/2 files whose
    /// header predates the field being reliable.
    var appVersion: String?
    var calculationVersion: Int?
    var exportedAt: Date
    /// Structural record counts, largest collections first.
    var counts: [Count]
    /// Non-financial shape: "4 credit cards", "2 checking accounts".
    var categories: [String]
    /// Non-fatal findings — optional references that point outside the file,
    /// an older schema that will be upgraded on the way in.
    var warnings: [String]
    /// True when the file predates the current schema and migrations will run
    /// as part of the commit.
    var requiresUpgrade: Bool
    var totalRecords: Int

    /// The staged payload. Deliberately not exposed: everything a preview
    /// needs is already summarized above.
    fileprivate let backup: ExportService.Backup

    /// Actual stored values, produced only when the user explicitly asks to
    /// see them. Never called during normal preview rendering.
    func revealDetails() -> RestoreDetails {
        RestoreDetails(backup: backup)
    }
}

/// The unredacted view of a staged backup, behind an explicit user action.
struct RestoreDetails {
    struct Row: Identifiable, Equatable {
        var label: String
        var value: String
        var id: String { label + value }
    }

    var accounts: [Row] = []
    var debts: [Row] = []
    var obligations: [Row] = []
    var income: [Row] = []

    fileprivate init(backup: ExportService.Backup) {
        accounts = (backup.cashAccounts ?? []).map {
            Row(label: $0.name, value: RestoreDetails.money($0.currentBalance))
        }
        debts = backup.debts.map {
            Row(label: $0.displayName, value: RestoreDetails.money($0.startingBalance))
        }
        obligations = (backup.obligations ?? []).map {
            Row(label: $0.name, value: RestoreDetails.money($0.amount))
        }
        income = (backup.incomeSchedules ?? []).map {
            Row(label: $0.cadenceRaw, value: RestoreDetails.money($0.baseTakeHome))
        }
    }

    /// Formats a stored money string for display. Unparseable input renders as
    /// an em dash rather than echoing the raw text.
    private static func money(_ raw: String) -> String {
        guard let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else {
            return "—"
        }
        return MoneyFormat.string(value)
    }
}

// MARK: - Outcome

struct RestoreOutcome: Equatable {
    var restoredRecords: Int
    /// Where the pre-restore snapshot of the *previous* data was written.
    /// Nil when the user declined it.
    var safetyBackupURL: URL?
    var upgradedFromSchema: Int?
}

/// A commit that failed *and* the safety backup that survives it, so the UI can
/// tell the user where their previous data went instead of just what broke.
struct RestoreCommitFailure: LocalizedError {
    var underlying: any Error
    var safetyBackupURL: URL?

    var errorDescription: String? {
        let base = underlying.localizedDescription
        guard let safetyBackupURL else { return base }
        return "\(base) Your data was not changed. A safety backup was saved as \(safetyBackupURL.lastPathComponent)."
    }
}

// MARK: - Service

struct BackupPortingService: BackupPorting {
    let context: ModelContext
    let dateProvider: DateProviding

    init(context: ModelContext, dateProvider: DateProviding = SystemDateProvider()) {
        self.context = context
        self.dateProvider = dateProvider
    }

    // MARK: Export

    func exportBackup() throws -> URL {
        let data = try ExportService.encodeBackup(try ExportService.buildBackup(context: context))
        return try PortableFileStore.write(
            data,
            named: "PaydayPlaybook-Backup-\(PortableFileStore.timestamp(dateProvider.now)).json",
            in: .backups
        )
    }

    // MARK: Stage

    /// Parses and fully validates a candidate file without touching the store.
    ///
    /// Ordered cheapest-rejection-first: size, then shape, then structure. A
    /// 60 MB file is refused before the decoder ever allocates for it.
    func stage(data: Data) throws -> RestorePreview {
        let probe = try PortableDocumentProbe.probe(data)
        let backup = try ExportService.readBackup(from: data)
        let findings = try BackupValidator.validate(backup)

        var warnings = findings.warnings
        let requiresUpgrade = backup.schemaVersion < ExportService.backupSchemaVersion
        if requiresUpgrade {
            warnings.append(
                "This backup uses format \(backup.schemaVersion). It will be upgraded to format "
                + "\(ExportService.backupSchemaVersion) as it is restored, the same way an app update upgrades your data."
            )
        }

        return RestorePreview(
            documentKind: probe.effectiveKind,
            schemaVersion: backup.schemaVersion,
            appVersion: probe.appVersion ?? backup.appVersion,
            calculationVersion: nil,
            exportedAt: backup.exportedAt,
            counts: findings.counts,
            categories: findings.categories,
            warnings: warnings,
            requiresUpgrade: requiresUpgrade,
            totalRecords: findings.totalRecords,
            backup: backup
        )
    }

    // MARK: Commit

    /// Replaces the store with the staged backup.
    ///
    /// The safety backup is written first and deliberately *not* deleted on
    /// success: a restore that turns out to be the wrong file is only
    /// recoverable if the previous data still exists somewhere. It is pruned
    /// by age and count instead (`PortableFileStore.pruneSafetyBackups`).
    @discardableResult
    func commit(_ preview: RestorePreview, createSafetyBackup: Bool = true) throws -> RestoreOutcome {
        var safetyURL: URL?
        if createSafetyBackup {
            safetyURL = try writeSafetyBackup()
        }
        do {
            try ExportService.restore(preview.backup, context: context)
        } catch {
            // `restore` rolled the context back; the store is untouched.
            throw RestoreCommitFailure(underlying: error, safetyBackupURL: safetyURL)
        }
        return RestoreOutcome(
            restoredRecords: preview.totalRecords,
            safetyBackupURL: safetyURL,
            upgradedFromSchema: preview.requiresUpgrade ? preview.schemaVersion : nil
        )
    }

    /// Snapshot of the data a restore is about to replace.
    func writeSafetyBackup() throws -> URL {
        let data = try ExportService.encodeBackup(try ExportService.buildBackup(context: context))
        let url = try PortableFileStore.write(
            data,
            named: "PaydayPlaybook-BeforeRestore-\(PortableFileStore.timestamp(dateProvider.now)).json",
            in: .safety
        )
        // Wall clock, not `dateProvider`: this compares against filesystem
        // modification times (see `pruneSafetyBackups`).
        PortableFileStore.pruneSafetyBackups()
        return url
    }
}

// MARK: - Validation

/// Strict structural validation of a decoded backup (V3-09).
///
/// Split from decoding on purpose: `Decodable` proves the file has the right
/// *types*, and this proves it describes a coherent *graph*. A file can decode
/// perfectly and still claim a check-in belongs to a payday that isn't in it.
enum BackupValidator {

    struct Findings {
        var counts: [RestorePreview.Count] = []
        var categories: [String] = []
        var warnings: [String] = []
        var totalRecords: Int = 0
    }

    /// Required references — the ones whose absence would leave a restored row
    /// orphaned inside its own document — are errors. Optional references
    /// (an account link, a forecast's source plan) become warnings instead:
    /// they are nil-able by design, and rejecting a real backup the previous
    /// version restored happily would be a worse failure than importing a row
    /// with a stale pointer.
    static func validate(_ backup: ExportService.Backup) throws -> Findings {
        var findings = Findings()

        findings.counts = counts(of: backup)
        findings.totalRecords = findings.counts.reduce(0) { $0 + $1.count }
        guard findings.totalRecords <= PortableDocumentLimits.maxRecords else {
            throw PortabilityError.tooManyRecords(
                count: findings.totalRecords, limit: PortableDocumentLimits.maxRecords
            )
        }

        try checkAmounts(backup)
        try checkDuplicateIdentifiers(backup)
        try checkRequiredReferences(backup)
        findings.warnings = optionalReferenceWarnings(backup)
        findings.categories = categories(of: backup)

        return findings
    }

    // MARK: Counts and categories

    static func counts(of backup: ExportService.Backup) -> [RestorePreview.Count] {
        let raw: [(String, Int)] = [
            ("Plan versions", backup.planVersions.count),
            ("Debts", backup.debts.count),
            ("Checking accounts", (backup.cashAccounts ?? []).count),
            ("Bills", (backup.obligations ?? []).count),
            ("Paydays", backup.paydayPlanItems.count),
            ("Check-ins", backup.checkIns.count),
            ("Payments recorded", backup.checkInCardPayments.count),
            ("Ledger entries", backup.ledgerEntries.count),
            ("Balance snapshots", backup.balanceSnapshots.count),
            ("Projected balances", backup.plannedCardBalances.count),
            ("Bill reserves", (backup.plannedObligationReserves ?? []).count),
            ("Income schedules", (backup.incomeSchedules ?? []).count),
            ("Income changes", (backup.incomeChanges ?? []).count),
            ("Income rules", backup.incomeRules.count),
            ("Forecasts", backup.forecastSnapshots.count),
            ("Reminders", backup.notificationPreferences.count),
            ("Milestones", backup.milestones.count),
            ("Goal profiles", (backup.userGoalProfiles ?? []).count),
            ("Onboarding progress", (backup.onboardingProgress ?? []).count),
            ("App settings", backup.appSettings.count)
        ]
        return raw
            .filter { $0.1 > 0 }
            .map { RestorePreview.Count(label: $0.0, count: $0.1) }
    }

    /// Shape without values: how many of each debt type, account role, and
    /// bill cadence. Enough for a user to recognize their own data; not enough
    /// for a shoulder-surfer to learn anything about it.
    static func categories(of backup: ExportService.Backup) -> [String] {
        var lines: [String] = []

        let debtsByType = Dictionary(grouping: backup.debts) { $0.debtTypeRaw ?? DebtType.creditCard.rawValue }
        for key in debtsByType.keys.sorted() {
            let label = DebtType(rawValue: key)?.displayName ?? key
            lines.append(pluralized(debtsByType[key]?.count ?? 0, label.lowercased()))
        }

        let accounts = backup.cashAccounts ?? []
        if !accounts.isEmpty {
            lines.append(pluralized(accounts.count, "checking account"))
            let archived = accounts.filter(\.isArchived).count
            if archived > 0 { lines.append("\(archived) archived") }
        }

        let obligations = backup.obligations ?? []
        let byCadence = Dictionary(grouping: obligations) { $0.cadenceRaw }
        for key in byCadence.keys.sorted() {
            lines.append(pluralized(byCadence[key]?.count ?? 0, "\(key) bill"))
        }

        if !backup.checkIns.isEmpty {
            lines.append(pluralized(backup.checkIns.count, "recorded payday"))
        }
        return lines
    }

    private static func pluralized(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    // MARK: Amounts

    private static func checkAmounts(_ backup: ExportService.Backup) throws {
        func check(_ collection: String, _ field: String, _ values: [String?]) throws {
            guard values.allSatisfy(ExportService.isReadableAmount) else {
                throw PortabilityError.amountUnreadable(collection: collection, field: field)
            }
        }
        func required(_ values: [String]) -> [String?] { values.map { $0 } }

        try check("planVersions", "startingChecking1", required(backup.planVersions.map(\.startingChecking1)))
        try check("planVersions", "protectedBuffer", required(backup.planVersions.map(\.protectedBuffer)))
        try check("planVersions", "allowanceCap", required(backup.planVersions.map(\.allowanceCap)))
        try check("planVersions", "baselineModeledInterest", required(backup.planVersions.map(\.baselineModeledInterest)))
        try check("incomeRules", "netPaycheckAmount", required(backup.incomeRules.map(\.netPaycheckAmount)))
        try check("debts", "startingBalance", required(backup.debts.map(\.startingBalance)))
        try check("debts", "apr", required(backup.debts.map(\.apr)))
        try check("debts", "minimumAmount", backup.debts.map(\.minimumAmount))
        try check("debts", "creditLimit", backup.debts.map(\.creditLimit))
        try check("debts", "originalPrincipal", backup.debts.map(\.originalPrincipal))
        try check("paydayPlanItems", "plannedIncome", required(backup.paydayPlanItems.map(\.plannedIncome)))
        try check("paydayPlanItems", "plannedCardBudget", required(backup.paydayPlanItems.map(\.plannedCardBudget)))
        try check("plannedCardBalances", "balanceAfter", required(backup.plannedCardBalances.map(\.balanceAfter)))
        try check("checkIns", "actualIncome", backup.checkIns.map(\.actualIncome))
        try check("checkIns", "actualC1Balance", backup.checkIns.map(\.actualC1Balance))
        try check("checkInCardPayments", "amount", required(backup.checkInCardPayments.map(\.amount)))
        try check("ledgerEntries", "amount", required(backup.ledgerEntries.map(\.amount)))
        try check("balanceSnapshots", "amount", required(backup.balanceSnapshots.map(\.amount)))
        try check("forecastSnapshots", "estimatedRemainingInterest",
                  required(backup.forecastSnapshots.map(\.estimatedRemainingInterest)))
        try check("milestones", "thresholdAmount", backup.milestones.map(\.thresholdAmount))
        try check("cashAccounts", "currentBalance", required((backup.cashAccounts ?? []).map(\.currentBalance)))
        try check("cashAccounts", "protectedAmount", (backup.cashAccounts ?? []).map(\.protectedAmount))
        try check("obligations", "amount", required((backup.obligations ?? []).map(\.amount)))
        try check("userGoalProfiles", "protectedFloor", required((backup.userGoalProfiles ?? []).map(\.protectedFloor)))
        try check("userGoalProfiles", "allowanceCap", required((backup.userGoalProfiles ?? []).map(\.allowanceCap)))
        try check("userGoalProfiles", "minimumProtectedCash", (backup.userGoalProfiles ?? []).map(\.minimumProtectedCash))
        try check("userGoalProfiles", "plannedSavingsPerPaycheck", (backup.userGoalProfiles ?? []).map(\.plannedSavingsPerPaycheck))
        try check("userGoalProfiles", "additionalCushionReserve", (backup.userGoalProfiles ?? []).map(\.additionalCushionReserve))
        try check("userGoalProfiles", "extraPaymentCeiling", (backup.userGoalProfiles ?? []).map(\.extraPaymentCeiling))
        try check("incomeSchedules", "baseTakeHome", required((backup.incomeSchedules ?? []).map(\.baseTakeHome)))
        try check("incomeChanges", "newTakeHome", required((backup.incomeChanges ?? []).map(\.newTakeHome)))
        try check("plannedObligationReserves", "amount", required((backup.plannedObligationReserves ?? []).map(\.amount)))
        try check("appSettings", "phaseTwoTargetAmount", backup.appSettings.map(\.phaseTwoTargetAmount))
    }

    // MARK: Duplicate identifiers

    /// Duplicate IDs are rejected outright rather than de-duplicated. A restore
    /// replaces the whole store, so "merge them" has no honest meaning here —
    /// two rows claiming one identity means the file is wrong, and picking a
    /// winner would silently discard the other (MVP_LAYOUT §6).
    private static func checkDuplicateIdentifiers(_ backup: ExportService.Backup) throws {
        func check(_ collection: String, _ ids: [UUID]) throws {
            let duplicates = ids.count - Set(ids).count
            guard duplicates == 0 else {
                throw PortabilityError.duplicateIdentifiers(collection: collection, count: duplicates)
            }
        }
        try check("planVersions", backup.planVersions.map(\.id))
        try check("incomeRules", backup.incomeRules.map(\.id))
        try check("debts", backup.debts.map(\.id))
        try check("paydayPlanItems", backup.paydayPlanItems.map(\.id))
        try check("plannedCardBalances", backup.plannedCardBalances.map(\.id))
        try check("checkIns", backup.checkIns.map(\.id))
        try check("checkInCardPayments", backup.checkInCardPayments.map(\.id))
        try check("ledgerEntries", backup.ledgerEntries.map(\.id))
        try check("balanceSnapshots", backup.balanceSnapshots.map(\.id))
        try check("forecastSnapshots", backup.forecastSnapshots.map(\.id))
        try check("notificationPreferences", backup.notificationPreferences.map(\.id))
        try check("milestones", backup.milestones.map(\.id))
        try check("appSettings", backup.appSettings.map(\.id))
        try check("cashAccounts", (backup.cashAccounts ?? []).map(\.id))
        try check("obligations", (backup.obligations ?? []).map(\.id))
        try check("userGoalProfiles", (backup.userGoalProfiles ?? []).map(\.id))
        try check("onboardingProgress", (backup.onboardingProgress ?? []).map(\.id))
        try check("incomeSchedules", (backup.incomeSchedules ?? []).map(\.id))
        try check("incomeChanges", (backup.incomeChanges ?? []).map(\.id))
        try check("plannedObligationReserves", (backup.plannedObligationReserves ?? []).map(\.id))

        // A debt's letter is its plan-facing identity: the avalanche order,
        // planned balances, and ledger rows all key on it, so a collision
        // would silently reroute payments.
        let planIDs = backup.debts.map(\.planID)
        let duplicatePlanIDs = planIDs.count - Set(planIDs).count
        guard duplicatePlanIDs == 0 else {
            throw PortabilityError.duplicateIdentifiers(collection: "debts.planID", count: duplicatePlanIDs)
        }
    }

    // MARK: References

    private static func checkRequiredReferences(_ backup: ExportService.Backup) throws {
        let planIDs = Set(backup.planVersions.map(\.id))
        let itemIDs = Set(backup.paydayPlanItems.map(\.id))
        let checkInIDs = Set(backup.checkIns.map(\.id))
        let obligationIDs = Set((backup.obligations ?? []).map(\.id))
        let scheduleIDs = Set((backup.incomeSchedules ?? []).map(\.id))

        func check(_ collection: String, _ field: String, _ refs: [UUID], within known: Set<UUID>) throws {
            let dangling = refs.filter { !known.contains($0) }.count
            guard dangling == 0 else {
                throw PortabilityError.danglingReferences(
                    collection: collection, field: field, count: dangling
                )
            }
        }

        try check("incomeRules", "planVersionID", backup.incomeRules.map(\.planVersionID), within: planIDs)
        try check("paydayPlanItems", "planVersionID", backup.paydayPlanItems.map(\.planVersionID), within: planIDs)
        try check("plannedCardBalances", "paydayPlanItemID",
                  backup.plannedCardBalances.map(\.paydayPlanItemID), within: itemIDs)
        try check("checkIns", "paydayPlanItemID", backup.checkIns.map(\.paydayPlanItemID), within: itemIDs)
        try check("checkInCardPayments", "checkInID", backup.checkInCardPayments.map(\.checkInID), within: checkInIDs)
        try check("plannedObligationReserves", "paydayPlanItemID",
                  (backup.plannedObligationReserves ?? []).map(\.paydayPlanItemID), within: itemIDs)
        try check("plannedObligationReserves", "obligationID",
                  (backup.plannedObligationReserves ?? []).map(\.obligationID), within: obligationIDs)
        try check("incomeChanges", "scheduleID", (backup.incomeChanges ?? []).map(\.scheduleID), within: scheduleIDs)
    }

    private static func optionalReferenceWarnings(_ backup: ExportService.Backup) -> [String] {
        let accountIDs = Set((backup.cashAccounts ?? []).map(\.id))
        let debtIDs = Set(backup.debts.map(\.id))
        let planIDs = Set(backup.planVersions.map(\.id))
        let debtPlanIDs = Set(backup.debts.map(\.planID))

        var warnings: [String] = []
        func note(_ count: Int, _ collection: String, _ field: String) {
            guard count > 0 else { return }
            warnings.append(
                "\(count) \(collection) record(s) reference a \"\(field)\" that isn't in this file. "
                + "They will be restored with that link left empty."
            )
        }

        note(backup.ledgerEntries.compactMap(\.sourceAccountID).filter { !accountIDs.contains($0) }.count,
             "ledger", "sourceAccountID")
        note(backup.ledgerEntries.compactMap(\.destinationAccountID).filter { !accountIDs.contains($0) }.count,
             "ledger", "destinationAccountID")
        note(backup.ledgerEntries.compactMap(\.debtAccountID).filter { !debtIDs.contains($0) }.count,
             "ledger", "debtAccountID")
        note(backup.balanceSnapshots.compactMap(\.cashAccountID).filter { !accountIDs.contains($0) }.count,
             "balance snapshot", "cashAccountID")
        note(backup.balanceSnapshots.compactMap(\.debtAccountID).filter { !debtIDs.contains($0) }.count,
             "balance snapshot", "debtAccountID")
        note((backup.obligations ?? []).compactMap(\.accountID).filter { !accountIDs.contains($0) }.count,
             "bill", "accountID")
        note((backup.incomeSchedules ?? []).compactMap(\.destinationAccountID).filter { !accountIDs.contains($0) }.count,
             "income schedule", "destinationAccountID")
        note(backup.planVersions.compactMap(\.incomeAccountID).filter { !accountIDs.contains($0) }.count,
             "plan version", "incomeAccountID")
        note(backup.forecastSnapshots.map(\.sourcePlanVersionID).filter { !planIDs.contains($0) }.count,
             "forecast", "sourcePlanVersionID")
        note(backup.checkInCardPayments.map(\.debtPlanID).filter { !debtPlanIDs.contains($0) }.count,
             "recorded payment", "debtPlanID")

        return warnings
    }
}
