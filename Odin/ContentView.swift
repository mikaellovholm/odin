import SwiftUI

enum AppTab: Hashable {
    case todos, notes, terminal
    #if os(macOS)
    case claude
    #endif
}

struct ContentView: View {
    @State private var selectedTab: AppTab = .todos
    #if os(macOS)
    @State private var claudeViewModel = LocalTerminalViewModel()
    #endif

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
            #if os(macOS)
            Tab("Claude", systemImage: claudeViewModel.isActive ? "brain.head.profile.fill" : "brain", value: .claude) {
                ClaudeTerminalContainerView(viewModel: claudeViewModel)
            }
            #endif
        }
    }
}
