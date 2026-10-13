import Foundation
import SwiftData

@Model
final class Term {
    var yearOfStudy: Int
    var termNumber: Int
    var customName: String
    var startsOn: Date
    var endsOn: Date
    var isOpen: Bool
    var schedulePhotoRelativePath: String?
    var keepScheduleSource: Bool
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Course.term)
    var courses: [Course]

    @Relationship(deleteRule: .cascade, inverse: \WeeklySlot.term)
    var slots: [WeeklySlot]

    @Relationship(deleteRule: .cascade, inverse: \CancelledWeek.term)
    var cancelledWeeks: [CancelledWeek]

    init(
        yearOfStudy: Int,
        termNumber: Int,
        customName: String = "",
        startsOn: Date,
        endsOn: Date,
        isOpen: Bool = false
    ) {
        self.yearOfStudy = yearOfStudy
        self.termNumber = termNumber
        self.customName = customName
        self.startsOn = startsOn
        self.endsOn = endsOn
        self.isOpen = isOpen
        self.keepScheduleSource = false
        self.createdAt = Date()
        self.courses = []
        self.slots = []
        self.cancelledWeeks = []
    }
}

@Model
final class Course {
    var token: UUID
    var name: String
    var localeIdentifier: String
    var createdAt: Date

    var term: Term?

    @Relationship(deleteRule: .cascade, inverse: \Lecture.course)
    var lectures: [Lecture]

    @Relationship(deleteRule: .cascade, inverse: \Voiceprint.course)
    var voiceprints: [Voiceprint]

    @Relationship(deleteRule: .cascade, inverse: \TopicAlias.course)
    var aliases: [TopicAlias]

    @Relationship(deleteRule: .cascade, inverse: \ExamSitting.course)
    var sittings: [ExamSitting]

    @Relationship(deleteRule: .cascade, inverse: \Assignment.course)
    var assignments: [Assignment]

    @Relationship(deleteRule: .cascade, inverse: \QuizAttempt.course)
    var quizAttempts: [QuizAttempt]

    @Relationship(deleteRule: .cascade, inverse: \InventoryItem.course)
    var inventory: [InventoryItem]

    @Relationship(deleteRule: .cascade, inverse: \CourseFile.course)
    var files: [CourseFile]

    @Relationship(deleteRule: .cascade, inverse: \LecturerContact.course)
    var lecturer: LecturerContact?

    init(name: String, localeIdentifier: String, term: Term?) {
        self.token = UUID()
        self.name = name
        self.localeIdentifier = localeIdentifier
        self.createdAt = Date()
        self.term = term
        self.lectures = []
        self.voiceprints = []
        self.aliases = []
        self.sittings = []
        self.assignments = []
        self.quizAttempts = []
        self.inventory = []
        self.files = []
    }
}

@Model
final class LecturerContact {
    var title: String
    var givenName: String
    var familyName: String
    var phone: String
    var email: String
    var extra: String
    var course: Course?

    init() {
        self.title = ""
        self.givenName = ""
        self.familyName = ""
        self.phone = ""
        self.email = ""
        self.extra = ""
    }

    var displayName: String {
        [title, givenName, familyName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

@Model
final class WeeklySlot {
    var token: UUID
    var weekday: Int
    var startMinutes: Int
    var endMinutes: Int
    var placeName: String
    var placeKind: String
    var reminderKind: String
    var leadMinutes: Int
    var course: Course?
    var term: Term?

    @Relationship(deleteRule: .cascade, inverse: \SlotException.slot)
    var exceptions: [SlotException]

    init(
        weekday: Int,
        startMinutes: Int,
        endMinutes: Int,
        course: Course?,
        term: Term?,
        placeName: String = "",
        placeKind: SlotPlace = .inPerson
    ) {
        self.token = UUID()
        self.weekday = weekday
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.placeName = placeName
        self.placeKind = placeKind.rawValue
        self.reminderKind = ReminderKind.none.rawValue
        self.leadMinutes = 10
        self.course = course
        self.term = term
        self.exceptions = []
    }
}

@Model
final class SlotException {
    var weekStart: Date
    var cancelled: Bool
    var overridePlaceKind: String?
    var overrideStartMinutes: Int?
    var overrideEndMinutes: Int?
    var slot: WeeklySlot?

    init(weekStart: Date, slot: WeeklySlot) {
        self.weekStart = weekStart
        self.cancelled = false
        self.slot = slot
    }
}

@Model
final class CancelledWeek {
    var weekStart: Date
    var term: Term?

    init(weekStart: Date, term: Term?) {
        self.weekStart = weekStart
        self.term = term
    }
}

@Model
final class Lecture {
    var startedAt: Date
    var recordedSeconds: Int
    var state: String
    var stage: String
    var audioRelativePath: String?
    var title: String
    var failureMessageKey: String?
    var oralExam: Bool
    var examSpanStart: Int?
    var examSpanEnd: Int?
    var summary: String
    var flaggedSeconds: [Int]
    var processedThroughSecond: Int
    var neededModel: String?
    var speakerNames: [String] = []
    var course: Course?

    @Relationship(deleteRule: .cascade, inverse: \Block.lecture)
    var blocks: [Block]

    @Relationship(deleteRule: .cascade, inverse: \Attestation.lecture)
    var attestation: Attestation?

    @Relationship(deleteRule: .cascade, inverse: \BoardPhoto.lecture)
    var boardPhotos: [BoardPhoto]

    @Relationship(deleteRule: .cascade, inverse: \PauseSegment.lecture)
    var pauses: [PauseSegment]

    init(course: Course, startedAt: Date = Date(), oralExam: Bool = false, title: String = "") {
        self.course = course
        self.startedAt = startedAt
        self.recordedSeconds = 0
        self.state = LectureState.recording.rawValue
        self.stage = PipelineStage.idle.rawValue
        self.oralExam = oralExam
        self.title = title
        self.summary = ""
        self.flaggedSeconds = []
        self.processedThroughSecond = 0
        self.speakerNames = []
        self.blocks = []
        self.boardPhotos = []
        self.pauses = []
    }

    func speakerName(for cluster: Int) -> String? {
        let prefix = "\(cluster)\t"
        guard let line = speakerNames.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let name = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func setSpeakerName(_ name: String, cluster: Int) {
        let prefix = "\(cluster)\t"
        speakerNames.removeAll { $0.hasPrefix(prefix) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speakerNames.append(prefix + trimmed)
    }
}

@Model
final class PauseSegment {
    var startedAt: Date
    var endedAt: Date?
    var lecture: Lecture?

    init(startedAt: Date, lecture: Lecture) {
        self.startedAt = startedAt
        self.lecture = lecture
    }
}

@Model
final class Attestation {
    var allowedStatement: Bool
    var permittedStatement: Bool
    var attestedAt: Date
    var appVersion: String
    var faceIDSucceeded: Bool
    var lecture: Lecture?

    init(appVersion: String, faceIDSucceeded: Bool) {
        self.allowedStatement = true
        self.permittedStatement = true
        self.attestedAt = Date()
        self.appVersion = appVersion
        self.faceIDSucceeded = faceIDSucceeded
    }
}

@Model
final class Block {
    var token: UUID
    var second: Int
    var role: String
    var kind: String
    var text: String
    var topics: [String]
    var listItems: [String]
    var numbers: [Double]
    var importance: Bool
    var missing: Bool
    var userFlag: Bool
    var studentNote: String
    var timeHintRaw: String?
    var dueHintRaw: String?
    var speaker: Int = 0
    var lecture: Lecture?

    @Relationship(deleteRule: .cascade, inverse: \NoteLink.from)
    var outgoing: [NoteLink]

    init(
        lecture: Lecture,
        second: Int,
        role: SpeakerRole,
        kind: BlockKind,
        text: String,
        topics: [String] = [],
        listItems: [String] = [],
        numbers: [Double] = [],
        importance: Bool = false,
        missing: Bool = false,
        speaker: Int = 0
    ) {
        self.token = UUID()
        self.lecture = lecture
        self.second = second
        self.role = role.rawValue
        self.kind = kind.rawValue
        self.text = text
        self.topics = topics
        self.listItems = listItems
        self.numbers = numbers
        self.importance = importance
        self.missing = missing
        self.userFlag = false
        self.studentNote = ""
        self.speaker = speaker
        self.outgoing = []
    }
}

@Model
final class NoteLink {
    var toBlockID: UUID?
    var why: String
    var from: Block?

    init(from: Block, toBlockID: UUID?, why: String) {
        self.from = from
        self.toBlockID = toBlockID
        self.why = why
    }
}

@Model
final class Assignment {
    var text: String
    var due: Date?
    var done: Bool
    /// The lecturer took the task back, for example in a mail. Only the student sets this.
    var cancelled: Bool = false
    var sourceBlockID: UUID
    var sourceSecond: Int
    var course: Course?

    init(course: Course, text: String, due: Date?, sourceBlockID: UUID, sourceSecond: Int) {
        self.course = course
        self.text = text
        self.due = due
        self.done = false
        self.sourceBlockID = sourceBlockID
        self.sourceSecond = sourceSecond
    }
}

@Model
final class QuizAttempt {
    var at: Date
    var correct: Int
    var partial: Int
    var wrong: Int
    var missedBlockIDs: [UUID]
    var filterKey: String
    var cursor: Int
    var course: Course?

    init(course: Course, filterKey: String = "") {
        self.course = course
        self.at = Date()
        self.correct = 0
        self.partial = 0
        self.wrong = 0
        self.missedBlockIDs = []
        self.filterKey = filterKey
        self.cursor = 0
    }
}

@Model
final class Voiceprint {
    var label: String
    var vector: [Double]
    var course: Course?

    init(label: String, vector: [Double], course: Course) {
        self.label = label
        self.vector = vector
        self.course = course
    }
}

@Model
final class TopicAlias {
    var left: String
    var right: String
    var course: Course?

    init(left: String, right: String, course: Course) {
        self.left = left
        self.right = right
        self.course = course
    }
}

@Model
final class ExamSitting {
    var token: UUID
    var kind: String
    var title: String
    var date: Date?
    var startMinutes: Int?
    var endMinutes: Int?
    var place: String
    var scoreText: String
    var reminderKind: String
    var leadDays: Int
    var preferredTopic: String
    var course: Course?

    @Relationship(deleteRule: .cascade, inverse: \ExamPaperPhoto.sitting)
    var papers: [ExamPaperPhoto]

    init(course: Course, kind: ExamKind, title: String = "", date: Date? = nil) {
        self.token = UUID()
        self.course = course
        self.kind = kind.rawValue
        self.title = title
        self.date = date
        self.place = ""
        self.scoreText = ""
        self.reminderKind = ReminderKind.none.rawValue
        self.leadDays = 1
        self.preferredTopic = ""
        self.papers = []
    }
}

@Model
final class ExamPaperPhoto {
    var relativePath: String
    var sitting: ExamSitting?

    init(relativePath: String, sitting: ExamSitting) {
        self.relativePath = relativePath
        self.sitting = sitting
    }
}

@Model
final class InventoryItem {
    var title: String
    var kind: String
    var sourceSecond: Int
    var isAssignment: Bool
    var sourceBlockID: UUID
    var course: Course?

    init(
        course: Course,
        title: String,
        kind: InventoryKind,
        sourceSecond: Int,
        isAssignment: Bool,
        sourceBlockID: UUID
    ) {
        self.course = course
        self.title = title
        self.kind = kind.rawValue
        self.sourceSecond = sourceSecond
        self.isAssignment = isAssignment
        self.sourceBlockID = sourceBlockID
    }
}

@Model
final class CourseFile {
    var relativePath: String
    var displayName: String
    var kind: String
    var inventoryID: UUID?
    var assignmentID: UUID?
    var lectureID: UUID?
    var second: Int?
    var course: Course?

    @Relationship(deleteRule: .cascade, inverse: \PagePair.file)
    var pagePairs: [PagePair]

    init(course: Course, relativePath: String, displayName: String, kind: CourseFileKind) {
        self.course = course
        self.relativePath = relativePath
        self.displayName = displayName
        self.kind = kind.rawValue
        self.pagePairs = []
    }
}

@Model
final class PagePair {
    var topic: String
    var page: Int
    var file: CourseFile?

    init(topic: String, page: Int, file: CourseFile) {
        self.topic = topic
        self.page = page
        self.file = file
    }
}

@Model
final class BoardPhoto {
    var relativePath: String
    var second: Int
    var lecture: Lecture?

    init(relativePath: String, second: Int, lecture: Lecture) {
        self.relativePath = relativePath
        self.second = second
        self.lecture = lecture
    }
}

@Model
final class LectureGap {
    var day: Date
    var mark: String
    var courseID: UUID
    var slotID: UUID

    init(day: Date, mark: GapMark, courseID: UUID, slotID: UUID) {
        self.day = day
        self.mark = mark.rawValue
        self.courseID = courseID
        self.slotID = slotID
    }
}

@Model
final class DrillCursor {
    var courseID: UUID
    var filterKey: String
    var index: Int

    init(courseID: UUID, filterKey: String, index: Int = 0) {
        self.courseID = courseID
        self.filterKey = filterKey
        self.index = index
    }
}
