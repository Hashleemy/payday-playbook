import Foundation

/// Currency helpers. All monetary math in the app uses `Decimal`.
/// Internal engine math carries full precision; values are rounded to
/// two decimals only at persistence/display boundaries.
extension Decimal {
    /// Rounds to two decimal places, half away from zero (plain currency rounding).
    var rounded2: Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, 2, .plain)
        return result
    }

    var isNegative: Bool { self < 0 }

    /// True when the value rounds to $0.00.
    var isZeroMoney: Bool { rounded2 == 0 }

    var asDouble: Double { (self as NSDecimalNumber).doubleValue }

    static func fromCents(_ cents: Int) -> Decimal {
        Decimal(cents) / 100
    }
}

enum MoneyFormat {
    static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }()

    static let wholeCurrency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    static func string(_ value: Decimal) -> String {
        currency.string(from: value.rounded2 as NSDecimalNumber) ?? "$\(value)"
    }

    static func whole(_ value: Decimal) -> String {
        wholeCurrency.string(from: value.rounded2 as NSDecimalNumber) ?? "$\(value)"
    }

    /// Plain editing text for a value, in the user's locale, without grouping —
    /// the exact inverse of `parse` so field round-trips never corrupt amounts.
    static let editingFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    static func editingString(_ value: Decimal) -> String {
        editingFormatter.string(from: value.rounded2 as NSDecimalNumber) ?? "\(value.rounded2)"
    }

    /// Parses user-entered text such as "$1,234.56" into a Decimal.
    /// Text using the locale's decimal separator is parsed locale-aware after
    /// stripping the locale grouping separator; text without it is treated as
    /// plain dot-decimal so pasted/invariant values stay correct everywhere.
    static func parse(_ text: String) -> Decimal? {
        let symbol = currency.currencySymbol ?? "$"
        let grouping = currency.groupingSeparator ?? ","
        let decimalSeparator = currency.decimalSeparator ?? "."
        var cleaned = text
            .replacingOccurrences(of: symbol, with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }

        if decimalSeparator != "." {
            if cleaned.contains(decimalSeparator) {
                cleaned = cleaned.replacingOccurrences(of: grouping, with: "")
                return Decimal(string: cleaned, locale: Locale.current)
            }
            // No locale decimal separator present: interpret as dot-decimal.
            cleaned = cleaned.replacingOccurrences(of: ",", with: "")
            return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
        }

        cleaned = cleaned.replacingOccurrences(of: grouping, with: "")
        return Decimal(string: cleaned, locale: Locale.current)
            ?? Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }
}
