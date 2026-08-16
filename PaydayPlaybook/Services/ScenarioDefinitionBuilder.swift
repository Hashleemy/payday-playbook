import Foundation

/// Builds the three contracted scenario definitions from the user's saved
/// profile (R-17, V3-05/V3-06).
///
/// **This is the only store → `StoredScenarioDefinition` mapping.** Agent 3's
/// engine takes definitions as given and the report and the Payoff Scenarios
/// screen both need to produce them; two independent mappings would be exactly
/// the "duplicated bridges silently disagree" failure the v0.2.0 retro pinned,
/// with the twist that the disagreement would show up as a report that
/// contradicts the screen it was generated from.
///
/// Every field is the user's own value or nil. A profile stores its scenario
/// constraints as `Decimal` defaulting to zero, and zero here means "never
/// stated" — so it maps to nil, which the scenario layer turns into a named
/// missing-input result instead of a silently plausible answer.
enum ScenarioDefinitionBuilder {

    /// The three cards, always in display order, whether or not each is
    /// computable. A missing constraint produces a definition that the
    /// calculator answers with `missingInputs`, which is the honest result.
    static func definitions(
        profile: UserGoalProfile?,
        effectiveDate: Date
    ) -> [StoredScenarioDefinition] {
        ScenarioKind.allCases.map { definition(kind: $0, profile: profile, effectiveDate: effectiveDate) }
    }

    static func definition(
        kind: ScenarioKind,
        profile: UserGoalProfile?,
        effectiveDate: Date
    ) -> StoredScenarioDefinition {
        // `preferredFloor` / `preferredAllowance` stay nil on purpose: §6 reads
        // nil as "keep the floor and allowance already in the snapshot". Naming
        // them again here would give the same number two sources that could
        // drift apart.
        var definition = StoredScenarioDefinition(
            kind: kind,
            incomeOverride: nil,
            minimumProtectedCash: nil,
            preferredFloor: nil,
            preferredAllowance: nil,
            plannedSavingsPerPaycheck: nil,
            additionalReserve: nil,
            extraPaymentCeiling: nil,
            zeroAllowanceConfirmedAt: nil,
            effectiveDate: effectiveDate
        )
        guard let profile else { return definition }

        switch kind {
        case .fastestSafe:
            definition.minimumProtectedCash = stated(profile.minimumProtectedCash)
            definition.zeroAllowanceConfirmedAt = profile.zeroAllowanceConfirmedAt
        case .balanced:
            definition.plannedSavingsPerPaycheck = stated(profile.plannedSavingsPerPaycheck)
        case .moreCushion:
            definition.plannedSavingsPerPaycheck = stated(profile.plannedSavingsPerPaycheck)
            definition.additionalReserve = stated(profile.additionalCushionReserve)
            definition.extraPaymentCeiling = stated(profile.extraPaymentCeiling)
        }
        return definition
    }

    /// Zero is the storage default, not an answer.
    private static func stated(_ value: Decimal) -> Decimal? {
        value.rounded2 > 0 ? value : nil
    }
}
