import Foundation
import SwiftData

/// Assembles a `FinancialReport` from the user's saved inputs and the same
/// calculations the app shows on screen (V3-11).
///
/// Two rules govern everything here:
///
/// 1. **Nothing is computed twice.** Scenarios come from
///    `ScenarioCalculationService`, insights from `ExtraPaymentInsightService`,
///    the plan from `PlanGenerationService`, the calendar from
///    `CalendarEventService`. A report that recomputed its own payoff date
///    would eventually print a number the app disagrees with, and the printed
///    one is the one the user would act on.
/// 2. **Empty and missing are printed, not hidden.** A section with no data
///    says so; a scenario the app cannot compute prints what it still needs.
///    A report that silently omits a section reads as "there is nothing to
///    report", which is a different and false claim.
struct FinancialReportBuilder {
    let context: ModelContext
    let dateProvider: DateProviding

    init(context: ModelContext, dateProvider: DateProviding = SystemDateProvider()) {
        self.context = context
        self.dateProvider = dateProvider
    }

    // MARK: - Entry point

    /// Replaces user-entered labels inside generated prose when the user asked
    /// for a masked report.
    ///
    /// Masking the table columns is not enough: the engine writes sentences
    /// like "Enter <debt>'s required monthly payment", and the scenario,
    /// shortfall, warning, and assumption text all carry names the user typed.
    /// A report that masks the tables and prints the names in the paragraph
    /// underneath has not masked anything.
    ///
    /// Substring replacement is best-effort by nature — a debt literally named
    /// "Card" would also rewrite the word "Card" elsewhere. Longest names are
    /// replaced first so one label never partially consumes another, and the
    /// direction of the error is safe: it over-masks rather than under-masks.
    struct LabelMask {
        private let replacements: [(String, String)]

        init(replacements: [(String, String)]) {
            self.replacements = replacements
                .filter { !$0.0.trimmingCharacters(in: .whitespaces).isEmpty }
                .sorted { $0.0.count > $1.0.count }
        }

        static let none = LabelMask(replacements: [])

        func scrub(_ text: String) -> String {
            guard !replacements.isEmpty else { return text }
            var scrubbed = text
            for (original, masked) in replacements {
                scrubbed = scrubbed.replacingOccurrences(of: original, with: masked)
            }
            return scrubbed
        }
    }

    private func labelMask(_ config: ReportConfiguration) throws -> LabelMask {
        guard config.privacyOptions.maskNames else { return .none }
        var replacements: [(String, String)] = []
        for (index, debt) in try context.fetch(FetchDescriptor<DebtAccount>())
            .sorted(by: { $0.priority < $1.priority }).enumerated() {
            replacements.append((debt.displayName, "Debt \(index + 1)"))
        }
        for (index, account) in try context.fetch(FetchDescriptor<CashAccount>())
            .sorted(by: { $0.sortOrder < $1.sortOrder }).enumerated() {
            replacements.append((account.name, "Account \(index + 1)"))
        }
        for (index, bill) in try context.fetch(FetchDescriptor<RecurringObligation>())
            .sorted(by: { $0.createdAt < $1.createdAt }).enumerated() {
            replacements.append((bill.name, "Bill \(index + 1)"))
        }
        return LabelMask(replacements: replacements)
    }

    func build(_ config: ReportConfiguration) throws -> FinancialReport {
        let now = dateProvider.now
        let snapshot = try? PlanningInputBuilder(context: context).build(asOf: DateMath.startOfDay(now))
        let plan = try PlanRepository.currentPlan(context: context)
        let mask = try labelMask(config)

        var sections: [ReportSection] = []
        for section in ReportConfiguration.Section.allCases where config.includes(section) {
            let blocks: [ReportBlock]
            switch section {
            case .currentInputs: blocks = try currentInputsBlocks(config, snapshot: snapshot)
            case .accounts: blocks = try accountsBlocks(config)
            case .billsAndDebts: blocks = try billsAndDebtsBlocks(config)
            case .activePlan: blocks = try activePlanBlocks(config, plan: plan)
            case .nextActions: blocks = try nextActionsBlocks(config, snapshot: snapshot)
            case .scenarioComparison: blocks = scenarioBlocks(config, snapshot: snapshot, now: now)
            case .extraPaymentInsight: blocks = extraPaymentBlocks(config, snapshot: snapshot)
            case .payoffProjection: blocks = payoffBlocks(config, snapshot: snapshot)
            case .upcomingActions: blocks = try upcomingActionBlocks(config, now: now)
            }
            sections.append(ReportSection(id: section.rawValue, title: section.title, blocks: blocks))
        }

        if config.includeAppendix {
            sections.append(appendixSection(config, snapshot: snapshot))
        }

        return FinancialReport(
            title: "Financial report",
            subtitle: subtitle(for: config),
            generatedAt: now,
            range: config.dateRange,
            // Applied once, over the finished content, rather than at each of
            // the two dozen places a name can reach the page. A privacy
            // control that depends on every future call site remembering it
            // is a privacy control that will eventually be forgotten.
            sections: sections.map { Self.scrubbed($0, with: mask) },
            disclaimer: Self.disclaimer
        )
    }

    private static func scrubbed(_ section: ReportSection, with mask: LabelMask) -> ReportSection {
        ReportSection(
            id: section.id,
            title: mask.scrub(section.title),
            blocks: section.blocks.map { scrubbed($0, with: mask) }
        )
    }

    private static func scrubbed(_ block: ReportBlock, with mask: LabelMask) -> ReportBlock {
        switch block {
        case .paragraph(let text):
            return .paragraph(mask.scrub(text))
        case .subheading(let text):
            return .subheading(mask.scrub(text))
        case .empty(let text):
            return .empty(mask.scrub(text))
        case .bullets(let items):
            return .bullets(items.map(mask.scrub))
        case .keyValues(let values):
            return .keyValues(values.map {
                ReportKeyValue(
                    label: mask.scrub($0.label),
                    value: mask.scrub($0.value),
                    emphasis: $0.emphasis,
                    note: $0.note.map(mask.scrub)
                )
            })
        case .table(let table):
            var scrubbed = table
            scrubbed.rows = table.rows.map { row in
                row.map { ReportCell(mask.scrub($0.text), emphasis: $0.emphasis) }
            }
            scrubbed.footnote = table.footnote.map(mask.scrub)
            scrubbed.truncationNote = table.truncationNote.map(mask.scrub)
            return .table(scrubbed)
        case .callout(let callout):
            return .callout(ReportCallout(
                title: mask.scrub(callout.title),
                lines: callout.lines.map(mask.scrub),
                tone: callout.tone
            ))
        case .chart(let chart):
            var scrubbed = chart
            scrubbed.bars = chart.bars.map {
                var bar = $0
                bar.label = mask.scrub($0.label)
                return bar
            }
            return .chart(scrubbed)
        }
    }

    private func subtitle(for config: ReportConfiguration) -> String {
        let range = "\(DateMath.mediumString(config.dateRange.start)) – \(DateMath.mediumString(config.dateRange.end))"
        return "\(range) · \(config.detailLevel.title)"
    }

    static let disclaimer = [
        "These figures are estimates produced from the information you entered. They are not a statement from any lender, bank, or advisor.",
        "Real interest, posting dates, and minimum payments will differ from the model. Interest is estimated per accrual period on a 365-day year and settled at each paycheck; payments are modeled as posting on the payday that funds them.",
        "Nothing in this report is financial advice. Confirm every balance and due date with the institution that holds the account before acting on it."
    ]

    // MARK: - Current inputs

    private func currentInputsBlocks(
        _ config: ReportConfiguration,
        snapshot: StoredPlanInput?
    ) throws -> [ReportBlock] {
        let profile = try context.fetch(FetchDescriptor<UserGoalProfile>()).first
        let schedule = try context.fetch(FetchDescriptor<IncomeSchedule>()).first { !$0.isArchived }

        var values: [ReportKeyValue] = []
        if let schedule {
            values.append(ReportKeyValue(
                label: "Pay schedule",
                value: PayCadence(rawValue: schedule.cadenceRaw)?.displayName ?? schedule.cadenceRaw
            ))
            if !config.privacyOptions.omitBalances {
                values.append(ReportKeyValue(
                    label: "Take-home per paycheck",
                    value: MoneyFormat.string(schedule.baseTakeHome)
                ))
            }
        }
        if let next = snapshot?.nextPayday {
            values.append(ReportKeyValue(label: "Next payday", value: DateMath.mediumString(next)))
        }
        if let profile {
            values.append(ReportKeyValue(label: "Payoff posture", value: profile.posture.displayName))
            if !config.privacyOptions.omitBalances {
                values.append(ReportKeyValue(
                    label: "Protected floor",
                    value: MoneyFormat.string(profile.protectedFloor)
                ))
                values.append(ReportKeyValue(
                    label: "Spending allowance per paycheck",
                    value: MoneyFormat.string(profile.allowanceCap)
                ))
            }
            if let target = profile.targetDebtFreeDate {
                values.append(ReportKeyValue(label: "Target debt-free date", value: DateMath.mediumString(target)))
            }
        }

        guard !values.isEmpty else {
            return [.empty("No pay schedule or guardrails have been set up yet.")]
        }

        var blocks: [ReportBlock] = [.keyValues(values)]

        // Scenario constraints, listed only when stated. A blank line for an
        // unset constraint would read as "zero", which is a different answer.
        if let profile, !config.privacyOptions.omitBalances {
            let constraints: [(String, Decimal)] = [
                ("Least cash kept in checking", profile.minimumProtectedCash),
                ("Planned savings per paycheck", profile.plannedSavingsPerPaycheck),
                ("Extra cushion held back", profile.additionalCushionReserve),
                ("Most you'd put toward one extra payment", profile.extraPaymentCeiling)
            ].filter { $0.1.rounded2 > 0 }

            if constraints.isEmpty {
                blocks.append(.paragraph(
                    "No payoff-scenario limits have been set. The scenarios below will name what each one still needs."
                ))
            } else {
                blocks.append(.subheading("Scenario limits you've set"))
                blocks.append(.keyValues(constraints.map {
                    ReportKeyValue(label: $0.0, value: MoneyFormat.string($0.1))
                }))
            }
        }
        return blocks
    }

    // MARK: - Accounts

    private func accountsBlocks(_ config: ReportConfiguration) throws -> [ReportBlock] {
        let accounts = try context.fetch(FetchDescriptor<CashAccount>())
            .filter { config.entityScope.includesAccount($0.id) }
            .filter { config.entityScope.includeArchived || !$0.isArchived }
            .sorted { $0.sortOrder < $1.sortOrder }

        guard !accounts.isEmpty else {
            return [.empty("No checking accounts have been added yet.")]
        }
        if config.privacyOptions.omitBalances {
            return [.table(ReportTable(
                columns: [
                    ReportColumn(title: "Account", weight: 2.2),
                    ReportColumn(title: "Role", weight: 1.8),
                    ReportColumn(title: "Status", alignment: .trailing, weight: 1)
                ],
                rows: accounts.enumerated().map { index, account in
                    [
                        ReportCell(displayName(for: account, index: index, config: config)),
                        ReportCell(account.roles.map(\.displayName).sorted().joined(separator: ", ")),
                        ReportCell(account.isArchived ? "Archived" : "Active")
                    ]
                },
                footnote: "Balances were left out of this report."
            ))]
        }

        var rows: [[ReportCell]] = []
        var total = Decimal.zero
        var totalAvailable = Decimal.zero
        for (index, account) in accounts.enumerated() {
            // Available is derived, never stored: a spending account's usable
            // cash is its balance less the amount the plan protects.
            let available = account.currentBalance - account.protectedAmount
            total += account.currentBalance
            totalAvailable += available
            rows.append([
                ReportCell(displayName(for: account, index: index, config: config)),
                ReportCell(account.roles.map(\.displayName).sorted().joined(separator: ", ")),
                ReportCell(MoneyFormat.string(account.currentBalance),
                           emphasis: account.currentBalance < 0 ? .attention : .normal),
                ReportCell(MoneyFormat.string(account.protectedAmount)),
                ReportCell(MoneyFormat.string(available), emphasis: available < 0 ? .attention : .normal),
                ReportCell(account.balanceAsOf.map(DateMath.mediumString) ?? "Not stated")
            ])
        }

        var blocks: [ReportBlock] = [.table(ReportTable(
            columns: [
                ReportColumn(title: "Account", weight: 2),
                ReportColumn(title: "Role", weight: 1.8),
                ReportColumn(title: "Balance", alignment: .trailing, weight: 1.2),
                ReportColumn(title: "Protected", alignment: .trailing, weight: 1.2),
                ReportColumn(title: "Available", alignment: .trailing, weight: 1.2),
                ReportColumn(title: "As of", alignment: .trailing, weight: 1.3)
            ],
            rows: rows,
            footnote: "Available is the balance minus the amount you've protected. It is not a bank figure."
        ))]

        blocks.append(.keyValues([
            ReportKeyValue(label: "Total balance", value: MoneyFormat.string(total),
                           emphasis: total < 0 ? .attention : .strong),
            ReportKeyValue(label: "Total available", value: MoneyFormat.string(totalAvailable),
                           emphasis: totalAvailable < 0 ? .attention : .strong)
        ]))

        if accounts.contains(where: { $0.balanceAsOf == nil }) {
            blocks.append(.callout(ReportCallout(
                title: "Some balances have no date",
                lines: ["An account with no \"as of\" date is showing the last figure you entered, which may be out of date."],
                tone: .caution
            )))
        }
        if totalAvailable < 0 {
            blocks.append(.callout(ReportCallout(
                title: "Available cash is negative",
                lines: ["Your protected amounts add up to more than your balances. The plan will report a shortfall until that resolves."],
                tone: .caution
            )))
        }
        return blocks
    }

    // MARK: - Bills and debts

    private func billsAndDebtsBlocks(_ config: ReportConfiguration) throws -> [ReportBlock] {
        var blocks: [ReportBlock] = []

        let bills = try context.fetch(FetchDescriptor<RecurringObligation>())
            .filter { config.entityScope.includesObligation($0.id) }
            .filter { config.entityScope.includeArchived || !$0.isArchived }
            .sorted { ($0.dueDay ?? 99, $0.name) < ($1.dueDay ?? 99, $1.name) }

        blocks.append(.subheading("Bills"))
        if bills.isEmpty {
            blocks.append(.empty("No recurring bills have been added."))
        } else {
            let rows = bills.enumerated().map { index, bill -> [ReportCell] in
                var cells = [
                    ReportCell(config.privacyOptions.maskNames ? "Bill \(index + 1)" : bill.name),
                    ReportCell(bill.cadence.displayName),
                    ReportCell(bill.dueDay.map { "Day \($0)" } ?? "Not set")
                ]
                if !config.privacyOptions.omitBalances {
                    cells.append(ReportCell(MoneyFormat.string(bill.amount), emphasis: .normal))
                }
                cells.append(ReportCell(bill.isEssential ? "Essential" : "Flexible"))
                return cells
            }
            var columns = [
                ReportColumn(title: "Bill", weight: 2.4),
                ReportColumn(title: "How often", weight: 1.6),
                ReportColumn(title: "Due", weight: 1)
            ]
            if !config.privacyOptions.omitBalances {
                columns.append(ReportColumn(title: "Amount", alignment: .trailing, weight: 1.2))
            }
            columns.append(ReportColumn(title: "Type", alignment: .trailing, weight: 1.1))
            blocks.append(.table(capped(ReportTable(columns: columns, rows: rows), config)))

            if !config.privacyOptions.omitBalances {
                // The R-04 smoothing rule with twelve "paychecks" a year is
                // exactly a monthly equivalent. Reused rather than restated so
                // a quarterly bill is annualized the same way here as in the
                // plan the report describes.
                let monthly = bills.filter { !$0.isArchived }.reduce(Decimal.zero) {
                    $0 + ObligationMath.perPaycheckReserve(
                        amount: $1.amount, cadence: $1.cadence, paychecksPerYear: 12
                    )
                }
                blocks.append(.keyValues([
                    ReportKeyValue(label: "Bills per month (equivalent)",
                                   value: MoneyFormat.string(monthly), emphasis: .strong)
                ]))
            }
        }

        let debts = try context.fetch(FetchDescriptor<DebtAccount>())
            .filter { config.entityScope.includesDebt($0.id) }
            .filter { config.entityScope.includeArchived || !$0.isArchived }
            .sorted { $0.priority < $1.priority }

        blocks.append(.subheading("Debts"))
        if debts.isEmpty {
            blocks.append(.empty("No debts have been added."))
            return blocks
        }

        let rows = debts.enumerated().map { index, debt -> [ReportCell] in
            var cells = [
                ReportCell(displayName(for: debt, index: index, config: config)),
                ReportCell(debt.debtType.displayName)
            ]
            if !config.privacyOptions.omitBalances {
                cells.append(ReportCell(MoneyFormat.string(debt.startingBalance),
                                        emphasis: debt.startingBalance < 0 ? .attention : .normal))
            }
            cells.append(ReportCell(Self.percent(debt.apr)))
            if !config.privacyOptions.omitBalances {
                cells.append(ReportCell(debt.minimumAmount.map(MoneyFormat.string) ?? "Estimated"))
            }
            cells.append(ReportCell(debt.dueDayOfMonth.map { "Day \($0)" } ?? "Not set"))
            return cells
        }
        var columns = [
            ReportColumn(title: "Debt", weight: 2.2),
            ReportColumn(title: "Type", weight: 1.5)
        ]
        if !config.privacyOptions.omitBalances {
            columns.append(ReportColumn(title: "Balance", alignment: .trailing, weight: 1.3))
        }
        columns.append(ReportColumn(title: "APR", alignment: .trailing, weight: 0.9))
        if !config.privacyOptions.omitBalances {
            columns.append(ReportColumn(title: "Minimum", alignment: .trailing, weight: 1.2))
        }
        columns.append(ReportColumn(title: "Due", alignment: .trailing, weight: 1))

        blocks.append(.table(capped(ReportTable(
            columns: columns,
            rows: rows,
            footnote: debts.contains { $0.minimumAmount == nil }
                ? "\"Estimated\" minimums use the greater of $17.50 or 0.5% of the balance."
                : nil
        ), config)))

        if !config.privacyOptions.omitBalances {
            let total = debts.filter { !$0.isArchived }.reduce(Decimal.zero) { $0 + $1.startingBalance }
            blocks.append(.keyValues([
                ReportKeyValue(label: "Total debt", value: MoneyFormat.string(total), emphasis: .strong)
            ]))
        }
        return blocks
    }

    // MARK: - Active plan

    private func activePlanBlocks(
        _ config: ReportConfiguration,
        plan: PlanVersion?
    ) throws -> [ReportBlock] {
        guard let plan else {
            return [.empty("No plan has been generated yet. Finish setup to generate one.")]
        }
        var values: [ReportKeyValue] = [
            ReportKeyValue(label: "Plan", value: plan.name, emphasis: .strong),
            ReportKeyValue(label: "Status", value: plan.isActive ? "Active" : "Not active"),
            ReportKeyValue(label: "Created", value: DateMath.mediumString(plan.createdAt)),
            ReportKeyValue(label: "Calculation version", value: "v\(plan.calculationVersion)")
        ]
        if let kind = plan.scenarioKindRaw {
            values.append(ReportKeyValue(label: "Created from scenario", value: kind))
        }
        if let effective = plan.effectiveDate {
            values.append(ReportKeyValue(label: "Takes effect", value: DateMath.mediumString(effective)))
        }
        if plan.isOriginalBaseline {
            values.append(ReportKeyValue(label: "Baseline", value: "Immutable — kept for comparison"))
        }

        let items = try PlanRepository.planItems(context: context, plan: plan)
        values.append(ReportKeyValue(label: "Paydays in plan", value: "\(items.count)"))
        if let next = items.first(where: { $0.date >= DateMath.startOfDay(dateProvider.now) }) {
            values.append(ReportKeyValue(label: "Next payday in plan", value: DateMath.mediumString(next.date)))
        }

        var blocks: [ReportBlock] = [.keyValues(values)]
        let completed = try context.fetch(FetchDescriptor<PaydayCheckIn>())
            .filter { $0.status == .completed }.count
        if completed > 0 {
            blocks.append(.paragraph("\(completed) payday check-in(s) recorded."))
        }
        return blocks
    }

    // MARK: - Next actions

    private func nextActionsBlocks(
        _ config: ReportConfiguration,
        snapshot: StoredPlanInput?
    ) throws -> [ReportBlock] {
        guard let snapshot, let generated = try? PlanGenerationService.generate(from: snapshot),
              let next = generated.result.paychecks.first else {
            return [.empty("There is no upcoming paycheck to plan. Check your income setup.")]
        }

        let debtNames = try debtNameLookup(config)
        var values: [ReportKeyValue] = [
            ReportKeyValue(label: "Payday", value: DateMath.mediumString(next.date), emphasis: .strong)
        ]
        if !config.privacyOptions.omitBalances {
            values.append(ReportKeyValue(label: "Expected income", value: MoneyFormat.string(next.income)))
            values.append(ReportKeyValue(label: "Keep in spending", value: MoneyFormat.string(next.keepInSpending)))
            values.append(ReportKeyValue(label: "Move to reserves", value: MoneyFormat.string(next.transferToReserves)))
            values.append(ReportKeyValue(label: "Toward debt", value: MoneyFormat.string(next.minimumsTotal + next.extraTotal)))
        }
        if let target = next.targetDebtID {
            values.append(ReportKeyValue(label: "Extra principal goes to", value: debtNames[target] ?? "—"))
        }

        var blocks: [ReportBlock] = [.keyValues(values)]

        if !next.payments.isEmpty, !config.privacyOptions.omitBalances {
            blocks.append(.subheading("Payments on this payday"))
            blocks.append(.table(ReportTable(
                columns: [
                    ReportColumn(title: "Debt", weight: 2.4),
                    ReportColumn(title: "Minimum", alignment: .trailing, weight: 1.2),
                    ReportColumn(title: "Extra", alignment: .trailing, weight: 1.2),
                    ReportColumn(title: "Total", alignment: .trailing, weight: 1.2)
                ],
                rows: next.payments.map { payment in
                    [
                        ReportCell(debtNames[payment.debtID] ?? "—"),
                        ReportCell(MoneyFormat.string(payment.minimum)),
                        ReportCell(MoneyFormat.string(payment.extra)),
                        ReportCell(MoneyFormat.string(payment.total), emphasis: .strong)
                    ]
                }
            )))
        }

        if let shortfall = next.shortfall {
            blocks.append(.callout(ReportCallout(
                title: "This paycheck is short",
                lines: [
                    shortfall.explanation,
                    "Gap: \(MoneyFormat.string(shortfall.gap))."
                ],
                tone: .caution
            )))
        }
        return blocks
    }

    // MARK: - Scenarios

    private func scenarioBlocks(
        _ config: ReportConfiguration,
        snapshot: StoredPlanInput?,
        now: Date
    ) -> [ReportBlock] {
        guard let snapshot else {
            return [.empty("Payoff scenarios need your income, accounts, and debts before they can be compared.")]
        }
        let profile = try? context.fetch(FetchDescriptor<UserGoalProfile>()).first
        let definitions = ScenarioDefinitionBuilder.definitions(
            profile: profile ?? nil, effectiveDate: DateMath.startOfDay(now)
        )
        guard let results = try? ScenarioCalculationService.scenarios(from: snapshot, definitions: definitions) else {
            return [.empty("Payoff scenarios could not be calculated from the current setup.")]
        }

        var blocks: [ReportBlock] = [.paragraph(
            "Three ways to finish, all using the same balances and interest rules. Balanced is the recommended pace; none of these is applied to your plan by generating this report."
        )]

        blocks.append(.table(ReportTable(
            columns: [
                ReportColumn(title: "Scenario", weight: 2),
                ReportColumn(title: "Debt-free", alignment: .trailing, weight: 1.4),
                ReportColumn(title: "Time", alignment: .trailing, weight: 1.1),
                ReportColumn(title: "Interest", alignment: .trailing, weight: 1.3),
                ReportColumn(title: "Kept per check", alignment: .trailing, weight: 1.4)
            ],
            rows: results.map { result in
                let name = result.kind.displayName + (result.kind.isRecommended ? " (recommended)" : "")
                guard result.isComputable else {
                    return [
                        ReportCell(name),
                        ReportCell("Needs input", emphasis: .attention),
                        ReportCell("—"), ReportCell("—"), ReportCell("—")
                    ]
                }
                return [
                    ReportCell(name, emphasis: result.kind.isRecommended ? .strong : .normal),
                    ReportCell(result.payoffDate.map(DateMath.mediumString) ?? "Not within horizon"),
                    ReportCell(result.duration.map { "\($0.months) mo" } ?? "—"),
                    ReportCell(MoneyFormat.string(result.estimatedTotalInterest)),
                    ReportCell(MoneyFormat.string(result.cashRetainedPerPaycheck))
                ]
            },
            footnote: "\"Kept per check\" is money that stays in your spending account: allowance, floor top-ups, and planned savings."
        )))

        // Two charts, never one with two axes: interest is dollars and time is
        // months, and a shared axis would misrepresent whichever measure lost.
        let computable = results.filter(\.isComputable)
        if computable.count >= 2 {
            blocks.append(.chart(ReportMagnitudeChart(
                title: "Estimated interest paid",
                caption: "Shorter is cheaper.",
                bars: computable.map {
                    ReportMagnitudeChart.Bar(
                        label: $0.kind.displayName,
                        value: Self.double($0.estimatedTotalInterest),
                        displayValue: MoneyFormat.whole($0.estimatedTotalInterest),
                        isRecommended: $0.kind.isRecommended
                    )
                }
            )))
            blocks.append(.chart(ReportMagnitudeChart(
                title: "Months to debt-free",
                caption: "Shorter is sooner.",
                bars: computable.map {
                    ReportMagnitudeChart.Bar(
                        label: $0.kind.displayName,
                        value: Double($0.duration?.months ?? 0),
                        displayValue: $0.duration.map { "\($0.months) mo" } ?? "—",
                        isRecommended: $0.kind.isRecommended
                    )
                }
            )))
        }

        for result in results where !result.missingInputs.isEmpty {
            blocks.append(.callout(ReportCallout(
                title: "\(result.kind.displayName) needs more information",
                lines: result.missingInputs.map(\.message),
                tone: .caution
            )))
        }

        // Deltas are only meaningful against a Balanced run that happened.
        let deltas = results.compactMap { result -> String? in
            guard let delta = result.deltaVsBalanced, result.isComputable else { return nil }
            let interest = delta.interestDelta
            let days = delta.timeDelta
            guard interest != 0 || days != 0 else { return nil }
            let interestPart = interest < 0
                ? "\(MoneyFormat.whole(-interest)) less interest"
                : "\(MoneyFormat.whole(interest)) more interest"
            let timePart = days < 0 ? "\(-days) days sooner" : "\(days) days later"
            return "\(result.kind.displayName): \(interestPart), \(timePart) than Balanced."
        }
        if !deltas.isEmpty {
            blocks.append(.subheading("Compared with Balanced"))
            blocks.append(.bullets(deltas))
        }
        return blocks
    }

    // MARK: - Extra payment

    private func extraPaymentBlocks(
        _ config: ReportConfiguration,
        snapshot: StoredPlanInput?
    ) -> [ReportBlock] {
        guard let extra = config.extraPayment else {
            return [.empty("No extra payment was specified for this report.")]
        }
        guard let snapshot,
              let insight = try? ExtraPaymentInsightService.insight(from: snapshot, extra: extra) else {
            return [.empty("The extra-payment estimate could not be calculated from the current setup.")]
        }

        guard insight.isComputable else {
            return [.callout(ReportCallout(
                title: "This estimate needs more information",
                lines: insight.missingInputs.map(\.message),
                tone: .caution
            ))]
        }

        let debtNames = (try? debtNameLookup(config)) ?? [:]
        var values: [ReportKeyValue] = [
            ReportKeyValue(label: "Extra payment", value: MoneyFormat.string(insight.amount), emphasis: .strong),
            ReportKeyValue(label: "Starting", value: DateMath.mediumString(insight.effectiveDate)),
            ReportKeyValue(
                label: "Goes to",
                value: insight.targetDebtID.flatMap { debtNames[$0] } ?? "No eligible debt",
                note: insight.targetWasAutomatic ? "Chosen automatically — highest effective APR" : nil
            )
        ]
        if let saved = insight.interestSaved {
            values.append(ReportKeyValue(label: "Interest saved", value: MoneyFormat.string(saved), emphasis: .strong))
        }
        if let days = insight.daysSaved {
            values.append(ReportKeyValue(label: "Debt-free sooner by", value: "\(days) days"))
        }
        values.append(ReportKeyValue(
            label: "Principal knocked down",
            value: MoneyFormat.string(insight.projectedPrincipalReduction)
        ))

        var blocks: [ReportBlock] = [.keyValues(values)]

        if !insight.downstreamChanges.isEmpty {
            blocks.append(.subheading("How each debt moves"))
            blocks.append(.table(ReportTable(
                columns: [
                    ReportColumn(title: "Debt", weight: 2.4),
                    ReportColumn(title: "Paid off before", alignment: .trailing, weight: 1.5),
                    ReportColumn(title: "Paid off after", alignment: .trailing, weight: 1.5),
                    ReportColumn(title: "Change", alignment: .trailing, weight: 1.2)
                ],
                rows: insight.downstreamChanges.map { change in
                    [
                        ReportCell(debtNames[change.debtID] ?? change.name),
                        ReportCell(change.payoffDateBefore.map(DateMath.mediumString) ?? "—"),
                        ReportCell(change.payoffDateAfter.map(DateMath.mediumString) ?? "—"),
                        ReportCell(change.daysChanged.map { $0 <= 0 ? "\(-$0) days sooner" : "\($0) days later" } ?? "—")
                    ]
                }
            )))
        }
        if !insight.warnings.isEmpty {
            blocks.append(.callout(ReportCallout(
                title: "Worth knowing",
                lines: insight.warnings.map(\.message),
                tone: .caution
            )))
        }
        return blocks
    }

    // MARK: - Payoff projection

    private func payoffBlocks(
        _ config: ReportConfiguration,
        snapshot: StoredPlanInput?
    ) -> [ReportBlock] {
        guard let snapshot, let generated = try? PlanGenerationService.generate(from: snapshot) else {
            return [.empty("A payoff projection needs your income, accounts, and debts.")]
        }
        let result = generated.result
        guard !result.debtSummaries.isEmpty else {
            return [.empty("There are no debts to project.")]
        }

        var values: [ReportKeyValue] = []
        if let payoff = result.forecastPayoffDate {
            values.append(ReportKeyValue(label: "Projected debt-free", value: DateMath.mediumString(payoff), emphasis: .strong))
        } else {
            values.append(ReportKeyValue(
                label: "Projected debt-free",
                value: "Not reached in this projection",
                emphasis: .attention
            ))
        }
        values.append(ReportKeyValue(label: "Paychecks modeled", value: "\(result.paycheckCount)"))
        if !config.privacyOptions.omitBalances {
            values.append(ReportKeyValue(label: "Estimated interest", value: MoneyFormat.string(result.estimatedTotalInterest)))
            values.append(ReportKeyValue(label: "Debt remaining now", value: MoneyFormat.string(result.totalRemainingPrincipal)))
        }

        var blocks: [ReportBlock] = [.keyValues(values)]

        let ordered = result.payoffOrder.compactMap { id in
            result.debtSummaries.first { $0.debtID == id }
        }
        let summaries = ordered.isEmpty ? result.debtSummaries : ordered
        blocks.append(.subheading("Payoff order"))
        blocks.append(.table(capped(ReportTable(
            columns: {
                var columns = [
                    ReportColumn(title: "#", weight: 0.5),
                    ReportColumn(title: "Debt", weight: 2.2),
                    ReportColumn(title: "APR", alignment: .trailing, weight: 0.9),
                    ReportColumn(title: "Projected payoff", alignment: .trailing, weight: 1.6)
                ]
                if !config.privacyOptions.omitBalances {
                    columns.append(ReportColumn(title: "Interest", alignment: .trailing, weight: 1.2))
                }
                return columns
            }(),
            rows: summaries.enumerated().map { index, summary in
                var cells = [
                    ReportCell("\(index + 1)"),
                    ReportCell(config.privacyOptions.maskNames ? "Debt \(index + 1)" : summary.name),
                    ReportCell(Self.percent(summary.apr)),
                    ReportCell(summary.payoffDate.map(DateMath.mediumString) ?? "Beyond horizon",
                               emphasis: summary.payoffDate == nil ? .attention : .normal)
                ]
                if !config.privacyOptions.omitBalances {
                    cells.append(ReportCell(MoneyFormat.string(summary.interestPaid)))
                }
                return cells
            }
        ), config)))

        if result.notPayableAsConfigured {
            blocks.append(.callout(ReportCallout(
                title: "Not payable as configured",
                lines: ["With these inputs the projection reaches its limit before the debts are cleared. Raising the amount going to debt, or lowering a guardrail, changes that."],
                tone: .caution
            )))
        }
        if let comparison = result.minimumOnlyComparison, let saved = comparison.interestSaved,
           !config.privacyOptions.omitBalances {
            blocks.append(.paragraph(
                "Compared with paying only minimums, this plan saves about \(MoneyFormat.whole(saved)) in interest"
                + (comparison.daysSaved.map { " and finishes about \($0) days sooner" } ?? "") + "."
            ))
        }
        return blocks
    }

    // MARK: - 30/60/90-day actions

    private func upcomingActionBlocks(_ config: ReportConfiguration, now: Date) throws -> [ReportBlock] {
        let service = CalendarEventService(context: context, dateProvider: dateProvider)
        let start = DateMath.startOfDay(now)
        let windows: [(String, Int, Int)] = [
            ("Next 30 days", 0, 30),
            ("Days 31–60", 30, 60),
            ("Days 61–90", 60, 90)
        ]

        var blocks: [ReportBlock] = []
        var any = false
        for (title, from, to) in windows {
            let windowStart = DateMath.addingDays(from, to: start)
            let windowEnd = DateMath.addingDays(to, to: start)
            // Clipped to the user's chosen range: a 30-day report should not
            // print 90 days of events just because the section exists.
            let events = (try? service.events(from: windowStart, to: windowEnd))?
                .filter { config.dateRange.contains($0.date) }
                .sorted { $0.date < $1.date } ?? []

            blocks.append(.subheading(title))
            guard !events.isEmpty else {
                blocks.append(.empty("Nothing scheduled in this window."))
                continue
            }
            any = true
            blocks.append(.table(capped(ReportTable(
                columns: [
                    ReportColumn(title: "Date", weight: 1.3),
                    ReportColumn(title: "What", weight: 1.4),
                    ReportColumn(title: "Detail", weight: 3)
                ],
                rows: events.map { event in
                    [
                        ReportCell(DateMath.mediumString(event.date)),
                        ReportCell(event.kind.label),
                        ReportCell(config.privacyOptions.maskNames ? event.kind.label : event.title)
                    ]
                }
            ), config)))
        }
        if !any {
            return [.empty("Nothing is scheduled in the next 90 days within this report's date range.")]
        }
        return blocks
    }

    // MARK: - Appendix

    private func appendixSection(
        _ config: ReportConfiguration,
        snapshot: StoredPlanInput?
    ) -> ReportSection {
        var blocks: [ReportBlock] = []

        if let snapshot, let generated = try? PlanGenerationService.generate(from: snapshot) {
            let result = generated.result

            if !result.assumptions.isEmpty {
                blocks.append(.subheading("Assumptions this projection makes"))
                blocks.append(.bullets(Self.uniqueMessages(result.assumptions)))
            }
            if !result.warnings.isEmpty {
                blocks.append(.subheading("Warnings"))
                blocks.append(.bullets(Self.uniqueMessages(result.warnings)))
            }

            // The paycheck-by-paycheck schedule is the longest thing the report
            // can print, so it is full-detail only and lives at the back.
            if config.detailLevel == .full {
                let paychecks = result.paychecks.filter { config.dateRange.contains($0.date) }
                blocks.append(.subheading("Paycheck schedule"))
                if paychecks.isEmpty {
                    blocks.append(.empty("No paychecks fall inside this report's date range."))
                } else if config.privacyOptions.omitBalances {
                    blocks.append(.paragraph("Amounts were left out of this report."))
                } else {
                    blocks.append(.table(ReportTable(
                        columns: [
                            ReportColumn(title: "#", weight: 0.5),
                            ReportColumn(title: "Date", weight: 1.4),
                            ReportColumn(title: "Income", alignment: .trailing, weight: 1.1),
                            ReportColumn(title: "Keep", alignment: .trailing, weight: 1.1),
                            ReportColumn(title: "Reserves", alignment: .trailing, weight: 1.1),
                            ReportColumn(title: "To debt", alignment: .trailing, weight: 1.1),
                            ReportColumn(title: "Debt after", alignment: .trailing, weight: 1.2)
                        ],
                        rows: paychecks.map { paycheck in
                            [
                                ReportCell("\(paycheck.sequence)"),
                                ReportCell(DateMath.mediumString(paycheck.date)),
                                ReportCell(MoneyFormat.string(paycheck.income)),
                                ReportCell(MoneyFormat.string(paycheck.keepInSpending)),
                                ReportCell(MoneyFormat.string(paycheck.transferToReserves)),
                                ReportCell(MoneyFormat.string(paycheck.minimumsTotal + paycheck.extraTotal)),
                                ReportCell(MoneyFormat.string(paycheck.totalDebtAfter))
                            ]
                        },
                        footnote: "Every row balances: income and windfall equal what you keep plus what you move."
                    )))
                }
            }
        }

        blocks.append(.subheading("How this report was made"))
        blocks.append(.bullets([
            "Generated on this device from the data you entered. Nothing was uploaded.",
            "Date range: \(DateMath.mediumString(config.dateRange.start)) to \(DateMath.mediumString(config.dateRange.end)).",
            "Detail level: \(config.detailLevel.title).",
            config.privacyOptions.maskNames ? "Names were replaced with generic labels." : "Names are as you entered them.",
            config.privacyOptions.omitBalances ? "Balances were left out." : "Balances are as of the dates shown."
        ]))

        return ReportSection(id: "appendix", title: "Appendix", blocks: blocks)
    }

    // MARK: - Helpers

    private func capped(_ table: ReportTable, _ config: ReportConfiguration) -> ReportTable {
        guard let limit = config.detailLevel.tableRowLimit, table.rows.count > limit else { return table }
        var capped = table
        let hidden = table.rows.count - limit
        capped.rows = Array(table.rows.prefix(limit))
        capped.truncationNote = "\(hidden) more row(s) not shown at \(config.detailLevel.title.lowercased()) detail."
        return capped
    }

    private func debtNameLookup(_ config: ReportConfiguration) throws -> [UUID: String] {
        let debts = try context.fetch(FetchDescriptor<DebtAccount>()).sorted { $0.priority < $1.priority }
        var lookup: [UUID: String] = [:]
        for (index, debt) in debts.enumerated() {
            lookup[debt.id] = config.privacyOptions.maskNames ? "Debt \(index + 1)" : debt.displayName
        }
        return lookup
    }

    private func displayName(for account: CashAccount, index: Int, config: ReportConfiguration) -> String {
        config.privacyOptions.maskNames ? "Account \(index + 1)" : account.name
    }

    private func displayName(for debt: DebtAccount, index: Int, config: ReportConfiguration) -> String {
        config.privacyOptions.maskNames ? "Debt \(index + 1)" : debt.displayName
    }

    private static func percent(_ apr: Decimal) -> String {
        let percent = (apr * 100).rounded2
        return "\(percent)%"
    }

    private static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }

    /// Notes de-duplicated by message: the engine emits one per debt, and a
    /// report that repeats "interest is an estimate" six times reads as noise.
    private static func uniqueMessages(_ notes: [PlanningNote]) -> [String] {
        var seen = Set<String>()
        return notes.compactMap { seen.insert($0.message).inserted ? $0.message : nil }
    }
}
