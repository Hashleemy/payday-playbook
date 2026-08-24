import XCTest
import UIKit
@testable import PaydayPlaybook

/// T-22 (V4-05): the primary-action treatment's contrast, measured from the
/// asset catalog rather than asserted from memory.
///
/// Root cause of the reported unreadable CTAs: `AccentColor` was one
/// universal deep navy with no dark-appearance variant, so every
/// accent-tinted label (`.bordered` buttons included) rendered navy on
/// near-black in Dark Mode at under 2:1. The fix is a light-blue dark
/// variant plus the `PrimaryActionLabel` pair the button style uses; these
/// tests keep both appearances at or above WCAG AA (4.5:1) forever.
final class PrimaryActionContrastTests: XCTestCase {

    private func color(_ name: String, style: UIUserInterfaceStyle) throws -> UIColor {
        let bundle = Bundle(for: AppEnvironment.self)
        let traits = UITraitCollection(userInterfaceStyle: style)
        let named = try XCTUnwrap(
            UIColor(named: name, in: bundle, compatibleWith: traits),
            "Missing colorset \(name)"
        )
        return named.resolvedColor(with: traits)
    }

    /// WCAG relative luminance from sRGB components.
    private func luminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private func contrast(_ first: UIColor, _ second: UIColor) -> CGFloat {
        let lighter = max(luminance(first), luminance(second))
        let darker = min(luminance(first), luminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    // MARK: - The button pair: label on fill, both appearances

    func testPrimaryActionLabelOnFillMeetsAAInLightMode() throws {
        let fill = try color("AccentColor", style: .light)
        let label = try color("PrimaryActionLabel", style: .light)
        XCTAssertGreaterThanOrEqual(contrast(label, fill), 4.5)
    }

    func testPrimaryActionLabelOnFillMeetsAAInDarkMode() throws {
        let fill = try color("AccentColor", style: .dark)
        let label = try color("PrimaryActionLabel", style: .dark)
        XCTAssertGreaterThanOrEqual(contrast(label, fill), 4.5)
    }

    // MARK: - Accent as text (system .bordered labels, links, tinted icons)

    func testAccentReadsOnLightSurfaces() throws {
        let accent = try color("AccentColor", style: .light)
        let surfaces = [
            UIColor.systemGroupedBackground,
            UIColor.secondarySystemGroupedBackground,
            UIColor.systemBackground
        ].map { $0.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)) }
        for surface in surfaces {
            XCTAssertGreaterThanOrEqual(contrast(accent, surface), 4.5)
        }
    }

    func testAccentReadsOnDarkSurfaces() throws {
        // The defect this pins: universal navy resolved here too, at ~1.6:1.
        let accent = try color("AccentColor", style: .dark)
        let surfaces = [
            UIColor.systemGroupedBackground,
            UIColor.secondarySystemGroupedBackground,
            UIColor.systemBackground
        ].map { $0.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)) }
        for surface in surfaces {
            XCTAssertGreaterThanOrEqual(contrast(accent, surface), 4.5)
        }
    }

    // MARK: - The dark variant genuinely exists

    func testAccentColorHasADistinctDarkAppearance() throws {
        let light = try color("AccentColor", style: .light)
        let dark = try color("AccentColor", style: .dark)
        XCTAssertGreaterThan(contrast(light, dark), 3.0, "The dark appearance must be a genuinely lighter accent, not the same navy.")
    }

    func testPrimaryActionLabelSwapsWithItsFill() throws {
        let light = try color("PrimaryActionLabel", style: .light)
        let dark = try color("PrimaryActionLabel", style: .dark)
        XCTAssertGreaterThan(contrast(light, dark), 3.0, "The label pair must swap alongside the fill.")
    }
}
