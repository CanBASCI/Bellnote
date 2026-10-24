import Foundation
import os
import SwiftData
import UserNotifications

enum ReminderScheduler {
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
        guard kind != ReminderKind.none else { return }
        let content = UNMutableNotificationContent()
        content.title = courseName
        content.body = String(localized: "Starts \(Self.clock(slot.startMinutes)).")
        if kind == .alert {
            content.sound = .default
        }
        var components = DateComponents()
        components.weekday = slot.weekday
        let fire = max(0, slot.startMinutes - slot.leadMinutes)
        components.hour = fire / 60
        components.minute = fire % 60
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request)
    }

    static func replaceExam(_ sitting: ExamSitting, courseName: String) {
        let center = UNUserNotificationCenter.current()
        let id = "exam.\(sitting.token.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let kind = ReminderKind(rawValue: sitting.reminderKind) ?? ReminderKind.none
        guard let date = sitting.date, kind != ReminderKind.none else { return }
        let content = UNMutableNotificationContent()
        let examKind = sitting.kind
        content.title = courseName
        content.body = String(localized: "\(examKind) \(date.formatted(date: .abbreviated, time: .omitted))")
        if kind == .alert {
            content.sound = .default
        }
        let lead = sitting.leadDays
        let fire = Calendar.current.date(byAdding: .day, value: -lead, to: date) ?? date
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func notifyReady(course: String, startedAt: Date) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = course
        content.body = String(localized: "Note ready \(startedAt.formatted(date: .abbreviated, time: .shortened))")
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
