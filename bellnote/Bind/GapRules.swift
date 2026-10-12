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
    var date: Date?
    var startMinutes: Int?
    var endMinutes: Int?

    var overlaps: Bool = false
}

enum ExamSort {
    static func ordered(_ rows: [ExamRow]) -> [ExamRow] {
        rows.sorted { left, right in
            switch (left.date, right.date) {
            case let (l?, r?) where l != r:
                return l < r
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            default:
                let lStart = left.startMinutes ?? Int.max
                let rStart = right.startMinutes ?? Int.max
                if lStart != rStart { return lStart < rStart }
                return left.courseName.localizedCompare(right.courseName) == .orderedAscending
            }
        }
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
