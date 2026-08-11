import XCTest
import SwiftData
@testable import PaydayPlaybook

/// V2-03: multiple checking accounts with roles, and the exactly-one-default-
/// income-account invariant under add, edit, re-role, and archive.
final class CashAccountRepositoryTests: XCTestCase {

    private func makeRepository() throws -> (ModelContext, CashAccountRepository) {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        return (context, CashAccountRepository(context: context))
    }

    private func defaultCount(_ context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<CashAccount>())
            .filter { !$0.isArchived && $0.isDefaultIncome }
            .count
    }

    func testFirstAccountBecomesDefaultIncome() throws {
        let (context, repo) = try makeRepository()
        let account = try repo.create(name: "Everyday", currentBalance: TestSupport.money("500.00"), roles: [.spending])
        XCTAssertTrue(account.isDefaultIncome, "Sole account holds the default even without the income role")
        XCTAssertEqual(try defaultCount(context), 1)
    }

    func testIncomeRoleAccountPreferredForDefault() throws {
        let (context, repo) = try makeRepository()
        _ = try repo.create(name: "Spending only", currentBalance: .zero, roles: [.spending])
        // Re-roling later: the default stays where it is until reassigned.
        let all = try repo.activeAccounts()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(try defaultCount(context), 1)

        // Fresh store where an income-role account arrives first.
        let (context2, repo2) = try makeRepository()
        _ = try repo2.create(name: "Paycheck", currentBalance: .zero, roles: [.income])
        _ = try repo2.create(name: "Bills", currentBalance: .zero, roles: [.reserves])
        let income = try XCTUnwrap(repo2.defaultIncomeAccount())
        XCTAssertEqual(income.name, "Paycheck")
        XCTAssertEqual(try defaultCount(context2), 1)
    }

    func testManyAccountsStillExactlyOneDefault() throws {
        let (context, repo) = try makeRepository()
        for index in 1...10 {
            _ = try repo.create(
                name: "Account \(index)",
                currentBalance: TestSupport.money("\(index * 100).00"),
                roles: index % 2 == 0 ? [.income, .spending] : [.reserves]
            )
        }
        XCTAssertEqual(try repo.activeAccounts().count, 10)
        XCTAssertEqual(try defaultCount(context), 1)
    }

    func testSetDefaultIncomeMovesTheFlag() throws {
        let (context, repo) = try makeRepository()
        let first = try repo.create(name: "One", currentBalance: .zero, roles: [.income])
        let second = try repo.create(name: "Two", currentBalance: .zero, roles: [.income])
        XCTAssertTrue(first.isDefaultIncome)
        try repo.setDefaultIncome(second)
        XCTAssertFalse(first.isDefaultIncome)
        XCTAssertTrue(second.isDefaultIncome)
        XCTAssertEqual(try defaultCount(context), 1)
    }

    func testArchivingTheDefaultReassignsIt() throws {
        let (context, repo) = try makeRepository()
        let first = try repo.create(name: "Old main", currentBalance: .zero, roles: [.income, .spending])
        let second = try repo.create(name: "New main", currentBalance: .zero, roles: [.income])
        XCTAssertTrue(first.isDefaultIncome)

        try repo.archive(first)
        XCTAssertTrue(first.isArchived)
        XCTAssertFalse(first.isDefaultIncome)
        XCTAssertTrue(second.isDefaultIncome)
        XCTAssertEqual(try defaultCount(context), 1)

        // Archiving the last account leaves zero defaults — a no-account
        // store is valid mid-onboarding.
        try repo.archive(second)
        XCTAssertEqual(try defaultCount(context), 0)
    }

    func testEditsKeepInvariantAndValidate() throws {
        let (context, repo) = try makeRepository()
        let account = try repo.create(name: "Main", currentBalance: TestSupport.money("100.00"), roles: [.income])
        try repo.update(account, name: "Renamed", currentBalance: TestSupport.money("250.00"), roles: [.income, .reserves])
        XCTAssertEqual(account.name, "Renamed")
        XCTAssertEqual(account.currentBalance, TestSupport.money("250.00"))
        XCTAssertEqual(account.roles, [.income, .reserves])
        XCTAssertEqual(try defaultCount(context), 1)

        XCTAssertThrowsError(try repo.update(account, name: "  ")) { error in
            XCTAssertEqual(error as? ModelValidationError, .emptyName)
        }
        XCTAssertThrowsError(try repo.update(account, currentBalance: TestSupport.money("-1.00"))) { error in
            XCTAssertEqual(error as? ModelValidationError, .negativeAmount(field: "The balance"))
        }
        XCTAssertThrowsError(try repo.update(account, roles: [])) { error in
            XCTAssertEqual(error as? ModelValidationError, .noRoles)
        }
        // Failed validation changed nothing.
        XCTAssertEqual(account.name, "Renamed")
    }

    func testInvariantRepairsMultipleDefaults() throws {
        let (context, repo) = try makeRepository()
        // Simulate rows written without the repository (e.g. a hand-edited
        // backup): two defaults.
        let one = CashAccount(name: "A", currentBalance: .zero, roles: [.income], isDefaultIncome: true, sortOrder: 0)
        let two = CashAccount(name: "B", currentBalance: .zero, roles: [.income], isDefaultIncome: true, sortOrder: 1)
        context.insert(one)
        context.insert(two)
        try repo.ensureDefaultIncomeInvariant()
        try context.save()
        XCTAssertEqual(try defaultCount(context), 1)
        XCTAssertTrue(one.isDefaultIncome, "Display order breaks the tie")
        XCTAssertFalse(two.isDefaultIncome)
    }

    func testAccountsPersistAcrossContexts() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let repo = CashAccountRepository(context: context)
        _ = try repo.create(name: "Main", currentBalance: TestSupport.money("42.42"), roles: [.income, .spending, .reserves])

        let second = ModelContext(container)
        let fetched = try second.fetch(FetchDescriptor<CashAccount>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.currentBalance, TestSupport.money("42.42"))
        XCTAssertEqual(fetched.first?.roles, [.income, .spending, .reserves])
    }
}
