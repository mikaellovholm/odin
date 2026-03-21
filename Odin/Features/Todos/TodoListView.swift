import SwiftUI
import SwiftData

struct TodoListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TodoItem.sortOrder) private var todos: [TodoItem]
    @State private var showingAddSheet = false

    private var incompleteTodos: [TodoItem] {
        todos.filter { !$0.isCompleted }
    }

    private var completedTodos: [TodoItem] {
        todos.filter { $0.isCompleted }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(incompleteTodos) { todo in
                        TodoRowView(todo: todo)
                    }
                    .onDelete { offsets in
                        deleteTodos(from: incompleteTodos, at: offsets)
                    }
                }

                if !completedTodos.isEmpty {
                    Section("Completed") {
                        ForEach(completedTodos) { todo in
                            TodoRowView(todo: todo)
                        }
                        .onDelete { offsets in
                            deleteTodos(from: completedTodos, at: offsets)
                        }
                    }
                }
            }
            .navigationTitle("Todos")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                TodoDetailView()
            }
            .overlay {
                if todos.isEmpty {
                    ContentUnavailableView(
                        "No Todos",
                        systemImage: "checklist",
                        description: Text("Tap + to add a todo")
                    )
                }
            }
        }
    }

    private func deleteTodos(from list: [TodoItem], at offsets: IndexSet) {
        for index in offsets {
            let todo = list[index]
            if let notificationID = todo.notificationID {
                NotificationManager.shared.cancelReminder(id: notificationID)
            }
            modelContext.delete(todo)
        }
    }
}
