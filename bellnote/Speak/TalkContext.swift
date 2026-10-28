import Foundation
import SwiftData

/// Builds the Talk assistant’s readable facts from the terms it is given.
/// The session passes the term selected on the home page.
/// Settings are not in this catalogue.
@MainActor
enum TalkContext {
    private static let catalogBudget = 4_500
    private static let dateFormat: Date.FormatStyle = .dateTime.day().month(.abbreviated).year()

    /// One StudyBlock per stored note line, with term / course / lecture / time in the text and topics
    /// so BM25 and the model can answer “which course, which term, when”.
    static func noteBlocks(from terms: [Term]) -> [StudyBlock] {
        var blocks: [StudyBlock] = []
        for term in terms {
            let termLabel = termLabel(term)
            for course in term.courses {
                for lecture in course.lectures where lecture.state == LectureState.ready.rawValue {
                    let lectureLabel = lectureTitle(lecture)
                    let day = lecture.startedAt.formatted(dateFormat)
                    for block in lecture.blocks where !block.text.isEmpty {
                        let clock = MediaClock.short(block.second)
                        let prefix =
                            "[\(termLabel); course \(course.name); lecture \(lectureLabel); \(day); \(clock)] "
                        var topics = block.topics
                        topics.append(contentsOf: [course.name, termLabel, lectureLabel, day])
                        blocks.append(
                            StudyBlock(
                                id: block.token,
                                at: lecture.startedAt,
                                second: block.second,
                                kind: BlockKind(tag: block.kind),
                                text: prefix + block.text,
                                topics: topics,
                                importance: block.importance,
                                missing: block.missing,
                                userFlag: block.userFlag,
                                examScope: block.kind == BlockKind.examScope.rawValue
                            )
                        )
                    }
                }
            }
        }
        return blocks
    }

    /// Structured facts about the library. Always offered to the model (budget-capped).
    /// Wall clock is not stored here — `LocalModelRuntime.answer` attaches a fresh Device clock each call.
    /// Settings stay out of this catalogue so they do not spend the prompt budget.
    static func catalogTags(terms: [Term], session: AppSession) -> [WindowTag] {
        var lines: [String] = []
        lines.append("App catalogue (facts on this device):")
        let sortedTerms = terms.sorted {
            ($0.yearOfStudy, $0.termNumber, $0.createdAt) < ($1.yearOfStudy, $1.termNumber, $1.createdAt)
        }
        for term in sortedTerms {
            lines.append(contentsOf: termLines(term))
        }
        var tags: [WindowTag] = []
        var used = 0
        for line in lines {
            let size = line.count + 1
            if used + size > catalogBudget, !tags.isEmpty { break }
            tags.append(
                WindowTag(
                    language: session.locale.identifier,
                    speakerRole: "catalog",
                    kind: BlockKind.other.rawValue,
                    topics: [],
                    text: line,
                    importanceCue: false,
                    missing: false
                )
            )
            used += size
        }
        return tags
    }

    private static func termLines(_ term: Term) -> [String] {
        var lines: [String] = []
        let label = termLabel(term)
        let open = term.isOpen ? "open" : "closed"
        let start = term.startsOn.formatted(dateFormat)
        let end = term.endsOn.formatted(dateFormat)
        lines.append(
            "Term \(label) (\(open)): \(start) to \(end); courses \(term.courses.count); "
                + "timetable slots \(term.slots.count)."
        )
        for course in term.courses.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            lines.append(contentsOf: courseLines(course, termLabel: label))
        }
        // Full weekday names, same words as the device clock (“Çarşamba”, not “Çar”).
        // A day with no row is written out so the model does not fill it from another day.
        let symbols = Calendar.current.standaloneWeekdaySymbols
        let byDay = Dictionary(grouping: term.slots, by: \.weekday)
        for weekday in 1...7 {
            let day = symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : "?"
            let daySlots = (byDay[weekday] ?? []).sorted { $0.startMinutes < $1.startMinutes }
            if daySlots.isEmpty {
                lines.append("Timetable \(label): \(day); no slots.")
                continue
            }
            for slot in daySlots {
                let courseName = slot.course?.name ?? "no course"
                let shownPlace = PlacePreset.displayName(for: slot.placeName)
                let place = shownPlace.isEmpty ? "no place" : shownPlace
                lines.append(
                    "Timetable \(label): \(day) \(ReminderScheduler.clock(slot.startMinutes))–"
                        + "\(ReminderScheduler.clock(slot.endMinutes)); course \(courseName); place \(place)."
                )
            }
        }
        return lines
    }

    private static func courseLines(_ course: Course, termLabel: String) -> [String] {
        var lines: [String] = []
        let ready = course.lectures.filter { $0.state == LectureState.ready.rawValue }.count
        let total = course.lectures.count
        let favorite = course.isFavorite ? "favorite; " : ""
        let lecturer = course.lecturer?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lecturerPart = lecturer.isEmpty ? "" : "lecturer \(lecturer); "
        lines.append(
            "Course \(course.name) in \(termLabel): \(favorite)\(lecturerPart)"
                + "language \(course.localeIdentifier); recordings \(ready) ready of \(total); "
                + "open assignments \(course.assignments.filter { !$0.done && !$0.cancelled }.count); "
                + "exams \(course.sittings.count); inventory \(course.inventory.count)."
        )
        for lecture in course.lectures.sorted(by: { $0.startedAt > $1.startedAt }) {
            let title = lectureTitle(lecture)
            let day = lecture.startedAt.formatted(dateFormat)
            let minutes = max(lecture.recordedSeconds / 60, 0)
            let state = Self.recordingStateWord(lecture)
            lines.append(
                "Recording in \(course.name) (\(termLabel)): \(title); \(day); \(minutes) min; state \(state)."
            )
        }
        for assignment in course.assignments {
            let due = assignment.due?.formatted(dateFormat) ?? "no due date"
            let status: String
            if assignment.cancelled {
                status = "cancelled"
            } else if assignment.done {
                status = "done"
            } else {
                status = "open"
            }
            let task = assignment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let taskLabel = task.isEmpty ? "untitled task" : task
            lines.append(
                "Assignment in \(course.name) (\(termLabel)): \(taskLabel); due \(due); \(status)."
            )
        }
        for sitting in course.sittings {
            let when = sitting.date?.formatted(dateFormat) ?? "no date"
            let title = sitting.title.isEmpty ? sitting.kind : sitting.title
            let score: String
            if sitting.scoreText.isEmpty {
                score = "no score"
            } else if let grade = ExamGrade.mark(for: sitting.scoreText) {
                score = "score \(sitting.scoreText) out of 100, letter \(grade.letter), \(grade.result.catalogue)"
            } else {
                score = "score \(sitting.scoreText) out of 100"
            }
            let place = sitting.place.isEmpty ? "no place" : sitting.place
            lines.append(
                "Exam in \(course.name) (\(termLabel)): \(title); \(when); \(place); \(score)."
            )
        }
        for item in course.inventory {
            lines.append(
                "Inventory in \(course.name) (\(termLabel)): \(item.title) (\(item.kind))."
            )
        }
        for file in course.files {
            let name = file.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = name.isEmpty ? "untitled file" : name
            lines.append("File on \(course.name) (\(termLabel)): \(shown).")
        }
        for note in course.stickies {
            let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let drawn = note.drawingData?.isEmpty == false
            if text.isEmpty {
                if drawn {
                    lines.append(
                        "Student sticky on \(course.name) (\(termLabel)): a drawing the student made. It is not described. It is not a lecture."
                    )
                }
                continue
            }
            let picture = drawn ? " The student also drew on it. The drawing is not described." : ""
            lines.append(
                "Student sticky on \(course.name) (\(termLabel)): \(text). The student wrote this.\(picture) It is not a lecture."
            )
        }
        return lines
    }

    private static func termLabel(_ term: Term) -> String {
        let trimmed = term.customName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "year \(term.yearOfStudy) term \(term.termNumber)"
    }

    private static func lectureTitle(_ lecture: Lecture) -> String {
        let trimmed = lecture.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return lecture.startedAt.formatted(dateFormat)
    }

    /// The word the student sees. A stopped recording that was never processed is “recorded”, not “paused”.
    private static func recordingStateWord(_ lecture: Lecture) -> String {
        if lecture.isRecordedOnly { return "recorded, not processed" }
        switch LectureState(rawValue: lecture.state) {
        case .paused: return "paused, not processed"
        case .ready: return "ready"
        case .processing: return "processing"
        case .recording: return "recording"
        case .failed: return "failed"
        case nil: return lecture.state
        }
    }
}
