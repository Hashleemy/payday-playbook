import XCTest
import SwiftData
@testable import PaydayPlaybook

/// T-13 (V3-10): templates carry structure, not history or personal values;
/// applying one never rewrites what the user already has.
final class TemplatePortingTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        ModelContext(try TestSupport.makeContainer())
    }

    private func service(_ context: ModelContext) -> TemplateImportExportService {
        TemplateImportExportService(context: context, dateProvider: PortabilityFixtures.dateProvider)
    }

    private func encoded(_ context: ModelContext, options: TemplateExportOptions) throws -> Data {
        let service = service(context)
        return try PortableCoding.encoder().encode(
            service.document(for: try service.buildPayload(options: options))
        )
    }

    // MARK: - Default exclusions

    func testStructureOnlyTemplateCarriesNoValuesAndNoLabels() throws {
        let context = try makeContext()
        let setup = try PortabilityFixtures.setupWithPlan(context)
        try PortabilityFixtures.addHistory(context, setup: setup)

        let payload = try service(context).buildPayload(options: .structureOnly)

        // Field by field, every sensitive field is nil.
        for account in payload.accounts {
            XCTAssertNil(account.name)
            XCTAssertNil(account.currentBalance)
            XCTAssertNil(account.protectedAmount)
            XCTAssertFalse(account.roles.isEmpty, "roles are structure and must survive")
        }
        for bill in payload.bills {
            XCTAssertNil(bill.name)
            XCTAssertNil(bill.amount)
            XCTAssertFalse(bill.cadence.isEmpty)
        }
        for debt in payload.debts {
            XCTAssertNil(debt.name)
            XCTAssertNil(debt.lastFour)
            XCTAssertNil(debt.startingBalance)
            XCTAssertNil(debt.originalPrincipal)
            XCTAssertNil(debt.creditLimit)
            XCTAssertNil(debt.minimumAmount)
            XCTAssertFalse(debt.debtType.isEmpty)
        }
        XCTAssertNil(payload.income?.baseTakeHome)
        XCTAssertNil(payload.settings?.protectedFloor)
        XCTAssertNil(payload.settings?.allowanceCap)
        XCTAssertNil(payload.settings?.minimumProtectedCash)
        XCTAssertNil(payload.settings?.plannedSavingsPerPaycheck)
        XCTAssertNil(payload.settings?.additionalCushionReserve)
        XCTAssertNil(payload.settings?.extraPaymentCeiling)
        XCTAssertTrue(payload.includedSensitiveCategories.isEmpty)
    }

    /// The strongest form of the exclusion claim: search the serialized bytes
    /// for every value and label the fixture store holds.
    func testStructureOnlyTemplateBytesContainNoStoredValue() throws {
        let context = try makeContext()
        let setup = try PortabilityFixtures.setupWithPlan(context)
        try PortabilityFixtures.addHistory(context, setup: setup)

        let json = String(decoding: try encoded(context, options: .structureOnly), as: UTF8.self)

        let labels = ["Everyday checking", "Bills and reserves", "Blue card", "Green card",
                      "Auto loan", "Housing", "Transit pass", "Clear the cards"]
        for label in labels {
            XCTAssertFalse(json.contains(label), "template leaked the label \"\(label)\"")
        }
        let amounts = ["2400", "1200", "2000", "3200", "1450", "6800", "1100", "500.00", "150.00"]
        for amount in amounts {
            XCTAssertFalse(json.contains(amount), "template leaked the amount \(amount)")
        }
        // History has no field in the format at all.
        for marker in ["cardPayment", "checkIn", "paydayPlanItem", "ledger", "snapshot", "February payment"] {
            XCTAssertFalse(json.contains(marker), "template leaked history (\(marker))")
        }
    }

    func testHistoryAndPlanRowsHaveNoFieldInTheFormat() throws {
        let context = try makeContext()
        let setup = try PortabilityFixtures.setupWithPlan(context)
        try PortabilityFixtures.addHistory(context, setup: setup)

        let object = try PortabilityFixtures.XCTUnwrapDictionary(
            try encoded(context, options: .structureOnly)
        )
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        let allowed: Set<String> = [
            "accounts", "bills", "debts", "income", "reminders", "settings",
            "includedSensitiveCategories"
        ]
        XCTAssertTrue(
            Set(payload.keys).isSubset(of: allowed),
            "template payload grew a key outside the allow-list: \(Set(payload.keys).subtracting(allowed))"
        )
    }

    // MARK: - Explicit inclusion

    func testIncludingACategoryRequiresItAndWarnsExactly() throws {
        let context = try makeContext()
        try PortabilityFixtures.modernSetup(context)

        let options = TemplateExportOptions(includedCategories: [.displayNames, .balances])
        XCTAssertEqual(options.warnings.count, 2)
        XCTAssertTrue(options.warnings.contains { $0.contains("names you gave your accounts") })
        XCTAssertTrue(options.warnings.contains { $0.contains("original principal") })

        let payload = try service(context).buildPayload(options: options)
        XCTAssertEqual(payload.accounts.first?.name, "Everyday checking")
        XCTAssertNotNil(payload.debts.first?.startingBalance)
        // Not requested, so still absent.
        XCTAssertNil(payload.income?.baseTakeHome)
        XCTAssertNil(payload.debts.first?.minimumAmount)
        XCTAssertEqual(Set(payload.includedSensitiveCategories), ["balances", "displayNames"])
    }

    func testPreviewReportsWhichSensitiveCategoriesAFileCarries() throws {
        let context = try makeContext()
        try PortabilityFixtures.modernSetup(context)
        let data = try encoded(context, options: TemplateExportOptions(includedCategories: [.incomeAmounts]))

        let preview = try service(context).preview(data: data)
        XCTAssertEqual(preview.includedCategories, [.incomeAmounts])
        XCTAssertTrue(preview.warnings.contains { $0.contains("Income amounts") })
        XCTAssertTrue(preview.structuralExclusions.contains { $0.contains("check-ins") })
    }

    func testPreviewOfAStructureTemplateReportsNoSensitiveCategories() throws {
        let context = try makeContext()
        try PortabilityFixtures.modernSetup(context)
        let preview = try service(context).preview(data: try encoded(context, options: .structureOnly))

        XCTAssertTrue(preview.includedCategories.isEmpty)
        XCTAssertEqual(preview.counts.first { $0.label == "Debts" }?.count, 3)
        XCTAssertTrue(preview.categories.contains { $0.contains("credit card") })
    }

    // MARK: - Cross-kind rejection

    func testABackupIsRejectedByTheTemplateImporter() throws {
        let context = try makeContext()
        try PortabilityFixtures.modernSetup(context)
        let backup = try ExportService.encodeBackup(try ExportService.buildBackup(context: context))

        XCTAssertThrowsError(try service(context).preview(data: backup)) { error in
            guard case PortabilityError.wrongDocumentKind(let expected, let found) = error else {
                return XCTFail("expected wrongDocumentKind, got \(error)")
            }
            XCTAssertEqual(expected, .template)
            XCTAssertEqual(found, .fullBackup)
        }
    }

    func testALegacyEnvelopeLessFileIsRejectedByTheTemplateImporter() throws {
        let context = try makeContext()
        try PortabilityFixtures.modernSetup(context)
        var backup = try ExportService.buildBackup(context: context)
        backup.schemaVersion = 2
        let legacy = try PortableCoding.encoder().encode(backup)

        XCTAssertThrowsError(try service(context).preview(data: legacy)) { error in
            guard case PortabilityError.wrongDocumentKind(_, let found) = error else {
                return XCTFail("expected wrongDocumentKind, got \(error)")
            }
            XCTAssertEqual(found, .fullBackup, "a file with no kind is a legacy backup, not a template")
        }
    }

    // MARK: - Older formats

    func testOlderTemplateFormatsStillPreview() throws {
        let context = try makeContext()
        try PortabilityFixtures.modernSetup(context)

        for version in TemplateImportExportService.importableSchemaVersions {
            let data = try mutatedTemplate(context) { object in
                object["schemaVersion"] = version
            }
            let preview = try service(context).preview(data: data)
            XCTAssertEqual(preview.schemaVersion, version)
            if version < TemplateImportExportService.templateSchemaVersion {
                XCTAssertTrue(preview.warnings.contains { $0.contains("format \(version)") })
            }
        }
    }

    func testNewerTemplateFormatIsRejected() throws {
        let context = try makeContext()
        try PortabilityFixtures.modernSetup(context)
        let data = try mutatedTemplate(context) { $0["schemaVersion"] = 42 }

        XCTAssertThrowsError(try service(context).preview(data: data)) { error in
            guard case PortabilityError.unsupportedSchema(let found, _, _) = error else {
                return XCTFail("expected unsupportedSchema, got \(error)")
            }
            XCTAssertEqual(found, 42)
        }
    }

    func testTamperedTemplateCountIsCaught() throws {
        let context = try makeContext()
        try PortabilityFixtures.modernSetup(context)
        let data = try mutatedTemplate(context) { object in
            guard var payload = object["payload"] as? [String: Any],
                  var debts = payload["debts"] as? [[String: Any]], !debts.isEmpty else { return }
            debts.removeLast()
            payload["debts"] = debts
            object["payload"] = payload
        }
        XCTAssertThrowsError(try service(context).preview(data: data)) { error in
            guard case PortabilityError.integrityMismatch(let collection, _, _) = error else {
                return XCTFail("expected integrityMismatch, got \(error)")
            }
            XCTAssertEqual(collection, "debts")
        }
    }

    // MARK: - Apply

    /// A template arrives from someone else, and detailed lock-screen copy puts
    /// a debt's name and an amount on a screen readable without unlocking the
    /// phone. Whatever the file says, importing one must not switch that on
    /// (V3-13). Reminder timing and lead days are ordinary configuration and do
    /// carry across — the point is that one flag is the device owner's alone.
    func testImportingATemplateNeverEnablesDetailedLockScreenCopy() throws {
        let source = try makeContext()
        try PortabilityFixtures.modernSetup(source)
        for preference in try source.fetch(FetchDescriptor<NotificationPreference>()) {
            preference.detailedLockScreenContent = true
            preference.leadDays = 3
        }
        try source.save()
        let data = try encoded(source, options: .structureOnly)

        let target = try makeContext()
        let preview = try service(target).preview(data: data)
        let outcome = try service(target).apply(preview, mode: .add)

        XCTAssertGreaterThan(outcome.remindersAdded, 0, "the reminders must really have been imported")
        let imported = try target.fetch(FetchDescriptor<NotificationPreference>())
        XCTAssertFalse(
            imported.contains(where: \.detailedLockScreenContent),
            "an imported template must never turn on detailed lock-screen copy"
        )
        XCTAssertTrue(
            imported.contains { $0.leadDays == 3 },
            "ordinary reminder configuration still crosses, so this is not just an empty import"
        )
    }

    func testApplyingAStructureTemplateCreatesPlaceholdersAndInventsNoAmount() throws {
        let source = try makeContext()
        try PortabilityFixtures.modernSetup(source)
        let data = try encoded(source, options: .structureOnly)

        let target = try makeContext()
        let preview = try service(target).preview(data: data)
        // The user is told up front which rows this file cannot create: two
        // bills (no amount) and the auto loan (no required payment).
        XCTAssertTrue(preview.warnings.contains { $0.contains("can't be added until you enter one") })

        let outcome = try service(target).apply(preview, mode: .add)

        XCTAssertEqual(outcome.accountsAdded, 2)
        XCTAssertEqual(outcome.debtsAdded, 2, "the two cards land; the installment loan needs its payment")
        XCTAssertEqual(outcome.billsAdded, 0, "a bill with no amount is reported, never invented")
        // Two bills, the installment loan, and the pay schedule — each needs
        // an amount the template deliberately left out.
        XCTAssertEqual(outcome.needsValues.count, 4)
        XCTAssertTrue(outcome.needsValues.contains { $0.contains("required monthly payment") })
        XCTAssertTrue(outcome.needsValues.contains { $0.contains("take-home pay") })
        XCTAssertFalse(outcome.incomeApplied)
        XCTAssertEqual(outcome.remappedIdentifiers, outcome.accountsAdded + outcome.billsAdded
                       + outcome.debtsAdded + outcome.remindersAdded)

        // Placeholder names, never the exporting user's.
        let names = try target.fetch(FetchDescriptor<DebtAccount>()).map(\.displayName)
        XCTAssertFalse(names.contains("Blue card"))
        XCTAssertTrue(names.allSatisfy { $0.first?.isUppercase == true })

        // Structure survived; no amount was fabricated.
        let debts = try target.fetch(FetchDescriptor<DebtAccount>())
        XCTAssertEqual(Set(debts.map(\.debtTypeRaw)), ["creditCard"])
        XCTAssertTrue(debts.allSatisfy { $0.startingBalance == .zero })
        XCTAssertTrue(debts.allSatisfy { $0.apr > 0 }, "APR is a lender term and is structure")
        // A type that came from a file was not confirmed by this user.
        XCTAssertTrue(debts.allSatisfy { $0.debtTypeConfirmedAt == nil })

        // Exactly one default income account, still.
        let accounts = try target.fetch(FetchDescriptor<CashAccount>())
        XCTAssertEqual(accounts.filter { $0.isDefaultIncome && !$0.isArchived }.count, 1)
    }

    func testATemplateWithAmountsCreatesEveryRow() throws {
        let source = try makeContext()
        try PortabilityFixtures.modernSetup(source)
        let data = try encoded(source, options: TemplateExportOptions(
            includedCategories: [.displayNames, .balances, .billAmounts, .incomeAmounts]
        ))

        let target = try makeContext()
        let preview = try service(target).preview(data: data)
        XCTAssertFalse(preview.warnings.contains { $0.contains("can't be added") })

        let outcome = try service(target).apply(preview, mode: .add)
        XCTAssertEqual(outcome.accountsAdded, 2)
        XCTAssertEqual(outcome.billsAdded, 2)
        XCTAssertEqual(outcome.debtsAdded, 3)
        XCTAssertTrue(outcome.needsValues.isEmpty)
        XCTAssertTrue(outcome.incomeApplied)
    }

    func testApplyNeverTouchesHistoryOrPlans() throws {
        let target = try makeContext()
        let setup = try PortabilityFixtures.setupWithPlan(target)
        try PortabilityFixtures.addHistory(target, setup: setup)
        let before = try historyFingerprint(target)

        let source = try makeContext()
        try PortabilityFixtures.modernSetup(source)
        let data = try encoded(source, options: TemplateExportOptions(
            includedCategories: Set(TemplateSensitiveCategory.allCases)
        ))

        let preview = try service(target).preview(data: data)
        _ = try service(target).apply(preview, mode: .add)

        XCTAssertEqual(try historyFingerprint(target), before,
                       "applying a template must leave every history and plan row untouched")
    }

    func testMergeFillsGapsAndNeverOverwritesExistingValues() throws {
        let target = try makeContext()
        let setup = try PortabilityFixtures.modernSetup(target)
        let originalName = setup.debts[0].displayName
        let originalBalance = setup.debts[0].startingBalance
        let originalFloor = setup.profile.protectedFloor

        let source = try makeContext()
        let sourceSetup = try PortabilityFixtures.modernSetup(source)
        // Give the source a debt the target does not have, with a different
        // shape so merge treats it as new.
        source.insert(PortabilityFixtures.debt(
            planID: "D7", name: "Store card", balance: "900.00", apr: "0.2599",
            minimum: "30.00", dueDay: 27, priority: 7, type: .creditCard
        ))
        sourceSetup.profile.protectedFloor = TestSupport.money("999.00")
        try source.save()

        let data = try encoded(source, options: TemplateExportOptions(
            includedCategories: [.displayNames, .balances, .guardrails]
        ))
        let preview = try service(target).preview(data: data)
        let outcome = try service(target).apply(preview, mode: .merge)

        // The one genuinely new debt landed; the matching ones were skipped.
        XCTAssertEqual(outcome.debtsAdded, 1)
        XCTAssertFalse(outcome.skipped.isEmpty)

        // Nothing existing changed.
        let blue = try XCTUnwrap(
            target.fetch(FetchDescriptor<DebtAccount>()).first { $0.displayName == originalName }
        )
        XCTAssertEqual(blue.startingBalance, originalBalance)
        let profile = try XCTUnwrap(target.fetch(FetchDescriptor<UserGoalProfile>()).first)
        XCTAssertEqual(profile.protectedFloor, originalFloor,
                       "merge must not overwrite a guardrail the user already set")
    }

    func testMergeFillsAnUnsetGuardrail() throws {
        let target = try makeContext()
        try PortabilityFixtures.modernSetup(target, statingScenarioConstraints: false)

        let source = try makeContext()
        try PortabilityFixtures.modernSetup(source)
        let data = try encoded(source, options: TemplateExportOptions(includedCategories: [.guardrails]))

        let preview = try service(target).preview(data: data)
        let outcome = try service(target).apply(preview, mode: .merge)

        XCTAssertTrue(outcome.settingsApplied)
        let profile = try XCTUnwrap(target.fetch(FetchDescriptor<UserGoalProfile>()).first)
        XCTAssertEqual(profile.minimumProtectedCash, TestSupport.money("300.00"))
        XCTAssertEqual(profile.plannedSavingsPerPaycheck, TestSupport.money("100.00"))
    }

    func testIncomeScheduleIsNeverOverwritten() throws {
        let target = try makeContext()
        let setup = try PortabilityFixtures.modernSetup(target)
        let anchor = setup.schedule.anchorPayday
        let takeHome = setup.schedule.baseTakeHome

        let source = try makeContext()
        let sourceSetup = try PortabilityFixtures.modernSetup(source)
        sourceSetup.schedule.baseTakeHome = TestSupport.money("5000.00")
        try source.save()
        let data = try encoded(source, options: TemplateExportOptions(includedCategories: [.incomeAmounts]))

        let preview = try service(target).preview(data: data)
        let outcome = try service(target).apply(preview, mode: .merge)

        XCTAssertFalse(outcome.incomeApplied)
        XCTAssertTrue(outcome.skipped.contains { $0.contains("Pay schedule") })
        let schedule = try XCTUnwrap(target.fetch(FetchDescriptor<IncomeSchedule>()).first)
        XCTAssertEqual(schedule.baseTakeHome, takeHome)
        XCTAssertEqual(schedule.anchorPayday, anchor)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<IncomeSchedule>()), 1)
    }

    // MARK: - Helpers

    private func mutatedTemplate(
        _ context: ModelContext,
        _ mutate: (inout [String: Any]) -> Void
    ) throws -> Data {
        var object = try PortabilityFixtures.XCTUnwrapDictionary(
            try encoded(context, options: .structureOnly)
        )
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Every row a template must never touch.
    private func historyFingerprint(_ context: ModelContext) throws -> String {
        let backup = try ExportService.buildBackup(context: context)
        struct History: Encodable {
            var planVersions: [ExportService.Backup.PlanVersionDTO]
            var paydayPlanItems: [ExportService.Backup.PaydayPlanItemDTO]
            var plannedCardBalances: [ExportService.Backup.PlannedCardBalanceDTO]
            var checkIns: [ExportService.Backup.CheckInDTO]
            var checkInCardPayments: [ExportService.Backup.CheckInCardPaymentDTO]
            var ledgerEntries: [ExportService.Backup.LedgerEntryDTO]
            var balanceSnapshots: [ExportService.Backup.SnapshotDTO]
            var incomeRules: [ExportService.Backup.IncomeRuleDTO]
            var forecastSnapshots: [ExportService.Backup.ForecastDTO]
            var milestones: [ExportService.Backup.MilestoneDTO]
            var plannedObligationReserves: [ExportService.Backup.PlannedObligationReserveDTO]
        }
        let history = History(
            planVersions: backup.planVersions,
            paydayPlanItems: backup.paydayPlanItems,
            plannedCardBalances: backup.plannedCardBalances,
            checkIns: backup.checkIns,
            checkInCardPayments: backup.checkInCardPayments,
            ledgerEntries: backup.ledgerEntries,
            balanceSnapshots: backup.balanceSnapshots,
            incomeRules: backup.incomeRules,
            forecastSnapshots: backup.forecastSnapshots,
            milestones: backup.milestones,
            plannedObligationReserves: backup.plannedObligationReserves ?? []
        )
        return String(decoding: try PortableCoding.encoder().encode(history), as: UTF8.self)
    }
}
