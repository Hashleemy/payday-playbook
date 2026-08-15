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
    /// Calculation version for newly generated plans (MVP_LAYOUT §5).
    ///
    /// Still 2: this is the version the shipped engine actually produces, and
    /// callers gate behaviour on it (`reforecastResult` returns nil below it).
    /// Raising it before the v3 engine exists would silently disable those
    /// paths on every plan in the store. The v0.3.0 bump to 3 belongs with the
    /// engine that implements it — see the Agent 2 report's handoff.
    static let currentCalculationVersion = 2
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
}
