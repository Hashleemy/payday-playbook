import SwiftUI

/// Step 1 — welcome and the privacy promise (§4.1, V2-17). States plainly
/// where the data lives and what the next few minutes produce.
struct WelcomeStepView: View {
    let onContinue: () -> Void
    let onLoadTemplate: () -> Void
    /// Distribution builds ship no template resource, so the affordance that
    /// offers it is not drawn at all — see `TemplateCatalog`.
    var templateAvailable: Bool = TemplateCatalog.isAvailable()

    @State private var showTemplateWarning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("Payday Playbook")
                        .font(.largeTitle.bold())
                    Text("Know today's play. Record what happened. See the finish line.")
                        .font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 12) {
                    Label {
                        Text("Everything stays on this iPhone. No account, no bank login, no internet needed — and we never ask for card numbers, CVVs, or your SSN.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                    Label {
                        Text("You export a backup yourself, or your data never leaves the device.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                }
                .font(.subheadline)

                VStack(alignment: .leading, spacing: 10) {
                    Text("What setup produces")
                        .font(.headline)
                    Text("A few questions about your accounts, paycheck, bills, and debts. From your own numbers the app builds a payday-by-payday plan: what to keep, what to move, and which debt to attack — plus your projected debt-free date.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("It takes a few minutes, and you can stop anytime — every answer is saved as you go.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            .padding(.horizontal)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button("Set Up My Plan", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("onboarding.setUpPlan")

                if templateAvailable {
                    Button("Load a template instead") { showTemplateWarning = true }
                        .font(.footnote)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("onboarding.loadTemplate")
                }
            }
            .padding()
            .background(.bar)
        }
        .alert("Load Original Plan v1?", isPresented: $showTemplateWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Load template") { onLoadTemplate() }
        } message: {
            Text("This is one specific person's plan — their income, their bills, their six cards — kept as a reference, not a recommendation. Your own numbers will not be used. You can start over from Settings.")
        }
    }
}
