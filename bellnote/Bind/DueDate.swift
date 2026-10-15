import Foundation

enum DueHint: Sendable, Equatable {
    case nextWeek
    case thisWeek
    case tomorrow
    case today
    case inDays(Int)
    case inMonths(Int)
    case endOfMonth
    /// A day of the month without a month, such as "ayın 15'ine kadar".
    case dayOfMonth(Int)
    /// A day of the week, as `Calendar` numbers it: 1 is Sunday, 2 is Monday.
    case weekday(Int)
    /// A day of the week named together with "next week", such as "haftaya cuma".
    case weekdayNextWeek(Int)
    /// A spoken day and month without a year, such as "22 Kasım".
    case monthDay(month: Int, day: Int)
    case explicit(Date)
}

/// A hint that points at a date the course already has, not at a date counted from the recording.
enum CourseDateHint: Sendable, Equatable {
    case midterm
    case final
    case endOfTerm
}

enum DueDateMath {
    /// Lower case without accents. Turkish "ı" does not fold to "i" by itself.
    private static func fold(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
            .replacingOccurrences(of: "ı", with: "i")
    }

    /// "Vizeye kadar", "before the final", "dönem sonuna kadar". The date itself comes from the
    /// course: the exam dates the student typed and the end of the term.
    static func parseCourseDate(_ hint: String) -> CourseDateHint? {
        let folded = fold(hint)
        if firstMatch(#"\bdonem(?:in)?\s+sonu"#, in: folded) != nil
            || firstMatch(#"\bend\s+of\s+(?:the\s+|this\s+)?(?:semester|term)\b"#, in: folded) != nil {
            return .endOfTerm
        }
        // "Vize" alone can also mean a visa, so the word needs "kadar" or "önce" after it.
        if firstMatch(#"\bvize(?:ye|den)\s+(?:kadar|dek|once|evvel)\b"#, in: folded) != nil
            || firstMatch(#"\b(?:before|until|by|till)\s+(?:the\s+)?midterms?(?:\s+exam)?\b"#, in: folded) != nil {
            return .midterm
        }
        if firstMatch(#"\bfinal(?:e|den)\s+(?:kadar|dek|once|evvel)\b"#, in: folded) != nil
            || firstMatch(#"\b(?:before|until|by|till)\s+(?:the\s+)?(?:final\s+exam|finals|final(?![a-z]|\s+[a-z]))"#, in: folded) != nil {
            return .final
        }
        return nil
    }

    static func parse(_ hint: String, calendar: Calendar = .current) -> DueHint? {
        let folded = fold(hint)
        let nextWeek = [
            "next week", "next lecture", "next class", "next session", "the following week",
            "haftaya", "gelecek hafta", "sonraki hafta", "onumuzdeki hafta",
            "sonraki ders", "gelecek ders", "onumuzdeki ders"
        ]
        if nextWeek.contains(where: folded.contains) {
            // "Haftaya cuma" names the day, so the day wins over the lecture's own weekday.
            if let weekday = weekday(in: folded) { return .weekdayNextWeek(weekday) }
            return .nextWeek
        }
        let thisWeek = ["this week", "bu hafta", "hafta sonuna", "end of the week", "end of this week"]
        if thisWeek.contains(where: folded.contains) { return .thisWeek }
        // Before "tomorrow", because these phrases contain it.
        let dayAfterTomorrow = ["day after tomorrow", "obur gun", "yarindan sonra"]
        if dayAfterTomorrow.contains(where: folded.contains) { return .inDays(2) }
        if folded.contains("tomorrow") || folded.contains("yarin") { return .tomorrow }
        let today = ["today", "tonight", "this evening", "bugun", "bu aksam", "bu gece"]
        if today.contains(where: folded.contains) { return .today }
        if let days = days(in: folded) { return .inDays(days) }
        if let months = months(in: folded) { return .inMonths(months) }
        if firstMatch(#"\bay(?:in)?\s+sonu"#, in: folded) != nil
            || firstMatch(#"\bend\s+of\s+(?:the\s+|this\s+)?month\b"#, in: folded) != nil {
            return .endOfMonth
        }
        // "Ayın 15'ine kadar": the month the teacher is speaking in.
        if let day = firstMatch(#"\b(?:ayin|bu\s+ay)\s+(\d{1,2})"#, in: folded)?.first.flatMap({ Int($0) }),
           (1...31).contains(day) {
            return .dayOfMonth(day)
        }
        if let date = isoDate(in: hint, calendar: calendar) { return .explicit(date) }
        if let date = numericDate(in: folded, calendar: calendar) { return .explicit(date) }
        if let monthDay = monthDay(in: folded) { return monthDay }
        // Last, because a weekday name is the loosest hint.
        if let weekday = weekday(in: folded) { return .weekday(weekday) }
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
        case .inMonths(let count):
            return calendar.date(byAdding: .month, value: count, to: calendar.startOfDay(for: lectureDate)) ?? lectureDate
        case .weekday(let weekday):
            // The next such day after the recording day. The same weekday means one week later.
            let start = calendar.startOfDay(for: lectureDate)
            return calendar.nextDate(after: start, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime) ?? start
        case .endOfMonth:
            let start = calendar.dateInterval(of: .month, for: lectureDate)?.start ?? calendar.startOfDay(for: lectureDate)
            let next = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            let last = calendar.date(byAdding: .day, value: -1, to: next) ?? start
            return calendar.startOfDay(for: last)
        case .dayOfMonth(let day):
            return nextDayOfMonth(day, from: lectureDate, calendar: calendar)
        case .weekdayNextWeek(let weekday):
            // The day in the calendar week after the recording week.
            let weekEnd = endOfWeek(containing: lectureDate, calendar: calendar)
            return calendar.nextDate(after: weekEnd, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime) ?? weekEnd
        case .monthDay(let month, let day):
            return nextOccurrence(month: month, day: day, from: lectureDate, calendar: calendar)
        case .explicit(let date):
            return calendar.startOfDay(for: date)
        }
    }

    /// This day of the month in the month of the recording, or in the next month that has such a day
    /// when it has already passed.
    private static func nextDayOfMonth(_ day: Int, from lectureDate: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: lectureDate)
        let parts = calendar.dateComponents([.year, .month], from: start)
        guard let monthStart = calendar.date(from: parts) else { return start }
        for offset in 0...12 {
            guard let base = calendar.date(byAdding: .month, value: offset, to: monthStart) else { continue }
            let target = calendar.dateComponents([.year, .month], from: base)
            let candidate = DateComponents(year: target.year, month: target.month, day: day)
            if let date = calendar.date(from: candidate), date >= start,
               calendar.component(.month, from: date) == target.month {
                return date
            }
        }
        return start
    }

    /// The first date with this month and day on or after the recording day, this year or the next.
    private static func nextOccurrence(month: Int, day: Int, from lectureDate: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: lectureDate)
        let year = calendar.component(.year, from: start)
        for candidateYear in [year, year + 1] {
            let parts = DateComponents(year: candidateYear, month: month, day: day)
            if let date = calendar.date(from: parts), date >= start,
               calendar.component(.month, from: date) == month {
                return date
            }
        }
        return start
    }

    static func endOfWeek(containing date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        return calendar.startOfDay(for: end)
    }

    /// Spoken numbers as they look after folding, so that "kırk beş" and "forty-five" are read.
    /// Digits are read too. Written numbers go up to one hundred.
    private static let numberWords: [String: Int] = [
        "bir": 1, "iki": 2, "uc": 3, "dort": 4, "bes": 5, "alti": 6, "yedi": 7, "sekiz": 8, "dokuz": 9,
        "on": 10, "yirmi": 20, "otuz": 30, "kirk": 40, "elli": 50, "altmis": 60, "yetmis": 70,
        "seksen": 80, "doksan": 90, "yuz": 100,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
        "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100
    ]

    /// Digits, or one or more number words joined by spaces or hyphens.
    private static var numberPattern: String {
        let word = numberWords.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        return #"\d+|(?:\#(word))(?:[\s-]+(?:\#(word)))*"#
    }

    private static let turkishMonths: [(String, Int)] = [
        ("ocak", 1), ("subat", 2), ("mart", 3), ("nisan", 4), ("mayis", 5), ("haziran", 6),
        ("temmuz", 7), ("agustos", 8), ("eylul", 9), ("ekim", 10), ("kasim", 11), ("aralik", 12)
    ]

    private static let englishMonths: [(String, Int)] = [
        ("january", 1), ("february", 2), ("march", 3), ("april", 4), ("may", 5), ("june", 6),
        ("july", 7), ("august", 8), ("september", 9), ("october", 10), ("november", 11), ("december", 12)
    ]

    /// The longest each month can be, February with a leap day.
    private static let daysInMonth = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    /// Weekday names as they look after folding, with the Turkish endings ("cumaya", "pazartesiye").
    /// Sunday needs "gunu" or an ending, so that "pazarlama" is not read as a day.
    private static let weekdayPatterns: [(String, Int)] = [
        (#"\bpazartesi(?:y?[ae])?\b"#, 2), (#"\bsali(?:y?[ae])?\b"#, 3), (#"\bcarsamba(?:y?[ae])?\b"#, 4),
        (#"\bpersembe(?:y?[ae])?\b"#, 5), (#"\bcuma(?:y?[ae])?\b"#, 6), (#"\bcumartesi(?:y?[ae])?\b"#, 7),
        (#"\bpazar(?:\s+gun\w*|y?a)\b"#, 1),
        (#"\bmonday\b"#, 2), (#"\btuesday\b"#, 3), (#"\bwednesday\b"#, 4), (#"\bthursday\b"#, 5),
        (#"\bfriday\b"#, 6), (#"\bsaturday\b"#, 7), (#"\bsunday\b"#, 1)
    ]

    private static func days(in folded: String) -> Int? {
        let number = numberPattern
        let patterns: [(String, Int)] = [
            (#"in\s+(\#(number))\s+days?"#, 1),
            (#"(?<![a-z])(\#(number))\s+gun\s+(?:sonra|icinde)"#, 1),
            (#"in\s+(\#(number))\s+weeks?"#, 7),
            (#"(?<![a-z])(\#(number))\s+hafta\s+(?:sonra|icinde)"#, 7)
        ]
        for (pattern, factor) in patterns {
            if let count = spokenCount(pattern, in: folded) { return count * factor }
        }
        if firstMatch(#"\bin\s+a\s+week\b"#, in: folded) != nil
            || firstMatch(#"\ba\s+week\s+from\s+(?:now|today)\b"#, in: folded) != nil {
            return 7
        }
        return nil
    }

    private static func months(in folded: String) -> Int? {
        if firstMatch(#"(?:gelecek|sonraki|onumuzdeki)\s+ay\b"#, in: folded) != nil
            || firstMatch(#"next\s+month\b"#, in: folded) != nil {
            return 1
        }
        let number = numberPattern
        let patterns = [
            #"(?<![a-z])(\#(number))\s+ay\s+(?:sonra|icinde)"#,
            #"in\s+(\#(number))\s+months?"#
        ]
        for pattern in patterns {
            if let count = spokenCount(pattern, in: folded) { return count }
        }
        return nil
    }

    private static func weekday(in folded: String) -> Int? {
        weekdayPatterns.first { firstMatch($0.0, in: folded) != nil }?.1
    }

    /// A day and a month, such as "22 kasima kadar" or "november 22". The year is not spoken.
    private static func monthDay(in folded: String) -> DueHint? {
        for (name, month) in turkishMonths {
            let pattern = #"(?<![0-9])(\d{1,2})\s+\#(name)\w*"#
            if let hint = monthDayHint(month: month, groups: firstMatch(pattern, in: folded)) { return hint }
        }
        for (name, month) in englishMonths {
            let patterns = [
                #"(?<![0-9])(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?\#(name)\b"#,
                #"\b\#(name)\s+(\d{1,2})(?:st|nd|rd|th)?\b"#
            ]
            for pattern in patterns {
                if let hint = monthDayHint(month: month, groups: firstMatch(pattern, in: folded)) { return hint }
            }
        }
        return nil
    }

    /// A full written date such as "22.11.2026" or "22/11/26". A date without a year is not read,
    /// because "2.5" and "1/2" are usually numbers, not dates.
    private static func numericDate(in text: String, calendar: Calendar) -> Date? {
        let pattern = #"(?<![0-9.])(\d{1,2})[./](\d{1,2})[./](\d{4}|\d{2})(?![0-9])"#
        guard let groups = firstMatch(pattern, in: text), groups.count == 3,
              let day = Int(groups[0]), let month = Int(groups[1]), let written = Int(groups[2]),
              (1...12).contains(month), day >= 1, day <= daysInMonth[month - 1] else {
            return nil
        }
        let year = written < 100 ? 2000 + written : written
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.month, from: date) == month else {
            return nil
        }
        return date
    }

    private static func monthDayHint(month: Int, groups: [String]?) -> DueHint? {
        guard let first = groups?.first, let day = Int(first), day >= 1, day <= daysInMonth[month - 1] else {
            return nil
        }
        return .monthDay(month: month, day: day)
    }

    /// The number in the first group of the pattern, written in digits or as words.
    private static func spokenCount(_ pattern: String, in folded: String) -> Int? {
        guard let phrase = firstMatch(pattern, in: folded)?.first else { return nil }
        return number(from: phrase)
    }

    /// "45" is 45, "kirk bes" and "forty-five" are 45, "yuz" is 100. Words above one hundred are not read.
    private static func number(from phrase: String) -> Int? {
        if let digits = Int(phrase) { return digits }
        var total = 0
        for token in phrase.split(whereSeparator: { $0 == "-" || $0.isWhitespace }) {
            guard let value = numberWords[String(token)] else { return nil }
            total = value == 100 ? max(total, 1) * 100 : total + value
        }
        return (1...100).contains(total) ? total : nil
    }

    /// The text of every group of the first match, or nil when the pattern does not match.
    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (1..<max(match.numberOfRanges, 1)).map { index in
            guard let span = Range(match.range(at: index), in: text) else { return "" }
            return String(text[span])
        }
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
