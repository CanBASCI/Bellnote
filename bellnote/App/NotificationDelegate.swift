import UIKit
import UserNotifications

/// Receives notification taps. The delegate must be set before the app finishes launching, or a tap that
/// starts the app is dropped.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// A notification that arrives while the app is open still shows as a banner.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A tap opens the course the notification belongs to.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info[NotificationRouter.courseKey] as? String, let token = UUID(uuidString: raw) else { return }
        await MainActor.run {
            NotificationRouter.shared.pendingCourse = token
        }
    }
}
