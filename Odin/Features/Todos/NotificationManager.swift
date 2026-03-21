import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()

    private var hasRequestedPermission = false

    private init() {}

    private func ensurePermission(completion: @escaping (Bool) -> Void) {
        if hasRequestedPermission {
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                completion(settings.authorizationStatus == .authorized)
            }
            return
        }
        hasRequestedPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("Notification permission error: \(error.localizedDescription)")
            }
            completion(granted)
        }
    }

    func scheduleReminder(id: String, title: String, body: String?, date: Date) {
        ensurePermission { granted in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            if let body {
                content.body = body
            }
            content.sound = .default

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: date
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    print("Failed to schedule notification: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelReminder(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    func cancelAllReminders() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
