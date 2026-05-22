import SwiftUI
import SwiftData

struct TodoListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TodoItem.sortOrder) private var todos: [TodoItem]
    @State private var showingAddSheet = false
    @State private var editingTodo: TodoItem?
    #if os(macOS)
    /// Keyboard-focused todo. Drives List's native selection highlight and is
    /// the target of ↩ / → "open" actions.
    @State private var selectedTodo: TodoItem?
    @FocusState private var listFocused: Bool
    #endif

    private var incompleteTodos: [TodoItem] {
        todos.filter { !$0.isCompleted }
    }

    private var completedTodos: [TodoItem] {
        todos.filter { $0.isCompleted }
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    // MARK: - macOS

    #if os(macOS)
    /// Matches the Notes / Claude Sessions layout: custom in-pane header with
    /// the `+` button beside the title, no window toolbar chrome.
    private var macBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            todoList
                .overlay { emptyOverlay }
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
        .onAppear {
            // Seed selection so ↑/↓/↩ work immediately without a click first.
            if selectedTodo == nil {
                selectedTodo = incompleteTodos.first ?? completedTodos.first
            }
            listFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Todos")
                .font(.headline)
            Spacer()
            CloudKitSyncStatusView()
            Button { showingAddSheet = true } label: {
                Image(systemName: "plus")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("New todo (⌘N)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if todos.isEmpty {
            ContentUnavailableView(
                "No Todos",
                systemImage: "checklist",
                description: Text("Click + to add a todo")
            )
        }
    }
    #endif

    // MARK: - iOS

    #if !os(macOS)
    private var iosBody: some View {
        NavigationStack {
            todoList
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
                }
                .sheet(isPresented: $showingAddSheet) {
                    TodoDetailView()
                }
                .sheet(item: $editingTodo) { todo in
                    TodoDetailView(existingTodo: todo)
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
    #endif

    // MARK: - Shared

    private var todoList: some View {
        #if os(macOS)
        macTodoList
        #else
        iosTodoList
        #endif
    }

    #if os(macOS)
    /// macOS: List(selection:) gives native ↑/↓ arrow navigation. ↩ and →
    /// open the focused todo. Single click both selects and opens — keeping
    /// the old click-to-open behavior intact, while seeding `selectedTodo`
    /// so subsequent arrow nav continues from where the user clicked.
    private var macTodoList: some View {
        List(selection: $selectedTodo) {
            Section {
                ForEach(incompleteTodos) { todo in
                    TodoRowView(todo: todo)
                        .tag(todo)
                        .onTapGesture {
                            selectedTodo = todo
                            editingTodo = todo
                        }
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
                            .tag(todo)
                            .onTapGesture {
                                selectedTodo = todo
                                editingTodo = todo
                            }
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
        .focused($listFocused)
        .onKeyPress(.return) { openSelection() }
        .onKeyPress(.rightArrow) { openSelection() }
        .onKeyPress(.space) { toggleSelectionCompleted() }
    }

    private func openSelection() -> KeyPress.Result {
        guard let selectedTodo else { return .ignored }
        editingTodo = selectedTodo
        return .handled
    }

    private func toggleSelectionCompleted() -> KeyPress.Result {
        guard let selectedTodo else { return .ignored }
        withAnimation {
            selectedTodo.isCompleted.toggle()
        }
        return .handled
    }
    #endif

    #if !os(macOS)
    private var iosTodoList: some View {
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
    }
    #endif

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
