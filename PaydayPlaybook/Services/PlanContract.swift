import Foundation

/// Version stamps and the estimator constants shared by the engine, the
/// migration, and the store.
///
/// This type once also carried the founding user's actual plan — balances,
/// income, payday dates, per-card payoffs — because a bundled template was
/// validated against it. That template is gone (V3-12) and so are those
/// constants: nothing here describes any real person's finances, and nothing
/// added here ever should. Values that vary per user live in the user's own
/// rows, which is the only place they can be correct.
enum PlanContract {
    /// Name of the frozen calc-v1 baseline. Retained because installs that
    /// migrated from 0.1.x still carry a `PlanVersion` row under this name and
    /// look themselves up by it; it is a lookup key, not a template.
    static let planName = "Original Plan v1"
    /// Schema/calc version of a 0.1.x-era baseline row. Those rows stay
    /// stamped with these forever.
    static let schemaVersion = 1
    static let calculationVersion = 1
    /// Current store schema (v0.3.0). `AppSettings.seedSchemaVersion` below
    /// this value routes the launch through `MigrationService`.
    static let currentSchemaVersion = 3
    /// Calculation version stamped on plans generated from now on
    /// (MVP_LAYOUT §5, docs/releases/v0.4.0/VERSIONING.md §5). Calc v4 adds
    /// the Balanced quick-win promotion input (R-25…R-27), so plans generated,
    /// previewed, or applied in 0.4.0 are stamped 4.
    ///
    /// Existing stamps are never rewritten: a 0.1.x baseline stays 1, a
    /// v0.2.0 plan stays 2, and a v0.3.0 plan stays 3, forever. Engines
    /// dispatch on the stamp, and the reduction chain holds exactly — v4 with
    /// no promotions reproduces v3 (`CalcV4ReductionTests`), v3 with no
    /// scenario and no extras reproduces v2 (`CalcV3ReductionTests`) — so
    /// nothing a user already has changes value because of this bump.
    static let currentCalculationVersion = 4

    /// The boundary between the frozen calc-v1 baseline and the modern engine
    /// — *not* a currency check, which is why it is a separate constant.
    ///
    /// Reforecast, insights, Today's projection and the plan screen ask "is
    /// this plan on the modern engine path?", and every plan stamped 2 or
    /// higher is. Gating those on `currentCalculationVersion` instead would
    /// mean that raising the stamp for new plans silently drops every existing
    /// v0.2.0 plan onto the calc-v1 legacy path, where an install that never
    /// had a 0.1.x baseline reforecasts to nothing at all. This constant only
    /// moves if a calculation version is genuinely retired.
    static let minimumModernCalculationVersion = 2
    /// Name of the baseline a fresh install generates in onboarding (A-04).
    /// A migrated install's row keeps its historical `planName` instead.
    static let generatedPlanName = "Plan v1"

    /// Default pay period for calc-v1 plans. Calc-v2 and later read cadence
    /// from the plan row; this remains the fallback for the frozen baseline.
    static let payFrequencyDays = 14

    /// Card minimum-payment estimator (R-06), used only when the user has not
    /// supplied an authoritative minimum: `max(floor, rate × balance)`.
    static let minimumPaymentFloor = Decimal(string: "17.50")!
    static let minimumPaymentRate = Decimal(string: "0.005")!

    // MARK: - Balanced quick-win policy (V4-03, R-25/R-26)

    // Named, tunable product modeling constants (A-12) — transparent numbers
    // a user could be told, never hidden scoring weights, and definitionally
    // not personal data. Changing one is a product decision, not a contract
    // change.

    /// R-25: a promoted quick win must retire within this many pay periods of
    /// plan start to count as a candidate.
    static let balancedQuickWinHorizonPaychecks = 3
    /// R-26 G1: the overall payoff may slip at most this many pay periods
    /// versus the pure-avalanche Balanced baseline.
    static let balancedQuickWinMaxDelayPaychecks = 1
    /// R-26 G2: extra estimated interest is capped at this fraction of the
    /// baseline's estimated interest…
    static let balancedQuickWinMaxExtraInterestRate = Decimal(string: "0.01")!
    /// …and never more than this many dollars, whichever is smaller.
    static let balancedQuickWinMaxExtraInterestCap = Decimal(50)
}
