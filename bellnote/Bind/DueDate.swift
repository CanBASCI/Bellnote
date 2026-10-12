import Foundation

enum DueHint: Sendable, Equatable {
    case nextWeek
    case thisWeek
    case tomorrow
    case today
    case inDays(Int)
    case explicit(Date)
}

enum DueDateMath {
    static func parse(_ hint: String, calendar: Calendar = .current) -> DueHint? {
        let folded = hint.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
        if folded.contains("next week") { return .nextWeek }
        if folded.contains("this week") { return .thisWeek }
        if folded.contains("tomorrow") { return .tomorrow }
        if folded.contains("today") { return .today }
        if let days = days(in: folded) { return .inDays(days) }
        if let date = isoDate(in: hint, calendar: calendar) { return .explicit(date) }
        return nil
    }

    static func due(from lectureDate: Date, hint: DueHint, calendar: Calendar = .current) -> Date {
        switch hint {
        case .today:
            return calendar.startOfDay(for: lectureDate)
        case .tomorrow:
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lectureDate)) ?? lectureDate
        case .thisWeek:
            return endOfWeek(containing: lectureDate, calendar: calendar)
        case .nextWeek:
            let thisEnd = endOfWeek(containing: lectureDate, calendar: calendar)
            return calendar.date(byAdding: .day, value: 7, to: thisEnd) ?? thisEnd
        case .inDays(let count):
            return calendar.date(byAdding: .day, value: count, to: calendar.startOfDay(for: lectureDate)) ?? lectureDate
        case .explicit(let date):
            return calendar.startOfDay(for: date)
        }
    }

    static func endOfWeek(containing date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        return calendar.startOfDay(for: end)
    }

    private static func days(in folded: String) -> Int? {
        let pattern = #"in\s+(\d+)\s+days?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(folded.startIndex..<folded.endIndex, in: folded)
        guard let match = regex.firstMatch(in: folded, range: range),
              let span = Range(match.range(at: 1), in: folded) else {
            return nil
        }
        return Int(folded[span])
    }

    private static func isoDate(in hint: String, calendar: Calendar) -> Date? {
        let pattern = #"\d{4}-\d{2}-\d{2}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(hint.startIndex..<hint.endIndex, in: hint)
        guard let match = regex.firstMatch(in: hint, range: range),
              let span = Range(match.range, in: hint) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(hint[span]))
    }
}
