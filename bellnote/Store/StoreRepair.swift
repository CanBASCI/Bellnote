import Foundation
import OSLog
import SwiftData

/// Fixes rows that an older build left behind, before any screen reads them.
enum StoreRepair {
    private static let log = Logger(subsystem: "app.bellnote", category: "store")

    /// A weekly slot points at its course with no inverse on the course, so deleting a course used to leave its
    /// slots behind, still pointing at a row that was gone. Reading that course's name then stopped the app.
    /// This removes those slots. It compares ids only and never reads a property of the missing course.
    @MainActor
    static func removeSlotsOfDeletedCourses(in context: ModelContext) {
        do {
            let courseIDs = Set(try context.fetch(FetchDescriptor<Course>()).map(\.persistentModelID))
            let slots = try context.fetch(FetchDescriptor<WeeklySlot>())
            var removed = 0
            for slot in slots {
                guard let course = slot.course else { continue }
                if !courseIDs.contains(course.persistentModelID) {
                    ReminderScheduler.removeSlot(slot)
                    context.delete(slot)
                    removed += 1
                }
            }
            guard removed > 0 else { return }
            try context.save()
            log.info("Removed \(removed) slots of deleted courses")
        } catch {
            log.error("Store repair failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
