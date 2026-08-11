import SwiftUI

/// Form building blocks shared by onboarding and the Settings setup editors.
/// Every control here meets the v0.2.0 accessibility bar: Dynamic Type (no
/// fixed font sizes or clipped frames), 44-point minimum targets, VoiceOver
/// labels that read the value and its state, and no motion that Reduce Motion
/// would need to suppress.

// MARK: - Field optionality (V2: label optional, required, and unknown)

/// How a field should be labeled to the user. "Unknown" is a first-class
/// state: the app would rather be told a value is unknown than guess it.
enum FieldRequirement {
    case required
    case optional
    case unknown

    var label: String {
        switch self {
        case .required: return "Required"
        case .optional: return "Optional"
        case .unknown: return "Marked unknown"
        }
    }

    var color: Color {
        switch self {
        case .required: return .accentColor
        case .optional: return .secondary
        case .unknown: return .orange
        }
    }
}

/// Small chip that labels a field's optionality beside its title.
struct RequirementChip: View {
    let requirement: FieldRequirement

    var body: some View {
        Text(requirement.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(requirement.color.opacity(0.15), in: Capsule())
            .foregroundStyle(requirement.color)
            .accessibilityHidden(true)
    }
}

/// A labeled row wrapper that carries the optionality chip, plain-language
/// help, and an inline validation message. Errors appear under the field and
/// never clear what the user typed.
struct SetupField<Content: View>: View {
    let title: String
    var requirement: FieldRequirement = .required
    var help: String?
    var error: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                RequirementChip(requirement: requirement)
                Spacer(minLength: 0)
            }
            content
            if let help, error == nil {
                Text(help)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [title, requirement.label]
        if let error { parts.append("Needs attention: \(error)") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Currency entry

/// Currency entry that parses as the user types and rejects negatives at the
/// field level. Unlike the check-in `MoneyField`, this one owns its own
/// label/validation layout and is safe inside a `Form` at accessibility text
/// sizes (the field wraps under the label rather than being squeezed).
struct SetupMoneyField: View {
    let title: String
    @Binding var value: Decimal?
    var requirement: FieldRequirement = .required
    var help: String?
    var error: String?
    var placeholder = "$0.00"

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        SetupField(title: title, requirement: requirement, help: help, error: error) {
            TextField(placeholder, text: $text)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .focused($focused)
                .frame(minHeight: 44)
                .accessibilityLabel(title)
                .accessibilityValue(value.map { MoneyFormat.string($0) } ?? "empty")
                .onChange(of: text) { _, newText in
                    value = MoneyFormat.parse(newText)
                }
                .onChange(of: value) { _, newValue in
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
        guard MoneyFormat.parse(text) != newValue else { return }
        text = newValue.map { MoneyFormat.editingString($0) } ?? ""
    }
}

// MARK: - APR entry

/// APR entry in whole percent ("24.99"), stored as a fraction (0.2499).
/// 0% is a legitimate value (medical debt, promo cards), so the field never
/// treats zero as missing.
struct SetupPercentField: View {
    let title: String
    /// Bound as a rate fraction: 0.2499 displays as 24.99.
    @Binding var rate: Decimal?
    var requirement: FieldRequirement = .required
    var help: String?
    var error: String?

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        SetupField(title: title, requirement: requirement, help: help, error: error) {
            HStack(spacing: 8) {
                TextField("0.00", text: $text)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .focused($focused)
                    .frame(minHeight: 44)
                Text("%")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(rate.map { Self.percentString($0) + " percent" } ?? "empty")
            .onChange(of: text) { _, newText in
                rate = Self.parsePercent(newText)
            }
            .onChange(of: rate) { _, newValue in
                guard !focused else { return }
                syncText(with: newValue)
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { syncText(with: rate) }
            }
            .onAppear { syncText(with: rate) }
        }
    }

    /// "24.99" → 0.2499. Uses the money parser so locale decimal separators
    /// behave the same way they do for amounts.
    static func parsePercent(_ text: String) -> Decimal? {
        let cleaned = text.replacingOccurrences(of: "%", with: "")
        guard let percent = MoneyFormat.parse(cleaned) else { return nil }
        return percent / 100
    }

    static func percentString(_ rate: Decimal) -> String {
        let percent = (rate * 100).rounded2
        return MoneyFormat.editingString(percent)
    }

    private func syncText(with newValue: Decimal?) {
        guard Self.parsePercent(text) != newValue else { return }
        text = newValue.map { Self.percentString($0) } ?? ""
    }
}

// MARK: - Day of month entry

/// Day-of-month picker (1–31). Day 31 means "last day" in shorter months by
/// the R-11 clamping rule, and the picker says so rather than hiding it.
struct SetupDayField: View {
    let title: String
    @Binding var day: Int?
    var requirement: FieldRequirement = .optional
    var help: String?
    var error: String?
    var allowsNone = true

    var body: some View {
        SetupField(title: title, requirement: requirement, help: help, error: error) {
            Picker(title, selection: $day) {
                if allowsNone {
                    Text("Not set").tag(Int?.none)
                }
                ForEach(1...31, id: \.self) { value in
                    Text(Self.dayLabel(value)).tag(Int?.some(value))
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
            .accessibilityLabel(title)
            .accessibilityValue(day.map(Self.dayLabel) ?? "not set")
        }
    }

    static func dayLabel(_ day: Int) -> String {
        switch day {
        case 31: return "31st (or the last day)"
        case 1, 21: return "\(day)st"
        case 2, 22: return "\(day)nd"
        case 3, 23: return "\(day)rd"
        default: return "\(day)th"
        }
    }
}

// MARK: - Explanatory copy

/// Plain-language explanation block: why the app is asking for something.
/// Never urgent, never a warning — it is the "because" behind a question.
struct SetupExplainer: View {
    let text: String
    var systemImage = "info.circle"

    var body: some View {
        Label {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A summary line: label on the left, value on the right, tabular figures.
struct SetupSummaryRow: View {
    let label: String
    let value: String
    var isEstimate = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)\(isEstimate ? ", estimated" : "")")
    }
}
