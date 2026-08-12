import Foundation

/// Whether this build carries the Original Plan v1 template.
///
/// The bundled template is one specific person's real finances — their income,
/// their bills, their six card balances. It is a useful development and
/// verification fixture, and it is the wrong thing to hand to anyone else, so
/// **distribution builds ship without the resource at all**: a Release build
/// phase strips `OriginalPlanV1.json` from the app bundle, which is what keeps
/// the numbers out of a distributed `.ipa` rather than merely out of the UI.
///
/// Availability is therefore derived from the resource actually being present,
/// not from a compile-time flag. One source of truth: if the file is not in the
/// bundle, the loader cannot load it and the onboarding affordance that offers
/// it is not drawn. There is no state in which the app advertises a template it
/// cannot produce, or holds one it will not show.
enum TemplateCatalog {
    static let resourceName = "OriginalPlanV1"
    static let resourceExtension = "json"

    static func isAvailable(in bundle: Bundle = .main) -> Bool {
        bundle.url(forResource: resourceName, withExtension: resourceExtension) != nil
    }
}
