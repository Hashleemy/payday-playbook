import SwiftUI

/// Currency text with tabular numerals and an accessible label.
struct MoneyText: View {
    let amount: Decimal
    var font: Font = .body
    var color: Color?

    var body: some View {
        Text(MoneyFormat.string(amount))
            .font(font)
            .monospacedDigit()
            .foregroundStyle(color ?? .primary)
    }
}

/// Labeled currency input backed by Decimal. The binding updates as the user
/// types (no commit-on-focus-loss surprises). Negative values are rejected at
/// the field level; refunds and corrections use their own explicit flows.
struct MoneyField: View {
    let label: String
    @Binding var value: Decimal?

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("$0.00", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 140)
                .monospacedDigit()
                .focused($focused)
                .accessibilityLabel(label)
                .onChange(of: text) { _, newText in
                    value = MoneyFormat.parse(newText)
                }
                .onChange(of: value) { _, newValue in
                    // External updates (prefill, draft load) refresh the text
                    // unless the user is actively typing.
                    guard !focused else { return }
                    syncText(with: newValue)
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { syncText(with: value) }
                }
                .onAppear { syncText(with: value) }
        }
    }

    private func syncText(with newValue: Decimal?) {
        let current = MoneyFormat.parse(text)
        guard current != newValue else { return }
        text = newValue.map { MoneyFormat.editingString($0) } ?? ""
    }
}

struct PlanActualRow: View {
    let label: String
    let planned: Decimal
    let actual: Decimal?

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Plan")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    MoneyText(amount: planned, font: .subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text("Actual")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let actual {
                        MoneyText(amount: actual, font: .subheadline.weight(.semibold))
                    } else {
                        Text("—")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): planned \(MoneyFormat.string(planned)), actual \(actual.map { MoneyFormat.string($0) } ?? "not recorded")")
    }
}

struct StatusBadge: View {
    enum Kind {
        case onTrack
        case ahead(Decimal)
        case behind(Decimal)
        case needsAttention

        var text: String {
            switch self {
            case .onTrack: return "On track"
            case .ahead(let amount): return "Ahead by \(MoneyFormat.string(amount))"
            case .behind(let amount): return "Needs \(MoneyFormat.string(amount)) to return to plan"
            case .needsAttention: return "Needs attention"
            }
        }

        var color: Color {
            switch self {
            case .onTrack, .ahead: return .mint
            case .behind: return .orange
            case .needsAttention: return Color(red: 0.94, green: 0.45, blue: 0.40)
            }
        }

        var symbol: String {
            switch self {
            case .onTrack: return "checkmark.circle.fill"
            case .ahead: return "arrow.up.circle.fill"
            case .behind: return "arrow.uturn.backward.circle"
            case .needsAttention: return "exclamationmark.circle"
            }
        }
    }

    let kind: Kind

    var body: some View {
        Label(kind.text, systemImage: kind.symbol)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(kind.color.opacity(0.18), in: Capsule())
            .foregroundStyle(kind.color)
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    var symbolName = "tray"

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

/// Text summary that accompanies every chart for VoiceOver and no-color use.
struct AccessibleChartSummary: View {
    let summary: String

    var body: some View {
        Text(summary)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Chart summary: \(summary)")
    }
}

/// Card-style container used across the dashboard.
struct DashboardCard<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
