import SwiftUI
import SwiftData

struct TodoDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var existingTodo: TodoItem?

    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var hasDueDate: Bool = false
    @State private var dueDate: Date = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)
    @State private var hasReminder: Bool = false
    @State private var reminderDate: Date = Date().addingTimeInterval(3600)

    private var isEditing: Bool { existingTodo != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    Toggle("Due date", isOn: $hasDueDate.animation())
                    if hasDueDate {
                        DatePicker("Date", selection: $dueDate, displayedComponents: .date)
                    }
                }

                Section {
                    Toggle("Reminder", isOn: $hasReminder.animation())
                    if hasReminder {
                        DatePicker("When", selection: $reminderDate)
                    }
                }

                if isEditing {
                    Section {
                        Button("Delete Todo", role: .destructive) {
                            if let todo = existingTodo {
                                if let notificationID = todo.notificationID {
                                    NotificationManager.shared.cancelReminder(id: notificationID)
                                }
                                modelContext.delete(todo)
                            }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Todo" : "New Todo")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let todo = existingTodo {
                    title = todo.title
                    notes = todo.notes
                    hasDueDate = todo.dueDate != nil
                    if let d = todo.dueDate { dueDate = d }
                    hasReminder = todo.reminderDate != nil
                    if let r = todo.reminderDate { reminderDate = r }
                }
            }
        }
    }

    private func save() {
        let todo = existingTodo ?? TodoItem(title: "")
        todo.title = title.trimmingCharacters(in: .whitespaces)
        todo.notes = notes
        todo.dueDate = hasDueDate ? dueDate : nil
        todo.reminderDate = hasReminder ? reminderDate : nil

        if !isEditing {
            modelContext.insert(todo)
        }

        // Handle notifications
        if let oldID = todo.notificationID {
            NotificationManager.shared.cancelReminder(id: oldID)
            todo.notificationID = nil
        }

        if hasReminder {
            let notifID = UUID().uuidString
            todo.notificationID = notifID
            NotificationManager.shared.scheduleReminder(
                id: notifID,
                title: todo.title,
                body: todo.notes.isEmpty ? nil : todo.notes,
                date: reminderDate
            )
        }
    }
}
