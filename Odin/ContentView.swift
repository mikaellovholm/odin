import SwiftUI

enum AppTab: Hashable {
    #if os(macOS)
    case claude
    #endif
    case terminal, notes, todos
}

struct ContentView: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        TabView(selection: $selectedTab) {
            #if os(macOS)
            Tab("Claude", systemImage: "brain", value: .claude) {
                ClaudeSessionListView()
            }
            #endif
            Tab("Terminal", systemImage: "terminal", value: .terminal) {
                TerminalContainerView(selectedTab: $selectedTab)
            }
            Tab("Notes", systemImage: "note.text", value: .notes) {
                NoteListView()
            }
            Tab("Todos", systemImage: "checklist", value: .todos) {
                TodoListView()
            }
        }
    }
}
