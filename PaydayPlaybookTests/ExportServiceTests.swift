import XCTest
import SwiftData
@testable import PaydayPlaybook

/// F-14: JSON round trip and CSV correctness.
final class ExportServiceTests: XCTestCase {

    private func seededContextWithActivity() throws -> ModelContext {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        try TestSupport.seed(context)
        let debts = try context.fetch(FetchDescriptor<DebtAccount>())
        let cardB = try XCTUnwrap(debts.first { $0.planID == "B" })
        context.insert(LedgerEntry(
            effectiveDate: TestSupport.date(2026, 8, 20),
            type: .cardPayment,
            amount: TestSupport.money("1061.07"),
            sourceAccount: .checking2,
            destinationAccount: .card,
            debtAccountID: cardB.id,
            debtPlanID: "B",
            note: "First, payday \"attack\""
        ))
        context.insert(BalanceSnapshot(
            debtAccountID: cardB.id,
            debtPlanID: "B",
            effectiveDate: TestSupport.date(2026, 8, 20),
            amount: .zero,
            sourceType: .currentOnlineBalance
        ))
        try context.save()
        return context
    }

    func testJSONRoundTripRestoresEquivalentRecords() throws {
        let context = try seededContextWithActivity()
        let backup = try ExportService.buildBackup(context: context)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup)
        let decoded = try ExportService.readBackup(from: data)

        // Restore into a fresh store.
        let freshContainer = try TestSupport.makeContainer()
        let fresh = ModelContext(freshContainer)
        try ExportService.restore(decoded, context: fresh)

        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<PlanVersion>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<DebtAccount>()), 6)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<PaydayPlanItem>()), 23)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<PlannedCardBalance>()), 23 * 6)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<LedgerEntry>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<BalanceSnapshot>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Milestone>()), 12)

        // Decimals survive the round trip exactly.
        let plan = try XCTUnwrap(fresh.fetch(FetchDescriptor<PlanVersion>()).first)
        XCTAssertEqual(plan.baselineModeledInterest, TestSupport.money("3461.16"))
        XCTAssertEqual(plan.carReservePerCheck, TestSupport.money("335.08"))
        let entry = try XCTUnwrap(fresh.fetch(FetchDescriptor<LedgerEntry>()).first)
        XCTAssertEqual(entry.amount, TestSupport.money("1061.07"))
        XCTAssertEqual(entry.type, .cardPayment)
        XCTAssertEqual(entry.debtPlanID, "B")
        let debts = try fresh.fetch(FetchDescriptor<DebtAccount>())
        XCTAssertEqual(
            debts.reduce(Decimal.zero) { $0 + $1.startingBalance },
            TestSupport.money("29681.61")
        )
    }

    func testRestoreRejectsUnsupportedSchema() throws {
        let context = try seededContextWithActivity()
        var backup = try ExportService.buildBackup(context: context)
        backup.schemaVersion = 99
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup)
        XCTAssertThrowsError(try ExportService.readBackup(from: data)) { error in
            guard case ExportService.ExportError.unsupportedSchema(99) = error else {
                return XCTFail("Expected unsupportedSchema, got \(error)")
            }
        }
    }

    func testLedgerCSVHeaderAndValues() throws {
        let context = try seededContextWithActivity()
        let csv = try ExportService.ledgerCSV(context: context)
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "date,type,amount,source,destination,card,note,isCorrection,auditNote")
        XCTAssertEqual(lines.count, 2)
        let row = lines[1]
        XCTAssertTrue(row.contains("2026-08-20"))
        XCTAssertTrue(row.contains("cardPayment"))
        XCTAssertTrue(row.contains("1061.07"))
        // Comma- and quote-bearing notes are escaped per RFC 4180.
        XCTAssertTrue(row.contains("\"First, payday \"\"attack\"\"\""))
    }

    func testOtherCSVHeaders() throws {
        let context = try seededContextWithActivity()
        XCTAssertTrue(try ExportService.snapshotsCSV(context: context)
            .hasPrefix("effectiveDate,account,card,amount,sourceType,isAuthoritative,note"))
        XCTAssertTrue(try ExportService.debtsCSV(context: context)
            .hasPrefix("planID,displayName,startingBalance,apr,minimum,dueDay,priority,archived"))
        XCTAssertTrue(try ExportService.checkInsCSV(context: context)
            .hasPrefix("payday,date,status,actualIncome,outsideFunds,c1Kept,c1Balance,allowanceSpent,c2Transfer,carReserve,trainReserve,unallocated,completedAt,exception"))
        let debtsCSV = try ExportService.debtsCSV(context: context)
        XCTAssertTrue(debtsCSV.contains("B,Card B,1049.00,0.2999"))
    }

    func testDeleteAllClearsEveryModel() throws {
        let context = try seededContextWithActivity()
        try ExportService.deleteAll(context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlanVersion>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DebtAccount>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PaydayPlanItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BalanceSnapshot>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Milestone>()), 0)
    }
}
