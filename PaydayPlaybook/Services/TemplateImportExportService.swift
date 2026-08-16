import Foundation
import SwiftData

/// User-owned, structure-only JSON templates (V3-10), implementing
/// `TemplatePorting`.
///
/// A template answers "set me up the way I set myself up" — pay cadence, which
/// roles the accounts play, what kinds of bills and debts exist, how reminders
/// are configured — without carrying what any of it is worth. That separation
/// is the whole point: v0.2.0 shipped one real person's finances as a bundled
/// template, and the lesson (soul.md amendment 4) is that a plan full of
/// values is not a template.
///
/// The payload is an **allow-list**, not a redaction pass. `TemplatePayload`
/// has no field for a check-in, a ledger row, a plan event, or a free-text
/// note, so no amount of misconfiguration can emit one — a category the user
/// never opts into simply has nowhere to go. Money fields exist but are
/// optional and left nil unless the user names that category explicitly.
protocol TemplatePorting {
    func exportTemplate(options: TemplateExportOptions) throws -> URL
    func preview(data: Data) throws -> TemplatePreview
    @discardableResult
    func apply(_ preview: TemplatePreview, mode: TemplateApplyMode) throws -> TemplateApplyOutcome
}

// MARK: - Sensitive categories

/// Categories of real data a user may deliberately add to a template.
///
/// Everything here is **off** by default. Each case's `warning` enumerates
/// exactly what turning it on will write into a file the user may hand to
/// someone else — a vague "this may include personal data" is not consent.
enum TemplateSensitiveCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case displayNames
    case balances
    case incomeAmounts
    case billAmounts
    case guardrails

    var id: String { rawValue }

    var title: String {
        switch self {
        case .displayNames: return "Names and labels"
        case .balances: return "Balances and principal"
        case .incomeAmounts: return "Income amounts"
        case .billAmounts: return "Bill amounts and minimum payments"
        case .guardrails: return "Guardrail amounts"
        }
    }

    var warning: String {
        switch self {
        case .displayNames:
            return "Includes the names you gave your accounts, bills, and debts, and any last-four digits."
        case .balances:
            return "Includes each account's current balance and protected amount, and each debt's current balance, original principal, and credit limit."
        case .incomeAmounts:
            return "Includes your take-home pay per paycheck."
        case .billAmounts:
            return "Includes each bill's amount and each debt's minimum payment."
        case .guardrails:
            return "Includes your protected floor, spending allowance, and the scenario limits you set (minimum protected cash, planned savings, cushion reserve, extra-payment ceiling)."
        }
    }
}

/// What the exporter always leaves out, regardless of options — recorded here
/// so the UI can state it and a test can pin it.
enum TemplateStructuralExclusion: String, CaseIterable {
    case history = "Payday check-ins and recorded payments"
    case ledger = "Ledger entries and balance snapshots"
    case planEvents = "Plans, paydays, projected balances, and plan events"
    case notes = "Notes and free text"
    case milestones = "Milestones and forecasts"

    /// These have no field in `TemplatePayload` at all. The exclusion is
    /// structural rather than a filter someone can forget to apply.
    static var all: [String] { allCases.map(\.rawValue) }
}

// MARK: - Payload

/// The allow-listed template document (MVP_LAYOUT §6).
///
/// Money is carried as optional strings for the same reason the backup carries
/// it that way — `Decimal` has no lossless JSON number form — and nil here
/// carries real meaning: "this category was not included", not "zero".
struct TemplatePayload: Codable, Equatable {

    struct Account: Codable, Equatable {
        /// `AccountRole` raw values, sorted.
        var roles: [String]
        var isDefaultIncome: Bool
        var sortOrder: Int
        var name: String?
        var currentBalance: String?
        var protectedAmount: String?
    }

    struct Bill: Codable, Equatable {
        var cadence: String
        var dueDay: Int?
        var isEssential: Bool
        var name: String?
        var amount: String?
    }

    struct Debt: Codable, Equatable {
        var debtType: String
        /// Lender terms, not personal values: an APR and a due day describe the
        /// agreement's shape and are what make a template reusable at all.
        var apr: String
        var dueDayOfMonth: Int?
        var priority: Int
        var prepayment: String
        var isExtraPrincipalEligible: Bool
        var creditLimitMarkedUnknown: Bool
        var name: String?
        var lastFour: String?
        var startingBalance: String?
        var originalPrincipal: String?
        var creditLimit: String?
        var minimumAmount: String?
    }

    struct Income: Codable, Equatable {
        var cadence: String
        var monthlyDay: Int?
        var semimonthlyFirstDay: Int?
        var semimonthlySecondDay: Int?
        /// Deliberately no anchor payday: a specific date is a fact about the
        /// exporting user's calendar, and the importer supplies their own.
        var baseTakeHome: String?
    }

    struct Reminder: Codable, Equatable {
        var type: String
        var enabled: Bool
        var hour: Int
        var minute: Int
        var leadDays: Int
        var detailedLockScreenContent: Bool
    }

    struct Settings: Codable, Equatable {
        var posture: String
        var protectedFloor: String?
        var allowanceCap: String?
        var minimumProtectedCash: String?
        var plannedSavingsPerPaycheck: String?
        var additionalCushionReserve: String?
        var extraPaymentCeiling: String?
    }

    var accounts: [Account] = []
    var bills: [Bill] = []
    var debts: [Debt] = []
    var income: Income?
    var reminders: [Reminder] = []
    var settings: Settings?
    /// Categories the exporter deliberately included, so an importer's preview
    /// can say what the file carries without inspecting every field.
    var includedSensitiveCategories: [String] = []
}

// MARK: - Options, preview, outcome

struct TemplateExportOptions: Equatable {
    /// Empty means a pure structure template — the default.
    var includedCategories: Set<TemplateSensitiveCategory> = []
    var includeArchived: Bool = false

    static let structureOnly = TemplateExportOptions()

    func includes(_ category: TemplateSensitiveCategory) -> Bool {
        includedCategories.contains(category)
    }

    /// The warnings a confirmation sheet must show before writing the file.
    var warnings: [String] {
        includedCategories
            .sorted { $0.rawValue < $1.rawValue }
            .map { "\($0.title): \($0.warning)" }
    }
}

enum TemplateApplyMode: String, CaseIterable, Identifiable {
    /// Fill gaps only: add what is missing, never overwrite an existing value.
    case merge
    /// Add every template entity as a new record, leaving current setup alone.
    case add

    var id: String { rawValue }

    var title: String {
        switch self {
        case .merge: return "Merge with my setup"
        case .add: return "Add as new records"
        }
    }

    var explanation: String {
        switch self {
        case .merge:
            return "Adds anything you don't already have and fills in settings you haven't set. Nothing you've already entered is changed."
        case .add:
            return "Adds every account, bill, and debt in this template as a new record. Your current setup is left exactly as it is."
        }
    }
}

struct TemplatePreview {
    struct Count: Identifiable, Equatable {
        var label: String
        var count: Int
        var id: String { label }
    }

    var schemaVersion: Int
    var appVersion: String?
    var exportedAt: Date?
    var counts: [Count]
    var categories: [String]
    /// Sensitive categories this file actually carries.
    var includedCategories: [TemplateSensitiveCategory]
    /// What the format never carries, for display alongside the above.
    var structuralExclusions: [String] = TemplateStructuralExclusion.all
    var warnings: [String]

    fileprivate let payload: TemplatePayload
}

struct TemplateApplyOutcome: Equatable {
    var accountsAdded: Int = 0
    var billsAdded: Int = 0
    var debtsAdded: Int = 0
    var remindersAdded: Int = 0
    var incomeApplied: Bool = false
    var settingsApplied: Bool = false
    /// Entities skipped in merge mode because a counterpart already existed.
    var skipped: [String] = []
    /// Entities that could not be created because the template deliberately
    /// left out a value the app requires — a bill's amount, an installment
    /// debt's contractual payment, a pay schedule's take-home.
    ///
    /// These are reported, never filled in. A bill with an invented amount
    /// would flow straight into the per-paycheck reserve math and produce a
    /// plan built on a number nobody entered (V3-06).
    var needsValues: [String] = []
    /// Records whose template identity was replaced with a fresh one. Templates
    /// never carry IDs, so this is always the full count of added rows — stated
    /// explicitly rather than left implicit (MVP_LAYOUT §6: remapped, never
    /// silently merged).
    var remappedIdentifiers: Int = 0
}

// MARK: - Service

struct TemplateImportExportService: TemplatePorting {
    static let templateSchemaVersion = 3
    static let importableSchemaVersions = 1...3

    let context: ModelContext
    let dateProvider: DateProviding

    init(context: ModelContext, dateProvider: DateProviding = SystemDateProvider()) {
        self.context = context
        self.dateProvider = dateProvider
    }

    // MARK: Export

    func buildPayload(options: TemplateExportOptions) throws -> TemplatePayload {
        var payload = TemplatePayload()

        let accounts = try context.fetch(FetchDescriptor<CashAccount>())
            .filter { options.includeArchived || !$0.isArchived }
            .sorted { $0.sortOrder < $1.sortOrder }
        payload.accounts = accounts.map { account in
            TemplatePayload.Account(
                roles: account.roles.map(\.rawValue).sorted(),
                isDefaultIncome: account.isDefaultIncome,
                sortOrder: account.sortOrder,
                name: options.includes(.displayNames) ? account.name : nil,
                currentBalance: options.includes(.balances) ? money(account.currentBalance) : nil,
                protectedAmount: options.includes(.balances) ? money(account.protectedAmount) : nil
            )
        }

        let bills = try context.fetch(FetchDescriptor<RecurringObligation>())
            .filter { options.includeArchived || !$0.isArchived }
            .sorted { $0.createdAt < $1.createdAt }
        payload.bills = bills.map { bill in
            TemplatePayload.Bill(
                cadence: bill.cadenceRaw,
                dueDay: bill.dueDay,
                isEssential: bill.isEssential,
                name: options.includes(.displayNames) ? bill.name : nil,
                amount: options.includes(.billAmounts) ? money(bill.amount) : nil
            )
        }

        let debts = try context.fetch(FetchDescriptor<DebtAccount>())
            .filter { options.includeArchived || !$0.isArchived }
            .sorted { $0.priority < $1.priority }
        payload.debts = debts.map { debt in
            TemplatePayload.Debt(
                debtType: debt.debtTypeRaw,
                apr: money(debt.apr),
                dueDayOfMonth: debt.dueDayOfMonth,
                priority: debt.priority,
                prepayment: debt.prepayment.rawValue,
                isExtraPrincipalEligible: debt.isExtraPrincipalEligible,
                creditLimitMarkedUnknown: debt.creditLimitMarkedUnknown,
                name: options.includes(.displayNames) ? debt.displayName : nil,
                lastFour: options.includes(.displayNames) ? debt.lastFour : nil,
                startingBalance: options.includes(.balances) ? money(debt.startingBalance) : nil,
                originalPrincipal: options.includes(.balances) ? money(debt.originalPrincipal) : nil,
                creditLimit: options.includes(.balances) ? money(debt.creditLimit) : nil,
                minimumAmount: options.includes(.billAmounts) ? money(debt.minimumAmount) : nil
            )
        }

        if let schedule = try context.fetch(FetchDescriptor<IncomeSchedule>())
            .first(where: { !$0.isArchived }) {
            payload.income = TemplatePayload.Income(
                cadence: schedule.cadenceRaw,
                monthlyDay: schedule.monthlyDay,
                semimonthlyFirstDay: schedule.semimonthlyFirstDay,
                semimonthlySecondDay: schedule.semimonthlySecondDay,
                baseTakeHome: options.includes(.incomeAmounts) ? money(schedule.baseTakeHome) : nil
            )
        }

        payload.reminders = try context.fetch(FetchDescriptor<NotificationPreference>())
            .sorted { $0.typeRaw < $1.typeRaw }
            .map {
                TemplatePayload.Reminder(
                    type: $0.typeRaw, enabled: $0.enabled, hour: $0.hour, minute: $0.minute,
                    leadDays: $0.leadDays, detailedLockScreenContent: $0.detailedLockScreenContent
                )
            }

        if let profile = try context.fetch(FetchDescriptor<UserGoalProfile>()).first {
            let guardrails = options.includes(.guardrails)
            payload.settings = TemplatePayload.Settings(
                posture: profile.postureRaw,
                protectedFloor: guardrails ? money(profile.protectedFloor) : nil,
                allowanceCap: guardrails ? money(profile.allowanceCap) : nil,
                minimumProtectedCash: guardrails ? money(profile.minimumProtectedCash) : nil,
                plannedSavingsPerPaycheck: guardrails ? money(profile.plannedSavingsPerPaycheck) : nil,
                additionalCushionReserve: guardrails ? money(profile.additionalCushionReserve) : nil,
                extraPaymentCeiling: guardrails ? money(profile.extraPaymentCeiling) : nil
            )
        }

        payload.includedSensitiveCategories = options.includedCategories
            .map(\.rawValue).sorted()
        return payload
    }

    func document(for payload: TemplatePayload) -> PortableDocument<TemplatePayload> {
        PortableDocument(
            documentKind: .template,
            schemaVersion: Self.templateSchemaVersion,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            calculationVersion: PlanContract.currentCalculationVersion,
            exportedAt: dateProvider.now,
            integrity: Self.integrity(of: payload),
            payload: payload
        )
    }

    static func integrity(of payload: TemplatePayload) -> PortableIntegrity {
        PortableIntegrity(recordCounts: [
            "accounts": payload.accounts.count,
            "bills": payload.bills.count,
            "debts": payload.debts.count,
            "reminders": payload.reminders.count,
            "income": payload.income == nil ? 0 : 1,
            "settings": payload.settings == nil ? 0 : 1
        ])
    }

    func exportTemplate(options: TemplateExportOptions) throws -> URL {
        let data = try PortableCoding.encoder().encode(document(for: try buildPayload(options: options)))
        return try PortableFileStore.write(
            data,
            named: "PaydayPlaybook-Template-\(PortableFileStore.timestamp(dateProvider.now)).json",
            in: .templates
        )
    }

    // MARK: Preview

    /// Parses and validates a template file. Writes nothing.
    func preview(data: Data) throws -> TemplatePreview {
        let probe = try PortableDocumentProbe.probe(data)

        // A backup opened here is the single most likely mistake a user can
        // make with two JSON pickers in one screen, and it is the one that
        // would import a whole financial history as "setup". Named, not
        // guessed at (T-13 documentKind cross-rejection).
        guard let kind = probe.documentKind else {
            throw PortabilityError.wrongDocumentKind(expected: .template, found: .fullBackup)
        }
        guard kind == .template else {
            throw PortabilityError.wrongDocumentKind(expected: .template, found: kind)
        }
        guard Self.importableSchemaVersions.contains(probe.schemaVersion) else {
            throw PortabilityError.unsupportedSchema(
                found: probe.schemaVersion,
                lowest: Self.importableSchemaVersions.lowerBound,
                highest: Self.importableSchemaVersions.upperBound
            )
        }

        let document: PortableDocument<TemplatePayload>
        do {
            document = try PortableCoding.decoder().decode(
                PortableDocument<TemplatePayload>.self, from: data
            )
        } catch let error as DecodingError {
            throw PortabilityError.malformed(ExportService.fieldPath(error))
        }

        let payload = document.payload
        let derived = Self.integrity(of: payload)
        if let (collection, declared, found) = document.integrity.disagreements(with: derived).first {
            throw PortabilityError.integrityMismatch(
                collection: collection, declared: declared, found: found
            )
        }
        try validateAmounts(payload)

        let records = derived.totalRecords
        guard records <= PortableDocumentLimits.maxRecords else {
            throw PortabilityError.tooManyRecords(count: records, limit: PortableDocumentLimits.maxRecords)
        }

        let included = payload.includedSensitiveCategories
            .compactMap(TemplateSensitiveCategory.init(rawValue:))

        var counts: [TemplatePreview.Count] = []
        func add(_ label: String, _ count: Int) {
            if count > 0 { counts.append(.init(label: label, count: count)) }
        }
        add("Checking accounts", payload.accounts.count)
        add("Bills", payload.bills.count)
        add("Debts", payload.debts.count)
        add("Reminders", payload.reminders.count)

        var warnings: [String] = []
        if !included.isEmpty {
            warnings.append(
                "This template includes real values: "
                + included.map(\.title).joined(separator: ", ") + "."
            )
        }
        if document.schemaVersion < Self.templateSchemaVersion {
            warnings.append(
                "This template uses format \(document.schemaVersion); anything newer formats added will use its default."
            )
        }
        // Said before applying, not after: a user choosing between merge and
        // add deserves to know which rows this file cannot create on its own.
        let incomplete = Self.rowsNeedingValues(payload)
        if incomplete > 0 {
            warnings.append(
                "\(incomplete) item(s) in this template have no amount, so they can't be added until you enter one. "
                + "The app won't guess an amount for you."
            )
        }

        return TemplatePreview(
            schemaVersion: document.schemaVersion,
            appVersion: document.appVersion,
            exportedAt: document.exportedAt,
            counts: counts,
            categories: Self.categories(of: payload),
            includedCategories: included,
            warnings: warnings,
            payload: payload
        )
    }

    /// Rows the app cannot create from this template because a required amount
    /// was excluded. Counted the same way `apply` decides, so the preview's
    /// promise and the outcome agree.
    static func rowsNeedingValues(_ payload: TemplatePayload) -> Int {
        var count = payload.bills.filter { !ExportService.isPositiveAmount($0.amount) }.count
        count += payload.debts.filter { debt in
            (DebtType(rawValue: debt.debtType) ?? .creditCard).requiresEnteredMinimum
                && !ExportService.isPositiveAmount(debt.minimumAmount)
        }.count
        if let income = payload.income, !ExportService.isPositiveAmount(income.baseTakeHome) {
            count += 1
        }
        return count
    }

    static func categories(of payload: TemplatePayload) -> [String] {
        var lines: [String] = []
        let byType = Dictionary(grouping: payload.debts, by: \.debtType)
        for key in byType.keys.sorted() {
            let label = (DebtType(rawValue: key)?.displayName ?? key).lowercased()
            let count = byType[key]?.count ?? 0
            lines.append("\(count) \(label)\(count == 1 ? "" : "s")")
        }
        let byCadence = Dictionary(grouping: payload.bills, by: \.cadence)
        for key in byCadence.keys.sorted() {
            let count = byCadence[key]?.count ?? 0
            lines.append("\(count) \(key) bill\(count == 1 ? "" : "s")")
        }
        if !payload.accounts.isEmpty {
            let roles = Set(payload.accounts.flatMap(\.roles)).sorted().joined(separator: ", ")
            lines.append("\(payload.accounts.count) account(s) covering: \(roles)")
        }
        if let income = payload.income {
            lines.append("\(income.cadence) pay schedule")
        }
        return lines
    }

    private func validateAmounts(_ payload: TemplatePayload) throws {
        func check(_ collection: String, _ field: String, _ values: [String?]) throws {
            guard values.allSatisfy(ExportService.isReadableAmount) else {
                throw PortabilityError.amountUnreadable(collection: collection, field: field)
            }
        }
        try check("accounts", "currentBalance", payload.accounts.map(\.currentBalance))
        try check("accounts", "protectedAmount", payload.accounts.map(\.protectedAmount))
        try check("bills", "amount", payload.bills.map(\.amount))
        try check("debts", "apr", payload.debts.map { $0.apr })
        try check("debts", "startingBalance", payload.debts.map(\.startingBalance))
        try check("debts", "minimumAmount", payload.debts.map(\.minimumAmount))
        try check("debts", "creditLimit", payload.debts.map(\.creditLimit))
        try check("income", "baseTakeHome", [payload.income?.baseTakeHome])
        try check("settings", "protectedFloor", [payload.settings?.protectedFloor])
        try check("settings", "allowanceCap", [payload.settings?.allowanceCap])
    }

    // MARK: Apply

    /// Writes a previewed template into the store.
    ///
    /// **The guarantee that matters:** this only ever *inserts* setup rows and
    /// fills settings that have no value yet. It never deletes, never rewrites
    /// an existing amount, and never touches a history table — check-ins,
    /// ledger entries, snapshots, plans, and paydays are not readable from a
    /// template and not writable by this method (T-13).
    ///
    /// Every inserted row gets a freshly minted identifier. Templates carry no
    /// IDs at all, so there is nothing to collide with; the outcome reports the
    /// remap count so "explicitly remapped" is visible rather than assumed.
    @discardableResult
    func apply(_ preview: TemplatePreview, mode: TemplateApplyMode) throws -> TemplateApplyOutcome {
        let payload = preview.payload
        let now = dateProvider.now
        var outcome = TemplateApplyOutcome()

        let accountRepo = CashAccountRepository(context: context)
        let obligationRepo = ObligationRepository(context: context)
        let debtRepo = DebtRepository(context: context)

        // Accounts — merge matches on role set, which is what an account *is*
        // for planning purposes; a template with no names has nothing else to
        // match on, and matching on balance would be both fragile and wrong.
        let existingAccounts = try context.fetch(FetchDescriptor<CashAccount>())
        var coveredRoles = Set(existingAccounts.filter { !$0.isArchived }.flatMap(\.roles))
        for account in payload.accounts.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let roles = Set(account.roles.compactMap(AccountRole.init(rawValue:)))
            if mode == .merge, !roles.isEmpty, roles.isSubset(of: coveredRoles) {
                outcome.skipped.append("Account covering \(roleList(roles)) — you already have one")
                continue
            }
            let created = try accountRepo.create(
                name: account.name ?? Self.placeholderAccountName(for: roles),
                currentBalance: (try? decimal(account.currentBalance)) ?? .zero,
                roles: roles.isEmpty ? [.spending] : roles,
                now: now
            )
            if let protected = try? decimal(account.protectedAmount), protected > 0 {
                created.protectedAmount = protected
                created.updatedAt = now
            }
            coveredRoles.formUnion(roles)
            outcome.accountsAdded += 1
        }

        // Bills — merge matches on (name when present, else cadence + due day).
        let existingBills = try context.fetch(FetchDescriptor<RecurringObligation>())
        var billKeys = Set(existingBills.map { Self.billKey(name: $0.name, cadence: $0.cadenceRaw, dueDay: $0.dueDay) })
        for bill in payload.bills {
            let name = bill.name ?? Self.placeholderBillName(cadence: bill.cadence, index: outcome.billsAdded + 1)
            let key = Self.billKey(name: bill.name, cadence: bill.cadence, dueDay: bill.dueDay)
            if mode == .merge, billKeys.contains(key) {
                outcome.skipped.append("Bill \"\(name)\" — you already have a match")
                continue
            }
            guard let amount = try decimal(bill.amount), amount > 0 else {
                outcome.needsValues.append("\(name) — add its amount to use it")
                continue
            }
            try obligationRepo.create(
                name: name,
                amount: amount,
                cadence: ObligationCadence(rawValue: bill.cadence) ?? .monthly,
                dueDay: bill.dueDay,
                isEssential: bill.isEssential,
                now: now
            )
            billKeys.insert(key)
            outcome.billsAdded += 1
        }

        // Debts — merge matches on (name when present, else type + due day).
        let existingDebts = try context.fetch(FetchDescriptor<DebtAccount>())
        var debtKeys = Set(existingDebts.map {
            Self.debtKey(name: $0.displayName, type: $0.debtTypeRaw, dueDay: $0.dueDayOfMonth)
        })
        for debt in payload.debts.sorted(by: { $0.priority < $1.priority }) {
            let type = DebtType(rawValue: debt.debtType) ?? .creditCard
            let name = debt.name ?? Self.placeholderDebtName(type: type, index: outcome.debtsAdded + 1)
            let key = Self.debtKey(name: debt.name, type: debt.debtType, dueDay: debt.dueDayOfMonth)
            if mode == .merge, debtKeys.contains(key) {
                outcome.skipped.append("Debt \"\(name)\" — you already have a match")
                continue
            }
            // Installment debts have a contractual payment; without it there is
            // no honest schedule (R-06/A-06) and the model refuses the row.
            let minimum = try decimal(debt.minimumAmount)
            if type.requiresEnteredMinimum, minimum == nil || minimum! <= 0 {
                outcome.needsValues.append("\(name) — add its required monthly payment to use it")
                continue
            }
            let created = try debtRepo.create(
                type: type,
                displayName: name,
                currentBalance: (try? decimal(debt.startingBalance)) ?? .zero,
                apr: (try? decimal(debt.apr)) ?? .zero,
                minimumAmount: minimum,
                originalPrincipal: try? decimal(debt.originalPrincipal),
                creditLimit: try? decimal(debt.creditLimit),
                dueDayOfMonth: debt.dueDayOfMonth,
                prepayment: PrepaymentEligibility(rawValue: debt.prepayment) ?? .eligible,
                creditLimitMarkedUnknown: debt.creditLimitMarkedUnknown,
                now: now
            )
            created.isExtraPrincipalEligible = debt.isExtraPrincipalEligible
            // A type that arrived from a file is not a type the user confirmed.
            created.debtTypeConfirmedAt = debt.name == nil ? nil : now
            debtKeys.insert(key)
            outcome.debtsAdded += 1
        }

        // Reminders — one row per kind, so this is always gap-filling.
        let existingKinds = Set(try context.fetch(FetchDescriptor<NotificationPreference>()).map(\.typeRaw))
        for reminder in payload.reminders where !existingKinds.contains(reminder.type) {
            guard let kind = NotificationKind(rawValue: reminder.type) else { continue }
            context.insert(NotificationPreference(
                type: kind, enabled: reminder.enabled, hour: reminder.hour,
                minute: reminder.minute, leadDays: reminder.leadDays,
                // Never honoured from a file, whatever it says. Detailed
                // lock-screen copy puts a name and an amount on a screen
                // visible without unlocking the device; that is a decision for
                // the person holding the phone, and a template arrives from
                // someone else. Timing and lead days are ordinary
                // configuration, so those do come across (V3-13).
                detailedLockScreenContent: false
            ))
            outcome.remindersAdded += 1
        }

        // Income cadence — applied only when the user has no schedule at all.
        // Overwriting a live pay schedule from a file would silently re-date
        // every future payday.
        if let income = payload.income,
           try context.fetch(FetchDescriptor<IncomeSchedule>()).isEmpty {
            if let takeHome = try decimal(income.baseTakeHome), takeHome > 0 {
                let schedule = IncomeSchedule(
                    cadence: PayCadence(rawValue: income.cadence) ?? .biweekly,
                    // The template carries no anchor date on purpose — a
                    // specific payday is a fact about the exporting user's
                    // calendar. The importer starts from their own today and
                    // corrects it in the Income step.
                    anchorPayday: DateMath.startOfDay(now),
                    monthlyDay: income.monthlyDay,
                    semimonthlyFirstDay: income.semimonthlyFirstDay,
                    semimonthlySecondDay: income.semimonthlySecondDay,
                    baseTakeHome: takeHome,
                    createdAt: now,
                    updatedAt: now
                )
                context.insert(schedule)
                outcome.incomeApplied = true
            } else {
                outcome.needsValues.append("Pay schedule — add your take-home pay to use it")
            }
        } else if payload.income != nil {
            outcome.skipped.append("Pay schedule — yours is already set up")
        }

        // Settings — posture and any guardrail the user has not set. A zero
        // guardrail is "not set yet" here, matching how onboarding treats it.
        if let settings = payload.settings {
            let profile = try context.fetch(FetchDescriptor<UserGoalProfile>()).first
            if let profile {
                var changed = false
                func fill(_ current: Decimal, _ incoming: String?, _ apply: (Decimal) -> Void) {
                    guard current == .zero, let incoming, let value = try? decimal(incoming), value > 0 else { return }
                    apply(value)
                    changed = true
                }
                fill(profile.protectedFloor, settings.protectedFloor) { profile.protectedFloor = $0 }
                fill(profile.allowanceCap, settings.allowanceCap) { profile.allowanceCap = $0 }
                fill(profile.minimumProtectedCash, settings.minimumProtectedCash) { profile.minimumProtectedCash = $0 }
                fill(profile.plannedSavingsPerPaycheck, settings.plannedSavingsPerPaycheck) { profile.plannedSavingsPerPaycheck = $0 }
                fill(profile.additionalCushionReserve, settings.additionalCushionReserve) { profile.additionalCushionReserve = $0 }
                fill(profile.extraPaymentCeiling, settings.extraPaymentCeiling) { profile.extraPaymentCeiling = $0 }
                if changed {
                    profile.updatedAt = now
                    outcome.settingsApplied = true
                } else {
                    outcome.skipped.append("Goal settings — yours are already set")
                }
            }
        }

        outcome.remappedIdentifiers =
            outcome.accountsAdded + outcome.billsAdded + outcome.debtsAdded + outcome.remindersAdded
        try context.save()
        return outcome
    }

    // MARK: Helpers

    private func money(_ value: Decimal) -> String { "\(value)" }
    private func money(_ value: Decimal?) -> String? { value.map { "\($0)" } }

    private func decimal(_ raw: String?) throws -> Decimal? {
        guard let raw else { return nil }
        return try ExportService.decimalOrThrow(raw)
    }

    private func roleList(_ roles: Set<AccountRole>) -> String {
        roles.map(\.displayName).sorted().joined(separator: " + ")
    }

    /// Placeholder labels for a structure-only template. Generic by design:
    /// the file carried no name, so the app must not invent one that looks
    /// like the exporting user's.
    static func placeholderAccountName(for roles: Set<AccountRole>) -> String {
        if roles.contains(.income) { return "Main account" }
        if roles.contains(.reserves) { return "Reserves account" }
        return "Spending account"
    }

    static func placeholderBillName(cadence: String, index: Int) -> String {
        "\(ObligationCadence(rawValue: cadence)?.displayName ?? "Recurring") bill \(index)"
    }

    static func placeholderDebtName(type: DebtType, index: Int) -> String {
        "\(type.displayName) \(index)"
    }

    private static func billKey(name: String?, cadence: String, dueDay: Int?) -> String {
        if let name, !name.isEmpty { return "name:\(name.lowercased())" }
        return "shape:\(cadence):\(dueDay.map(String.init) ?? "-")"
    }

    private static func debtKey(name: String?, type: String, dueDay: Int?) -> String {
        if let name, !name.isEmpty { return "name:\(name.lowercased())" }
        return "shape:\(type):\(dueDay.map(String.init) ?? "-")"
    }
}
