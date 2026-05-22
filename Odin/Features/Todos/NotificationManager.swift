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
                NSLog("[Odin] notification permission error: \(error.localizedDescription)")
                NotificationManager.recordDiagnosticsFailure(
                    "Permission request failed: \(error.localizedDescription)"
                )
            } else if !granted {
                NotificationManager.recordDiagnosticsFailure(
                    "Reminders disabled — enable notifications for Odin in System Settings."
                )
            } else {
                NotificationManager.recordDiagnosticsOK()
            }
            completion(granted)
        }
    }

    /// Hop to MainActor to write the diagnostics singleton. NotificationManager
    /// itself isn't actor-isolated (it's a thin wrapper around an Apple API
    /// whose callbacks fire on private queues), so we marshal on demand.
    private static func recordDiagnosticsFailure(_ message: String) {
        Task { @MainActor in
            OdinDiagnostics.shared.notifications = .failed(message)
        }
    }

    private static func recordDiagnosticsOK() {
        Task { @MainActor in
            OdinDiagnostics.shared.notifications = .ok
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
                    NSLog("[Odin] failed to schedule notification: \(error.localizedDescription)")
                    NotificationManager.recordDiagnosticsFailure(
                        "Failed to schedule reminder: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    func cancelReminder(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}
