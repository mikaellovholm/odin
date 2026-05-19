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
            Tab(tabTitle("Claude", shortcut: "⌃1"), systemImage: "brain", value: .claude) {
                ClaudeSessionListView()
            }
            #endif
            Tab(tabTitle("Terminal", shortcut: "⌃2"), systemImage: "terminal", value: .terminal) {
                TerminalContainerView(selectedTab: $selectedTab)
            }
            Tab(tabTitle("Notes", shortcut: "⌃3"), systemImage: "note.text", value: .notes) {
                NoteListView()
            }
            Tab(tabTitle("Todos", shortcut: "⌃4"), systemImage: "checklist", value: .todos) {
                TodoListView()
            }
        }
    }

    private func tabTitle(_ name: String, shortcut: String) -> String {
        #if os(macOS)
        return "\(name)  \(shortcut)"
        #else
        return name
        #endif
    }
}
