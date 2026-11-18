import Foundation
import Observation

/// One kind of notification Bellnote can send. Every kind is off until the student switches it on in Settings.
/// A switch in a course or exam sheet turns its kind on too, because that is the same decision made where it matters.
enum NotificationKind: String, CaseIterable, Identifiable {
    case classStart
    case exam
    case noteReady

    var id: String { rawValue }

    /// The `UserDefaults` key. Settings reads it with `@AppStorage`, so a change made in a sheet shows there at once.
    var key: String { "notify.\(rawValue)" }

    var isOn: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    /// False until the student has chosen once, for this kind. Tells an untouched default from an off switch.
    var isUnset: Bool {
        UserDefaults.standard.object(forKey: key) == nil
    }

    func setOn(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
    }

    /// The prefix of the request identifiers this kind uses, to clear them when the switch goes off.
    /// Note-ready requests fire after one second and are not pending for long, so they have none.
    var identifierPrefix: String? {
        switch self {
        case .classStart: "slot."
        case .exam: "exam."
        case .noteReady: nil
        }
    }
}

/// The most "note ready" notifications in one day. A day of long recordings finished in a row stays quiet after these.
enum NotificationQuota {
    static let noteReadyPerDay = 3
    private static let dayKey = "notify.noteReady.day"
    private static let countKey = "notify.noteReady.count"

    /// True and counted when one more may be sent today.
    static func takeNoteReady(now: Date = .now, defaults: UserDefaults = .standard) -> Bool {
        let today = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        if defaults.double(forKey: dayKey) != today {
            defaults.set(today, forKey: dayKey)
            defaults.set(0, forKey: countKey)
        }
        let count = defaults.integer(forKey: countKey)
        guard count < noteReadyPerDay else { return false }
        defaults.set(count + 1, forKey: countKey)
        return true
    }
}

/// Where a tapped notification should open. A notification carries only the course it belongs to, as an id.
/// The home screen reads this, opens that course, and clears it. A tap that arrives while the app is locked or
/// closed waits here until the home screen exists.
@MainActor
@Observable
final class NotificationRouter {
    static let shared = NotificationRouter()

    /// The `Course.token` of the course to open.
    var pendingCourse: UUID?

    /// The key of the course id in a notification's `userInfo`.
    nonisolated static let courseKey = "course"

    private init() {}
}
