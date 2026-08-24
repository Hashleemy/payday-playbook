import XCTest
import SwiftData
@testable import PaydayPlaybook

/// T-12 (V3-09): full JSON backup — round trip, older-format import, every
/// rejection path, staged preview redaction, atomic rollback, safety backup.
final class BackupPortingTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let context = ModelContext(try TestSupport.makeContainer())
        return context
    }

    private func service(_ context: ModelContext) -> BackupPortingService {
        BackupPortingService(context: context, dateProvider: PortabilityFixtures.dateProvider)
    }

    // MARK: - Envelope

    func testExportWritesSchemaFourEnvelope() throws {
        let context = try makeContext()
        let setup = try PortabilityFixtures.modernSetup(context)
        try PortabilityFixtures.addHistory(context, setup: setup)

        let data = try ExportService.encodeBackup(try ExportService.buildBackup(context: context))
        let object = try PortabilityFixtures.XCTUnwrapDictionary(data)

        XCTAssertEqual(object["documentKind"] as? String, "fullBackup")
        XCTAssertEqual(object["schemaVersion"] as? Int, 4)
        XCTAssertNotNil(object["exportedAt"])
        XCTAssertNotNil(object["appVersion"])
        XCTAssertNotNil(object["calculationVersion"])
        XCTAssertNotNil(object["integrity"])
        XCTAssertNotNil(object["payload"], "schemas 3+ nest the payload inside the envelope")
    }

    func testProbeClassifiesEnvelopeAndLegacyDocuments() throws {
        let context = try makeContext()
        try PortabilityFixtures.modernSetup(context)

        let current = try ExportService.encodeBackup(try ExportService.buildBackup(context: context))
        let probe = try PortableDocumentProbe.probe(current)
        XCTAssertEqual(probe.documentKind, .fullBackup)
        XCTAssertEqual(probe.schemaVersion, 4)

        // A bare schema-2 object has no documentKind, and absence *means*
        // "legacy full backup" rather than "unknown".
        let legacy = try legacyBackupJSON(context, schemaVersion: 2)
        let legacyProbe = try PortableDocumentProbe.probe(legacy)
        XCTAssertNil(legacyProbe.documentKind)
        XCTAssertEqual(legacyProbe.effectiveKind, .fullBackup)
    }

    // MARK: - Round trip

    func testSchemaThreeRoundTripPreservesEveryRecordAndNewField() throws {
        let source = try makeContext()
        let setup = try PortabilityFixtures.modernSetup(source)
        try PortabilityFixtures.addHistory(source, setup: setup)

        let data = try ExportService.encodeBackup(try ExportService.buildBackup(context: source))

        let target = try makeContext()
        let preview = try service(target).stage(data: data)
        try service(target).commit(preview, createSafetyBackup: false)

        // Counts.
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<CashAccount>()), 2)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<DebtAccount>()), 3)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<RecurringObligation>()), 2)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<LedgerEntry>()), 1)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<BalanceSnapshot>()), 2)

        // Schema-3 fields specifically — the ones a schema-2 exporter would
        // have dropped silently.
        let spending = try XCTUnwrap(
            target.fetch(FetchDescriptor<CashAccount>()).first { $0.name == "Everyday checking" }
        )
        XCTAssertEqual(spending.protectedAmount, TestSupport.money("500.00"))
        XCTAssertEqual(spending.balanceAsOf, PortabilityFixtures.today)

        let profile = try XCTUnwrap(target.fetch(FetchDescriptor<UserGoalProfile>()).first)
        XCTAssertEqual(profile.minimumProtectedCash, TestSupport.money("300.00"))
        XCTAssertEqual(profile.plannedSavingsPerPaycheck, TestSupport.money("100.00"))
        XCTAssertEqual(profile.additionalCushionReserve, TestSupport.money("75.00"))
        XCTAssertEqual(profile.extraPaymentCeiling, TestSupport.money("400.00"))
        XCTAssertNotNil(profile.zeroAllowanceConfirmedAt)

        let entry = try XCTUnwrap(target.fetch(FetchDescriptor<LedgerEntry>()).first)
        XCTAssertEqual(entry.provenance, .user)
    }

    func testRoundTripIsByteStable() throws {
        let source = try makeContext()
        try PortabilityFixtures.modernSetup(source)
        let first = try ExportService.encodeBackup(try ExportService.buildBackup(context: source))

        let target = try makeContext()
        let preview = try service(target).stage(data: first)
        try service(target).commit(preview, createSafetyBackup: false)
        let second = try ExportService.encodeBackup(try ExportService.buildBackup(context: target))

        // `exportedAt` and `appVersion` legitimately differ between two runs;
        // the payload must not.
        let firstPayload = try payload(of: first)
        let secondPayload = try payload(of: second)
        XCTAssertEqual(
            NSDictionary(dictionary: firstPayload), NSDictionary(dictionary: secondPayload),
            "restoring and re-exporting must reproduce the same payload"
        )
    }

    // MARK: - Older formats

    func testImportsSchemaOneAndSchemaTwoDocuments() throws {
        for version in [1, 2] {
            let source = try makeContext()
            try TestSupport.seed(source)
            let data = try legacyBackupJSON(source, schemaVersion: version)

            let target = try makeContext()
            let preview = try service(target).stage(data: data)
            XCTAssertEqual(preview.schemaVersion, version)
            XCTAssertTrue(preview.requiresUpgrade, "format \(version) must be flagged for upgrade")

            let outcome = try service(target).commit(preview, createSafetyBackup: false)
            XCTAssertEqual(outcome.upgradedFromSchema, version)

            // A restored store must land on the *current* schema: one stamped
            // behind the app is indistinguishable from a legacy install and
            // would be migrated a second time on next launch.
            let settings = try XCTUnwrap(target.fetch(FetchDescriptor<AppSettings>()).first)
            XCTAssertEqual(settings.seedSchemaVersion, PlanContract.currentSchemaVersion)
            XCTAssertTrue(settings.onboardingComplete)
        }
    }

    func testNewerSchemaIsRejectedWithAnUpdateMessage() throws {
        let context = try makeContext()
        try PortabilityFixtures.modernSetup(context)
        let data = try PortabilityFixtures.mutatedBackupJSON(context) { object in
            object["schemaVersion"] = 99
            if var payload = object["payload"] as? [String: Any] {
                payload["schemaVersion"] = 99
                object["payload"] = payload
            }
        }
        XCTAssertThrowsError(try service(context).stage(data: data)) { error in
            guard case PortabilityError.unsupportedSchema(let found, _, let highest) = error else {
                return XCTFail("expected unsupportedSchema, got \(error)")
            }
            XCTAssertEqual(found, 99)
            XCTAssertEqual(highest, 4)
            XCTAssertTrue(
                error.localizedDescription.contains("newer version"),
                "a future-format file should tell the user to update, not that their file is broken"
            )
        }
    }

    // MARK: - Rejections

    func testCorruptedFileIsRejected() throws {
        let context = try makeContext()
        let notJSON = Data("this is not a backup".utf8)
        XCTAssertThrowsError(try service(context).stage(data: notJSON)) { error in
            XCTAssertEqual(error as? PortabilityError, .notJSON)
        }

        // Valid JSON, wrong shape: the header is missing entirely.
        let headerless = Data(#"{"hello":"world"}"#.utf8)
        XCTAssertThrowsError(try service(context).stage(data: headerless)) { error in
            XCTAssertEqual(error as? PortabilityError, .malformed("schemaVersion"))
        }

        // Truncated payload: envelope decodes, contents do not.
        let broken = try PortabilityFixtures.mutatedBackupJSON(context) { object in
            object["payload"] = ["schemaVersion": 3]
        }
        XCTAssertThrowsError(try service(context).stage(data: broken))
    }

    func testWrongDocumentKindIsRejectedByName() throws {
        let context = try makeContext()
        try PortabilityFixtures.modernSetup(context)
        let templateService = TemplateImportExportService(
            context: context, dateProvider: PortabilityFixtures.dateProvider
        )
        let templateData = try PortableCoding.encoder().encode(
            templateService.document(for: try templateService.buildPayload(options: .structureOnly))
        )

        XCTAssertThrowsError(try service(context).stage(data: templateData)) { error in
            guard case PortabilityError.wrongDocumentKind(let expected, let found) = error else {
                return XCTFail("expected wrongDocumentKind, got \(error)")
            }
            XCTAssertEqual(expected, .fullBackup)
            XCTAssertEqual(found, .template)
            XCTAssertTrue(error.localizedDescription.contains("Import Template"),
                          "the message should point at the action that does accept this file")
        }
    }

    func testUnknownDocumentKindIsRejected() throws {
        let context = try makeContext()
        try PortabilityFixtures.modernSetup(context)
        let data = try PortabilityFixtures.mutatedBackupJSON(context) { object in
            object["documentKind"] = "somethingElse"
        }
        XCTAssertThrowsError(try service(context).stage(data: data)) { error in
            XCTAssertEqual(error as? PortabilityError, .unknownDocumentKind("somethingElse"))
        }
    }

    func testOversizeFileIsRejectedBeforeDecoding() throws {
        let context = try makeContext()
        let oversize = Data(count: PortableDocumentLimits.maxFileBytes + 1)
        XCTAssertThrowsError(try service(context).stage(data: oversize)) { error in
            guard case PortabilityError.fileTooLarge(_, let limit) = error else {
                return XCTFail("expected fileTooLarge, got \(error)")
            }
            XCTAssertEqual(limit, PortableDocumentLimits.maxFileBytes)
        }
    }

    func testDuplicateIdentifiersAreRejectedRatherThanMerged() throws {
        let context = try makeContext()
        try PortabilityFixtures.modernSetup(context)
        let data = try PortabilityFixtures.mutatedBackupJSON(context) { object in
            guard var payload = object["payload"] as? [String: Any],
                  var debts = payload["debts"] as? [[String: Any]], debts.count >= 2 else { return }
            debts[1]["id"] = debts[0]["id"]
            payload["debts"] = debts
            object["payload"] = payload
            // Keep the declared count honest so integrity is not what fails.
            object["integrity"] = object["integrity"]
        }
        XCTAssertThrowsError(try service(context).stage(data: data)) { error in
            guard case PortabilityError.duplicateIdentifiers(let collection, let count) = error else {
                return XCTFail("expected duplicateIdentifiers, got \(error)")
            }
            XCTAssertEqual(collection, "debts")
            XCTAssertEqual(count, 1)
        }
    }

    func testDanglingRequiredReferenceIsRejected() throws {
        let context = try makeContext()
        try PortabilityFixtures.setupWithPlan(context)
        let data = try PortabilityFixtures.mutatedBackupJSON(context) { object in
            guard var payload = object["payload"] as? [String: Any],
                  var items = payload["paydayPlanItems"] as? [[String: Any]], !items.isEmpty else { return }
            items[0]["planVersionID"] = UUID().uuidString
            payload["paydayPlanItems"] = items
            object["payload"] = payload
        }
        XCTAssertThrowsError(try service(context).stage(data: data)) { error in
            guard case PortabilityError.danglingReferences(let collection, let field, _) = error else {
                return XCTFail("expected danglingReferences, got \(error)")
            }
            XCTAssertEqual(collection, "paydayPlanItems")
            XCTAssertEqual(field, "planVersionID")
        }
    }

    func testTamperedRecordCountIsCaughtByIntegrity() throws {
        let context = try makeContext()
        try PortabilityFixtures.modernSetup(context)
        let data = try PortabilityFixtures.mutatedBackupJSON(context) { object in
            guard var payload = object["payload"] as? [String: Any],
                  var debts = payload["debts"] as? [[String: Any]], !debts.isEmpty else { return }
            debts.removeLast()
            payload["debts"] = debts
            object["payload"] = payload
        }
        XCTAssertThrowsError(try service(context).stage(data: data)) { error in
            guard case PortabilityError.integrityMismatch(let collection, let declared, let found) = error else {
                return XCTFail("expected integrityMismatch, got \(error)")
            }
            XCTAssertEqual(collection, "debts")
            XCTAssertEqual(declared, 3)
            XCTAssertEqual(found, 2)
        }
    }

    func testUnreadableAmountNamesTheFieldNotTheValue() throws {
        let context = try makeContext()
        try PortabilityFixtures.modernSetup(context)
        let data = try PortabilityFixtures.mutatedBackupJSON(context) { object in
            guard var payload = object["payload"] as? [String: Any],
                  var debts = payload["debts"] as? [[String: Any]], !debts.isEmpty else { return }
            debts[0]["startingBalance"] = "not-a-number"
            payload["debts"] = debts
            object["payload"] = payload
        }
        XCTAssertThrowsError(try service(context).stage(data: data)) { error in
            guard case PortabilityError.amountUnreadable(let collection, let field) = error else {
                return XCTFail("expected amountUnreadable, got \(error)")
            }
            XCTAssertEqual(collection, "debts")
            XCTAssertEqual(field, "startingBalance")
            // V3-13: an error string reaches screenshots and bug reports.
            XCTAssertFalse(error.localizedDescription.contains("not-a-number"))
        }
    }

    // MARK: - Preview redaction

    func testStagedPreviewShowsCountsAndCategoriesNotAmounts() throws {
        let source = try makeContext()
        let setup = try PortabilityFixtures.modernSetup(source)
        try PortabilityFixtures.addHistory(source, setup: setup)
        let data = try ExportService.encodeBackup(try ExportService.buildBackup(context: source))

        let target = try makeContext()
        let preview = try service(target).stage(data: data)

        XCTAssertEqual(preview.documentKind, .fullBackup)
        XCTAssertEqual(preview.counts.first { $0.label == "Debts" }?.count, 3)
        XCTAssertEqual(preview.counts.first { $0.label == "Checking accounts" }?.count, 2)
        XCTAssertTrue(preview.categories.contains { $0.contains("credit card") })

        // The redaction claim, checked literally: no amount the fixture holds
        // appears anywhere in what the preview would render.
        let rendered = ([preview.categories, preview.warnings].flatMap { $0 }
            + preview.counts.map { "\($0.label) \($0.count)" }).joined(separator: " ")
        for amount in ["2400", "3200", "1450", "6800", "2000", "1100"] {
            XCTAssertFalse(rendered.contains(amount), "preview leaked the amount \(amount)")
        }
        XCTAssertFalse(rendered.contains("Blue card"), "preview leaked a debt label")
    }

    func testDetailsAreAvailableOnlyThroughExplicitReveal() throws {
        let source = try makeContext()
        try PortabilityFixtures.modernSetup(source)
        let data = try ExportService.encodeBackup(try ExportService.buildBackup(context: source))

        let target = try makeContext()
        let preview = try service(target).stage(data: data)

        let details = preview.revealDetails()
        XCTAssertEqual(details.debts.count, 3)
        XCTAssertTrue(details.debts.contains { $0.label == "Blue card" })
        XCTAssertTrue(details.accounts.contains { $0.value.contains("2,400") })
    }

    // MARK: - Atomicity

    func testStagingNeverTouchesTheStore() throws {
        let context = try makeContext()
        let setup = try PortabilityFixtures.modernSetup(context)
        try PortabilityFixtures.addHistory(context, setup: setup)
        let before = try storeFingerprint(context)

        let other = try makeContext()
        try TestSupport.seed(other)
        let data = try ExportService.encodeBackup(try ExportService.buildBackup(context: other))

        _ = try service(context).stage(data: data)

        XCTAssertEqual(try storeFingerprint(context), before,
                       "staging a foreign backup must leave the current store byte-identical")
    }

    func testFailedCommitRollsBackAndLeavesDataUnchanged() throws {
        let context = try makeContext()
        let setup = try PortabilityFixtures.modernSetup(context)
        try PortabilityFixtures.addHistory(context, setup: setup)
        let before = try storeFingerprint(context)

        // A schema-1 document whose reserves cannot be inverted by R-04 makes
        // the legacy upgrade abort *after* the delete-and-insert, which is the
        // only point where a restore can fail with rows already gone.
        let legacySource = try makeContext()
        try TestSupport.seed(legacySource, applySchemaUpgrade: false)
        let poisoned = try PortabilityFixtures.mutatedBackupJSON(legacySource) { object in
            object["documentKind"] = nil
            object["schemaVersion"] = 1
            if let payload = object["payload"] as? [String: Any] {
                for (key, value) in payload { object[key] = value }
            }
            object["payload"] = nil
            object["integrity"] = nil
            object["schemaVersion"] = 1
            // Break the inverse-R-04 round trip the §7 derivation verifies.
            if var plans = object["planVersions"] as? [[String: Any]], !plans.isEmpty {
                plans[0]["carReservePerCheck"] = "0.007"
                plans[0]["trainReservePerCheck"] = "0.003"
                object["planVersions"] = plans
            }
        }

        let staged = try? service(context).stage(data: poisoned)
        if let staged {
            XCTAssertThrowsError(try service(context).commit(staged, createSafetyBackup: false)) { error in
                XCTAssertTrue(error is RestoreCommitFailure)
            }
        }
        XCTAssertEqual(try storeFingerprint(context), before,
                       "a failed restore must leave the store exactly as it was")
    }

    func testCancellingAStagedRestoreChangesNothing() throws {
        let context = try makeContext()
        let setup = try PortabilityFixtures.modernSetup(context)
        try PortabilityFixtures.addHistory(context, setup: setup)
        let before = try storeFingerprint(context)

        let other = try makeContext()
        try TestSupport.seed(other)
        let data = try ExportService.encodeBackup(try ExportService.buildBackup(context: other))

        // Staging, previewing, revealing details, then walking away.
        var preview: RestorePreview? = try service(context).stage(data: data)
        _ = preview?.revealDetails()
        preview = nil

        XCTAssertEqual(try storeFingerprint(context), before)
    }

    // MARK: - Safety backup

    func testCommitWritesASafetyBackupOfThePreviousData() throws {
        PortableFileStore.purge(.safety)
        let context = try makeContext()
        let setup = try PortabilityFixtures.modernSetup(context)
        try PortabilityFixtures.addHistory(context, setup: setup)
        let before = try storeFingerprint(context)

        let other = try makeContext()
        try PortabilityFixtures.modernSetup(other)
        // A store that differs from the current one, so a successful restore
        // is observable.
        let extra = PortabilityFixtures.debt(
            planID: "D9", name: "Store card", balance: "500.00", apr: "0.2499",
            minimum: "25.00", dueDay: 9, priority: 9, type: .creditCard
        )
        other.insert(extra)
        try other.save()
        let data = try ExportService.encodeBackup(try ExportService.buildBackup(context: other))

        let preview = try service(context).stage(data: data)
        let outcome = try service(context).commit(preview, createSafetyBackup: true)

        let safetyURL = try XCTUnwrap(outcome.safetyBackupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: safetyURL.path))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DebtAccount>()), 4)

        // The safety file must actually restore the previous data — a backup
        // that cannot be restored is not a safety net.
        let recovery = try makeContext()
        let safetyData = try Data(contentsOf: safetyURL)
        let recoveryPreview = try service(recovery).stage(data: safetyData)
        try service(recovery).commit(recoveryPreview, createSafetyBackup: false)
        XCTAssertEqual(try storeFingerprint(recovery), before)

        PortableFileStore.purge(.safety)
    }

    func testSafetyBackupsArePrunedByCount() throws {
        PortableFileStore.purge(.safety)
        let context = try makeContext()
        try PortabilityFixtures.modernSetup(context)

        for index in 0..<(PortableFileStore.safetyBackupKeepCount + 3) {
            let provider = FixedDateProvider(
                fixed: PortabilityFixtures.today.addingTimeInterval(Double(index) * 3600)
            )
            _ = try BackupPortingService(context: context, dateProvider: provider).writeSafetyBackup()
        }
        XCTAssertLessThanOrEqual(
            PortableFileStore.files(in: .safety).count,
            PortableFileStore.safetyBackupKeepCount
        )
        PortableFileStore.purge(.safety)
    }

    // MARK: - Helpers

    /// A structural fingerprint of the store: every collection's count plus a
    /// sorted digest of the values a restore could disturb. Compared before
    /// and after an operation that must not change anything.
    private func storeFingerprint(_ context: ModelContext) throws -> String {
        let backup = try ExportService.buildBackup(context: context)
        let payload = try PortableCoding.encoder().encode(backup)
        // `exportedAt` is stamped at build time and legitimately differs.
        var object = try PortabilityFixtures.XCTUnwrapDictionary(payload)
        object["exportedAt"] = nil
        let normalized = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: normalized, as: UTF8.self)
    }

    private func payload(of data: Data) throws -> [String: Any] {
        let object = try PortabilityFixtures.XCTUnwrapDictionary(data)
        var payload = try XCTUnwrap(object["payload"] as? [String: Any])
        payload["exportedAt"] = nil
        payload["appVersion"] = nil
        return payload
    }

    /// Re-encodes the current store as a bare pre-envelope document, the shape
    /// v0.2.0 and v0.1.x wrote.
    private func legacyBackupJSON(_ context: ModelContext, schemaVersion: Int) throws -> Data {
        var backup = try ExportService.buildBackup(context: context)
        backup.schemaVersion = schemaVersion
        let encoder = PortableCoding.encoder()
        return try encoder.encode(backup)
    }
}
