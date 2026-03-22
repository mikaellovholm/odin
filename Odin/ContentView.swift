import SwiftUI

enum AppTab: Hashable {
    case todos, notes, terminal
}

struct ContentView: View {
    @State private var selectedTab: AppTab = .todos

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Todos", systemImage: "checklist", value: .todos) {
                TodoListView()
            }
            Tab("Notes", systemImage: "note.text", value: .notes) {
                NoteListView()
            }
            Tab("Terminal", systemImage: "terminal", value: .terminal) {
                TerminalContainerView(selectedTab: $selectedTab)
            }
        }
    }
}
