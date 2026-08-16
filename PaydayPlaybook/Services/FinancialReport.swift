import Foundation

/// The financial report as content, with no idea that PDFs exist (V3-11).
///
/// Split from rendering on purpose. "Does the report say the right thing" and
/// "does the report fit on the page" are different questions with different
/// failure modes, and only the second one needs UIKit. Everything here is
/// Foundation-only and `Equatable`, so a test can assert the exact rows a
/// configuration produces without rasterizing anything.

// MARK: - Configuration

/// What the user chose on the Generate Financial Report screen (MVP_LAYOUT §6).
struct ReportConfiguration: Equatable {

    /// Report sections, in the order they are printed.
    enum Section: String, Codable, CaseIterable, Identifiable, Sendable {
        case currentInputs
        case accounts
        case billsAndDebts
        case activePlan
        case nextActions
        case scenarioComparison
        case extraPaymentInsight
        case payoffProjection
        case upcomingActions

        var id: String { rawValue }

        var title: String {
            switch self {
            case .currentInputs: return "Your current inputs"
            case .accounts: return "Accounts"
            case .billsAndDebts: return "Bills and debts"
            case .activePlan: return "Active plan"
            case .nextActions: return "Next actions"
            case .scenarioComparison: return "Payoff scenarios"
            case .extraPaymentInsight: return "Extra payment"
            case .payoffProjection: return "Projected payoff"
            case .upcomingActions: return "Next 30, 60, and 90 days"
            }
        }

        /// Everything except the extra-payment insight, which needs a payment
        /// to model and is therefore opt-in.
        static var defaults: Set<Section> {
            Set(allCases).subtracting([.extraPaymentInsight])
        }
    }

    /// How much of each section is printed.
    enum DetailLevel: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Headline figures; tables capped to the leading rows.
        case summary
        /// Full tables, no paycheck-by-paycheck schedule.
        case standard
        /// Everything, including per-paycheck detail in the appendix.
        case full

        var id: String { rawValue }

        var title: String {
            switch self {
            case .summary: return "Summary"
            case .standard: return "Standard"
            case .full: return "Full detail"
            }
        }

        /// Row cap for long tables. Nil means no cap.
        var tableRowLimit: Int? {
            switch self {
            case .summary: return 5
            case .standard, .full: return nil
            }
        }
    }

    struct DateRange: Equatable, Codable, Sendable {
        var start: Date
        var end: Date

        /// Whether a dated item belongs in this report. Compared by local day
        /// and inclusive at both ends, so an event on the last day is not
        /// dropped for falling after midnight.
        func contains(_ date: Date) -> Bool {
            let day = DateMath.startOfDay(date)
            return day >= DateMath.startOfDay(start) && day <= DateMath.startOfDay(end)
        }
    }

    /// Which entities are printed. Nil means "every non-archived one" rather
    /// than an empty selection, so a default configuration is complete.
    struct EntityScope: Equatable {
        var accountIDs: Set<UUID>?
        var debtIDs: Set<UUID>?
        var obligationIDs: Set<UUID>?
        var includeArchived: Bool = false

        static let all = EntityScope()

        func includesAccount(_ id: UUID) -> Bool { accountIDs?.contains(id) ?? true }
        func includesDebt(_ id: UUID) -> Bool { debtIDs?.contains(id) ?? true }
        func includesObligation(_ id: UUID) -> Bool { obligationIDs?.contains(id) ?? true }
    }

    /// Reductions a user can apply to a document they intend to hand to
    /// someone — an advisor, a partner, a lender.
    struct PrivacyOptions: Equatable {
        /// Replace account and debt labels with generic positional names.
        var maskNames: Bool = false
        /// Print structure and projections without current balances.
        var omitBalances: Bool = false

        static let none = PrivacyOptions()
    }

    var dateRange: DateRange
    var sections: Set<Section>
    var entityScope: EntityScope = .all
    var detailLevel: DetailLevel = .standard
    var includeAppendix: Bool = true
    var privacyOptions: PrivacyOptions = .none
    /// The payment modeled when `.extraPaymentInsight` is selected. Without
    /// one, the section reports that nothing was specified rather than
    /// inventing an amount.
    var extraPayment: StoredExtraPayment?

    func includes(_ section: Section) -> Bool { sections.contains(section) }

    /// The default report: the next 90 days, standard detail, everything the
    /// app can answer without asking another question.
    static func standard(from today: Date, days: Int = 90) -> ReportConfiguration {
        let start = DateMath.startOfDay(today)
        let end = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: start) ?? start
        return ReportConfiguration(
            dateRange: DateRange(start: start, end: end),
            sections: Section.defaults
        )
    }
}

// MARK: - Content model

struct FinancialReport: Equatable {
    var title: String
    var subtitle: String
    var generatedAt: Date
    var range: ReportConfiguration.DateRange
    var sections: [ReportSection]
    /// Printed at the end of every report, at every detail level. An estimate
    /// presented without its disclaimer is a claim (R-14/A-04).
    var disclaimer: [String]
}

struct ReportSection: Equatable, Identifiable {
    var id: String
    var title: String
    var blocks: [ReportBlock]
}

enum ReportBlock: Equatable {
    case paragraph(String)
    case subheading(String)
    case keyValues([ReportKeyValue])
    case table(ReportTable)
    case bullets([String])
    case callout(ReportCallout)
    case chart(ReportMagnitudeChart)
    /// A section with nothing to say says so, rather than printing an empty
    /// frame the reader has to interpret.
    case empty(String)
}

/// How a figure should read. Never carried by color alone in the renderer —
/// attention values are also marked in text.
enum ReportEmphasis: Equatable {
    case normal
    case strong
    /// Negative, overdrawn, below floor, or otherwise needing a look.
    case attention
}

struct ReportKeyValue: Equatable {
    var label: String
    var value: String
    var emphasis: ReportEmphasis = .normal
    /// Optional second line under the value, for an as-of date or a caveat.
    var note: String?
}

enum ReportAlignment: Equatable { case leading, trailing }

struct ReportColumn: Equatable {
    var title: String
    var alignment: ReportAlignment = .leading
    /// Relative width. Columns are laid out proportionally so a long label
    /// column can be given room without hard-coding point widths.
    var weight: Double = 1
}

struct ReportCell: Equatable {
    var text: String
    var emphasis: ReportEmphasis = .normal

    init(_ text: String, emphasis: ReportEmphasis = .normal) {
        self.text = text
        self.emphasis = emphasis
    }
}

struct ReportTable: Equatable {
    var columns: [ReportColumn]
    var rows: [[ReportCell]]
    /// Set when a detail level capped the rows, so the reader knows the table
    /// is partial rather than assuming it is complete.
    var truncationNote: String?
    var footnote: String?
}

struct ReportCallout: Equatable {
    enum Tone: Equatable { case info, caution }
    var title: String
    var lines: [String]
    var tone: Tone = .info
}

/// A one-measure magnitude comparison.
///
/// One measure per chart, deliberately: interest and time are different units,
/// and putting them on a shared axis would make one of the two scales a lie.
/// The scenario comparison therefore emits two charts rather than one chart
/// with two axes.
///
/// Bars are shaded light→dark by magnitude (a sequential ramp, one hue), which
/// keeps the ranking readable when the report is printed in grayscale — the
/// common case for a document generated to be handed to someone.
struct ReportMagnitudeChart: Equatable {
    struct Bar: Equatable {
        var label: String
        /// Magnitude driving bar length. Non-negative.
        var value: Double
        /// Preformatted value for the direct label.
        var displayValue: String
        var isRecommended: Bool = false
    }

    var title: String
    var caption: String?
    var bars: [Bar]

    /// Largest bar, used to scale the axis. Zero when every bar is zero, which
    /// the renderer treats as "draw the labels, draw no bars".
    var maximum: Double { bars.map(\.value).max() ?? 0 }
}
