import Foundation
import UserNotifications

/// Thin wrapper over `UNUserNotificationCenter`.
///
/// Authorization is requested once at launch and the result cached, because a
/// denied prompt must not re-ask on every agent event. When notifications are
/// unavailable the app degrades silently — cards are the primary surface, the
/// banners are a convenience.
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private var authorized = false

    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                Task { @MainActor in self.authorized = granted }
            }
    }

    func notify(title: String, body: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Silent on purpose: SoundSettings plays the alert itself, so attaching
        // a sound here would double every notification.
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
