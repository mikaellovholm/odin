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
    @State private var claudeFinished = false
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
            Tab(value: .claude) {
                ClaudeTerminalContainerView(viewModel: claudeViewModel)
            } label: {
                let title = if claudeViewModel.isActive {
                    "Claude ⬤"
                } else if claudeFinished {
                    "Claude ✓"
                } else {
                    "Claude"
                }
                Label(title, systemImage: "brain")
            }
            #endif
        }
        #if os(macOS)
        .onChange(of: claudeViewModel.isActive) { old, new in
            if old && !new {
                claudeFinished = true
            }
        }
        .onChange(of: selectedTab) {
            if selectedTab == .claude {
                claudeFinished = false
            }
        }
        #endif
    }
}
