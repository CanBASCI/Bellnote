import Foundation
import SwiftData

/// Deleting one recording. The course, the timetable and the other recordings stay.
enum LectureRemoval {
    /// A recording that is being processed cannot be deleted, the run still writes to it.
    @MainActor
    static func canDelete(_ lecture: Lecture) -> Bool {
        !PipelineActivity.shared.isRunning(lecture)
    }

    /// Removes the audio and the board photos, then the note, the assignments from this
    /// recording, and the links of other recordings that point at it. Files go first, so a file
    /// that cannot be removed keeps the recording and the error reaches the student.
    @MainActor
    static func delete(_ lecture: Lecture, context: ModelContext) throws {
        guard canDelete(lecture) else { return }
        let root = try Vault.documents()
        let paths = [lecture.audioRelativePath].compactMap { $0 } + lecture.boardPhotos.map(\.relativePath)
        for path in paths {
            let url = root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        let blockIDs = Set(lecture.blocks.map(\.token))
        if let course = lecture.course {
            for assignment in course.assignments where blockIDs.contains(assignment.sourceBlockID) {
                context.delete(assignment)
            }
            for other in course.lectures where other !== lecture {
                for block in other.blocks {
                    for link in block.outgoing {
                        if let target = link.toBlockID, blockIDs.contains(target) {
                            context.delete(link)
                        }
                    }
                }
            }
        }
        context.delete(lecture)
        try context.save()
    }
}
