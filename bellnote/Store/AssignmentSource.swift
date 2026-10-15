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
        if let courseHint = DueDateMath.parseCourseDate(text),
           let date = courseDate(courseHint, lecture: lecture) {
            return date
        }
        guard let hint = DueDateMath.parse(text) else { return nil }
        return DueDateMath.due(
            from: lecture.startedAt,
            hint: hint,
            slotStartMinutes: hint == .nextWeek ? slotStart(for: lecture) : nil
        )
    }

    /// The end of the term, or the next midterm or final the student typed for this course.
    /// Nothing when that date is not set, so no date is guessed.
    private static func courseDate(_ hint: CourseDateHint, lecture: Lecture) -> Date? {
        guard let course = lecture.course else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: lecture.startedAt)
        switch hint {
        case .endOfTerm:
            guard let end = course.term?.endsOn else { return nil }
            let day = calendar.startOfDay(for: end)
            return day >= today ? day : nil
        case .midterm:
            return nextSitting(.midterm, in: course, from: today)
        case .final:
            return nextSitting(.final, in: course, from: today)
        }
    }

    private static func nextSitting(_ kind: ExamKind, in course: Course, from today: Date) -> Date? {
        let calendar = Calendar.current
        return course.sittings
            .filter { $0.kind == kind.rawValue }
            .compactMap(\.date)
            .map { calendar.startOfDay(for: $0) }
            .filter { $0 >= today }
            .min()
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
