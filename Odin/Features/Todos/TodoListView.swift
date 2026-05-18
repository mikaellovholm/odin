import SwiftUI
import SwiftData

struct TodoListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TodoItem.sortOrder) private var todos: [TodoItem]
    @State private var showingAddSheet = false
    @State private var editingTodo: TodoItem?
    #if os(iOS)
    @State private var showingSettings = false
    #endif

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
                            .onTapGesture { editingTodo = todo }
                    }
                    .onDelete { offsets in
                        deleteTodos(from: incompleteTodos, at: offsets)
                    }
                    .onMove { source, destination in
                        moveTodos(from: source, to: destination)
                    }
                }

                if !completedTodos.isEmpty {
                    Section {
                        ForEach(completedTodos) { todo in
                            TodoRowView(todo: todo)
                                .onTapGesture { editingTodo = todo }
                        }
                        .onDelete { offsets in
                            deleteTodos(from: completedTodos, at: offsets)
                        }
                    } header: {
                        HStack {
                            Text("Completed")
                            Spacer()
                            Button("Clear") {
                                clearCompleted()
                            }
                            .font(.caption)
                            .textCase(nil)
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
                ToolbarItem(placement: .automatic) {
                    CloudKitSyncStatusView()
                }
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
                #endif
            }
            .sheet(isPresented: $showingAddSheet) {
                TodoDetailView()
            }
            .sheet(item: $editingTodo) { todo in
                TodoDetailView(existingTodo: todo)
            }
            .onReceive(NotificationCenter.default.publisher(for: .odinCreateNewTodo)) { _ in
                showingAddSheet = true
            }
            #if os(iOS)
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingSettings = false }
                            }
                        }
                }
            }
            #endif
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

    private func moveTodos(from source: IndexSet, to destination: Int) {
        var items = incompleteTodos
        items.move(fromOffsets: source, toOffset: destination)
        for (index, item) in items.enumerated() {
            item.sortOrder = index
        }
    }

    private func clearCompleted() {
        for todo in completedTodos {
            if let notificationID = todo.notificationID {
                NotificationManager.shared.cancelReminder(id: notificationID)
            }
            modelContext.delete(todo)
        }
    }
}
