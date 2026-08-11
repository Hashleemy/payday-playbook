import Foundation
import SwiftData

/// What setup still doesn't know. Drives two screens from one rule set: the
/// onboarding review step ("missing or estimated" list) and the Settings
/// upgrade checklist that migrated users see instead of re-onboarding.
///
/// Nothing here blocks: an item is either a *blocker* (the plan genuinely
/// cannot be generated without it) or a *gap* (the plan works, but a real
/// value would make it more accurate than an estimate).
struct SetupGap: Identifiable, Equatable {
    enum Kind: String {
        case goals
        case accountRoles
        case defaultIncomeAccount
        case income
        case incomeCadenceDays
        case debtType
        case creditLimit
        case originalPrincipal
        case dueDay
        case estimatedMinimum
        case extraPrincipalEligibility
        case obligations
    }

    /// Where the user goes to resolve it.
    enum Destination: String {
        case goals, accounts, debts, income, obligations
    }

    var id: String { "\(kind.rawValue)-\(subjectID?.uuidString ?? "global")" }
    let kind: Kind
    let title: String
    let detail: String
    let destination: Destination
    /// True when plan generation cannot proceed at all.
    let isBlocker: Bool
    /// The row this gap is about, when it is about one row.
    var subjectID: UUID?
    var subjectName: String?
}

struct SetupCompletenessService {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Every unresolved item, blockers first.
    func gaps() throws -> [SetupGap] {
        var gaps: [SetupGap] = []
        gaps.append(contentsOf: try goalGaps())
        gaps.append(contentsOf: try accountGaps())
        gaps.append(contentsOf: try incomeGaps())
        gaps.append(contentsOf: try debtGaps())
        gaps.append(contentsOf: try obligationGaps())
        return gaps.sorted { lhs, rhs in
            if lhs.isBlocker != rhs.isBlocker { return lhs.isBlocker }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    var blockers: [SetupGap] {
        (try? gaps().filter(\.isBlocker)) ?? []
    }

    // MARK: - Goals (V2-02, V2-08, V2-09)

    private func goalGaps() throws -> [SetupGap] {
        let profile = try context.fetch(FetchDescriptor<UserGoalProfile>()).first
        guard let profile else {
            return [SetupGap(
                kind: .goals,
                title: "Your goal and guardrails",
                detail: "Set a payoff posture, a protected cash floor, and a per-paycheck allowance.",
                destination: .goals,
                isBlocker: true
            )]
        }
        // A migrated install has a floor and allowance from its plan but was
        // never asked what it is working toward.
        guard profile.goalText == nil && profile.targetDebtFreeDate == nil else { return [] }
        return [SetupGap(
            kind: .goals,
            title: "What you're working toward",
            detail: "Add a goal or a target date and the dashboard can show your progress against it.",
            destination: .goals,
            isBlocker: false
        )]
    }

    // MARK: - Accounts (V2-03)

    private func accountGaps() throws -> [SetupGap] {
        let repository = CashAccountRepository(context: context)
        let accounts = try repository.activeAccounts()
        guard !accounts.isEmpty else {
            return [SetupGap(
                kind: .accountRoles,
                title: "Your checking accounts",
                detail: "Add at least one account with its balance.",
                destination: .accounts,
                isBlocker: true
            )]
        }
        var gaps: [SetupGap] = []
        for account in accounts where account.roles.isEmpty {
            gaps.append(SetupGap(
                kind: .accountRoles,
                title: "What \"\(account.name)\" is for",
                detail: "Mark whether it receives income, covers day-to-day spending, or holds reserves.",
                destination: .accounts,
                isBlocker: false,
                subjectID: account.id,
                subjectName: account.name
            ))
        }
        if try repository.defaultIncomeAccount() == nil {
            gaps.append(SetupGap(
                kind: .defaultIncomeAccount,
                title: "Which account gets your paycheck",
                detail: "Exactly one account receives income.",
                destination: .accounts,
                isBlocker: true
            ))
        }
        return gaps
    }

    // MARK: - Income (V2-06)

    private func incomeGaps() throws -> [SetupGap] {
        guard let schedule = try IncomeRepository(context: context).activeSchedule() else {
            return [SetupGap(
                kind: .income,
                title: "Your paycheck",
                detail: "Add your take-home amount, your next payday, and how often you're paid.",
                destination: .income,
                isBlocker: true
            )]
        }
        var gaps: [SetupGap] = []
        if schedule.baseTakeHome <= 0 {
            gaps.append(SetupGap(
                kind: .income,
                title: "Your take-home amount",
                detail: "The deposit amount for one paycheck.",
                destination: .income,
                isBlocker: true
            ))
        }
        switch schedule.cadence {
        case .monthly where schedule.monthlyDay == nil:
            gaps.append(SetupGap(
                kind: .incomeCadenceDays,
                title: "Which day of the month you're paid",
                detail: "Monthly pay needs its day of the month.",
                destination: .income,
                isBlocker: true
            ))
        case .semimonthly where schedule.semimonthlyFirstDay == nil || schedule.semimonthlySecondDay == nil:
            gaps.append(SetupGap(
                kind: .incomeCadenceDays,
                title: "Your two paydays each month",
                detail: "Twice-a-month pay needs both days.",
                destination: .income,
                isBlocker: true
            ))
        default:
            break
        }
        return gaps
    }

    // MARK: - Debts (V2-04, V2-05)

    private func debtGaps() throws -> [SetupGap] {
        let debts = try DebtRepository(context: context).activeDebts()
        var gaps: [SetupGap] = []
        for debt in debts {
            // Migrated 0.1.x rows all defaulted to credit card; ask once
            // whether that is really what they are.
            if debt.debtTypeConfirmedAt == nil {
                gaps.append(SetupGap(
                    kind: .debtType,
                    title: "What kind of debt \"\(debt.displayName)\" is",
                    detail: "Confirm the type so the app asks for the right details.",
                    destination: .debts,
                    isBlocker: false,
                    subjectID: debt.id,
                    subjectName: debt.displayName
                ))
            }
            if debt.debtType == .creditCard && debt.creditLimit == nil && !debt.creditLimitMarkedUnknown {
                gaps.append(SetupGap(
                    kind: .creditLimit,
                    title: "Credit limit for \"\(debt.displayName)\"",
                    detail: "With a limit the app can show how much of the card is in use.",
                    destination: .debts,
                    isBlocker: false,
                    subjectID: debt.id,
                    subjectName: debt.displayName
                ))
            }
            if debt.originalPrincipal == nil {
                gaps.append(SetupGap(
                    kind: .originalPrincipal,
                    title: "Original amount for \"\(debt.displayName)\"",
                    detail: "Lets the app show how far you've come, not just what's left.",
                    destination: .debts,
                    isBlocker: false,
                    subjectID: debt.id,
                    subjectName: debt.displayName
                ))
            }
            if debt.dueDayOfMonth == nil {
                gaps.append(SetupGap(
                    kind: .dueDay,
                    title: "Due day for \"\(debt.displayName)\"",
                    detail: "Without it, the minimum is set aside every paycheck instead of timed to the statement.",
                    destination: .debts,
                    isBlocker: false,
                    subjectID: debt.id,
                    subjectName: debt.displayName
                ))
            }
            if debt.minimumAmount == nil {
                if debt.debtType.requiresEnteredMinimum {
                    gaps.append(SetupGap(
                        kind: .estimatedMinimum,
                        title: "Payment amount for \"\(debt.displayName)\"",
                        detail: "\(debt.debtType.displayName) needs its contractual payment.",
                        destination: .debts,
                        isBlocker: true,
                        subjectID: debt.id,
                        subjectName: debt.displayName
                    ))
                } else {
                    gaps.append(SetupGap(
                        kind: .estimatedMinimum,
                        title: "Minimum for \"\(debt.displayName)\" is estimated",
                        detail: "The app estimates it from the balance. Your statement's number is more accurate.",
                        destination: .debts,
                        isBlocker: false,
                        subjectID: debt.id,
                        subjectName: debt.displayName
                    ))
                }
            }
            if debt.debtType != .creditCard && debt.prepayment == .unknown {
                gaps.append(SetupGap(
                    kind: .extraPrincipalEligibility,
                    title: "Extra payments on \"\(debt.displayName)\"",
                    detail: "Until you confirm there's no prepayment penalty, the plan sticks to the required payment.",
                    destination: .debts,
                    isBlocker: false,
                    subjectID: debt.id,
                    subjectName: debt.displayName
                ))
            }
        }
        return gaps
    }

    // MARK: - Obligations (V2-07)

    private func obligationGaps() throws -> [SetupGap] {
        let obligations = try ObligationRepository(context: context).activeObligations()
        guard obligations.isEmpty else { return [] }
        return [SetupGap(
            kind: .obligations,
            title: "Your essential bills",
            detail: "Rent, car, insurance — the app reserves for them before deciding what can go to debt.",
            destination: .obligations,
            isBlocker: false
        )]
    }
}
