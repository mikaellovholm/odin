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
            Tab(value: AppTab.claude) {
                ClaudeSessionListView()
            } label: {
                Label {
                    tabTitleText("Claude", shortcut: "⌃1")
                } icon: {
                    Image(systemName: "brain")
                }
            }
            Tab(value: AppTab.terminal) {
                TerminalContainerView(selectedTab: $selectedTab)
            } label: {
                Label {
                    tabTitleText("Terminal", shortcut: "⌃2")
                } icon: {
                    Image(systemName: "terminal")
                }
            }
            Tab(value: AppTab.notes) {
                NoteListView()
            } label: {
                Label {
                    tabTitleText("Notes", shortcut: "⌃3")
                } icon: {
                    Image(systemName: "note.text")
                }
            }
            Tab(value: AppTab.todos) {
                TodoListView()
            } label: {
                Label {
                    tabTitleText("Todos", shortcut: "⌃4")
                } icon: {
                    Image(systemName: "checklist")
                }
            }
            #else
            Tab("Terminal", systemImage: "terminal", value: AppTab.terminal) {
                TerminalContainerView(selectedTab: $selectedTab)
            }
            Tab("Notes", systemImage: "note.text", value: AppTab.notes) {
                NoteListView()
            }
            Tab("Todos", systemImage: "checklist", value: AppTab.todos) {
                TodoListView()
            }
            #endif
        }
    }

    #if os(macOS)
    private func tabTitleText(_ name: String, shortcut: String) -> Text {
        var attr = AttributedString("\(name)  ")
        var shortcutAttr = AttributedString(shortcut)
        shortcutAttr.foregroundColor = .secondary
        attr.append(shortcutAttr)
        return Text(attr)
    }
    #endif
}
