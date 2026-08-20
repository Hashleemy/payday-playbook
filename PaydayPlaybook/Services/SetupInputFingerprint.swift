import Foundation
import SwiftData

/// Content fingerprint of the canonical setup inputs a generated plan is
/// built from (V4-02, MVP_LAYOUT §4.7): goal profile, checking accounts,
/// income schedule and future income changes, bills, and debts.
///
/// The fingerprint is each row's identity plus its last-edit stamp, so any
/// content change — including one that keeps row counts equal — produces a
/// different value, and a deletion changes the set. It is the invalidation
/// key for derived setup state ("inputs persist; derivations don't") and the
/// Review step's commit-staleness guard: a plan preview generated under one
/// fingerprint must never persist under another.
///
/// Repositories bump `updatedAt` on every mutation (`SetupRepositories`,
/// `CashAccountRepository`), which is what makes the stamp trustworthy.
struct SetupInputFingerprint: Equatable {
    let value: String

    /// Reads the live store. Lines are sorted so the fingerprint is a
    /// function of content, never of fetch order.
    static func capture(context: ModelContext) throws -> SetupInputFingerprint {
        var lines: [String] = []

        func line(_ family: String, _ id: UUID, _ stamp: Date, archived: Bool = false) -> String {
            "\(family):\(id.uuidString):\(stamp.timeIntervalSinceReferenceDate):\(archived)"
        }

        for row in try context.fetch(FetchDescriptor<UserGoalProfile>()) {
            lines.append(line("profile", row.id, row.updatedAt))
        }
        for row in try context.fetch(FetchDescriptor<CashAccount>()) {
            lines.append(line("account", row.id, row.updatedAt, archived: row.isArchived))
        }
        for row in try context.fetch(FetchDescriptor<IncomeSchedule>()) {
            lines.append(line("income", row.id, row.updatedAt, archived: row.isArchived))
        }
        // Income changes are insert/delete only; creation is their edit stamp.
        for row in try context.fetch(FetchDescriptor<IncomeChange>()) {
            lines.append(line("incomeChange", row.id, row.createdAt))
        }
        for row in try context.fetch(FetchDescriptor<RecurringObligation>()) {
            lines.append(line("bill", row.id, row.updatedAt, archived: row.isArchived))
        }
        for row in try context.fetch(FetchDescriptor<DebtAccount>()) {
            lines.append(line("debt", row.id, row.updatedAt, archived: row.isArchived))
        }

        return SetupInputFingerprint(value: lines.sorted().joined(separator: "\n"))
    }
}
