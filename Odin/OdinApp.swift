import SwiftUI
import SwiftData

@main
struct OdinApp: App {
    let container: ModelContainer
    #if os(macOS)
    @State private var selectedTab: AppTab = .claude
    @State private var claudeSessionStore = ClaudeSessionStore()
    #else
    @State private var selectedTab: AppTab = .todos
    #endif

    init() {
        do {
            let schema = Schema([TodoItem.self, Note.self])
            let config = ModelConfiguration(
                schema: schema,
                cloudKitDatabase: .automatic
            )
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        #if os(macOS)
        Task { @MainActor in
            OdinSkillInstaller.install()
            OdinHookInstaller.install()
            do {
                try OdinMCPServer.shared.start()
            } catch {
                NSLog("[OdinMCP] failed to start server: \(error)")
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ThemedContainer {
                ContentView(selectedTab: $selectedTab)
                #if os(macOS)
                    .environment(claudeSessionStore)
                    .task { claudeSessionStore.loadPersisted() }
                    // Force the NSWindow opaque — without this, the system
                    // window can pick up translucency from materials inside
                    // it (e.g. `.listStyle(.sidebar)`'s vibrant background)
                    // and show whatever is behind the app through the panel.
                    .background(OpaqueWindowAccessor())
                #endif
            }
        }
        .modelContainer(container)
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .newItem) {
                /// ⌘N is context-sensitive: the title and effect track
                /// `selectedTab` so a single shortcut creates a new item in
                /// whichever pane is showing. Disabled on Terminal (no
                /// "new" concept there).
                Button(newItemTitle) { performNewItem() }
                    .keyboardShortcut("n", modifiers: [.command])
                    .disabled(selectedTab == .terminal)
            }
            CommandMenu("Go") {
                Button("Claude") { selectedTab = .claude }
                    .keyboardShortcut("1", modifiers: .control)
                Button("Terminal") { selectedTab = .terminal }
                    .keyboardShortcut("2", modifiers: .control)
                Button("Notes") { selectedTab = .notes }
                    .keyboardShortcut("3", modifiers: .control)
                Button("Todos") { selectedTab = .todos }
                    .keyboardShortcut("4", modifiers: .control)
            }
        }
        #endif

        #if os(macOS)
        Settings {
            ThemedContainer {
                SettingsView()
            }
        }
        #endif
    }

    #if os(macOS)
    private var newItemTitle: String {
        switch selectedTab {
        case .claude:   return "New Claude Session"
        case .notes:    return "New Note"
        case .todos:    return "New Todo"
        case .terminal: return "New"
        }
    }

    private func performNewItem() {
        switch selectedTab {
        case .claude:
            NotificationCenter.default.post(name: .odinCreateNewClaudeSession, object: nil)
        case .notes:
            NotificationCenter.default.post(name: .odinCreateNewNote, object: nil)
        case .todos:
            NotificationCenter.default.post(name: .odinCreateNewTodo, object: nil)
        case .terminal:
            break
        }
    }
    #endif
}
