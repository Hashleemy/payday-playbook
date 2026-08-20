import SwiftUI

/// The one semantic treatment for a screen's primary action (V4-05).
///
/// Call sites say what a button *is* — `.buttonStyle(.primaryAction)` — and
/// this style decides how it looks, so a contrast fix lands everywhere at
/// once instead of screen by screen. The contract it must keep meeting
/// (MVP_LAYOUT §8.11): text contrast ≥ 4.5:1 against the fill in both light
/// and dark appearance, a pressed state that reads as pressed, a disabled
/// state that cannot be mistaken for an enabled one, a 44-point minimum
/// target, and Dynamic Type scaling.
///
/// The fill is `AccentColor` (deep navy in light, light blue in dark — the
/// dark variant exists so accent-tinted content is never navy-on-near-black)
/// and the label is `PrimaryActionLabel` (white on navy, near-navy-black on
/// light blue). The two colorsets swap appearance together; verified as a
/// WCAG pair by `PrimaryActionContrastTests`.
struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(isEnabled ? Color("PrimaryActionLabel") : Color.secondary)
            .background(
                isEnabled ? Color.accentColor : Color.secondary.opacity(0.18),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            // Pressed = a uniform dim over fill and label together; both
            // appearances keep the label comfortably above 4.5:1 through it.
            .overlay(
                shape.fill(Color.black.opacity(configuration.isPressed && isEnabled ? 0.15 : 0))
            )
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == PrimaryActionButtonStyle {
    /// Semantic name for a screen's primary call to action.
    static var primaryAction: PrimaryActionButtonStyle { PrimaryActionButtonStyle() }
}
