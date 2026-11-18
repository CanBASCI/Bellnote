import Foundation
import os
import SwiftData
import UserNotifications

enum ReminderScheduler {
    /// 09:00. When day-ahead exam reminders arrive.
    private static let morningMinutes = 9 * 60

    /// Sets every class and exam reminder again, for the kinds that are on. Call it when the app opens, and when a kind
    /// is switched on. Reminders saved before the hour was chosen would otherwise still fire at midnight.
    static func resync(context: ModelContext) {
        let log = Logger(subsystem: "app.bellnote", category: "notify")
        do {
            let sittings = try context.fetch(FetchDescriptor<ExamSitting>())
            // Exam reminders saved before there was a switch keep working: their kind starts on.
            if NotificationKind.exam.isUnset,
               sittings.contains(where: { $0.reminderKind != ReminderKind.none.rawValue }) {
                NotificationKind.exam.setOn(true)
            }
            for sitting in sittings where sitting.date != nil && sitting.reminderKind != ReminderKind.none.rawValue {
                replaceExam(sitting, courseName: sitting.course?.name ?? "")
            }
        } catch {
            log.error("Exam reminders could not be set again: \(error.localizedDescription, privacy: .public)")
        }
        do {
            let slots = try context.fetch(FetchDescriptor<WeeklySlot>())
            for slot in slots where slot.reminderKind != ReminderKind.none.rawValue {
                replaceSlot(slot, courseName: slot.course?.name ?? "")
            }
        } catch {
            log.error("Class reminders could not be set again: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes every pending request of one kind. Used when its switch goes off.
    static func removeAll(_ kind: NotificationKind) async {
        guard let prefix = kind.identifierPrefix else { return }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// What a tap on the notification opens: the course it belongs to.
    private static func routing(_ course: Course?) -> [AnyHashable: Any] {
        routing(token: course?.token)
    }

    private static func routing(token: UUID?) -> [AnyHashable: Any] {
        guard let token else { return [:] }
        return [NotificationRouter.courseKey: token.uuidString]
    }

    static func askPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Logger(subsystem: "app.bellnote", category: "notify").error("Notification permission failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func replaceSlot(_ slot: WeeklySlot, courseName: String) {
        let center = UNUserNotificationCenter.current()
        let identifier = "slot.\(slot.token.uuidString).weekly"
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let kind = ReminderKind(rawValue: slot.reminderKind) ?? ReminderKind.none
        guard kind != ReminderKind.none, NotificationKind.classStart.isOn else { return }
        // Only the course name and the time. Never a note.
        let content = UNMutableNotificationContent()
        content.title = courseName
        let fire = max(0, slot.startMinutes - slot.leadMinutes)
        let lead = slot.startMinutes - fire
        let start = Self.clock(slot.startMinutes)
        content.body = lead >= 2
            ? String(localized: "Starts in \(lead) minutes · \(start)")
            : String(localized: "Starting now · \(start)")
        content.userInfo = routing(slot.course)
        if kind == .alert {
            content.sound = .default
        }
        var components = DateComponents()
        components.weekday = slot.weekday
        components.hour = fire / 60
        components.minute = fire % 60
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request)
    }

    /// Drops the weekly reminder of a time that is deleted, so it never fires for a class that is gone.
    static func removeSlot(_ slot: WeeklySlot) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["slot.\(slot.token.uuidString).weekly"])
    }

    static func replaceExam(_ sitting: ExamSitting, courseName: String) {
        let center = UNUserNotificationCenter.current()
        let id = "exam.\(sitting.token.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let kind = ReminderKind(rawValue: sitting.reminderKind) ?? ReminderKind.none
        guard let date = sitting.date, kind != ReminderKind.none, NotificationKind.exam.isOn else { return }
        // Only the course name, the exam name and when it is. Never a note.
        let content = UNMutableNotificationContent()
        content.title = courseName
        content.userInfo = routing(sitting.course)
        content.body = Self.examBody(sitting, date: date)
        if kind == .alert {
            content.sound = .default
        }
        let lead = sitting.leadDays
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -lead, to: date) ?? date
        // The exam date is stored as the start of its day, so the hour must be chosen here. A reminder some days
        // ahead comes in the morning. One for the exam day itself comes an hour before the exam when its time is
        // known, and in the morning otherwise.
        let minutes: Int
        if lead == 0, let start = sitting.startMinutes {
            minutes = max(start - 60, 0)
        } else {
            minutes = Self.morningMinutes
        }
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = minutes / 60
        parts.minute = minutes % 60
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// "Midterm in 3 days · Nov 20", "Final tomorrow · 10:00", "Midterm today". Plain, and only the exam and its time.
    private static func examBody(_ sitting: ExamSitting, date: Date) -> String {
        let title = sitting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        switch ExamKind(rawValue: sitting.kind) {
        case .midterm: name = ExamKind.midterm.title
        case .final: name = ExamKind.final.title
        case .other: name = title.isEmpty ? String(localized: "Exam") : title
        case nil: name = String(localized: "Exam")
        }
        let start = sitting.startMinutes.map { Self.clock($0) }
        switch sitting.leadDays {
        case ...0:
            if let start { return String(localized: "\(name) in an hour · \(start)") }
            return String(localized: "\(name) today")
        case 1:
            if let start { return String(localized: "\(name) tomorrow · \(start)") }
            return String(localized: "\(name) tomorrow")
        default:
            let day = date.formatted(.dateTime.day().month(.abbreviated))
            return String(localized: "\(name) in \(sitting.leadDays) days · \(day)")
        }
    }

    static func notifyReady(courseName: String, courseToken: UUID, startedAt: Date) async {
        guard NotificationKind.noteReady.isOn else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }
        // A few a day at most, so a day of long recordings does not turn into a stream of them.
        guard NotificationQuota.takeNoteReady() else { return }
        // Only the course name and when the lecture was. Never a line of the note.
        let content = UNMutableNotificationContent()
        content.title = courseName
        let when = startedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        content.body = String(localized: "Your note is ready · \(when)")
        content.userInfo = routing(token: courseToken)
        content.interruptionLevel = .passive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "ready.\(startedAt.timeIntervalSince1970)",
            content: content,
            trigger: trigger
        )
        do {
            try await center.add(request)
        } catch {
            Logger(subsystem: "app.bellnote", category: "notify").error("Ready notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func clock(_ minutes: Int) -> String {
        var parts = DateComponents()
        parts.hour = minutes / 60
        parts.minute = minutes % 60
        let date = Calendar.current.date(from: parts) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}
