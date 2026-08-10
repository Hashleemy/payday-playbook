import Foundation

/// Date helpers. Plan dates are normalized to local start-of-day and the
/// user's time zone identifier is persisted with the plan version.
enum DateMath {
    static var calendar: Calendar { Calendar.current }

    static func localDate(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else {
            preconditionFailure("Invalid date components \(year)-\(month)-\(day)")
        }
        return calendar.startOfDay(for: date)
    }

    static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    static func addingDays(_ days: Int, to date: Date) -> Date {
        guard let result = calendar.date(byAdding: .day, value: days, to: date) else {
            preconditionFailure("Date arithmetic failed")
        }
        return result
    }

    static func days(from start: Date, to end: Date) -> Int {
        calendar.dateComponents([.day], from: startOfDay(start), to: startOfDay(end)).day ?? 0
    }

    static func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }

    static let mediumFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func mediumString(_ date: Date) -> String {
        mediumFormat.string(from: date)
    }
}

/// Abstraction over "now" so tests and UI tests can pin the current date.
protocol DateProviding {
    var now: Date { get }
}

struct SystemDateProvider: DateProviding {
    var now: Date { Date() }
}

struct FixedDateProvider: DateProviding {
    let fixed: Date
    var now: Date { fixed }
}

enum DateProviderFactory {
    /// In DEBUG builds, `--uitest-today yyyy-MM-dd` pins the app's notion of today
    /// so UI tests are deterministic. Release builds always use the system clock.
    static func make() -> DateProviding {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--uitest-today"), index + 1 < arguments.count {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone.current
            if let date = formatter.date(from: arguments[index + 1]) {
                return FixedDateProvider(fixed: DateMath.startOfDay(date))
            }
        }
        #endif
        return SystemDateProvider()
    }
}
