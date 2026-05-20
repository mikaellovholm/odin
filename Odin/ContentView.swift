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
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var macBody: some View {
        VStack(spacing: 0) {
            MacTabBar(selectedTab: $selectedTab)
            ZStack {
                switch selectedTab {
                case .claude:   ClaudeSessionListView()
                case .terminal: TerminalContainerView(selectedTab: $selectedTab)
                case .notes:    NoteListView()
                case .todos:    TodoListView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    #else
    @ViewBuilder
    private var iosBody: some View {
        TabView(selection: $selectedTab) {
            Tab("Terminal", systemImage: "terminal", value: AppTab.terminal) {
                TerminalContainerView(selectedTab: $selectedTab)
            }
            Tab("Notes", systemImage: "note.text", value: AppTab.notes) {
                NoteListView()
            }
            Tab("Todos", systemImage: "checklist", value: AppTab.todos) {
                TodoListView()
            }
        }
    }
    #endif
}

#if os(macOS)
private struct MacTabItemData: Identifiable {
    let id: AppTab
    let label: String
    let icon: String
    let shortcut: String
}

private let macTabItems: [MacTabItemData] = [
    .init(id: .claude,   label: "Claude",   icon: "brain",     shortcut: "⌃1"),
    .init(id: .terminal, label: "Terminal", icon: "terminal.fill", shortcut: "⌃2"),
    .init(id: .notes,    label: "Notes",    icon: "note.text", shortcut: "⌃3"),
    .init(id: .todos,    label: "Todos",    icon: "checklist", shortcut: "⌃4"),
]

private struct MacTabBar: View {
    @Binding var selectedTab: AppTab
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 24) {
            ForEach(macTabItems) { item in
                MacTabItem(
                    item: item,
                    isSelected: selectedTab == item.id,
                    namespace: underline
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTab = item.id
                    }
                }
            }
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }
}

private struct MacTabItem: View {
    let item: MacTabItemData
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .medium))
                Text(item.label)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                Text(item.shortcut)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .matchedGeometryEffect(id: "underline", in: namespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var textColor: Color {
        if isSelected { return .primary }
        if hovering { return .primary.opacity(0.85) }
        return .secondary
    }
}
#endif
