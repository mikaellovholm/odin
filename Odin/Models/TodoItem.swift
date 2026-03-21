import Foundation
import SwiftData

@Model
final class TodoItem {
    var id: UUID = UUID()
    var title: String = ""
    var isCompleted: Bool = false
    var notes: String = ""
    var createdAt: Date = Date()
    var dueDate: Date?
    var reminderDate: Date?
    var notificationID: String?
    var sortOrder: Int = 0

    init(title: String, notes: String = "", dueDate: Date? = nil) {
        self.id = UUID()
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.createdAt = Date()
    }
}
