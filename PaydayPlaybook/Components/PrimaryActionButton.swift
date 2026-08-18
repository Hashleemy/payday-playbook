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
struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .background(
                isEnabled
                    ? Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1)
                    : Color.secondary.opacity(0.18),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension ButtonStyle where Self == PrimaryActionButtonStyle {
    /// Semantic name for a screen's primary call to action.
    static var primaryAction: PrimaryActionButtonStyle { PrimaryActionButtonStyle() }
}
