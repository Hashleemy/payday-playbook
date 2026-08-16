import SwiftUI

/// The entry point to the payoff calculator, at the top of Progress (§8.6).
///
/// Deliberately a plain link with no figures on it. Showing a headline number
/// here would mean running three projections every time Progress appears —
/// over a second of main-thread work on a large plan — and would put a payoff
/// date on screen that nobody asked to have computed.
struct ScenariosEntryCard: View {
    var body: some View {
        NavigationLink {
            PayoffScenariosView()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "square.stack.3d.up")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compare payoff plans")
                        .font(.subheadline.weight(.semibold))
                    Text("Three ways to finish — faster, balanced, or with more cushion. Nothing changes until you choose.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Compare payoff plans")
        .accessibilityHint("Three ways to finish, worked out from your own numbers. Nothing changes until you choose one.")
        .accessibilityIdentifier("progress.scenariosEntry")
    }
}
