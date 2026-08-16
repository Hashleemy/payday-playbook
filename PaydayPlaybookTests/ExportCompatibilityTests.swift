import XCTest
import SwiftData
@testable import PaydayPlaybook

/// V2-18 / F-14: backup schema 2 writes, version-1 files restore through the
/// same logical migration, incompatible files fail safely with no partial
/// write, and CSV columns stay append-only.
final class ExportCompatibilityTests: XCTestCase {

    /// Keys that exist only in schema-2 backups.
    private static let v2OnlyKeys: Set<String> = [
        "payCadenceRaw", "monthlyPayDay", "semimonthlyPayDay1", "semimonthlyPayDay2",
        "incomeAccountID", "generatedFromProfile", "inputSnapshotData",
        "debtTypeRaw", "originalPrincipal", "creditLimit", "isExtraPrincipalEligible",
        "shortfallAmount", "sourceAccountID", "destinationAccountID", "cashAccountID",
        "migratedAt", "migrationAuditNote",
        "cashAccounts", "obligations", "userGoalProfiles", "onboardingProgress",
        "incomeSchedules", "incomeChanges", "plannedObligationReserves"
    ]

    private func stripToV1(_ object: Any) -> Any {
        if var dict = object as? [String: Any] {
            for key in Self.v2OnlyKeys { dict.removeValue(forKey: key) }
            return dict.mapValues { stripToV1($0) }
        }
        if let array = object as? [Any] {
            return array.map { stripToV1($0) }
        }
        return object
    }

    /// A byte-faithful version-1 backup file, produced from a legacy
    /// (schema-1-shaped) store and stripped of every schema-2 key.
    private func makeV1BackupData() throws -> Data {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context, applySchemaUpgrade: false)
        if let settings = try context.fetch(FetchDescriptor<AppSettings>()).first {
            settings.onboardingComplete = true
        }
        context.insert(LedgerEntry(
            effectiveDate: TestSupport.date(2054, 8, 20),
            type: .c2Transfer,
            amount: TestSupport.money("1705.00"),
            sourceAccount: .checking1,
            destinationAccount: .checking2
        ))
        try context.save()

        let backup = try ExportService.buildBackup(context: context)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let v2Data = try encoder.encode(backup)

        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: v2Data) as? [String: Any]
        )
        json = try XCTUnwrap(stripToV1(json) as? [String: Any])
        json["schemaVersion"] = 1
        return try JSONSerialization.data(withJSONObject: json)
    }

    // MARK: - v1 file → v2 store (§7 acceptance)

    func testVersion1BackupRestoresThroughMigration() throws {
        let data = try makeV1BackupData()
        let backup = try ExportService.readBackup(from: data)
        XCTAssertEqual(backup.schemaVersion, 1)

        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try ExportService.restore(backup, context: context)

        // The plan came through value-for-value…
        let plan = try XCTUnwrap(context.fetch(FetchDescriptor<PlanVersion>()).first)
        XCTAssertEqual(plan.name, "Original Plan v1")
        XCTAssertEqual(plan.calculationVersion, 1)
        XCTAssertEqual(plan.baselineModeledInterest, TestSupport.money("2617.18"))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PaydayPlanItem>()), 23)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DebtAccount>()), 6)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlannedCardBalance>()), 23 * 6)

        // …and the store landed at schema 2 via the same logical migration.
        let settings = try XCTUnwrap(context.fetch(FetchDescriptor<AppSettings>()).first)
        XCTAssertEqual(settings.seedSchemaVersion, PlanContract.currentSchemaVersion)
        XCTAssertTrue(settings.onboardingComplete)
        let accounts = try context.fetch(FetchDescriptor<CashAccount>())
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(accounts.filter(\.isDefaultIncome).count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecurringObligation>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlannedObligationReserve>()), 46)
        // No fabricated debt facts.
        for debt in try context.fetch(FetchDescriptor<DebtAccount>()) {
            XCTAssertNil(debt.creditLimit)
            XCTAssertNil(debt.originalPrincipal)
        }
    }

    // MARK: - v2 round trip with the new models

    func testVersion2RoundTripPreservesSchema2Rows() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context)
        let profileID = try XCTUnwrap(context.fetch(FetchDescriptor<UserGoalProfile>()).first).id

        let backup = try ExportService.buildBackup(context: context)
        // The writer emits export schema 3 (V3-09); this suite's subject is
        // that the schema-2 *rows* survive a round trip, which they must
        // whichever envelope carries them.
        XCTAssertEqual(backup.schemaVersion, 3)
        let decoded = try ExportService.readBackup(from: ExportService.encodeBackup(backup))

        let freshContainer = try TestSupport.makeContainer()
        let fresh = ModelContext(freshContainer)
        try ExportService.restore(decoded, context: fresh)

        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<CashAccount>()), 2)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<RecurringObligation>()), 2)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<PlannedObligationReserve>()), 46)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<IncomeSchedule>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<IncomeChange>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<OnboardingProgress>()), 1)

        let profile = try XCTUnwrap(fresh.fetch(FetchDescriptor<UserGoalProfile>()).first)
        XCTAssertEqual(profile.id, profileID)
        XCTAssertEqual(profile.protectedFloor, TestSupport.money("1500.00"))
        XCTAssertEqual(profile.allowanceCap, TestSupport.money("300.00"))

        let c1 = try XCTUnwrap(fresh.fetch(FetchDescriptor<CashAccount>()).first { $0.legacyKind == .checking1 })
        XCTAssertEqual(c1.roles, [.income, .spending])
        XCTAssertTrue(c1.isDefaultIncome)

        // Restoring a v2 file must not re-run migration side effects twice.
        let settings = try XCTUnwrap(fresh.fetch(FetchDescriptor<AppSettings>()).first)
        XCTAssertEqual(settings.seedSchemaVersion, PlanContract.currentSchemaVersion)
    }

    // MARK: - Fail-safe incompatibility (mission rule 7)

    func testFutureSchemaFailsWithClearMessageAndNoWrite() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context)
        var backup = try ExportService.buildBackup(context: context)
        // One past what this build reads. Written as a bare document (no
        // envelope) so the *schema* is what rejects it, not the shape.
        let future = ExportService.importableSchemaVersions.upperBound + 1
        backup.schemaVersion = future
        let data = try PortableCoding.encoder().encode(backup)

        XCTAssertThrowsError(try ExportService.readBackup(from: data)) { error in
            guard case PortabilityError.unsupportedSchema(let found, _, _) = error else {
                return XCTFail("Expected unsupportedSchema(\(future)), got \(error)")
            }
            XCTAssertEqual(found, future)
            XCTAssertTrue(error.localizedDescription.contains("newer version"))
        }
        // The store was never touched.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PaydayPlanItem>()), 23)
    }

    func testCorruptAmountAbortsRestoreWithoutPartialWrite() throws {
        let data = try makeV1BackupData()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var debts = try XCTUnwrap(json["debts"] as? [[String: Any]])
        debts[0]["startingBalance"] = "not-money"
        json["debts"] = debts
        let corrupt = try JSONSerialization.data(withJSONObject: json)
        let backup = try ExportService.readBackup(from: corrupt)

        // Target store already has real data that must survive.
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context)
        let planCount = try context.fetchCount(FetchDescriptor<PlanVersion>())
        let itemCount = try context.fetchCount(FetchDescriptor<PaydayPlanItem>())
        let accountCount = try context.fetchCount(FetchDescriptor<CashAccount>())

        XCTAssertThrowsError(try ExportService.restore(backup, context: context))

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), planCount)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PaydayPlanItem>()), itemCount)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CashAccount>()), accountCount)
    }

    func testV1ImportMigrationFailureRollsBackTheWholeRestore() throws {
        // A v1 file whose baseline graph is incomplete: decodes and parses
        // fine, but the §7 integrity check must reject it AFTER the old rows
        // were deleted in-context — the rollback has to bring everything back.
        let data = try makeV1BackupData()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["paydayPlanItems"] = []
        json["plannedCardBalances"] = []
        let incomplete = try JSONSerialization.data(withJSONObject: json)
        let backup = try ExportService.readBackup(from: incomplete)

        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context)

        XCTAssertThrowsError(try ExportService.restore(backup, context: context)) { error in
            guard case MigrationService.MigrationError.baselineIncomplete = error else {
                return XCTFail("Expected baselineIncomplete, got \(error)")
            }
        }

        // The pre-restore store survived intact, including schema-2 rows.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PaydayPlanItem>()), 23)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlannedCardBalance>()), 23 * 6)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CashAccount>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecurringObligation>()), 2)
        let settings = try XCTUnwrap(context.fetch(FetchDescriptor<AppSettings>()).first)
        XCTAssertEqual(settings.seedSchemaVersion, PlanContract.currentSchemaVersion)
    }

    // MARK: - Append-only CSV (V2-18)

    func testDebtsCSVColumnsAreSupersetOfV1() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context)
        let csv = try ExportService.debtsCSV(context: context)
        let header = try XCTUnwrap(csv.split(separator: "\n").first.map(String.init))

        let v1Header = "planID,displayName,startingBalance,apr,minimum,dueDay,priority,archived"
        XCTAssertTrue(header.hasPrefix(v1Header), "existing columns keep names and order")
        // Append-only, not frozen: schema-2 columns follow the v1 block in a
        // fixed order, and later columns may be appended after them without
        // breaking a v1 reader.
        XCTAssertTrue(
            header.hasPrefix(v1Header + ",type,originalPrincipal,creditLimit,extraPrincipalEligible"),
            "schema-2 columns keep their names and order too"
        )
        let columns = header.split(separator: ",").map(String.init)
        XCTAssertEqual(Set(columns).count, columns.count, "no duplicate column names")

        let firstRow = try XCTUnwrap(csv.split(separator: "\n").dropFirst().first.map(String.init))
        XCTAssertTrue(firstRow.contains("creditCard"))
    }

    func testOtherCSVHeadersUnchanged() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context)
        XCTAssertTrue(try ExportService.ledgerCSV(context: context)
            .hasPrefix("date,type,amount,source,destination,card,note,isCorrection,auditNote"))
        XCTAssertTrue(try ExportService.snapshotsCSV(context: context)
            .hasPrefix("effectiveDate,account,card,amount,sourceType,isAuthoritative,note"))
        XCTAssertTrue(try ExportService.checkInsCSV(context: context)
            .hasPrefix("payday,date,status,actualIncome,outsideFunds,c1Kept,c1Balance,allowanceSpent,c2Transfer,carReserve,trainReserve,unallocated,completedAt,exception"))
    }
}
