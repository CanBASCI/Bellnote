import Foundation
import SwiftData

enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        Term.self,
        Course.self,
        LecturerContact.self,
        WeeklySlot.self,
        SlotException.self,
        CancelledWeek.self,
        Lecture.self,
        PauseSegment.self,
        Attestation.self,
        Block.self,
        NoteLink.self,
        Assignment.self,
        QuizAttempt.self,
        Voiceprint.self,
        TopicAlias.self,
        ExamSitting.self,
        ExamPaperPhoto.self,
        InventoryItem.self,
        CourseFile.self,
        StickyNote.self,
        PagePair.self,
        BoardPhoto.self,
        LectureGap.self,
        DrillCursor.self
    ]

    static func container(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
