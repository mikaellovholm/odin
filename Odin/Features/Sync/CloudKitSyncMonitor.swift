import SwiftUI
import CoreData

/// Observes `NSPersistentCloudKitContainer.eventChangedNotification` and
/// surfaces the most recent sync error to SwiftUI. SwiftData uses
/// NSPersistentCloudKitContainer under the hood when `cloudKitDatabase` is
/// `.automatic`, so the same notification still fires.
@MainActor
@Observable
final class CloudKitSyncMonitor {
    static let shared = CloudKitSyncMonitor()

    /// Most recent sync error, if any. Cleared when a later successful event
    /// of the same type arrives.
    private(set) var lastError: String?
    private(set) var lastErrorAt: Date?
    private(set) var isSyncing: Bool = false

    private init() {
        // Singleton — registration outlives the process. No need to remove.
        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handle(notification: notification)
            }
        }
    }

    private func handle(notification: Notification) {
        let key = NSPersistentCloudKitContainer.eventNotificationUserInfoKey
        guard let event = notification.userInfo?[key]
                as? NSPersistentCloudKitContainer.Event else { return }
        if event.endDate == nil {
            isSyncing = true
            return
        }
        isSyncing = false
        if let error = event.error {
            lastError = describe(error)
            lastErrorAt = event.endDate
        } else {
            // Successful event of any type clears the last error so a transient
            // failure doesn't keep the warning lit forever.
            lastError = nil
            lastErrorAt = event.endDate
        }
    }

    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return "\(ns.localizedDescription) (\(underlying.localizedDescription))"
        }
        return ns.localizedDescription
    }
}

/// Small status indicator showing CloudKit sync state. Mount in a toolbar.
/// No icon when everything is healthy and idle.
struct CloudKitSyncStatusView: View {
    @State private var monitor = CloudKitSyncMonitor.shared
    @State private var showingError = false

    var body: some View {
        Group {
            if let error = monitor.lastError {
                Button {
                    showingError = true
                } label: {
                    Image(systemName: "exclamationmark.icloud.fill")
                        .foregroundStyle(.orange)
                }
                .help("iCloud sync error: \(error)")
                .alert("iCloud sync error", isPresented: $showingError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(error)
                }
            } else if monitor.isSyncing {
                ProgressView()
                    .controlSize(.small)
                    .help("Syncing with iCloud…")
            }
        }
    }
}
