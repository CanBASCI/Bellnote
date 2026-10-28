import Foundation

enum AttendanceKind: String, Sendable, Equatable {
    case recorded
    case missed
    case cancelled
    case noRecording
}

struct SessionMark: Sendable, Equatable {
    var day: Date
    var kind: AttendanceKind
}

enum GapRules {
    static func counts(in sessions: [SessionMark]) -> (recorded: Int, missed: Int, cancelled: Int, none: Int) {
        var recorded = 0
        var missed = 0
        var cancelled = 0
        var none = 0
        for session in sessions {
            switch session.kind {
            case .recorded: recorded += 1
            case .missed: missed += 1
            case .cancelled: cancelled += 1
            case .noRecording: none += 1
            }
        }
        return (recorded, missed, cancelled, none)
    }

    static func subtractsHours(_ kind: AttendanceKind) -> Bool {
        kind == .cancelled
    }
}

struct ExamRow: Identifiable, Sendable, Equatable {
    var id: UUID
    var courseName: String
    var kind: String
    /// The name typed for another exam. Empty for a midterm or a final. The default keeps older call sites.
    var title: String = ""
    var date: Date?
    var startMinutes: Int?
    var endMinutes: Int?
    /// Stored place. Empty when the student did not set one. The default keeps older call sites.
    var place: String = ""
    /// A score from 0 to 100, or empty until the result is typed. The default keeps older call sites.
    var score: String = ""

    var overlaps: Bool = false
}

enum ExamSort {
    /// Today or later, soonest first. Dates already past follow, the latest of those first.
    /// A sitting with no date stays last. On one day, the earlier clock leads while it is still ahead,
    /// and the later clock leads once that day has passed.
    static func ordered(_ rows: [ExamRow], now: Date = .now) -> [ExamRow] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return rows.sorted { left, right in
            let leftDay = left.date.map { calendar.startOfDay(for: $0) }
            let rightDay = right.date.map { calendar.startOfDay(for: $0) }
            switch (leftDay, rightDay) {
            case (nil, _):
                return false
            case (_, nil):
                return true
            case let (leftDay?, rightDay?):
                let leftPast = leftDay < today
                let rightPast = rightDay < today
                if leftPast != rightPast { return !leftPast }
                if leftDay != rightDay { return leftPast ? leftDay > rightDay : leftDay < rightDay }
                return earlierClock(left, right, past: leftPast)
            }
        }
    }

    /// The clock that comes first on a shared day. A past day leads with the later clock.
    private static func earlierClock(_ left: ExamRow, _ right: ExamRow, past: Bool) -> Bool {
        let leftStart = left.startMinutes ?? Int.max
        let rightStart = right.startMinutes ?? Int.max
        if leftStart != rightStart { return past ? leftStart > rightStart : leftStart < rightStart }
        return left.courseName.localizedCompare(right.courseName) == .orderedAscending
    }

    static func markingOverlaps(_ rows: [ExamRow]) -> [ExamRow] {
        let sorted = ordered(rows)
        var marked = sorted
        for index in marked.indices {
            guard let date = marked[index].date, let start = marked[index].startMinutes else { continue }
            let end = marked[index].endMinutes ?? (start + 60)
            for other in marked.indices where other != index {
                guard marked[other].date == date, let otherStart = marked[other].startMinutes else { continue }
                let otherEnd = marked[other].endMinutes ?? (otherStart + 60)
                if start < otherEnd && otherStart < end {
                    marked[index].overlaps = true
                }
            }
        }
        return marked
    }
}

/// Gedik University’s course-grade bands, applied to the number the student typed.
struct ExamGrade: Sendable, Equatable {
    enum Result: String, Sendable {
        case passed = "Passed"
        case conditional = "Conditional"
        case notPassed = "Not passed"

        /// English word for the on-device catalogue.
        var catalogue: String {
            switch self {
            case .passed: "passed"
            case .conditional: "conditional"
            case .notPassed: "not passed"
            }
        }
    }

    var letter: String
    var result: Result

    /// AA through FF for a whole number from 0 to 100. Anything else is nil.
    static func mark(for score: String) -> ExamGrade? {
        let trimmed = score.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Int(trimmed), (0...100).contains(number) else { return nil }
        let letter: String
        let result: Result
        switch number {
        case 88...100: letter = "AA"; result = .passed
        case 81...87: letter = "BA"; result = .passed
        case 76...80: letter = "BB"; result = .passed
        case 65...75: letter = "CB"; result = .passed
        case 55...64: letter = "CC"; result = .passed
        case 45...54: letter = "DC"; result = .conditional
        case 40...44: letter = "DD"; result = .conditional
        case 30...39: letter = "FD"; result = .notPassed
        default: letter = "FF"; result = .notPassed
        }
        return ExamGrade(letter: letter, result: result)
    }
}
