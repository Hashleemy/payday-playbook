import Foundation
import SwiftData

/// Display-order writes for the consolidated Bills & Debts page (V3-08, §5.2
/// item 7).
///
/// Declared here rather than in `SetupRepositories.swift` so the setup-UX
/// surfaces get a repository API without editing a file another agent owns.
/// Both follow `CashAccountRepository.reorder`'s rule: rows the caller did not
/// name keep their relative order *after* the ones that were named, so a
/// partial reorder can never silently shuffle something the user did not touch.

extension DebtRepository {
    /// Sets the listed order of debts.
    ///
    /// This is presentation only. `priority` is the field the debt list sorts
    /// by; the payoff order the plan actually follows is recomputed from APR
    /// and balance by the engine (R-08) and is unaffected by dragging a row.
    func reorder(_ orderedIDs: [UUID], now: Date = Date()) throws {
        let debts = try activeDebts()
        var index = 0
        for id in orderedIDs {
            guard let debt = debts.first(where: { $0.id == id }) else { continue }
            debt.priority = index
            debt.updatedAt = now
            index += 1
        }
        for debt in debts where !orderedIDs.contains(debt.id) {
            debt.priority = index
            debt.updatedAt = now
            index += 1
        }
        try context.save()
    }
}

extension ObligationRepository {
    /// Sets the listed order of bills.
    func reorder(_ orderedIDs: [UUID], now: Date = Date()) throws {
        let obligations = try activeObligations()
        var index = 0
        for id in orderedIDs {
            guard let obligation = obligations.first(where: { $0.id == id }) else { continue }
            obligation.sortOrder = index
            obligation.updatedAt = now
            index += 1
        }
        for obligation in obligations where !orderedIDs.contains(obligation.id) {
            obligation.sortOrder = index
            obligation.updatedAt = now
            index += 1
        }
        try context.save()
    }

    /// Restores an archived bill, so archiving stays a reversible parking
    /// action rather than a soft delete the user cannot undo.
    func restore(_ obligation: RecurringObligation, now: Date = Date()) throws {
        obligation.isArchived = false
        obligation.updatedAt = now
        try context.save()
    }
}
