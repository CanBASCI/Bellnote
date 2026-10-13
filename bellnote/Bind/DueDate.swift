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
        // Turkish "ı" does not fold to "i" by itself.
        let folded = hint
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
            .replacingOccurrences(of: "ı", with: "i")
        let nextWeek = ["next week", "next lecture", "next class", "next session", "haftaya", "gelecek hafta", "sonraki ders", "bir sonraki hafta"]
        if nextWeek.contains(where: folded.contains) { return .nextWeek }
        if folded.contains("this week") || folded.contains("bu hafta") { return .thisWeek }
        if folded.contains("tomorrow") || folded.contains("yarin") { return .tomorrow }
        if folded.contains("today") || folded.contains("bugun") { return .today }
        if let days = days(in: folded) { return .inDays(days) }
        if let date = isoDate(in: hint, calendar: calendar) { return .explicit(date) }
        return nil
    }

    /// "Next week" means the next lecture of this course: the same weekday, one week later, at the
    /// time of the slot (or of the recording when the course has no slot that day).
    static func due(
        from lectureDate: Date,
        hint: DueHint,
        slotStartMinutes: Int? = nil,
        calendar: Calendar = .current
    ) -> Date {
        switch hint {
        case .today:
            return calendar.startOfDay(for: lectureDate)
        case .tomorrow:
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lectureDate)) ?? lectureDate
        case .thisWeek:
            return endOfWeek(containing: lectureDate, calendar: calendar)
        case .nextWeek:
            let sameDay = calendar.date(byAdding: .day, value: 7, to: lectureDate) ?? lectureDate
            guard let slotStartMinutes else { return sameDay }
            return calendar.date(
                byAdding: .minute,
                value: slotStartMinutes,
                to: calendar.startOfDay(for: sameDay)
            ) ?? sameDay
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
        let patterns: [(String, Int)] = [
            (#"in\s+(\d+)\s+days?"#, 1),
            (#"(\d+)\s+gun\s+sonra"#, 1),
            (#"in\s+(\d+)\s+weeks?"#, 7),
            (#"(\d+)\s+hafta\s+sonra"#, 7)
        ]
        for (pattern, factor) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(folded.startIndex..<folded.endIndex, in: folded)
            guard let match = regex.firstMatch(in: folded, range: range),
                  let span = Range(match.range(at: 1), in: folded),
                  let count = Int(folded[span]) else {
                continue
            }
            return count * factor
        }
        return nil
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
