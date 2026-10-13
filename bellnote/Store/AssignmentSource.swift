import Foundation

extension Assignment {
    /// The recording this task was spoken in.
    var sourceLecture: Lecture? {
        course?.lectures.first { lecture in
            lecture.blocks.contains { $0.token == sourceBlockID }
        }
    }

    /// The due date computed from the words and the recording date.
    static func dueDate(for text: String, lecture: Lecture) -> Date? {
        guard let hint = DueDateMath.parse(text) else { return nil }
        return DueDateMath.due(
            from: lecture.startedAt,
            hint: hint,
            slotStartMinutes: hint == .nextWeek ? slotStart(for: lecture) : nil
        )
    }

    /// Older rows were saved before Turkish hints were read. Fill them from the spoken words.
    func fillDueIfMissing() {
        guard due == nil, let lecture = sourceLecture else { return }
        let spoken = lecture.blocks.first { $0.token == sourceBlockID }?.text
        for candidate in [text, spoken].compactMap({ $0 }) {
            if let date = Assignment.dueDate(for: candidate, lecture: lecture) {
                due = date
                return
            }
        }
    }

    /// Start of the course slot that the recording belongs to, if the course has one that day.
    private static func slotStart(for lecture: Lecture) -> Int? {
        guard let course = lecture.course else { return nil }
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: lecture.startedAt)
        let parts = calendar.dateComponents([.hour, .minute], from: lecture.startedAt)
        let started = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let slots = (course.term?.slots ?? []).filter { $0.course?.token == course.token && $0.weekday == weekday }
        return slots.min { abs($0.startMinutes - started) < abs($1.startMinutes - started) }?.startMinutes
    }
}
